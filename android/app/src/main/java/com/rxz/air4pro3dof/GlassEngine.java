package com.rxz.air4pro3dof;

import android.app.Activity;
import android.app.ActivityOptions;
import android.app.Presentation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.drawable.ColorDrawable;
import android.hardware.display.DisplayManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 原生引擎门面（Flutter UI 的唯一入口）。
 *
 * 本类是原 MainActivity 里"会话逻辑"的完整搬运：USB/IMU 打开、眼镜屏挂载、
 * MediaProjection 授权、扩展屏（私有/受信/兼容公共屏）启动、DP 重挂、
 * 看门狗、以及触控板注入。界面相关代码全部删除，改由 Flutter 通过
 * MethodChannel/EventChannel 驱动。
 *
 * 线程模型（与原实现一致）：UI 生命周期与 DisplayManager 回调在主线程；
 * USB open/close 与应用列表查询走 IO 单线程；shell 命令在 ShizukuBridge 自己的线程。
 */
public final class GlassEngine {

    private static final String TAG = "GlassEngine";
    private static final String CH_METHOD = "air4pro3dof/engine";
    private static final String CH_STATUS = "air4pro3dof/status";
    private static final String PREFS = "cfg";
    private static final int REQ_PROJECTION = 1001;
    /** 运行时权限申请码（截图/录像/通知）。 */
    public static final int REQ_PERMISSIONS = 1003;

    /** 捕获长边档位（与原实现一致）。 */
    private static final int[] RES_LEVELS = {1920, 1600, 1280};
    /** 算法内置方向取反（Air 1s 实测）。 */
    private static final boolean BASE_YAW_INVERTED = true;
    private static final boolean BASE_PITCH_INVERTED = true;

    // ---------------- 融合自 rayneo_imu：按型号的方向预置
    /**
     * 设备型号识别（GetDeviceInfo → deviceType），用于按型号套方向预置。
     *
     * 实测结论（Air 4 Pro，刚体恒等式 dĝ/dt = -ω × ĝ，48 排列暴力搜索 + 打乱对照）：
     *   Air 4 Pro(0x3A) 的陀螺轴相对加速度计轴是 (+, -, -)，即 gyro Y/Z 反向。
     *   这不是"欧拉角要翻个面"，而是原始角速度的手系差异，必须在进 AHRS 之前修正。
     *
     * 注意：型号是**开流之后**才查到的（queryDeviceInfo 要独占读通道），
     * 所以 startSession 里拿到 deviceType 后会再调一次 applyPoseSettings()。
     */
    private int deviceType = -1;

    /** @return 当前眼镜 deviceType；-1 = 未识别。0x3A = taurus4p0pro（Air 4 Pro）。 */
    public int deviceType() {
        return deviceType;
    }

    /** @return 型号名，未识别时 "unknown"。 */
    public String modelName() {
        return GlassUsb.modelName(deviceType);
    }

    private final Activity act;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final HeadPose pose = new HeadPose();
    private final MethodChannel method;
    private final EventChannel statusChannel;

    private EventChannel.EventSink statusSink;
    private final Runnable statusTask = this::pushStatus;
    /** 独立看门狗（每秒一次，不依赖 Flutter 订阅）。 */
    private final Runnable watchdogTask = this::watchdogTick;

    private static final ExecutorService IO = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "engine-io");
        t.setDaemon(true);
        return t;
    });

    private final DisplayManager dm;

    // ---------------- 会话状态
    private GlassUsb glass;
    private ScreenGlView glView;
    private Presentation presentation;
    private boolean running;
    private boolean starting;
    private boolean rebinding;
    private long stageStartMs;
    private long lastRebindMs;
    private boolean restartTried;
    private int focusArmedDisplay = -1;
    // ---- 画面卡死检测：帧数长时间不涨 = 扩展屏上的应用不再提交新帧
    private long lastFrames;
    private long lastFrameAtMs;
    private long lastBeatAtMs;
    /** 卡住前的出帧速率（fps），用于区分"动态内容卡死"和"静态画面本来就不出帧"。 */
    private int activeFps;
    /** 卡死处理阶段：0 未处理 / 1 已重新拉起目标应用 / 2 已重建或判定静态。 */
    private int stallStage;
    /** 本次会话重建次数（扩展屏消失 / 重建画面都计），上限 2，避免死循环。 */
    private int reviveCount;
    /** 是否正在跑 dumpsys 归因（避免叠加）。 */
    private boolean diagnosing;
    private boolean stallLogged;
    /** 卡死第三级是否已经杀过目标进程（每次会话只做一次，避免与应用反复拉锯）。 */
    private boolean stallKilled;
    /** 上次强制重建虚拟屏的时刻。悬停模式自愈用，带冷却，避免每秒重建一次。 */
    private long lastRebuildAtMs;
    /** 本次会话悬停模式自愈重建次数，只用于日志。 */
    private int rebuildTries;
    /** 会话期间是否持有「保持亮屏」标志。 */
    private boolean screenOnHeld;
    private boolean hostedLaunched;
    private String lastError;

    // ---------------- 配置（持久化，key 与原版一致，可覆盖升级）
    private int sizeP = 70;      // 尺寸 0..170 → 0.3..2.0×
    private int distP = 15;      // 距离 0..100 → 1.0..11.0 m
    private int fovP = 8;        // 视场 0..?  → 15..(15+n)°
    private int resP = 1;        // 0/1/2 → 1920/1600/1280
    private boolean freeze = true;
    private boolean invFwd, invYaw, invPitch, invRoll;
    /** 追踪模式：画面平滑跟随头部（不悬停）。 */
    /** 画面行为：0=悬停 1=追踪 2=扩展（见 HeadPose.MODE_*）。 */
    private int viewMode = HeadPose.MODE_HOVER;
    /** 跟随时间常数（秒）。 */
    private float followTau = 0.4f;
    /**
     * 临时色彩模式（0=关，11/12/13=红/青/黄）。
     *
     * **不持久化**：色彩档是面板寄存器的越界值，万一某台机器在这几档上直接熄屏，
     * 存盘会让它每次连接都黑屏。所以它只在本次运行内有效，重启/重连回落到亮度档。
     */
    private int colorLevel;
    /** 用户是否动过面板调光：动过才在下次会话启动时自动套用，没动过完全不发命令。 */
    private boolean panelUsed;
    /** 面板档位（1~10），与色彩档共用同一条 0x09 命令。 */
    private int panelLevel = 6;
    private boolean compat;
    private boolean trusted = true;
    private boolean hostedMode;  // 扩展屏（任意应用）
    private String hostedComponent;
    private String hostedLabel;

    // ---------------- 截图 / 录像
    /** 当前录像器（null = 没在录）。 */
    private GlassRecorder recorder;
    /** 最近一次截图 / 录像的落盘路径，供界面显示与「打开文件夹」用。 */
    private String lastCapturePath;
    /** 已申请过的运行时权限结果（onRequestPermissionsResult 里回填）。 */
    private String permissionNote;
    /** 上一次「权限已齐」提示的时间戳。节流用：点击一次只该出一行。 */
    private long lastPermDiagAtMs;

    private final DisplayManager.DisplayListener displayListener;

    public GlassEngine(Activity activity, BinaryMessenger messenger) {
        this.act = activity;
        this.dm = (DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
        this.method = new MethodChannel(messenger, CH_METHOD);
        this.statusChannel = new EventChannel(messenger, CH_STATUS);

        displayListener = new DisplayManager.DisplayListener() {
            @Override
            public void onDisplayAdded(int displayId) {
                if (displayId == CaptureService.vdDisplayId) {
                    return;
                }
                diag("显示器接入：id=" + displayId);
                ui.postDelayed(() -> {
                    if (!running || Stage.stageReady || presentation != null) {
                        return;
                    }
                    Display d = DisplayUtils.findExternal(dm);
                    if (d != null) {
                        diag("补挂到显示器 id=" + d.getDisplayId());
                        showGlassesStage(d);
                    }
                }, 1500);
            }

            @Override
            public void onDisplayRemoved(int displayId) {
                if (displayId == CaptureService.vdDisplayId) {
                    return;
                }
                if (running && displayId == ExtendHost.displayId) {
                    diag("扩展屏 display=" + displayId + " 被移除，重建画面");
                    if (reviveCount < 2) {
                        reviveCount++;
                        reviveStageNow("扩展屏移除回调");
                    }
                    return;
                }
                diag("显示器移除：id=" + displayId);
                boolean wasPresentation = presentation != null && presentation.getDisplay() != null
                        && presentation.getDisplay().getDisplayId() == displayId;
                boolean wasStage = Stage.stageReady && Stage.displayId == displayId;
                if (!wasPresentation && !wasStage) {
                    return;
                }
                ui.postDelayed(() -> {
                    if (!running) {
                        return;
                    }
                    Display d = DisplayUtils.findExternal(dm);
                    if (d == null) {
                        stopSession("眼镜已断开");
                        return;
                    }
                    diag("重新挂载到显示器 id=" + d.getDisplayId());
                    rebindDisplay(d);
                }, 1500);
            }

            @Override
            public void onDisplayChanged(int displayId) {
                if (displayId == Display.DEFAULT_DISPLAY && running) {
                    CaptureService.refreshSize(act);
                }
            }
        };
    }

    // ------------------------------------------------------------ 装配

    public void attach() {
        loadSettings();
        applyPoseSettings();
        pushStageConfig();
        CaptureService.setStopCallback(projectionStopped);
        dm.registerDisplayListener(displayListener, ui);
        requestNotificationPermission();
        ui.post(watchdogTask);
        method.setMethodCallHandler(this::onMethodCall);
        statusChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object args, EventChannel.EventSink sink) {
                statusSink = sink;
                ui.removeCallbacks(statusTask);
                ui.post(statusTask);
            }

            @Override
            public void onCancel(Object args) {
                statusSink = null;
                ui.removeCallbacks(statusTask);
            }
        });
    }

    public void dispose() {
        stopSession(null);
        saveNow();
        ui.removeCallbacks(watchdogTask);
        ui.removeCallbacksAndMessages(null);
        try {
            dm.unregisterDisplayListener(displayListener);
        } catch (Exception ignored) {
        }
        CaptureService.setStopCallback(null);
        statusSink = null;
    }

    // ------------------------------------------------------------ 通道入口

    private void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "getConfig":
                    result.success(configMap());
                    break;
                case "start": {
                    String mode = call.argument("mode");
                    String comp = call.argument("component");
                    String label = call.argument("label");
                    Boolean compatArg = call.argument("compat");
                    Boolean trustedArg = call.argument("trusted");
                    hostedMode = "hosted".equals(mode);
                    hostedComponent = comp;
                    hostedLabel = label;
                    // 兼容模式改用"本机私有屏"实现（trusted=false），
                    // 旧的 MediaProjection 公共屏路径已废弃：公共屏不允许承载
                    // 第三方应用的任务，实测会被系统送回手机屏（眼镜里没画面）。
                    compat = false;
                    // 只剩受信屏这一条路：应用自建屏承载不了第三方应用
                    trusted = true;
                    Stage.useTrustedDisplay = true;
                    saveNow();
                    startSession();
                    result.success(null);
                    break;
                }
                case "stop":
                    stopSession(null);
                    result.success(null);
                    break;
                case "setParams": {
                    Integer s = call.argument("size");
                    Integer d = call.argument("distance");
                    Integer f = call.argument("fov");
                    if (s != null) sizeP = clamp(s, 0, 170);
                    if (d != null) distP = clamp(d, 0, 100);
                    if (f != null) fovP = clamp(f, 0, 40);
                    applyParamsAndSave();
                    result.success(null);
                    break;
                }
                case "setPose": {
                    Boolean fr = call.argument("freeze");
                    Boolean fwd = call.argument("invertForward");
                    Boolean yaw = call.argument("invertYaw");
                    Boolean pit = call.argument("invertPitch");
                    Boolean rol = call.argument("invertRoll");
                    if (fr != null) freeze = fr;
                    if (fwd != null) invFwd = fwd;
                    if (yaw != null) invYaw = yaw;
                    if (pit != null) invPitch = pit;
                    if (rol != null) invRoll = rol;
                    String mode = call.argument("viewMode");
                    Boolean trk = call.argument("tracking");
                    Double tau = call.argument("followTau");
                    if (mode != null) {
                        viewMode = "track".equals(mode) ? HeadPose.MODE_TRACK
                                : "extend".equals(mode) ? HeadPose.MODE_EXTEND
                                : HeadPose.MODE_HOVER;
                    } else if (trk != null) {
                        // 兼容旧参数：true/false 直接映射成追踪/悬停
                        viewMode = trk ? HeadPose.MODE_TRACK : HeadPose.MODE_HOVER;
                    }
                    if (tau != null) followTau = (float) Math.max(0.15, Math.min(1.5, tau));
                    applyPoseSettings();
                    saveNow();
                    result.success(null);
                    break;
                }
                case "setPanel": {
                    // 面板调光：只在会话运行中可调（界面也只在开始悬停后显示）
                    Integer lv = call.argument("level");
                    if (lv != null) {
                        int v = clamp(lv, GlassUsb.LEVEL_MIN, GlassUsb.LEVEL_MAX);
                        if (GlassUsb.isColorLevel(v)) {
                            colorLevel = v;
                        } else {
                            colorLevel = 0;
                            panelLevel = v;
                        }
                        panelUsed = true;
                        applyPanel();
                        saveNow();
                    }
                    result.success(null);
                    break;
                }
                case "setResolution": {
                    Integer level = call.argument("level");
                    if (level != null) resP = clamp(level, 0, RES_LEVELS.length - 1);
                    CaptureSize.maxLongSide = RES_LEVELS[resP];
                    saveNow();
                    if (running) {
                        CaptureService.refreshSize(act);
                    }
                    result.success(null);
                    break;
                }
                case "listApps": {
                    IO.execute(() -> {
                        List<Map<String, String>> apps = queryApps();
                        ui.post(() -> result.success(apps));
                    });
                    break;
                }
                case "launchHosted": {
                    String comp = call.argument("component");
                    String label = call.argument("label");
                    if (comp != null) {
                        hostedComponent = comp;
                        hostedLabel = label;
                        saveNow();
                    }
                    if (running && hostedMode) {
                        launchHosted();
                    }
                    result.success(null);
                    break;
                }
                case "caps": {
                    result.success(capsMap());
                    break;
                }
                case "openAccessibilitySettings":
                    openAccessibilitySettings();
                    result.success(null);
                    break;
                case "requestShizuku":
                    requestShizuku();
                    result.success(null);
                    break;
                // ---------------- 触控板
                case "setCursor": {
                    Double u = call.argument("u");
                    Double v = call.argument("v");
                    Boolean visible = call.argument("visible");
                    if (u != null) Stage.cursorU = (float) clamp01(u);
                    if (v != null) Stage.cursorV = (float) clamp01(v);
                    if (visible != null) Stage.cursorVisible = visible;
                    result.success(null);
                    break;
                }
                case "tap": {
                    Boolean longPress = call.argument("longPress");
                    tapAtCursor(longPress != null && longPress);
                    result.success(null);
                    break;
                }
                case "scroll": {
                    Integer axis = call.argument("axis");
                    Integer dir = call.argument("dir");
                    if (axis != null && dir != null) {
                        scroll(axis, dir);
                    }
                    result.success(null);
                    break;
                }
                case "key": {
                    Integer code = call.argument("code");
                    if (code != null) {
                        key(code);
                    }
                    result.success(null);
                    break;
                }
                case "screenshot": {
                    requestScreenshot(result);
                    break;
                }
                case "recordStart": {
                    startRecording(result);
                    break;
                }
                case "recordStop": {
                    stopRecording(result);
                    break;
                }
                case "killHosted": {
                    // 画面卡死时的最后手段：用已授权的 adb / Shizuku shell 把目标进程杀掉，
                    // 让系统重新拉一份干净的。只杀**我们启动的那个**目标应用，不动系统进程。
                    killHostedProcess(result);
                    break;
                }
                case "openCaptureFolder": {
                    openCaptureFolder();
                    result.success(null);
                    break;
                }
                case "ensurePermissions": {
                    ensureRuntimePermissions();
                    result.success(null);
                    break;
                }
                case "reviveStage": {
                    // 手动重连：重建眼镜端 StageActivity（会连带重建 SurfaceTexture、
                    // 扩展屏与目标应用），用于画面卡死后自救
                    reviveStageNow("手动");
                    result.success(null);
                    break;
                }
                case "recenter":
                    pose.recenter();
                    result.success(null);
                    break;
                case "recalibrate":
                    // 重新采样零偏（不动画面中位）：换环境/温漂变大后手动触发
                    pose.resetBias();
                    result.success(null);
                    break;
                case "dismissError":
                    lastError = null;
                    result.success(null);
                    break;
                default:
                    result.notImplemented();
            }
        } catch (Throwable t) {
            Log.e(TAG, "method " + call.method + " 失败", t);
            result.error("engine", String.valueOf(t.getMessage()), null);
        }
    }

    // ------------------------------------------------------------ 会话

    private void startSession() {
        if (running || starting) {
            return;
        }
        final boolean appMode = hostedMode;
        if (appMode && (hostedComponent == null || !hostedComponent.contains("/"))) {
            toast("先选择要投屏的应用");
            return;
        }
        if (appMode && !ShizukuBridge.ready(act)) {
            // 扩展屏要把**第三方应用**放到副屏上，而系统只允许"屏的所有者"或 shell
            // 这样做。本应用自建的虚拟屏（私有屏 / MediaProjection 公共屏）虽然 owner
            // 是我们，但非 trusted，系统会把第三方 Activity 的启动请求退回默认屏 ——
            // 表现就是「眼镜没画面、应用在手机上打开」。所以这里直接拦住，不再假装能跑。
            fail(ShizukuBridge.installed(act)
                    ? "扩展屏需要 Shizuku 授权：先到「辅助能力」里授权，或改用镜像整屏"
                    : "扩展屏需要 Shizuku（本机未安装）：可改用镜像整屏");
            return;
        }
        Stage.appContext = act.getApplicationContext();
        Stage.extendMode = appMode;
        Stage.pendingComponent = appMode ? hostedComponent : null;
        CaptureService.hostedMode = false;
        hostedLaunched = false;

        if (appMode && !ShizukuBridge.ready(act)) {
            diag(AutoConsentAccessibilityService.canInject()
                    ? "没有 Shizuku：用无障碍辅助向扩展屏注入触摸"
                    : "没有 Shizuku 且无障碍辅助未开启：扩展屏能显示，但点击无效");
        }

        Display d = DisplayUtils.findExternal(dm);
        if (d == null) {
            fail("未检测到眼镜显示器：请确认手机支持 USB-C DP 输出并已插好眼镜");
            return;
        }
        UsbDevice dev = GlassUsb.findDevice(act);
        if (dev == null) {
            fail("未找到眼镜 USB 设备（VID 0x1BBB）");
            return;
        }
        UsbManager um = (UsbManager) act.getSystemService(Context.USB_SERVICE);
        if (um == null || !um.hasPermission(dev)) {
            diag("申请 USB 权限…");
            AutoConsentAccessibilityService.armUsbConsentAutoClick(8000);
            toast("请在弹窗中允许访问眼镜");
            new GlassUsb(act, glassListener).requestPermission(granted -> ui.post(() -> {
                if (granted) {
                    diag("USB 权限已授予，继续启动");
                    startSession();
                } else {
                    fail("USB 授权未完成：若系统没弹授权框，请拔插眼镜后重试");
                }
            }));
            return;
        }

        diag("使用显示器：" + DisplayUtils.describe(d));
        showGlassesStage(d);
        pose.resetSession();

        starting = true;
        final GlassUsb g = new GlassUsb(act, glassListener);
        glass = g;
        IO.execute(() -> {
            String err = g.open();
            if (err != null) {
                ui.post(() -> {
                    if (glass != g) {
                        return;
                    }
                    fail("打开失败：" + err);
                });
                return;
            }
            // 融合自 rayneo_imu：先同步查设备型号（必须在采集启动前，独占读通道）
            GlassUsb.DeviceInfo devInfo = g.queryDeviceInfo(3000);
            deviceType = devInfo != null ? devInfo.deviceType : -1;
            if (devInfo != null) {
                Log.i(TAG, "识别设备: " + devInfo + "（查询耗时不计入会话）");
            } else {
                Log.w(TAG, "设备型号未识别（GetDeviceInfo 无应答），按默认方向预置运行");
            }
            // 关键：attach() 时 deviceType 还是 -1，陀螺轴符号只能取默认 (+,+,+)。
            // 这里拿到真实型号后必须**再套一次**姿态设置，否则 Air 4 Pro 的 (+, -, -)
            // 永远不会生效 —— 表现就是"画面越转越歪"。
            ui.post(this::applyPoseSettings);
            g.start();
            ui.post(() -> {
                if (glass != g) {
                    return;
                }
                diag("HID：" + g.describe());
                starting = false;
                running = true;
                lastFrameAtMs = 0;
                lastBeatAtMs = 0;
                activeFps = 0;
                stallStage = 0;
                stallKilled = false;
                diagnosing = false;
                reviveCount = 0;
                lastRebuildAtMs = 0;
                rebuildTries = 0;
                if (hostedMode) {
                    // 手机既是触控板又是扩展屏的宿主：息屏会把扩展屏一起挂起
                    setScreenOn(true);
                }
                if (panelUsed) {
                    // 用户调过面板亮度：开屏后补上，等出站通道锁定（读到首帧）之后再发
                    ui.postDelayed(this::applyPanel, 1500);
                }
                // 面板亮度与会话无关但要走同一条出站通道：等 kick() 把通道锁住再发，
                // 否则可能落在还没验证过的通道变体上被固件忽略。
                stageStartMs = SystemClock.elapsedRealtime();
                restartTried = false;
                QuadRenderer.textureFrames = 0;
                // 镜像整屏才需要 MediaProjection；扩展屏由 ExtendHost 自建屏
                boolean needProjection = !hostedMode;
                if (needProjection) {
                    requestProjection();
                } else {
                    method.invokeMethod("onSessionStarted", null);
                }
            });
        });
    }

    /**
     * 把面板档位下发到眼镜（用户拖动/点色时调用；会话启动时若用过也会补一次）。
     *
     * 没有会话连接时静默跳过：不为调亮度单独开 HID 连接——那条连接和会话共用
     * 同一个接口，是画面异常的可疑来源之一。界面也只在开始悬停后才显示调光控件。
     */
    private void applyPanel() {
        final int lv = colorLevel > 0 ? colorLevel : panelLevel;
        IO.execute(() -> {
            GlassUsb g = glass;
            if (g == null) {
                diag("面板调光未下发：当前没有眼镜会话");
                return;
            }
            int w = g.setBrightnessLevel(lv);
            if (w < 0) {
                diag("面板调光写入失败（返回 " + w + "）");
            }
        });
    }

    private void stopSession(String reason) {
        running = false;
        starting = false;
        deviceType = -1;   // 融合自 rayneo_imu：会话结束即清除型号识别
        if (screenOnHeld) {
            setScreenOn(false);
        }
        lastBeatAtMs = 0;
        lastFrameAtMs = 0;
        final GlassUsb g = glass;
        glass = null;
        if (g != null) {
            IO.execute(g::close);
        }
        if (presentation != null) {
            try {
                presentation.dismiss();
            } catch (Exception ignored) {
            }
            presentation = null;
        }
        if (glView != null) {
            glView.onPause();
            glView.renderer().release();
            glView = null;
        }
        act.stopService(new Intent(act, CaptureService.class));
        Stage.close();
        ExtendHost.release();
        Stage.extendMode = false;
        CaptureService.hostedMode = false;
        hostedLaunched = false;
        AutoConsentAccessibilityService.clearFocusRestore();
        focusArmedDisplay = -1;
        pose.resetSession();
        if (reason != null) {
            diag("已停止：" + reason);
            toast(reason);
        }
        method.invokeMethod("onSessionStopped", reason == null ? "" : reason);
    }

    private void fail(String message) {
        lastError = message;
        diag(message);
        toast(message);
        starting = false;
        method.invokeMethod("onError", message);
        pushStatus();
    }

    private final GlassUsb.Listener glassListener = new GlassUsb.Listener() {
        @Override
        public void onStatus(String text) {
            diag(text);
        }

        @Override
        public void onSample(float[] accel, float[] gyroRad, float dt) {
            pose.onSample(accel, gyroRad, dt);
        }

        @Override
        public void onFatal(String reason) {
            ui.post(() -> stopSession("IMU 异常：" + reason));
        }
    };

    private final CaptureService.OnStopped projectionStopped = reason ->
            ui.post(() -> {
                if (running) {
                    stopSession(reason);
                }
            });

    private void showGlassesStage(Display display) {
        Stage.close();
        Stage.pose = pose;
        pushStageConfig();

        Intent intent = new Intent(act, StageActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_MULTIPLE_TASK);
        Bundle opts = null;
        try {
            opts = ActivityOptions.makeBasic()
                    .setLaunchDisplayId(display.getDisplayId())
                    .toBundle();
        } catch (Exception e) {
            diag("构造副屏启动参数失败：" + e.getMessage());
        }
        try {
            act.startActivity(intent, opts);
            diag("画面已投到眼镜屏（display " + display.getDisplayId() + "）");
        } catch (Exception e) {
            diag("副屏启动失败：" + e.getMessage() + "，回退 Presentation");
            showPresentation(display);
            return;
        }
        ui.postDelayed(() -> {
            if (!running || Stage.launched || Stage.stageReady || presentation != null) {
                return;
            }
            diag("眼镜屏未接管，回退 Presentation（切后台会失效）");
            Stage.close();
            showPresentation(display);
        }, 2500);
    }

    private void showPresentation(Display display) {
        try {
            glView = new ScreenGlView(act, pose);
            presentation = new Presentation(act, display);
            presentation.getWindow().setBackgroundDrawable(new ColorDrawable(0xFF000000));
            presentation.setContentView(glView);
            presentation.setOnDismissListener(p -> {
                if (running && !rebinding) {
                    stopSession(null);
                }
            });
            presentation.show();
        } catch (WindowManager.BadTokenException | WindowManager.InvalidDisplayException
                | IllegalStateException e) {
            diag("Presentation 挂载失败：" + e);
            presentation = null;
            glView = null;
            stopSession("眼镜屏不可用");
        }
    }

    private void rebindDisplay(Display display) {
        long now = SystemClock.elapsedRealtime();
        if (now - lastRebindMs < 2500) {
            diag("忽略过频的重挂请求");
            return;
        }
        lastRebindMs = now;
        rebinding = true;
        try {
            if (presentation != null) {
                presentation.dismiss();
            }
            if (glView != null) {
                glView.onPause();
                glView.renderer().release();
            }
            Stage.close();
        } catch (Exception ignored) {
        }
        presentation = null;
        glView = null;
        showGlassesStage(display);
        rebinding = false;
    }

    private void requestProjection() {
        AutoConsentAccessibilityService.armConsentAutoClick(5000);
        MediaProjectionManager mpm =
                (MediaProjectionManager) act.getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        act.startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJECTION);
    }

    /** 由 MainActivity.onActivityResult 转发；返回 true 表示已消费。 */
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQ_PROJECTION) {
            return false;
        }
        if (!running) {
            diag("投屏授权返回时会话已停止，忽略");
            act.stopService(new Intent(act, CaptureService.class));
            return true;
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            diag("投屏授权被取消");
            stopSession("需要投屏权限");
            return true;
        }
        Intent i = new Intent(act, CaptureService.class)
                .setAction(CaptureService.ACTION_START)
                .putExtra(CaptureService.EXTRA_CODE, resultCode)
                .putExtra(CaptureService.EXTRA_RESULT, data);
        act.startForegroundService(i);
        diag("投屏已启动");
        stageStartMs = SystemClock.elapsedRealtime();
        restartTried = false;
        QuadRenderer.textureFrames = 0;
        method.invokeMethod("onSessionStarted", null);
        return true;
    }

    // ------------------------------------------------------------ 参数

    private void applyParamsAndSave() {
        pushStageConfig();
        saveNow();
        pushStatus();
    }

    private void pushStageConfig() {
        Stage.fill = 0.3f + sizeP / 100f;
        Stage.distanceM = 1f + distP / 10f;
        Stage.fovYDeg = 15f + fovP;
    }

    /**
     * 陀螺轴符号表：按 deviceType 返回 (sx, sy, sz)。
     *
     * 依据 rayneo_imu 在真机上的实测（判据是刚体恒等式 dĝ/dt = -ω × ĝ，
     * 48 种带符号排列暴力搜索，最佳者 cos 从 -0.83 提升到 +0.86、RMS 从 1.48 降到 0.75）：
     *   - Air 1s 基准：(+, +, +)
     *   - Air 4 Pro  ：(+, -, -)，即 gyro Y/Z 与加速度计反向
     *
     * 注意这与 invertYaw/invertPitch 是**两件不同的事**：
     * 那两个是对欧拉角取负（整体翻角），这里是对送入 AHRS 的原始角速度取负（换手系）。
     * 轴搞错的表现是"一动就朝反方向漂、越转越歪"，靠欧拉角取反是救不回来的。
     *
     * 未识别的机型一律返回 (+, +, +)，保持改造前的行为。
     */
    private float[] gyroSignFor(int devType) {
        switch (devType) {
            case 0x3A:  // taurus4p0pro / Air 4 Pro —— 实测 (+, -, -)
                return new float[]{1f, -1f, -1f};
            case 0x39:  // taurus4p0 / Air 4 —— 与 4 Pro 同固件，先按同轴处理
                return new float[]{1f, -1f, -1f};
            default:    // aries 系列（Air 1s 等）及未识别
                return new float[]{1f, 1f, 1f};
        }
    }

    private void applyPoseSettings() {
        pose.freezeWhenStill = freeze;
        pose.viewMode = viewMode;
        pose.followTauS = followTau;
        // 陀螺轴符号：按识别到的型号决定（融合自 rayneo_imu 实测）
        float[] gs = gyroSignFor(deviceType);
        pose.setGyroSign(gs[0], gs[1], gs[2]);
        pose.invertYaw = BASE_YAW_INVERTED ^ invYaw;
        pose.invertPitch = BASE_PITCH_INVERTED ^ invPitch;
        pose.invertForward = invFwd;
        pose.invertRoll = invRoll;
        // 便于真机排查：每次应用姿态设置都打一行，确认型号→轴符号的映射真的生效
        Log.i(TAG, "姿态设置: deviceType=0x" + Integer.toHexString(deviceType)
                + "(" + modelName() + ") gyroSign=" + pose.gyroSignText()
                + " yawInv=" + pose.invertYaw + " pitchInv=" + pose.invertPitch
                + " fwdInv=" + pose.invertForward + " rollInv=" + pose.invertRoll);
    }

    private List<Map<String, String>> queryApps() {
        List<Map<String, String>> out = new ArrayList<>();
        try {
            android.content.pm.PackageManager pm = act.getPackageManager();
            Intent q = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
            List<android.content.pm.ResolveInfo> found = pm.queryIntentActivities(q, 0);
            List<String[]> rows = new ArrayList<>();
            for (android.content.pm.ResolveInfo ri : found) {
                rows.add(new String[]{String.valueOf(ri.loadLabel(pm)),
                        ri.activityInfo.packageName + "/" + ri.activityInfo.name});
            }
            Collections.sort(rows, (a, b) -> a[0].compareTo(b[0]));
            for (String[] r : rows) {
                java.util.HashMap<String, String> m = new java.util.HashMap<>();
                m.put("label", r[0]);
                m.put("component", r[1]);
                out.add(m);
            }
        } catch (Throwable t) {
            Log.w(TAG, "查询应用失败", t);
        }
        return out;
    }

    // ------------------------------------------------------------ 触控板注入

    private int currentDisplayId() {
        return CaptureService.vdDisplayId > 0 ? CaptureService.vdDisplayId : ExtendHost.displayId;
    }

    private int[] targetSize() {
        Display d = Ui_free_display(currentDisplayId());
        int[] s = DisplayUtils.sizeOf(d);
        return s != null ? s : CaptureSize.of(act);
    }

    /** 按 displayId 取 Display（不依赖已删除的 Ui 工具类）。 */
    private Display Ui_free_display(int displayId) {
        try {
            Display[] all = dm.getDisplays();
            for (Display d : all) {
                if (d.getDisplayId() == displayId) {
                    return d;
                }
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    private void tapAtCursor(boolean longPress) {
        int id = currentDisplayId();
        if (id <= 0) {
            return;
        }
        int[] size = targetSize();
        float x = Stage.cursorU * size[0];
        float y = Stage.cursorV * size[1];
        if (ShizukuBridge.ready(act)) {
            if (longPress) {
                ShizukuBridge.longPressOnDisplay(id, x, y);
            } else {
                ShizukuBridge.tapOnDisplay(id, x, y);
            }
            return;
        }
        if (AutoConsentAccessibilityService.injectTap(id, x, y, longPress ? 650 : 80)) {
            return;
        }
        toast("无法注入触摸：请开启 Shizuku 或无障碍辅助");
    }

    private void scroll(int axis, int dir) {
        int id = currentDisplayId();
        if (id <= 0) {
            return;
        }
        int[] size = targetSize();
        float cx = Stage.cursorU * size[0];
        float cy = Stage.cursorV * size[1];
        float x2, y2;
        if (axis == 1) {
            float step = size[0] * 0.30f;
            x2 = clampF(cx + dir * step, 0, size[0]);
            y2 = cy;
        } else {
            float step = size[1] * 0.30f;
            x2 = cx;
            y2 = clampF(cy + dir * step, 0, size[1]);
        }
        if (ShizukuBridge.ready(act)) {
            ShizukuBridge.swipeOnDisplay(id, cx, cy, x2, y2);
            return;
        }
        if (!AutoConsentAccessibilityService.injectSwipe(id, cx, cy, x2, y2, 220)) {
            toast("无法注入触摸：请开启 Shizuku 或无障碍辅助");
        }
    }

    private void key(int code) {
        int id = currentDisplayId();
        if (id > 0 && ShizukuBridge.ready(act)) {
            ShizukuBridge.keyOnDisplay(id, code);
            return;
        }
        if (code == android.view.KeyEvent.KEYCODE_BACK && AutoConsentAccessibilityService.performBack()) {
            return;
        }
        toast("无法注入按键：请开启 Shizuku 或无障碍辅助");
    }

    private void launchHosted() {
        if (hostedComponent == null) {
            toast("先选择要投屏的应用");
            return;
        }
        int displayId = currentDisplayId();
        if (displayId <= 0) {
            toast("扩展屏还没就绪，稍后再试");
            return;
        }
        hostedLaunched = true;
        String[] parts = hostedComponent.split("/");
        String pkg = parts[0];
        String cls = parts.length > 1 ? parts[1] : null;
        ShizukuBridge.launchOnDisplay(pkg, cls, displayId, ok ->
                diag((ok ? "已在扩展屏启动 " : "启动失败 ")
                        + (hostedLabel == null ? pkg : hostedLabel) + "（display " + displayId + "）"));
    }

    // ------------------------------------------------------------ 辅助入口

    private void openAccessibilitySettings() {
        if (AutoConsentAccessibilityService.isEnabled(act)) {
            toast("无障碍辅助已开启");
            return;
        }
        try {
            act.startActivity(new Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            toast("在列表里找到 AIR4PRO3DOF 并开启");
        } catch (Exception e) {
            toast("打不开无障碍设置页，请到系统设置 → 无障碍里手动开启");
        }
    }

    private void requestShizuku() {
        if (!ShizukuBridge.installed(act)) {
            toast("未检测到 Shizuku，请先安装并启动");
            ShizukuBridge.openShizuku(act);
            return;
        }
        if (ShizukuBridge.ready(act)) {
            toast("Shizuku 已就绪");
            return;
        }
        ShizukuBridge.request(new ShizukuBridge.Listener() {
            @Override
            public void onGranted() {
                ui.post(() -> {
                    diag("Shizuku 已授权");
                    toast("Shizuku 已授权");
                    pushStatus();
                });
            }

            @Override
            public void onDenied() {
                ui.post(() -> toast("Shizuku 授权被拒绝"));
            }
        });
    }

    // ------------------------------------------------------------ 画面卡死检测 / 亮屏

    /**
     * 画面卡死看门狗：**独立每秒跑**，不挂在 Flutter 的状态流上。
     *
     * 为什么要独立：状态推送只在 Flutter 订阅了 EventChannel 时才跑（手机端界面退到
     * 后台时订阅可能被取消），而卡死往往正好发生在"手机揣着看眼镜"的时候——
     * 挂在那条链路上等于关键时刻没有日志。
     *
     * 判据与动作：
     *   · 帧数不涨 10 秒 → 记一次日志（GL / stage / 屏幕状态）；
     *   · 卡住前帧率 ≥4fps（说明原本在动，不是静态画面）且已卡 12 秒
     *     → 自动重建一次眼镜端 Stage（连带扩展屏与目标应用），每个会话最多两次。
     *
     * 之所以用"卡住前的帧率"做门槛：看文档、暂停的视频本来就不出帧，
     * 这种情况不能去重连，否会造成打扰。
     */
    private void watchdogTick() {
        if (!running) {
            lastFrameAtMs = 0;
            stallLogged = false;
            ui.postDelayed(watchdogTask, 1000);
            return;
        }
        long now = SystemClock.elapsedRealtime();
        long frames = QuadRenderer.textureFrames;
        if (lastFrameAtMs == 0) {
            lastFrames = frames;
            lastFrameAtMs = now;
        }
        long delta = frames - lastFrames;
        if (delta > 0) {
            // 每秒帧数：简单取本秒增量的移动平均，避免抖动
            activeFps = (int) Math.min(240, (activeFps * 2 + delta) / 3);
            lastFrames = frames;
            lastFrameAtMs = now;
            if (stallLogged) {
                stallLogged = false;
                diag("画面恢复出帧");
            }
        }

        // 扩展屏被系统悄悄回收时不会回调 onDisplayRemoved（实测受信屏会这样），
        // 引擎就会一直"运行中"但没有任何生产者 —— 画面永久定格。
        // 这里每秒核对一次，没了就整体重建。
        if (hostedMode && ExtendHost.displayId > 0
                && dm.getDisplay(ExtendHost.displayId) == null && reviveCount < 2) {
            reviveCount++;
            diag("扩展屏 display=" + ExtendHost.displayId + " 已消失，重建画面（第 " + reviveCount + " 次）");
            reviveStageNow("扩展屏消失");
            lastFrameAtMs = now;
            return;
        }

        long idleMs = now - lastFrameAtMs;
        if (idleMs >= 10_000 && !stallLogged) {
            stallLogged = true;
            diag("画面已 " + (idleMs / 1000) + " 秒无新帧，卡住前约 " + activeFps + "fps"
                    + renderStateSummary() + displayStateSummary());
            // 只提示，不擅自动手：暂停视频/看静态页面同样不出帧，靠帧率分不开
            toast("画面 10 秒未更新（声音与操控正常）");
            diagnoseStall(1);
        }
        // 第二级：已经尝试过一次仍无帧 → 再查一次，必要时重建整条链路
        if (idleMs >= 25_000 && stallStage == 1 && !diagnosing) {
            diagnoseStall(2);
        }
        // 第三级：重建过、判定过"任务还在本屏"之后仍然不出帧，而且**姿态还在正常更新**
        // → 说明 IMU/GL/看门狗都活着，只有那个应用自己卡住了（Surface 队列堵死）。
        // 这时唯一有效的动作是把它的进程杀掉重拉。只做一次，避免和应用反复拉锯。
        if (idleMs >= 40_000 && stallStage == 2 && !stallKilled && hostedMode
                && pose.isTracking() && pose.frames > 0) {
            stallKilled = true;
            diag("画面静默 " + (idleMs / 1000) + "s 但姿态仍在更新（IMU " + (int) pose.hz
                    + "Hz，已出 " + pose.frames + " 帧）→ 判定目标应用自身卡死，杀掉重拉");
            killHostedQuietly();
        }

        // 悬停/镜像模式的自愈：没有 Shizuku，上面的 killHostedQuietly 走不通，
        // 但"横竖屏切换后 SurfaceTexture 与虚拟屏尺寸错配 → BufferQueue 堵死"
        // 在这两种模式下一样会发生。这里直接重建虚拟屏，是唯一不依赖外部权限的动作。
        // 姿态没在更新时不重建：那时问题在 IMU 侧，重建虚拟屏救不回来，只会白闪一下。
        if (idleMs >= 12_000 && !hostedMode && pose.isTracking()
                && !CaptureService.hostedMode && CaptureService.isRunning()
                && now - lastRebuildAtMs >= 15_000) {
            lastRebuildAtMs = now;
            rebuildTries++;
            diag("画面静默 " + (idleMs / 1000) + "s（悬停模式，姿态仍在更新）"
                    + " → 重建虚拟屏（第 " + rebuildTries + " 次）");
            CaptureService.forceRebuild();
            // 重建后帧计数会重新起算，别让 idleMs 一路累加把后面几级全触发掉。
            //
            // ⚠️ 这里**不能** return：方法末尾的 ui.postDelayed(watchdogTask, 1000)
            // 是看门狗唯一的续命点，一旦 return 跳过它，看门狗就永久停摆 ——
            // 心跳日志、25s/40s 后两级、后续所有自愈全部失效，而且症状是"日志突然没了"，
            // 极易被误判成进程被冻结。实测：18:51:48 触发一次自愈后，
            // 直到用户手动操作才有新日志，中间两分多钟一条心跳都没有。
            // 现在只把帧基准时间顶回 now，然后继续往下走（心跳照发、下轮照排）。
            lastFrameAtMs = now;
            idleMs = 0;
        }

        // 心跳：每 5 秒一条，用来判断"进程是否被冻结"
        if (now - lastBeatAtMs >= 5000) {
            lastBeatAtMs = now;
            diag("心跳 帧=" + frames
                    + " 画面静默=" + (idleMs / 1000) + "s 卡前帧率=" + activeFps
                    + renderStateSummary() + displayStateSummary());
        }
        ui.postDelayed(watchdogTask, 1000);
    }

    /**
     * 卡死归因：查目标应用的任务还挂不挂在我们这块扩展屏上。
     *
     * 这一步是区分"真卡死"和"静态画面"的唯一可靠依据：
     *   · 任务**不在**本屏 → 系统把它搬走了（受信屏 canHostTasks=false 的老问题）
     *     → 重新拉起（level 1）；还不行就重建整条链路（level 2）；
     *   · 任务**还在**本屏 → 应用只是没有新内容可画（暂停的视频、静态网页）
     *     → 一行日志，不动手。
     */
    private void diagnoseStall(int level) {
        final String comp = hostedComponent;
        if (!hostedMode || comp == null || !ShizukuBridge.ready(act)) {
            diag("卡死归因：无法查询任务归属（hosted=" + hostedMode
                    + " shizuku=" + ShizukuBridge.ready(act) + "）");
            return;
        }
        final int did = currentDisplayId();
        if (did <= 0) {
            return;
        }
        diagnosing = true;
        final String pkg = comp.split("/")[0];
        ShizukuBridge.execForOutput("dumpsys activity activities", text -> {
            diagnosing = false;
            if (text == null) {
                diag("卡死归因：dumpsys 无输出");
                return;
            }
            String block = displaySection(text, did);
            boolean onOurDisplay = block.contains(pkg);
            diag("卡死归因：任务 " + pkg + (onOurDisplay ? " 仍在本扩展屏" : " 已不在本扩展屏")
                    + "（display=" + did + "，" + block.length() + " 字符）");
            if (onOurDisplay) {
                stallStage = 2;   // 静态画面，不再反复处理
                return;
            }
            stallStage = level;
            if (level == 1 && ExtendHost.displayId > 0) {
                diag("把目标应用拉回扩展屏 display=" + ExtendHost.displayId);
                ExtendHost.launch(act, ExtendHost.displayId, comp);
                lastFrameAtMs = android.os.SystemClock.elapsedRealtime();
                stallLogged = false;
            } else {
                diag("重建眼镜端画面（第 " + level + " 级）");
                reviveStageNow("看门狗");
                lastFrameAtMs = android.os.SystemClock.elapsedRealtime();
                stallLogged = false;
            }
        });
    }

    /** 取出 dumpsys activity 里某个 display 的段落文本。 */
    private static String displaySection(String dump, int displayId) {
        String key = "Display: mDisplayId=" + displayId;
        int start = dump.indexOf(key);
        if (start < 0) {
            return "";
        }
        int next = dump.indexOf("Display: mDisplayId=", start + key.length());
        return next > 0 ? dump.substring(start, next) : dump.substring(start);
    }

    /** 重建眼镜端画面：Stage → SurfaceTexture → 扩展屏 → 目标应用，一条链全重来。 */
    private void reviveStageNow(String why) {
        int did = currentDisplayId();
        if (!running || did <= 0) {
            return;
        }
        Display d = dm.getDisplay(did);
        if (d == null) {
            return;
        }
        diag("重连画面（" + why + "）：display=" + did
                + "（旧扩展屏 display=" + ExtendHost.displayId + "）");
        // 旧虚拟屏可能已经不存在，release() 内部会忽略失败
        ExtendHost.release();
        Stage.close();
        showGlassesStage(d);
    }

    /** GL 线程、Stage 生命周期状态：用来区分"渲染停了"和"生产者不画了"。 */
    private String renderStateSummary() {
        long now = SystemClock.elapsedRealtime();
        long drawAgo = QuadRenderer.lastDrawAtMs == 0 ? -1 : now - QuadRenderer.lastDrawAtMs;
        return "（GL 最近绘制 " + (drawAgo < 0 ? "未知" : drawAgo + "ms 前")
                + " · stageReady=" + Stage.stageReady
                + " · stageLaunched=" + Stage.launched
                + " · stageActivity=" + (Stage.activity() != null) + "）";
    }

    /** 每 5 秒一条心跳：卡住时用它判断"进程被冻结"（心跳停）还是"只是画面停了"（心跳继续）。 */
    private void heartbeat() {
        long now = SystemClock.elapsedRealtime();
        if (!running || now - lastBeatAtMs < 5000) {
            return;
        }
        lastBeatAtMs = now;
        diag("心跳 帧=" + QuadRenderer.textureFrames
                + " 画面静默=" + ((now - lastFrameAtMs) / 1000) + "s"
                + renderStateSummary() + displayStateSummary());
    }

    /** 扩展屏与手机屏的电源状态，用来判断"是息屏还是应用不画了"。 */
    private String displayStateSummary() {
        try {
            int id = currentDisplayId();
            Display ext = id > 0 ? dm.getDisplay(id) : null;
            Display main = dm.getDisplay(Display.DEFAULT_DISPLAY);
            return "（扩展屏 " + (ext == null ? "无" : stateName(ext.getState()))
                    + " · 手机屏 " + (main == null ? "无" : stateName(main.getState()))
                    + " · hosted=" + hostedMode + "）";
        } catch (Throwable t) {
            return "（读取显示状态失败：" + t + "）";
        }
    }

    private static String stateName(int state) {
        switch (state) {
            case Display.STATE_OFF: return "OFF";
            case Display.STATE_ON: return "ON";
            case Display.STATE_DOZE: return "DOZE";
            case Display.STATE_DOZE_SUSPEND: return "DOZE_SUSPEND";
            case Display.STATE_ON_SUSPEND: return "ON_SUSPEND";
            case Display.STATE_VR: return "VR";
            default: return "state=" + state;
        }
    }

    /**
     * 会话期间是否让手机保持亮屏。
     *
     * 扩展屏模式下手机就是触控板，本来就得亮着；而息屏会让系统把扩展屏和上面的
     * 目标应用一起挂起 —— 表现正是"声音还在、画面冻住、帧数不涨"。
     * 镜像模式不设：屏幕关了本来也没什么可镜像的，没必要耗电。
     */
    private void setScreenOn(boolean on) {
        final boolean want = on;
        ui.post(() -> {
            try {
                if (want) {
                    act.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                } else {
                    act.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                }
                screenOnHeld = want;
            } catch (Throwable t) {
                Log.w(TAG, "设置保持亮屏失败", t);
            }
        });
    }

    // ------------------------------------------------------------ 状态推送

    private void pushStatus() {
        if (statusSink == null) {
            ui.removeCallbacks(statusTask);
            return;
        }
        // 启动看门狗：投屏开始 6 秒还没帧 → 重建一次虚拟屏
        if (running && !restartTried && CaptureService.isRunning()
                && QuadRenderer.textureFrames == 0
                && SystemClock.elapsedRealtime() - stageStartMs > 6000) {
            restartTried = true;
            diag("6 秒未收到投屏帧，重建虚拟屏");
            CaptureService.restart(act);
        }
        // 焦点恢复布防
        if (running) {
            int did = currentDisplayId();
            if (did > 0 && did != focusArmedDisplay) {
                focusArmedDisplay = did;
                AutoConsentAccessibilityService.requestFocusRestore(did);
            }
        }
        for (String line : Stage.drainLog()) {
            diag(line);
        }
        try {
            statusSink.success(statusMap());
        } catch (Throwable t) {
            Log.w(TAG, "status 推送失败", t);
            statusSink = null;
        }
        ui.removeCallbacks(statusTask);
        ui.postDelayed(statusTask, 800);
    }

    private Map<String, Object> statusMap() {
        java.util.HashMap<String, Object> m = new java.util.HashMap<>();
        Display ext = DisplayUtils.findExternal(dm);
        m.put("running", running);
        m.put("starting", starting);
        m.put("glasses", ext != null);
        m.put("displayName", DisplayUtils.describe(ext));
        m.put("displayId", currentDisplayId());
        m.put("stageReady", Stage.stageReady);
        m.put("stageLaunched", Stage.launched);
        m.put("presentation", presentation != null);
        m.put("frames", QuadRenderer.textureFrames);
        m.put("frameIdleMs", running && lastFrameAtMs > 0
                ? (int) Math.min(Integer.MAX_VALUE, SystemClock.elapsedRealtime() - lastFrameAtMs)
                : 0);
        m.put("aspect", (double) QuadRenderer.contentAspectNow);
        m.put("mode", hostedMode ? "hosted" : "mirror");
        m.put("hidReady", glass != null);
        m.put("viewMode", viewModeName(viewMode));
        m.put("component", hostedComponent);
        m.put("label", hostedLabel);

        java.util.HashMap<String, Object> poseM = new java.util.HashMap<>();
        poseM.put("tracking", pose.isTracking());
        float[] yp = pose.yawPitch();
        poseM.put("yaw", (double) yp[0]);
        poseM.put("pitch", (double) yp[1]);
        poseM.put("roll", (double) pose.rollDeg());
        poseM.put("hz", (double) pose.hz);
        poseM.put("frozen", pose.isFrozen());
        poseM.put("biasDps", (double) pose.biasDps());
        poseM.put("residualDps", (double) pose.residualDps());
        poseM.put("firstCal", pose.isFirstCalibrated());
        m.put("pose", poseM);

        java.util.HashMap<String, Object> capM = new java.util.HashMap<>();
        int[] want = CaptureSize.of(act);
        capM.put("wantW", want[0]);
        capM.put("wantH", want[1]);
        capM.put("w", CaptureService.capW);
        capM.put("h", CaptureService.capH);
        m.put("capture", capM);
        m.put("shots", captureExtra());

        java.util.HashMap<String, Object> imuM = new java.util.HashMap<>();
        imuM.put("open", glass != null && glass.isOpen());
        imuM.put("frames", glass != null ? glass.frames() : 0);
        imuM.put("sendMode", glass != null ? glass.sendModeName() : "");
        imuM.put("deviceType", deviceType);
        imuM.put("model", modelName());
        imuM.put("gyroSign", pose.gyroSignText());
        m.put("imu", imuM);

        java.util.HashMap<String, Object> a11y = new java.util.HashMap<>();
        a11y.put("enabled", AutoConsentAccessibilityService.isEnabled(act));
        a11y.put("canInject", AutoConsentAccessibilityService.canInject());
        m.put("accessibility", a11y);

        java.util.HashMap<String, Object> shizuku = new java.util.HashMap<>();
        shizuku.put("installed", ShizukuBridge.installed(act));
        shizuku.put("ready", ShizukuBridge.ready(act));
        m.put("shizuku", shizuku);

        m.put("error", lastError);
        m.put("version", versionName());
        return m;
    }

    /**
     * 画面模式名（给 Flutter 侧）。
     *
     * 必须发字符串：Dart 侧按 String 解析，早先这里发的是 int，
     * `fromMap` 直接类型异常 → config 永远为 null → 界面卡在"正在连接原生引擎…"。
     */
    private static String viewModeName(int mode) {
        return mode == HeadPose.MODE_TRACK ? "track"
                : mode == HeadPose.MODE_EXTEND ? "extend" : "hover";
    }

    private Map<String, Object> configMap() {
        java.util.HashMap<String, Object> m = new java.util.HashMap<>();
        m.put("size", sizeP);
        m.put("distance", distP);
        m.put("fov", fovP);
        m.put("resolution", resP);
        m.put("freeze", freeze);
        m.put("viewMode", viewModeName(viewMode));
        m.put("followTau", (double) followTau);
        m.put("invertForward", invFwd);
        m.put("invertYaw", invYaw);
        m.put("invertPitch", invPitch);
        m.put("invertRoll", invRoll);
        m.put("mode", hostedMode ? "hosted" : "mirror");
        m.put("panelLevel", panelLevel);
        m.put("color", colorLevel);
        m.put("brightnessMin", GlassUsb.LEVEL_MIN);
        m.put("brightnessMax", GlassUsb.BRIGHT_MAX);
        m.put("colorMin", GlassUsb.COLOR_MIN);
        m.put("colorMax", GlassUsb.COLOR_MAX);
        m.put("compat", compat);
        m.put("trusted", trusted);
        m.put("component", hostedComponent);
        m.put("label", hostedLabel);
        m.put("version", versionName());
        return m;
    }

    private Map<String, Object> capsMap() {
        java.util.HashMap<String, Object> m = new java.util.HashMap<>();
        m.put("accessibility", AutoConsentAccessibilityService.isEnabled(act));
        m.put("canInject", AutoConsentAccessibilityService.canInject());
        m.put("shizukuInstalled", ShizukuBridge.installed(act));
        m.put("shizukuReady", ShizukuBridge.ready(act));
        m.put("version", versionName());
        return m;
    }

    private String versionName() {
        try {
            return act.getPackageManager().getPackageInfo(act.getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "unknown";
        }
    }

    // ------------------------------------------------------------ 设置读写

    private boolean loading;

    private void loadSettings() {
        SharedPreferences p = act.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        loading = true;
        sizeP = p.getInt("size", 70);
        distP = p.getInt("dist", 15);
        fovP = p.getInt("fov", 8);
        resP = clamp(p.getInt("res", 1), 0, RES_LEVELS.length - 1);
        CaptureSize.maxLongSide = RES_LEVELS[resP];
        freeze = p.getBoolean("freeze", true);
        viewMode = p.getInt("view_mode", p.getBoolean("tracking", false)
                ? HeadPose.MODE_TRACK : HeadPose.MODE_HOVER);
        followTau = p.getFloat("follow_tau", 0.4f);
        panelUsed = p.getBoolean("panel_used", false);
        panelLevel = p.getInt("brightness", 6);
        if (panelLevel < GlassUsb.LEVEL_MIN || panelLevel > GlassUsb.BRIGHT_MAX) {
            // 2.2.x 曾把色彩档（11~13）存进 brightness：不跨会话保留，回落到 6
            panelLevel = 6;
        }
        colorLevel = 0;
        boolean dirV3 = p.getBoolean("dir_v3", false);
        invFwd = dirV3 && p.getBoolean("inv_fwd", false);
        invYaw = dirV3 && p.getBoolean("inv_yaw", false);
        invPitch = dirV3 && p.getBoolean("inv_pitch", false);
        invRoll = dirV3 && p.getBoolean("inv_roll", false);
        if (!dirV3) {
            p.edit().putBoolean("dir_v3", true)
                    .putBoolean("inv_fwd", false).putBoolean("inv_yaw", false)
                    .putBoolean("inv_pitch", false).putBoolean("inv_roll", false).apply();
        }
        // 旧版本可能存过 compat=true（MediaProjection 公共屏），该路径承载不了
        // 第三方应用，一律回到 false，避免升级后仍是黑屏
        compat = false;
        trusted = p.getBoolean("trusted", true);
        hostedMode = p.getInt("mode", 0) >= 1;
        hostedComponent = p.getString("hosted_comp", null);
        hostedLabel = p.getString("hosted_label", null);
        loading = false;
    }

    private void saveNow() {
        if (loading) {
            return;
        }
        act.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putInt("size", sizeP)
                .putInt("dist", distP)
                .putInt("fov", fovP)
                .putInt("res", resP)
                .putBoolean("freeze", freeze)
                .putInt("view_mode", viewMode)
                .putFloat("follow_tau", followTau)
                .putBoolean("panel_used", panelUsed)
                .putInt("brightness", panelLevel)
                .putBoolean("inv_fwd", invFwd)
                .putBoolean("inv_yaw", invYaw)
                .putBoolean("inv_pitch", invPitch)
                .putBoolean("inv_roll", invRoll)
                .putBoolean("compat", compat)
                .putBoolean("trusted", trusted)
                .putInt("mode", hostedMode ? 1 : 0)
                .putString("hosted_comp", hostedComponent)
                .putString("hosted_label", hostedLabel)
                .apply();
    }

    // ------------------------------------------------------------ 小工具

    /** Android 13+ 前台服务通知需要运行时权限；拒绝不影响投屏，只是通知不显示。 */
    private void requestNotificationPermission() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33
                    && act.checkSelfPermission("android.permission.POST_NOTIFICATIONS")
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                act.requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 1002);
            }
        } catch (Throwable t) {
            Log.w(TAG, "申请通知权限失败", t);
        }
    }

    private void diag(String line) {
        Log.i(TAG, line);
    }

    private void toast(final String s) {
        ui.post(() -> {
            try {
                android.widget.Toast.makeText(act, s, android.widget.Toast.LENGTH_SHORT).show();
            } catch (Throwable ignored) {
            }
            method.invokeMethod("onToast", s);
        });
    }

    private static int clamp(int v, int lo, int hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    private static float clampF(float v, float lo, float hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    private static double clamp01(double v) {
        return v < 0 ? 0 : (v > 1 ? 1 : v);
    }

    // ------------------------------------------------------------ 截图 / 录像 / 授权 / 杀进程

    /**
     * 截图：让渲染器在下一帧画完后把默认 framebuffer 读成 PNG。
     *
     * 为什么不在引擎这边直接抓手机屏：要的是**眼镜里看到的画面**
     * （3DoF 位移、光标、虚拟屏透视都在里面），那只有 GL 线程知道。
     */
    private void requestScreenshot(MethodChannel.Result result) {
        QuadRenderer r = currentRenderer();
        if (r == null) {
            result.error("engine", "当前没有眼镜画面（先开始悬停）", null);
            return;
        }
        r.requestShot();

        // 轮询窗口 400ms → 2500ms。
        //
        // 原值 400ms 的依据是"60Hz 下 1~2 帧就好"，但那只算了帧间隔，
        // 没算 captureCurrentFrame 的真实开销：glReadPixels（1920×1080 同步
        // 回读）+ 像素搬运 + 编码 + 写文件。整套在慢设备上轻松越过 400ms，
        // 于是出现"文件已保存、界面却报截图超时"的割裂现象 —— 用户明确反馈
        // 「截图会提示失败，但成功了」就是这个。
        //
        // 两头都修：这里放宽窗口（给真实耗时留余量），
        // QuadRenderer/GlassCapture 那边把 PNG100 换成 JPEG95 + 批量像素搬运
        // （把真实耗时压到几十毫秒）。
        final long deadline = SystemClock.elapsedRealtime() + 2500;
        final Runnable[] poll = new Runnable[1];
        poll[0] = () -> {
            String p = r.takeShotResult();
            if (p != null) {
                lastCapturePath = p;
                diag("截图已保存 " + p);
                toast("截图已保存");
                result.success(p);
                return;
            }
            if (SystemClock.elapsedRealtime() > deadline) {
                // 错误文案从"截图超时（画面可能没在渲染）"改成明确的处置指引：
                // 超时不代表失败，文件有可能已经落盘，只是回传晚了一步。
                result.error("engine",
                        "截图超时：画面可能没在出帧，请先确认投屏正常；若相册里已有新图则说明已保存", null);
                return;
            }
            ui.postDelayed(poll[0], 30);
        };
        ui.postDelayed(poll[0], 30);
    }

    /** 开始录像：编码器尺寸跟眼镜屏走，录出来的就是用户看到的构图。 */
    private void startRecording(MethodChannel.Result result) {
        if (recorder != null && recorder.isRunning()) {
            result.error("engine", "已在录制中", null);
            return;
        }
        QuadRenderer r = currentRenderer();
        if (r == null) {
            result.error("engine", "当前没有眼镜画面（先开始悬停）", null);
            return;
        }
        int w = r.surfaceW > 0 ? r.surfaceW : (Stage.appContext != null
                ? CaptureSize.of(Stage.appContext)[0] : 1920);
        int h = r.surfaceH > 0 ? r.surfaceH : (Stage.appContext != null
                ? CaptureSize.of(Stage.appContext)[1] : 1080);
        java.io.File out = GlassCapture.newFile(act, "rec", "mp4");
        GlassRecorder rec = new GlassRecorder(w, h, out);
        String err = rec.start();
        if (err != null) {
            result.error("engine", err, null);
            return;
        }
        recorder = rec;
        r.setRecorder(rec);
        lastCapturePath = rec.filePath();
        diag("开始录制 " + w + "x" + h + " -> " + rec.filePath());
        toast("开始录制");
        result.success(rec.filePath());
    }

    /** 停止录像并落盘 + 登记相册。 */
    private void stopRecording(MethodChannel.Result result) {
        GlassRecorder rec = recorder;
        if (rec == null) {
            result.error("engine", "当前没有在录制", null);
            return;
        }
        QuadRenderer r = currentRenderer();
        if (r != null) {
            r.setRecorder(null);
        }
        recorder = null;
        // stop() 内部会 join drain 线程，放 IO 线程做，避免卡 UI
        IO.execute(() -> {
            // ⚠️ 必须先等 GL 线程把录像上下文拆干净，再停编码器。
            //
            // RecorderGl 的工作线程可能正卡在 eglSwapBuffers 上往编码器 Surface 里写；
            // 这边一旦 codec.stop() + release 掉 Surface，就是让生产者往已释放的
            // BufferQueue 里写 —— native 层崩溃或死锁。setRecorder(null) 只是登记意愿，
            // 真正的销毁发生在 GL 线程的下一帧，所以这里要等那个标记。
            if (r != null && !r.awaitRecorderTornDown(1500)) {
                diag("录像上下文 1.5 秒没拆完，仍继续停编码器（可能丢掉尾帧）");
            }
            String path = rec.stop();
            java.io.File f = path != null ? new java.io.File(path) : null;
            if (f != null && f.exists() && f.length() > 0) {
                GlassCapture.publishVideo(act, f);
                long size = f.length();
                ui.post(() -> {
                    diag("录像已保存 " + path + "（" + (size / 1024) + " KB）");
                    toast("录像已保存");
                    result.success(path);
                });
            } else {
                ui.post(() -> result.error("engine", "录像文件为空（可能没录到帧）", null));
            }
        });
    }

    /**
     * 看门狗第三级用：静默杀进程 + 重拉，不返回 MethodChannel 结果。
     * 与 killHostedProcess 同一套动作，只是没有 UI 调用方在等结果。
     */
    private void killHostedQuietly() {
        final String comp = hostedComponent;
        if (comp == null || !comp.contains("/")) {
            return;
        }
        final String pkg = comp.split("/")[0];
        if (!ShizukuBridge.ready(act)) {
            diag("想杀 " + pkg + " 但没有 Shizuku 授权，跳过（画面卡死请手动重连）");
            return;
        }
        toast("画面卡死但姿态正常，正在重启目标应用");
        ShizukuBridge.forceStop(pkg, ok -> {
            diag("看门狗 force-stop " + pkg + (ok ? " 成功" : " 失败"));
            final int did = ExtendHost.displayId;
            ui.postDelayed(() -> {
                if (did > 0 && running) {
                    ExtendHost.launch(act, did, comp);
                    lastFrameAtMs = SystemClock.elapsedRealtime();
                    stallLogged = false;
                    stallStage = 0;
                    diag("已把 " + pkg + " 重新拉回 display=" + did);
                }
            }, 800);
        });
    }

    /**
     * 用 shell（Shizuku 或已授权的 adb）杀掉目标应用进程。
     *
     * 这是画面卡死的最后手段：kill 之后系统会重新拉一份干净进程，
     * 比"重建虚拟屏"更彻底。只杀 hostedComponent 指定的那个包，不碰系统进程。
     */
    private void killHostedProcess(MethodChannel.Result result) {
        final String comp = hostedComponent;
        if (comp == null || !comp.contains("/")) {
            result.error("engine", "当前不是扩展屏模式，没有可杀的目标应用", null);
            return;
        }
        final String pkg = comp.split("/")[0];
        if (!ShizukuBridge.ready(act)) {
            result.error("engine", "需要 Shizuku（或已授权的 adb）才能杀进程", null);
            return;
        }
        diag("杀掉目标进程 " + pkg);
        ShizukuBridge.forceStop(pkg, ok -> {
            diag("force-stop " + pkg + (ok ? " 成功" : " 失败（可能是权限或包名不对）"));
            // 杀完把应用重新拉回扩展屏，用户不用手动再点一次
            final int did = ExtendHost.displayId;
            ui.postDelayed(() -> {
                if (did > 0) {
                    ExtendHost.launch(act, did, comp);
                    lastFrameAtMs = SystemClock.elapsedRealtime();
                    stallLogged = false;
                    stallStage = 0;
                }
                toast(ok ? "已重启目标应用" : "杀进程失败，请检查 Shizuku 授权");
                result.success(pkg);
            }, 600);
        });
    }

    /** 打开截图/录像所在目录（用系统文件管理器）。 */
    private void openCaptureFolder() {
        try {
            java.io.File d = GlassCapture.dir(act);
            android.net.Uri uri = android.net.Uri.parse(
                    "content://com.android.externalstorage.documents/document/primary%3A"
                            + "Android%2Fdata%2F" + act.getPackageName() + "%2Ffiles%2Fcaptures");
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(uri, "vnd.android.document/directory");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            act.startActivity(i);
            diag("打开截图目录 " + d.getAbsolutePath());
        } catch (Throwable t) {
            // 部分 ROM 不支持直接打开目录，退回提示路径
            toast("截图目录：" + GlassCapture.dir(act).getAbsolutePath());
        }
    }

    /**
     * 一次性把运行需要的权限都申请了。
     *
     * 清单：
     *   - POST_NOTIFICATIONS（13+）：前台服务通知
     *   - WRITE_EXTERNAL_STORAGE（仅 9 及以下）：往公共目录写截图/录像
     *   - READ_MEDIA_IMAGES / READ_MEDIA_VIDEO（13+）：让相册能看到我们登记的项
     *
     * 录像/截图本身在 10+ 走 MediaStore 自己创建的项，不需要存储权限；
     * 这里申请是为了覆盖旧系统与"想在相册里直接浏览"的场景。
     */
    private void ensureRuntimePermissions() {
        // 节流：真机日志里这条在 3 秒内被触发过 8 次（连续点按 / 通道重入），
        // 每次都往诊断区刷一行，把别的信息挤掉了。1.5 秒内只处理第一次。
        long now = SystemClock.uptimeMillis();
        if (now - lastPermDiagAtMs < 1500) {
            return;
        }
        lastPermDiagAtMs = now;
        try {
            java.util.ArrayList<String> want = new java.util.ArrayList<>();
            if (Build.VERSION.SDK_INT >= 33) {
                if (act.checkSelfPermission("android.permission.POST_NOTIFICATIONS")
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    want.add("android.permission.POST_NOTIFICATIONS");
                }
                if (act.checkSelfPermission("android.permission.READ_MEDIA_IMAGES")
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    want.add("android.permission.READ_MEDIA_IMAGES");
                }
                if (act.checkSelfPermission("android.permission.READ_MEDIA_VIDEO")
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    want.add("android.permission.READ_MEDIA_VIDEO");
                }
            } else if (Build.VERSION.SDK_INT <= 28) {
                if (act.checkSelfPermission("android.permission.WRITE_EXTERNAL_STORAGE")
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    want.add("android.permission.WRITE_EXTERNAL_STORAGE");
                }
            }
            if (want.isEmpty()) {
                diag("权限已齐，无需申请");
                return;
            }
            diag("申请权限：" + want);
            act.requestPermissions(want.toArray(new String[0]), REQ_PERMISSIONS);
        } catch (Throwable t) {
            Log.w(TAG, "申请权限失败", t);
        }
    }

    /** 由 MainActivity 转发 onRequestPermissionsResult。 */
    public void onPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != REQ_PERMISSIONS) {
            return;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < permissions.length; i++) {
            boolean ok = i < grantResults.length
                    && grantResults[i] == android.content.pm.PackageManager.PERMISSION_GRANTED;
            sb.append(permissions[i]).append(ok ? "=OK " : "=DENIED ");
        }
        permissionNote = sb.toString().trim();
        diag("权限结果：" + permissionNote);
    }

    /** 供 UI 显示的截图/录像状态。 */
    private Map<String, Object> captureExtra() {
        java.util.HashMap<String, Object> m = new java.util.HashMap<>();
        m.put("recording", recorder != null && recorder.isRunning());
        m.put("lastPath", lastCapturePath);
        m.put("dir", GlassCapture.dir(act).getAbsolutePath());
        m.put("permissionNote", permissionNote);
        return m;
    }

    /**
     * 取当前活着的渲染器。
     *
     * 画面可能承载在两种地方：本 Activity 的 Presentation（glView 有值），
     * 或者眼镜那块屏自己的 StageActivity（glView 为 null，但 ScreenGlView
     * 在创建时把渲染器登记到静态引用）。截图 / 录像两种都要能工作。
     */
    private QuadRenderer currentRenderer() {
        ScreenGlView view = glView;
        QuadRenderer r = view != null ? view.renderer() : null;
        if (r == null) {
            r = ScreenGlView.live();
        }
        return r;
    }

    /** 供 UI 显示的分辨率档位名。 */
    static String[] resolutionNames() {
        return new String[]{"1920（清晰）", "1600（均衡）", "1280（流畅）"};
    }

    static String fmt(String pattern, Object... args) {
        return String.format(Locale.US, pattern, args);
    }
}
