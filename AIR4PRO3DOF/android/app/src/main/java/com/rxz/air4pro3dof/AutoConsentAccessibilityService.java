package com.rxz.air4pro3dof;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.accessibilityservice.GestureDescription;
import android.content.Intent;
import android.content.Context;
import android.graphics.Path;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.util.SparseArray;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 无障碍辅助服务（免 Shizuku 全链路的核心）。
 *
 * 职责三块：
 *   1. 识别系统授权弹窗：MediaProjection 录屏授权 + USB 设备访问授权
 *      （文案集合与标题谓词移植自 base.apk(Arctrl)；**只识别、只记录，不自动点击**，
 *       点不点由用户决定 —— 见 AUTO_CLICK 常量的注释）
 *   2. 跨屏焦点恢复：副屏应用切换后焦点丢失，自动把输入焦点还给目标 display
 *   3. 无障碍手势注入：触控板的点击/滑动/返回派发到扩展屏（替代 Shizuku `input -d`，
 *      API 30+；这是免 Shizuku 时唯一的触摸注入通道）
 *
 * 文案集合与标题谓词与 base.apk 实测值逐字对齐（G/L/O 集合、c2 case0/1、
 * 5 秒窗口 + 250ms 轮询）。
 */
public class AutoConsentAccessibilityService extends AccessibilityService {

    private static final String TAG = "AutoConsent";

    /** systemui 包名。getPackageName() 可能返回 null，比较前必须判空。 */
    private static final String SYS_UI = "com.android.systemui";

    @android.annotation.SuppressLint("StaticFieldLeak")
    private static volatile AutoConsentAccessibilityService instance;

    private final Handler main = new Handler(Looper.getMainLooper());

    /**
     * 无障碍节点操作（getWindows / 递归 getChild / findFocus）全是 binder 调用，
     * 一棵稍大的树就有上百次往返。**绝不能放在主线程**：本应用的主线程还要处理
     * CaptureService 的 attachSurface / createVirtualDisplay，一旦被占死，
     * 虚拟屏挂不上 Surface，眼镜就一直是灰屏（实测踩过）。
     * 所有扫描/遍历统一走这条后台线程。
     */
    private final java.util.concurrent.ExecutorService worker =
            java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
                Thread t = new Thread(r, "a11y-worker");
                t.setDaemon(true);
                return t;
            });

    // ------------------------------------------------------------ 生命周期

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
        // 有些 ROM 会忽略 XML flag，动态补一次（82 = INCLUDE_NOT_IMPORTANT_VIEWS(2)
        // | REPORT_VIEW_IDS(16) | RETRIEVE_INTERACTIVE_WINDOWS(64)，与 base.apk 一致）。
        // REPORT_VIEW_IDS 不是可选项：没有它 getViewIdResourceName() 拿不到 id，
        // "android:id/button1" 这类兜底匹配会失效。
        AccessibilityServiceInfo info = getServiceInfo();
        if (info != null) {
            info.flags |= 82;
            setServiceInfo(info);
        }
        Log.i(TAG, "connected, flags=" + (info != null ? info.flags : -1));
        Stage.log("无障碍辅助已连接");
    }

    @Override
    public boolean onUnbind(Intent intent) {
        if (instance == this) {
            instance = null;
        }
        Stage.log("无障碍辅助已断开");
        return super.onUnbind(intent);
    }

    @Override
    public void onInterrupt() {
    }

    @Override
    public void onDestroy() {
        if (instance == this) {
            instance = null;
        }
        main.removeCallbacksAndMessages(null);
        worker.shutdownNow();
        super.onDestroy();
    }

    // ------------------------------------------------------------ 对外查询

    public static AutoConsentAccessibilityService get() {
        return instance;
    }

    /** 本服务是否已在系统设置中启用（MainActivity 引导用）。 */
    public static boolean isEnabled(Context ctx) {
        String want = ctx.getPackageName() + "/" + AutoConsentAccessibilityService.class.getName();
        String enabled = Settings.Secure.getString(
                ctx.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        return enabled != null && enabled.contains(want);
    }

    /** 免 Shizuku 触摸注入是否可用（dispatchGesture 指定 displayId 需 API 30+）。 */
    public static boolean canInject() {
        return instance != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R;
    }

    // ------------------------------------------------------------ ① 授权弹窗自动点击

    /** 授权弹窗按钮文本集合（与 base.apk 的 G/L 集合逐字一致，双语覆盖主流 ROM）。 */
    private static final Set<String> BTN_CONTINUE = new HashSet<>(Arrays.asList("继续", "Continue"));
    private static final Set<String> BTN_START = new HashSet<>(Arrays.asList(
            "开始", "立即开始", "Start", "Start now"));
    /** 通用确认按钮 id（与 base.apk 的 O 集合一致）+ USB 授权框的常见确认键。 */
    private static final Set<String> BTN_IDS = new HashSet<>(Arrays.asList(
            "android:id/button1", "com.android.systemui:id/yes"));
    private static final Set<String> BTN_USB = new HashSet<>(Arrays.asList(
            "确定", "允许", "OK", "Allow"));

    /** 标题动词表（与 base.apk c2 case 0 一致；base.apk 硬编码 "Arctrl"，这里泛化为本应用名）。 */
    private static final String[] TITLE_VERBS = {
            "录制", "共享", "投放", "投射", "投屏", "屏幕", "record", "share", "cast"};

    private static final long CONSENT_WINDOW_MS = 5000;
    private static final long SWEEP_INTERVAL_MS = 250;

    private volatile long consentDeadline;     // MediaProjection 授权窗口（现在只用于识别）
    private volatile long usbDeadline;         // USB 授权窗口（现在只用于识别）
    private boolean consentSweepQueued;
    private boolean usbSweepQueued;
    /** 同一个授权窗口内只记一条日志，避免 250ms 轮询把 logcat 刷爆。 */
    private volatile boolean consentLogged;
    private volatile boolean usbLogged;
    /**
     * 「窗口已结束」也只记一条。
     *
     * 为什么需要它：sweepConsentDialog() 有两条入口 —— scheduleSweep() 会先
     * removeCallbacks 再 postDelayed（单条），但 onAccessibilityEvent 里的
     * 事件加速路径是直接 main.post(...)，不带 removeCallbacks。systemui 弹窗
     * 期间事件很密集，于是会有多个 sweepConsentDialog 排在同一毫秒执行，
     * 每个都发现 deadline 已过、各打一行，实测刷出 7 行一模一样的文案。
     * 这里加一次性闸门，只让第一行落地。
     */
    private volatile boolean consentEndLogged;
    private volatile boolean usbEndLogged;

    /**
     * 授权弹窗是否自动点击的**总开关**。
     *
     * 置 false 的原因（实测）：系统弹窗里"继续/开始"这些文本节点本身通常不可点击，
     * 而旧实现 clickOrBubble() 会沿父链向上找第一个可点击祖先去点，在 Android 14 的
     * 录屏弹窗上那个祖先正好是"取消"所在的容器 —— 于是自动授权反而把投屏取消了：
     *   已自动确认投屏授权 → 投屏授权被取消 → 已停止：需要投屏权限
     * 现在只识别、只记录，点不点由用户决定。
     */
    private static final boolean AUTO_CLICK = false;

    /** 发起录屏授权前调用：开一个识别窗口（不再点击，只把弹窗内容写进日志）。 */
    public static void armConsentAutoClick(long durationMs) {
        AutoConsentAccessibilityService svc = instance;
        if (svc == null) {
            return;
        }
        svc.consentDeadline = SystemClock.uptimeMillis() + durationMs;
        svc.consentLogged = false;
        svc.scheduleSweep(false, 0);
        Log.i(TAG, "MediaProjection consent watch armed " + durationMs + "ms (auto-click="
                + AUTO_CLICK + ")");
    }

    /** 申请 USB 设备权限前调用：同上，只识别。 */
    public static void armUsbConsentAutoClick(long durationMs) {
        AutoConsentAccessibilityService svc = instance;
        if (svc == null) {
            return;
        }
        svc.usbDeadline = SystemClock.uptimeMillis() + durationMs;
        svc.usbLogged = false;
        svc.scheduleSweep(true, 0);
        Log.i(TAG, "USB consent watch armed " + durationMs + "ms (auto-click="
                + AUTO_CLICK + ")");
    }

    private void scheduleSweep(boolean usb, long delay) {
        Runnable sweep = usb ? this::sweepUsbDialog : this::sweepConsentDialog;
        main.removeCallbacks(sweep);
        main.postDelayed(sweep, delay);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent e) {
        // 事件驱动加速：systemui 弹窗一出现立刻扫，不等下个轮询周期
        if (e == null) {
            return;
        }
        CharSequence pkg = e.getPackageName();
        // getPackageName() 可能返回 null（部分系统事件没有包名），
        // 此时 String.contentEquals(null) 会直接 NPE 把整个无障碍服务打死。
        boolean fromSystemUi = pkg != null && SYS_UI.contentEquals(pkg);
        if (fromSystemUi && SystemClock.uptimeMillis() < consentDeadline) {
            if (!consentSweepQueued) {
                consentSweepQueued = true;
                main.post(() -> {
                    consentSweepQueued = false;
                    sweepConsentDialog();
                });
            }
        }
        if (fromSystemUi && SystemClock.uptimeMillis() < usbDeadline) {
            if (!usbSweepQueued) {
                usbSweepQueued = true;
                main.post(() -> {
                    usbSweepQueued = false;
                    sweepUsbDialog();
                });
            }
        }
        // 焦点恢复：窗口变化时补一次
        if (focusDisplayId > 0 && !focusRestoreQueued) {
            focusRestoreQueued = true;
            main.post(() -> {
                focusRestoreQueued = false;
                restoreFocus();
            });
        }
    }

    private final java.util.concurrent.atomic.AtomicBoolean consentSweeping =
            new java.util.concurrent.atomic.AtomicBoolean();
    private final java.util.concurrent.atomic.AtomicBoolean usbSweeping =
            new java.util.concurrent.atomic.AtomicBoolean();

    /** 录屏授权弹窗扫描（MediaProjection consent）：调度在主线程，扫描体在工作线程。 */
    private void sweepConsentDialog() {
        if (SystemClock.uptimeMillis() > consentDeadline) {
            if (!consentEndLogged) {
                consentEndLogged = true;
                Stage.log("投屏授权窗口已结束（未识别到弹窗，或你已手动处理）");
            }
            return;
        }
        if (!consentSweeping.compareAndSet(false, true)) {
            return;   // 单飞：上一轮还没扫完就跳过这一拍
        }
        worker.execute(() -> {
            try {
                sweepConsentOnce();
            } catch (Throwable t) {
                Log.w(TAG, "consent sweep 异常", t);
                scheduleSweep(false, SWEEP_INTERVAL_MS);
            } finally {
                consentSweeping.set(false);
            }
        });
    }

    private void sweepConsentOnce() {
        if (SystemClock.uptimeMillis() > consentDeadline) {
            return;
        }
        AccessibilityNodeInfo root = findSystemUiDialogRoot();
        if (root == null) {
            scheduleSweep(false, SWEEP_INTERVAL_MS);
            return;
        }
        try {
            if (titleMatchesProjection(root)) {
                if (!consentLogged) {
                    consentLogged = true;
                    String dump = describeDialog(root);
                    Stage.log("检测到投屏授权弹窗，请手动点「立即开始」");
                    Log.i(TAG, "MediaProjection consent dialog detected:\n" + dump);
                }
                if (AUTO_CLICK) {
                    clickButton(root, BTN_CONTINUE, BTN_START, BTN_IDS);
                }
            }
        } finally {
            root.recycle();
        }
        scheduleSweep(false, SWEEP_INTERVAL_MS);
    }

    private void sweepUsbOnce() {
        if (SystemClock.uptimeMillis() > usbDeadline) {
            return;
        }
        AccessibilityNodeInfo root = findSystemUiDialogRoot();
        if (root == null) {
            scheduleSweep(true, SWEEP_INTERVAL_MS);
            return;
        }
        try {
            if (titleMatchesUsb(root)) {
                if (!usbLogged) {
                    usbLogged = true;
                    String dump = describeDialog(root);
                    Stage.log("检测到 USB 授权弹窗，请手动点「允许」");
                    Log.i(TAG, "USB consent dialog detected:\n" + dump);
                }
                if (AUTO_CLICK) {
                    clickButton(root, BTN_USB, BTN_USB, BTN_IDS);
                }
            }
        } finally {
            root.recycle();
        }
        scheduleSweep(true, SWEEP_INTERVAL_MS);
    }

    /**
     * 把弹窗里每个节点的可读信息拼成多行，用于日志定位"哪个才是真正的按钮"。
     * 只在识别到弹窗时调用一次，不参与轮询热路径。
     */
    private String describeDialog(AccessibilityNodeInfo root) {
        StringBuilder sb = new StringBuilder();
        describeNode(root, sb, 0);
        return sb.toString();
    }

    private void describeNode(AccessibilityNodeInfo n, StringBuilder sb, int depth) {
        if (depth > 12 || sb.length() > 4000) {
            return;
        }
        String text = textOf(n);
        String id = n.getViewIdResourceName();
        if (text != null || id != null) {
            for (int i = 0; i < depth; i++) {
                sb.append("  ");
            }
            sb.append(n.getClassName());
            if (id != null) {
                sb.append(" id=").append(id);
            }
            if (text != null) {
                sb.append(" text=").append(text);
            }
            sb.append(" clickable=").append(n.isClickable());
            sb.append(" enabled=").append(n.isEnabled());
            sb.append('\n');
        }
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c == null) {
                continue;
            }
            try {
                describeNode(c, sb, text != null || id != null ? depth + 1 : depth);
            } finally {
                c.recycle();
            }
        }
    }

    /** USB 设备授权弹窗扫描（"允许 xxx 访问 USB 设备吗？"）。 */
    private void sweepUsbDialog() {
        if (SystemClock.uptimeMillis() > usbDeadline) {
            if (!usbEndLogged) {
                usbEndLogged = true;
                Stage.log("USB 授权窗口已结束（未识别到弹窗，或你已手动处理）");
            }
            return;
        }
        if (!usbSweeping.compareAndSet(false, true)) {
            return;
        }
        worker.execute(() -> {
            try {
                sweepUsbOnce();
            } catch (Throwable t) {
                Log.w(TAG, "usb sweep 异常", t);
                scheduleSweep(true, SWEEP_INTERVAL_MS);
            } finally {
                usbSweeping.set(false);
            }
        });
    }

    /** 在所有窗口里找 systemui 的弹窗根节点（授权弹窗不一定在活动窗口）。 */
    private AccessibilityNodeInfo findSystemUiDialogRoot() {
        List<AccessibilityWindowInfo> wins = getWindows();
        if (wins == null) {
            return null;
        }
        for (AccessibilityWindowInfo w : wins) {
            if (w.getType() != AccessibilityWindowInfo.TYPE_APPLICATION
                    && w.getType() != AccessibilityWindowInfo.TYPE_SYSTEM) {
                continue;
            }
            AccessibilityNodeInfo r = w.getRoot();
            if (r != null) {
                CharSequence p = r.getPackageName();
                if (p != null && SYS_UI.contentEquals(p)) {
                    return r;
                }
                r.recycle();
            }
        }
        return null;
    }

    /**
     * 录屏授权标题谓词（base.apk c2 case 0/1）：
     * 文本包含本应用名/包名，且包含投屏动词之一；或全等"屏幕共享保护"。
     */
    private boolean titleMatchesProjection(AccessibilityNodeInfo root) {
        final String appLabel = getApplicationInfo() != null && getApplicationInfo().labelRes != 0
                ? getString(getApplicationInfo().labelRes) : "AIR4PRO3DOF";
        final String pkg = getPackageName();
        return findByText(root, s -> {
            if (s == null) {
                return false;
            }
            if ("屏幕共享保护".equals(s)) {
                return true;
            }
            String lower = s.toLowerCase();
            boolean hasApp = lower.contains(appLabel.toLowerCase()) || s.contains(pkg);
            if (!hasApp) {
                return false;
            }
            for (String v : TITLE_VERBS) {
                if (lower.contains(v.toLowerCase())) {
                    return true;
                }
            }
            return false;
        });
    }

    /** USB 授权标题谓词：包含本应用名且包含 USB / 访问。 */
    private boolean titleMatchesUsb(AccessibilityNodeInfo root) {
        final String appLabel = getApplicationInfo() != null && getApplicationInfo().labelRes != 0
                ? getString(getApplicationInfo().labelRes) : "AIR4PRO3DOF";
        final String pkg = getPackageName();
        return findByText(root, s -> {
            if (s == null) {
                return false;
            }
            String lower = s.toLowerCase();
            boolean hasApp = lower.contains(appLabel.toLowerCase()) || s.contains(pkg);
            return hasApp && (lower.contains("usb") || s.contains("访问") || lower.contains("access"));
        });
    }

    /** 点击匹配的按钮：文本集合命中或 viewId 命中；节点不可点则向上找可点击祖先。 */
    private boolean clickButton(AccessibilityNodeInfo root, Set<String> primary,
                                Set<String> secondary, Set<String> ids) {
        return findAndClick(root, n -> {
            if (!n.isEnabled()) {
                return false;
            }
            String s = textOf(n);
            boolean byText = s != null
                    && (primary.contains(s) || secondary.contains(s));
            boolean byId = ids.contains(String.valueOf(n.getViewIdResourceName()));
            return byText || byId;
        });
    }

    private boolean findAndClick(AccessibilityNodeInfo node, NodePredicate pred) {
        if (pred.test(node)) {
            return clickOrBubble(node);
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo c = node.getChild(i);
            if (c == null) {
                continue;
            }
            try {
                if (findAndClick(c, pred)) {
                    return true;
                }
            } finally {
                c.recycle();
            }
        }
        return false;
    }

    /**
     * 只点击**精确匹配到的那一个节点**，不再沿父链找可点击祖先。
     *
     * 旧实现会向上找第一个 isClickable 的祖先并点它 —— 在 Android 14 的录屏弹窗上，
     * 匹配到的"继续/开始"文本节点本身不可点，父链第一个可点祖先恰好是承载"取消"的
     * 容器，于是自动授权把投屏取消了。宁可点不中（返回 false，交给用户手动点），
     * 也不能点到一个语义不确定的祖先。
     */
    private boolean clickOrBubble(AccessibilityNodeInfo n) {
        return n.isClickable() && n.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    }

    private boolean findByText(AccessibilityNodeInfo node, TextPredicate pred) {
        if (pred.test(textOf(node))) {
            return true;
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo c = node.getChild(i);
            if (c == null) {
                continue;
            }
            try {
                if (findByText(c, pred)) {
                    return true;
                }
            } finally {
                c.recycle();
            }
        }
        return false;
    }

    private static String textOf(AccessibilityNodeInfo n) {
        CharSequence t = n.getText();
        CharSequence d = n.getContentDescription();
        return t != null ? t.toString() : d != null ? d.toString() : null;
    }

    private interface NodePredicate {
        boolean test(AccessibilityNodeInfo n);
    }

    private interface TextPredicate {
        boolean test(String s);
    }

    // ------------------------------------------------------------ ② 跨屏焦点恢复

    private volatile int focusDisplayId = -1;
    private boolean focusRestoreQueued;
    /** 焦点恢复的节流与预算：树的遍历很贵，绝不能被事件洪水放大成无限重试（会拖死主线程 → 灰屏）。 */
    private long focusLastAttemptAt;
    private int focusAttempts;
    private static final long FOCUS_MIN_INTERVAL_MS = 800;
    private static final int FOCUS_MAX_ATTEMPTS = 5;

    /** 副屏就绪/切换应用后调用；onAccessibilityEvent 里会按节流规则补刀。 */
    public static void requestFocusRestore(int displayId) {
        AutoConsentAccessibilityService svc = instance;
        if (svc == null || displayId <= 0) {
            return;
        }
        if (svc.focusDisplayId != displayId) {
            svc.focusAttempts = 0;
            svc.focusLastAttemptAt = 0;
        }
        svc.focusDisplayId = displayId;
        svc.main.post(svc::restoreFocus);
    }

    public static void clearFocusRestore() {
        AutoConsentAccessibilityService svc = instance;
        if (svc != null) {
            svc.focusDisplayId = -1;
            svc.focusAttempts = 0;
        }
    }

    /**
     * 把输入焦点还给目标 display 上的最顶层应用窗口（base.apk b() 语义）。
     *
     * 相比原版有两处加固，都是为了不动主线程：
     *   - 最小间隔 800ms 节流，避免每个无障碍事件都扫一遍树；
     *   - 最多试 5 次就放弃（很多应用根本不接受 ACTION_FOCUS，无限重试只会白烧 CPU）。
     */
    private void restoreFocus() {
        final int target = focusDisplayId;
        if (target <= 0) {
            return;
        }
        final long now = SystemClock.uptimeMillis();
        if (now - focusLastAttemptAt < FOCUS_MIN_INTERVAL_MS) {
            return;
        }
        if (focusAttempts >= FOCUS_MAX_ATTEMPTS) {
            focusDisplayId = -1;
            Log.i(TAG, "focus restore giving up after " + focusAttempts + " attempts");
            return;
        }
        focusLastAttemptAt = now;
        focusAttempts++;
        worker.execute(() -> {
            boolean ok = false;
            AccessibilityNodeInfo root = topWindowRoot(target);
            if (root != null) {
                try {
                    AccessibilityNodeInfo n = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                    if (n == null) {
                        n = firstFocusable(root);
                    }
                    ok = n != null && n.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                } catch (Throwable t) {
                    Log.w(TAG, "restoreFocus 异常", t);
                } finally {
                    root.recycle();
                }
            }
            if (ok) {
                Log.i(TAG, "Restored input focus to display=" + target);
                main.post(() -> {
                    if (focusDisplayId == target) {
                        focusDisplayId = -1;   // 成功即停
                    }
                });
            }
        });
    }

    /** 目标 display 上 layer 最高的应用窗口根节点。 */
    private AccessibilityNodeInfo topWindowRoot(int displayId) {
        List<AccessibilityWindowInfo> wins = null;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            SparseArray<List<AccessibilityWindowInfo>> all = getWindowsOnAllDisplays();
            if (all != null) {
                wins = all.get(displayId);
            }
        }
        if (wins == null && displayId == Display.DEFAULT_DISPLAY) {
            wins = getWindows();
        }
        if (wins == null) {
            return null;
        }
        AccessibilityWindowInfo top = null;
        int topLayer = Integer.MIN_VALUE;
        for (AccessibilityWindowInfo w : wins) {
            if (w.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) {
                continue;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                    && w.getDisplayId() != displayId) {
                continue;
            }
            if (w.getLayer() > topLayer) {
                topLayer = w.getLayer();
                top = w;
            }
        }
        return top == null ? null : top.getRoot();
    }

    private static AccessibilityNodeInfo firstFocusable(AccessibilityNodeInfo n) {
        if (n.isVisibleToUser() && n.isFocusable()) {
            return n;
        }
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c == null) {
                continue;
            }
            AccessibilityNodeInfo r = firstFocusable(c);
            if (r != null) {
                return r;
            }
        }
        return null;
    }

    // ------------------------------------------------------------ ③ 无障碍手势注入（免 Shizuku 触摸）

    private static final ArrayDeque<GestureDescription> GESTURE_QUEUE = new ArrayDeque<>();
    private static boolean gestureBusy;

    /**
     * 触控板点击 → 扩展屏。durationMs=80 为轻点，650 为长按（与 input swipe 的时长语义对齐）。
     *
     * @return false = 不可用（无障碍未开启或系统 < Android 11），调用方自行提示
     */
    public static boolean injectTap(int displayId, float x, float y, long durationMs) {
        if (!canInject() || displayId <= 0) {
            return false;
        }
        Path p = new Path();
        p.moveTo(x, y);
        GestureDescription.Builder b = new GestureDescription.Builder();
        b.setDisplayId(displayId);
        b.addStroke(new GestureDescription.StrokeDescription(p, 0, durationMs));
        return enqueueGesture(b.build());
    }

    /** 触控板滑动/滚动 → 扩展屏（从 (x1,y1) 划到 (x2,y2)，时长 durationMs）。 */
    public static boolean injectSwipe(int displayId, float x1, float y1, float x2, float y2,
                                      long durationMs) {
        if (!canInject() || displayId <= 0) {
            return false;
        }
        Path p = new Path();
        p.moveTo(x1, y1);
        p.lineTo(x2, y2);
        GestureDescription.Builder b = new GestureDescription.Builder();
        b.setDisplayId(displayId);
        b.addStroke(new GestureDescription.StrokeDescription(p, 0, durationMs));
        return enqueueGesture(b.build());
    }

    /** 全局返回键（GLOBAL_ACTION_BACK），替代 Shizuku `input keyevent 4`。 */
    public static boolean performBack() {
        AutoConsentAccessibilityService svc = instance;
        if (svc == null) {
            return false;
        }
        return svc.performGlobalAction(GLOBAL_ACTION_BACK);
    }

    /**
     * 手势串行队列：dispatchGesture 同一时刻只接受一个，点太快会被拒。
     * 这里用队列 + 完成回调逐个放行，保证触控板操作顺序与用户操作一致。
     */
    private static boolean enqueueGesture(GestureDescription g) {
        AutoConsentAccessibilityService svc = instance;
        if (svc == null) {
            return false;
        }
        synchronized (GESTURE_QUEUE) {
            if (GESTURE_QUEUE.size() > 16) {
                GESTURE_QUEUE.poll();   // 防失控：积压过多说明注入速度跟不上，丢最老的
            }
            GESTURE_QUEUE.add(g);
        }
        svc.main.post(AutoConsentAccessibilityService::pumpGesture);
        return true;
    }

    private static void pumpGesture() {
        AutoConsentAccessibilityService svc = instance;
        if (svc == null) {
            synchronized (GESTURE_QUEUE) {
                GESTURE_QUEUE.clear();
                gestureBusy = false;
            }
            return;
        }
        if (gestureBusy) {
            return;
        }
        final GestureDescription g;
        synchronized (GESTURE_QUEUE) {
            g = GESTURE_QUEUE.poll();
            if (g == null) {
                return;
            }
            gestureBusy = true;
        }
        boolean accepted = svc.dispatchGesture(g, new GestureResultCallback() {
            @Override
            public void onCompleted(GestureDescription gestureDescription) {
                gestureBusy = false;
                AutoConsentAccessibilityService svc1 = instance;
                if (svc1 != null) {
                    svc1.main.post(AutoConsentAccessibilityService::pumpGesture);
                }
            }

            @Override
            public void onCancelled(GestureDescription gestureDescription) {
                gestureBusy = false;
                AutoConsentAccessibilityService svc1 = instance;
                if (svc1 != null) {
                    svc1.main.post(AutoConsentAccessibilityService::pumpGesture);
                }
            }
        }, svc.main);
        if (!accepted) {
            gestureBusy = false;
            svc.main.postDelayed(AutoConsentAccessibilityService::pumpGesture, 30);
        }
    }
}
