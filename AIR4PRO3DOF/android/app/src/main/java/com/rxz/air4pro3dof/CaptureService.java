package com.rxz.air4pro3dof;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;

import java.lang.ref.WeakReference;

/**
 * 投屏捕获服务。
 *
 * Android 14 起：必须先有 foregroundServiceType=mediaProjection 的前台服务，
 * 才能调用 MediaProjectionManager.getMediaProjection()；且必须先 registerCallback 再
 * createVirtualDisplay。这里严格按这个顺序执行。
 *
 * 线程模型：所有涉及 VirtualDisplay 的操作都在主线程排队执行（main handler），
 * GL 线程只通过静态方法投递，不直接碰 VirtualDisplay。
 *
 * 停止通知：MediaProjection 被系统/用户停止时，通过 {@link #stopCallback} 通知
 * MainActivity 触发 stopSession——旧实现只释放虚拟屏，界面还显示"运行中"。
 */
public class CaptureService extends Service {

    private static final String TAG = "CaptureService";
    private static final String CHANNEL = "capture";
    private static final int NOTIF_ID = 71;

    public static final String ACTION_START = "com.rxz.air4pro3dof.START";
    public static final String ACTION_STOP = "com.rxz.air4pro3dof.STOP";
    public static final String EXTRA_RESULT = "result";
    public static final String EXTRA_CODE = "code";

    /** 投屏被系统停止时的回调（MainActivity 注册）。弱引用，避免静态字段锁住 Activity。 */
    public interface OnStopped {
        void onProjectionStopped(String reason);
    }

    private static WeakReference<OnStopped> stopCallbackRef;

    public static void setStopCallback(OnStopped cb) {
        stopCallbackRef = cb == null ? null : new WeakReference<>(cb);
    }

    private static void notifyStopped(String reason) {
        OnStopped cb = stopCallbackRef == null ? null : stopCallbackRef.get();
        if (cb != null) {
            try {
                cb.onProjectionStopped(reason);
            } catch (Throwable t) {
                Log.w(TAG, "stopCallback 异常", t);
            }
        }
    }

    private static volatile CaptureService instance;
    /** GL 线程可能先于服务创建 Surface，这里先兜住，等服务起来再建 VirtualDisplay。 */
    private static volatile Surface pendingSurface;
    private static volatile int pendingW, pendingH;

    /** 当前捕获尺寸（静态：GL 线程要按它算内容宽高比）。 */
    public static volatile int capW, capH;

    /**
     * 独立投屏模式：虚拟屏不再镜像默认屏，而是当作一块"扩展屏"，
     * 由选定的应用渲染自己的界面（通过 Shizuku 的 am start --display 拉起）。
     */
    public static volatile boolean hostedMode;

    /**
     * 我们自己的虚拟屏 displayId。
     * 虚拟屏的创建/销毁会触发 DisplayManager 的 add/remove 回调，
     * 手机端如果不把它排除掉，就会"看到新显示器 → 重挂画面 → 新建虚拟屏 → 再触发事件"无限循环。
     */
    public static volatile int vdDisplayId = -1;

    public static boolean isRunning() {
        return instance != null;
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private MediaProjection projection;
    private VirtualDisplay virtualDisplay;
    private Surface surface;
    private MediaProjection.Callback callback;
    /** 当前 VirtualDisplay 绑定的 Surface 与尺寸，用于幂等判断，避免对同一 projection 反复 createVirtualDisplay。 */
    private Surface boundSurface;
    private int boundW, boundH;

    // ------------------------------------------------------------ 与 GL 线程交接

    /** GL 线程创建好 SurfaceTexture 后调用。 */
    public static void setSurface(Surface s, int w, int h) {
        pendingSurface = s;
        pendingW = w;
        pendingH = h;
        CaptureService svc = instance;
        if (svc != null) {
            svc.main.post(() -> svc.attachSurface(s, w, h));
        } else {
            Log.i(TAG, "setSurface: 服务未启动，已暂存 " + w + "x" + h);
        }
    }

    /** GL 线程销毁 Surface 前调用。 */
    public static void clearSurface(Surface s) {
        if (pendingSurface == s) {
            pendingSurface = null;
        }
        CaptureService svc = instance;
        if (svc != null) {
            svc.main.post(svc::releaseVirtualDisplay);
        }
    }

    private void attachSurface(Surface s, int w, int h) {
        // 尺寸不信任调用方传入的快照（渲染器可能在旧模式下创建），一律按当前模式重算，
        // 否则会出现"检测到竖向 862×1920、实际却还是 1920×1080"的错位。
        int[] size = CaptureSize.of(this);
        int nw = size[0] > 0 ? size[0] : w;
        int nh = size[1] > 0 ? size[1] : h;
        boolean same = s == surface && nw == capW && nh == capH;
        boolean hadDisplay = virtualDisplay != null;
        surface = s;
        capW = nw;
        capH = nh;
        Stage.log("绑定捕获表面 " + capW + "x" + capH + (same ? "（尺寸未变）" : ""));
        if (projection == null) {
            return;
        }
        // 尺寸或表面变了必须重建；没变但虚拟屏不在（比如刚被 clearSurface 释放过）也要补建
        if (!same || !hadDisplay) {
            createVirtualDisplay();
        }
    }

    /** 改捕获分辨率后重建虚拟屏（尺寸变了，只能重建）。 */
    public static void restart(Context ctx) {
        CaptureService svc = instance;
        Surface s = pendingSurface;
        if (svc == null || s == null) {
            return;
        }
        int[] size = CaptureSize.of(ctx);
        svc.main.post(() -> svc.attachSurface(s, size[0], size[1]));
    }

    /** 手机横竖屏切换后按新尺寸缩放虚拟屏（resize 比重建平滑得多）。 */
    public static void refreshSize(Context ctx) {
        CaptureService svc = instance;
        if (svc == null) {
            return;
        }
        int[] s = CaptureSize.of(ctx);
        svc.main.post(() -> svc.resize(s[0], s[1]));
    }

    /**
     * 手机横竖屏切换后按新尺寸缩放虚拟屏。
     *
     * ⚠️ 这里**只能**用 VirtualDisplay.resize()，绝对不能 release 后重建：
     * MediaProjection 一个实例只允许 createVirtualDisplay 一次，第二次会抛
     *   SecurityException: Don't take multiple captures by invoking
     *   MediaProjection#createVirtualDisplay multiple times on the same instance.
     * 而且系统会顺手把整个投屏停掉（MediaProjection 被系统停止 → 界面提示"投屏结束"）。
     * 这条路径以前踩过，实测日志见 PITFALLS。
     */
    /**
     * 尺寸变更的**防抖闸门**。
     *
     * 手机旋转过程中，Activity 与 Application 两个 Context 的 getRealMetrics 会在
     * 一段时间里给出互相矛盾的朝向：GlassEngine 的 onDisplayChanged 用 Activity，
     * QuadRenderer 的 30 帧自查用 Stage.appContext，两边轮流把尺寸改成对方的值。
     * 实测日志里 862x1920 ↔ 1920x862 在一秒内来回切了几十次。
     *
     * 每次 resize 都会重配 BufferQueue 的消费者，高频重配直接把画面顶死不再出帧
     * （17:44:00 心跳帧数停在 13203 就是这个原因）。
     *
     * 所以：新尺寸必须**稳定存在 RESIZE_SETTLE_MS** 才真正下发；期间又变了就重新计时。
     */
    private static final long RESIZE_SETTLE_MS = 400;

    private int pendW = -1;
    private int pendH = -1;

    private final Runnable pendingResize = new Runnable() {
        @Override
        public void run() {
            int w = pendW;
            int h = pendH;
            pendW = -1;
            pendH = -1;
            if (w <= 0 || h <= 0) {
                return;
            }
            applySize(w, h);
        }
    };

    private void resize(int w, int h) {
        if (w <= 0 || h <= 0) {
            return;
        }
        if (w == capW && h == capH && virtualDisplay != null) {
            // 已经是要的尺寸，撤销可能还挂着的待办，避免它过一会儿又改回去
            pendW = -1;
            pendH = -1;
            main.removeCallbacks(pendingResize);
            return;
        }
        if (w == pendW && h == pendH) {
            // 同一个候选值重复请求，说明已经稳定，让已排队的任务照常执行即可
            return;
        }
        pendW = w;
        pendH = h;
        main.removeCallbacks(pendingResize);
        main.postDelayed(pendingResize, RESIZE_SETTLE_MS);
    }

    private void applySize(int w, int h) {
        if (w == capW && h == capH && virtualDisplay != null) {
            return;
        }
        if (w <= 0 || h <= 0) {
            return;
        }
        Stage.log("捕获尺寸 " + capW + "x" + capH + " → " + w + "x" + h);
        Log.i(TAG, "捕获尺寸 " + capW + "x" + capH + " → " + w + "x" + h);

        // 顺序很重要：先让 GL 侧把 SurfaceTexture 的缓冲区改成新尺寸，再让虚拟屏按新尺寸生产。
        // 反过来（先动虚拟屏）会在一段时间里出现"生产者按新尺寸、消费者按旧尺寸"，
        // 表现就是画面被拉长 + BufferQueue 堵死不再出帧。
        QuadRenderer.syncBufferSize(w, h);

        int oldW = capW;
        int oldH = capH;
        capW = w;
        capH = h;

        if (virtualDisplay == null) {
            // 还没建屏（比如服务刚起），交给正常创建路径
            createVirtualDisplay();
            return;
        }

        try {
            virtualDisplay.resize(w, h, currentDpi());
            boundW = w;
            boundH = h;
            Log.i(TAG, "VirtualDisplay resize " + w + "x" + h);
        } catch (Throwable t) {
            // resize 失败也不要重建 —— 重建必然触发上面的 SecurityException 并把投屏打死。
            // 退回旧尺寸，至少画面比例还是对的；实在卡死由看门狗走 forceRebuild 那条路。
            Log.w(TAG, "VirtualDisplay.resize 失败，回退 " + oldW + "x" + oldH, t);
            Stage.log("缩放虚拟屏失败，回退 " + oldW + "x" + oldH);
            capW = oldW;
            capH = oldH;
            QuadRenderer.syncBufferSize(oldW, oldH);
        }
    }

    private int currentDpi() {
        return hostedMode ? 240 : getResources().getDisplayMetrics().densityDpi;
    }

    /**
     * 强制重建虚拟屏：尺寸可能完全没变，但链路已经堵死。
     * 给看门狗用 —— 悬停/镜像模式没有 Shizuku，也必须有一条自愈路径。
     *
     * 注意：**不能** release + createVirtualDisplay（见 resize 的注释）。
     * 能做的只有：① 用当前尺寸重新 resize 一次，把 BufferQueue 顶一下；
     * ② 如果连虚拟屏都没了，才允许走一次全新创建（此时 projection 通常也已失效，
     *    创建失败会被 catch 住并通知界面，属于预期路径）。
     */
    public static void forceRebuild() {
        CaptureService svc = instance;
        if (svc == null) {
            return;
        }
        svc.main.post(() -> {
            if (svc.virtualDisplay == null) {
                Stage.log("虚拟屏不存在，尝试创建");
                svc.createVirtualDisplay();
                return;
            }
            // 只 resize 救不回堵死的 BufferQueue（实测帧数仍然停在原地），
            // 真正有效的是换一块 SurfaceTexture：交给 GL 线程去做。
            Stage.log("画面停住 → 换一块捕获表面");
            QuadRenderer.requestHeal();
        });
    }

    /**
     * 把虚拟屏从旧表面上摘下来（不断开投影，也不销毁虚拟屏）。
     * GL 线程要换 SurfaceTexture 时先调这个，避免旧消费者被继续写入。
     */
    public static void detachSurface(Surface s) {
        CaptureService svc = instance;
        if (svc == null || s == null) {
            return;
        }
        svc.main.post(() -> {
            if (svc.virtualDisplay == null || svc.boundSurface != s) {
                return;
            }
            try {
                svc.virtualDisplay.setSurface(null);
                svc.boundSurface = null;
                Log.i(TAG, "VirtualDisplay 已摘除旧表面");
            } catch (Throwable t) {
                Log.w(TAG, "VirtualDisplay.setSurface(null) 失败", t);
            }
        });
    }

    private void createVirtualDisplay() {
        if (projection == null || surface == null || capW <= 0 || capH <= 0) {
            return;
        }
        // 一个 MediaProjection 实例只准 createVirtualDisplay 一次，重复调用会抛
        // SecurityException 并把整个投屏停掉。已经建过就直接跳过。
        if (virtualDisplay != null) {
            if (surface == boundSurface && capW == boundW && capH == boundH) {
                return;
            }
            // 尺寸/表面变了但已有虚拟屏 → 走 resize，不重建
            if (surface == boundSurface) {
                try {
                    virtualDisplay.resize(capW, capH, currentDpi());
                    boundW = capW;
                    boundH = capH;
                    return;
                } catch (Throwable t) {
                    Log.w(TAG, "createVirtualDisplay 里 resize 失败", t);
                }
            }
            // 换了 Surface（上下文重建 / 看门狗换了 SurfaceTexture）：
            // 用 VirtualDisplay.setSurface() 换消费端，**不要 release + 重建**。
            // setSurface 不受 "一个 MediaProjection 只准 createVirtualDisplay 一次" 的限制，
            // 是这里唯一能安全换表面的手段。实测重建会抛
            //   SecurityException: Don't take multiple captures ...
            // 并把整个投屏停掉（界面提示"投屏结束"）。
            if (surface != boundSurface) {
                Stage.log("捕获表面已更换 → 用 setSurface 换消费端（不重建虚拟屏）");
                try {
                    virtualDisplay.setSurface(surface);
                    boundSurface = surface;
                    boundW = capW;
                    boundH = capH;
                    Log.i(TAG, "VirtualDisplay.setSurface " + capW + "x" + capH);
                    return;
                } catch (Throwable t) {
                    Log.w(TAG, "VirtualDisplay.setSurface 失败", t);
                    Stage.log("换捕获表面失败：" + t.getMessage());
                    return;
                }
            }
        }
        try {
            int flags = hostedMode
                    ? DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC
                    : DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR;
            VirtualDisplay fresh = projection.createVirtualDisplay(
                    "air4pro3dof",
                    capW, capH,
                    currentDpi(),
                    flags,
                    surface, null, null);
            virtualDisplay = fresh;
            android.view.Display vd = fresh == null ? null : fresh.getDisplay();
            vdDisplayId = vd == null ? -1 : vd.getDisplayId();
            boundSurface = surface;
            boundW = capW;
            boundH = capH;
            Stage.log("虚拟屏已创建 " + capW + "x" + capH + " id=" + vdDisplayId
                    + (hostedMode ? "（PUBLIC）" : "（镜像）"));
            Log.i(TAG, "VirtualDisplay " + capW + "x" + capH + " 已创建 id=" + vdDisplayId);
        } catch (Exception e) {
            Stage.log("创建虚拟屏失败：" + e);
            Log.e(TAG, "createVirtualDisplay 失败", e);
        }
    }

    private void releaseVirtualDisplay() {
        if (virtualDisplay != null) {
            virtualDisplay.release();
            virtualDisplay = null;
        }
        boundSurface = null;
        boundW = boundH = 0;
        vdDisplayId = -1;
    }

    // ------------------------------------------------------------ 生命周期

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 必须 START_NOT_STICKY：进程被杀后 MediaProjection 授权令牌已失效，
        // 系统拉起重启也拿不回投屏，重启一个空壳只会留下孤儿前台通知。
        if (intent == null) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (ACTION_STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        startInForeground();

        if (projection == null) {
            int code = intent.getIntExtra(EXTRA_CODE, 0);
            Intent data = extractResult(intent);
            if (data == null) {
                stopSelf();
                return START_NOT_STICKY;
            }
            MediaProjectionManager mpm =
                    (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            try {
                projection = mpm.getMediaProjection(code, data);
            } catch (Exception e) {
                Log.e(TAG, "getMediaProjection 失败", e);
                notifyStopped("投屏授权已失效");
                stopSelf();
                return START_NOT_STICKY;
            }
            callback = new MediaProjection.Callback() {
                @Override
                public void onStop() {
                    Log.w(TAG, "MediaProjection 被系统停止");
                    releaseVirtualDisplay();
                    // 旧实现只释放虚拟屏，UI 还停在"运行中"；必须通知 MainActivity 收尾
                    notifyStopped("投屏被系统停止");
                }
            };
            projection.registerCallback(callback, main);
        }
        if (pendingSurface != null) {
            attachSurface(pendingSurface, pendingW, pendingH);
        } else {
            createVirtualDisplay();
        }
        return START_NOT_STICKY;
    }

    @SuppressWarnings("deprecation")
    private static Intent extractResult(Intent intent) {
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            return intent.getParcelableExtra(EXTRA_RESULT, Intent.class);
        }
        return intent.getParcelableExtra(EXTRA_RESULT);
    }

    private void startInForeground() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm.getNotificationChannel(CHANNEL) == null) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "投屏", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        PendingIntent open = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(this, 1,
                new Intent(this, CaptureService.class).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        // 旧实现 Action 图标传 null，部分 ROM 上"停止"按钮渲染不出来
        Notification.Action stopAction = new Notification.Action.Builder(
                Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                "停止", stop).build();

        Notification n = new Notification.Builder(this, CHANNEL)
                .setContentTitle("3DoF 悬停运行中")
                .setContentText("眼镜画面已按头部姿态锁定在空间中")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentIntent(open)
                .setOngoing(true)
                .addAction(stopAction)
                .build();
        // minSdk 29：FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION 从 Q 起可用，无需再分支
        startForeground(NOTIF_ID, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
    }

    @Override
    public void onDestroy() {
        releaseVirtualDisplay();
        if (projection != null) {
            if (callback != null) {
                try {
                    projection.unregisterCallback(callback);
                } catch (Exception ignored) {
                }
            }
            try {
                projection.stop();
            } catch (Exception ignored) {
            }
            projection = null;
        }
        surface = null;
        // 静态暂存的 Surface 可能已被 GL 线程释放；不清掉，下一次会话会用失效表面建屏
        pendingSurface = null;
        pendingW = pendingH = 0;
        instance = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
