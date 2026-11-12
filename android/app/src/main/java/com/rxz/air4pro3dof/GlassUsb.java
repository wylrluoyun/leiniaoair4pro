package com.rxz.air4pro3dof;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;

import java.util.Locale;

import android.annotation.SuppressLint;

/**
 * 雷鸟 Air 1s USB HID 访问（IMU 数据源）。
 *
 * 协议与 imutool/glass/protocol.go 一致，来源是反汇编官方 XRSDK.dll 并实机验证：
 *   出站 64 字节：buf[0]=0x01，buf[1]=0x66，buf[2]=命令码
 *   入站 64 字节：buf[1]=0x99 帧头，buf[2]=0x65 表示 IMU 载荷
 * （Windows 版按 65 字节处理，多出的尾字节对报文语义无影响；实机报告描述符为
 * 64 字节 Input/Output 且无 Report ID，故安卓侧一律按 64 收发，见 REPORT_LEN 注释。）
 *
 * 实机（Android 14 + Air 1s）：接口能抢到（itf0，IN 0x81 / OUT 0x01，mps 64），
 * 报告描述符里没有 Report ID，报文长度 64。裸端点没有 Windows HID 类驱动那层封包，
 * 所以出站保留多种变体依次试探，以「有没有数据回来」为唯一判据。
 */
public final class GlassUsb {

    private static final String TAG = "GlassUsb";
    public static final int VID = 0x1BBB;
    public static final int PID = 0xAF50;
    private static final String ACTION_USB_PERMISSION = "com.rxz.air4pro3dof.USB_PERMISSION";

    public static final byte CMD_SENSOR_ON = 0x01;
    public static final byte CMD_SENSOR_OFF = 0x02;
    /**
     * 融合自 rayneo_imu 项目（同会话验证）：0x66 命令族 cmd 0x00 = GetDeviceInfo。
     * 返回状态帧（payload[1]=0x99，payload[2]=0xC8），含 build 日期串与 deviceType。
     * 解析规则与 rayneo_imu/protocol.py 的 parse_device_info 逐字节一致。
     */
    public static final byte CMD_GET_DEVICE_INFO = 0x00;
    /** SetPanelLuminance(面板档位 0~12)，设备以 0xC8/0x09 回 ACK。 */
    public static final byte CMD_PANEL_LUMINANCE = 0x09;

    /**
     * 界面亮度档位（1~10）→ 设备面板档位（0~12）的实机校准表。
     *
     * 来源：imutool/glass/protocol.go 的 BrightnessModes。2026-09-30 在 Air 1s 上
     * 逐档下发测得——**两者不是简单偏移**（Lv4→panel5、Lv7→panel3、Lv10→panel8），
     * 直接拿界面值当参数下发会得到错误的亮度，必须查表。
     * Lv 11/12/13 是官方表里越界产生的**色彩模式**（红/青/黄，整屏呈单色调），
     * 界面上作为三个颜色选项暴露，与亮度互斥（同一个 0x09 命令，参数就是面板档位）。
     */
    private static final int[] PANEL_OF_LEVEL = {
            1, 2, 0, 5, 6, 7, 3, 9, 10, 8,   // Lv 1..10：亮度档
            4, 11, 12,                        // Lv 11/12/13：色彩模式 红/青/黄
    };

    /** 界面档位下界。 */
    public static final int LEVEL_MIN = 1;
    /** 亮度档上限（滑块范围 1..10）。 */
    public static final int BRIGHT_MAX = 10;
    /** 色彩模式起始档位：11=红、12=青、13=黄（面板 4/11/12，画面呈单色）。 */
    public static final int COLOR_MIN = 11;
    public static final int COLOR_MAX = 13;
    /** 界面档位上界（含色彩模式）。 */
    public static final int LEVEL_MAX = COLOR_MAX;

    /** 是否色彩模式档位。 */
    public static boolean isColorLevel(int level) {
        return level >= COLOR_MIN && level <= COLOR_MAX;
    }

    /** 界面档位 → 面板档位；越界夹到合法范围。 */
    public static int panelOfLevel(int level) {
        int lv = level < LEVEL_MIN ? LEVEL_MIN : (level > LEVEL_MAX ? LEVEL_MAX : level);
        return PANEL_OF_LEVEL[lv - 1];
    }

    private static final int READ_TIMEOUT_MS = 300;
    /** 超过这个耗时的失败算「没数据」（超时），否则算硬错误（STALL/设备重枚举）。 */
    private static final int TIMEOUT_THRESHOLD_MS = 180;

    /**
     * 报文长度 = 64 字节，**没有 HID Report ID**。
     *
     * 依据实机读到的报告描述符（52 字节）：
     *   06 A0 FF 09 01 A1 01 09 02 A1 00
     *   06 A1 FF 09 03 09 04 15 80 25 7F 35 00 45 FF 75 08 95 40 81 02   ← Input 64×8bit
     *   09 05 09 06 15 80 25 7F 35 00 45 FF 75 08 95 40 91 02           ← Output 64×8bit
     * 全篇没有 0x85（Report ID）项。
     *
     * 这一条决定了读缓冲必须是 64：设备每次正好发满 64 字节（等于端点 mps），
     * 不构成短包，所以请求 65 字节的 URB 永远等不到第 65 个字节、必然超时。
     * 之前"接口抢到了但一帧数据都没有"就是这个原因。
     *
     * 报文首字节 0x01 是载荷的一部分（不是 Report ID），所以出站命令同样是
     * 64 字节 `01 66 <cmd>`，与 Windows 版 65 字节报文的前 64 字节一致。
     */
    public static final int REPORT_LEN = 64;

    public interface Listener {
        void onStatus(String text);

        /** 一帧 IMU：加速度 m/s²、角速度 rad/s、采样间隔秒。 */
        void onSample(float[] accel, float[] gyroRad, float dt);

        void onFatal(String reason);
    }

    private final Context ctx;
    private final Listener listener;
    private final UsbManager usb;

    private UsbDevice device;
    private UsbDeviceConnection conn;
    private UsbInterface intf;
    private UsbEndpoint epIn;
    private UsbEndpoint epOut;
    private Thread thread;

    private volatile boolean running;
    private volatile boolean open;

    private final byte[] rx = new byte[REPORT_LEN];
    private final float[] accel = new float[3];
    private final float[] gyro = new float[3];
    private int prevStamp;
    private int otherFrames;
    private BroadcastReceiver permReceiver;

    /** 出站通道编号：0=bulk64，1=bulk65，2=bulk64无首字节，3=ctrlSET_REPORT，4=ctrl含ID。 */
    private int sendMode = -1;
    /** 已确认能催出数据后锁定通道，不再轮换。 */
    private boolean locked;
    private int cursor;
    private long frameCount;
    private long lastEnableAt;

    public GlassUsb(Context ctx, Listener listener) {
        this.ctx = ctx.getApplicationContext();
        this.listener = listener;
        this.usb = (UsbManager) this.ctx.getSystemService(Context.USB_SERVICE);
    }

    // ------------------------------------------------------------ 枚举 / 权限

    public static UsbDevice findDevice(Context ctx) {
        UsbManager m = (UsbManager) ctx.getSystemService(Context.USB_SERVICE);
        if (m == null) {
            return null;
        }
        UsbDevice loose = null;
        for (UsbDevice d : m.getDeviceList().values()) {
            if (d.getVendorId() == VID && d.getProductId() == PID) {
                return d;
            }
            if (d.getVendorId() == VID && loose == null) {
                loose = d;
            }
        }
        return loose;
    }

    /** USB 权限申请结果回调（主线程之外的广播线程，调用方自己切线程）。 */
    public interface PermissionCallback {
        void onResult(boolean granted);
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    public void requestPermission(final PermissionCallback cb) {
        final UsbDevice d = findDevice(ctx);
        if (d == null) {
            listener.onStatus("未检测到眼镜（VID 0x1BBB）");
            if (cb != null) {
                cb.onResult(false);
            }
            return;
        }
        if (usb.hasPermission(d)) {
            listener.onStatus("已具备 USB 权限");
            if (cb != null) {
                cb.onResult(true);
            }
            return;
        }
        // 回调只允许发生一次：结果广播与超时看门狗可能撞车
        final java.util.concurrent.atomic.AtomicBoolean answered =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        permReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (!answered.compareAndSet(false, true)) {
                    return;
                }
                boolean ok = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
                listener.onStatus(ok ? "USB 权限已授予" : "USB 权限被拒绝");
                unregisterPerm();
                if (cb != null) {
                    cb.onResult(ok);
                }
            }
        };
        IntentFilter f = new IntentFilter(ACTION_USB_PERMISSION);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(permReceiver, f, Context.RECEIVER_NOT_EXPORTED);
        } else {
            ctx.registerReceiver(permReceiver, f);
        }
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags |= PendingIntent.FLAG_MUTABLE;
        }
        // 必须显式 setPackage 指向本应用：隐式 PendingIntent 在部分 ROM（含 AOSP 14 的
        // NOT_EXPORTED 派发限制）上会被静默丢弃——表现为"既不弹授权框、结果也送不回来"。
        Intent piIntent = new Intent(ACTION_USB_PERMISSION).setPackage(ctx.getPackageName());
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 0, piIntent, flags);
        try {
            usb.requestPermission(d, pi);
        } catch (Throwable t) {
            Log.e(TAG, "requestPermission 失败", t);
            answered.set(true);
            unregisterPerm();
            listener.onStatus("申请 USB 权限失败：" + t);
            if (cb != null) {
                cb.onResult(false);
            }
            return;
        }
        // 兜底：有的 ROM 会静默吞掉授权请求（不弹窗也不回调）。
        // 10 秒无结果按失败处理，让界面回到可重试状态，而不是永远卡在"请允许访问眼镜"。
        Thread watchdog = new Thread(() -> {
            try {
                Thread.sleep(10_000);
            } catch (InterruptedException e) {
                return;
            }
            if (answered.compareAndSet(false, true)) {
                listener.onStatus("10 秒未收到 USB 授权结果（系统没有弹出授权框，可能被 ROM 拦截）");
                unregisterPerm();
                if (cb != null) {
                    cb.onResult(false);
                }
            }
        }, "usb-perm-watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void unregisterPerm() {
        if (permReceiver != null) {
            try {
                ctx.unregisterReceiver(permReceiver);
            } catch (Exception ignored) {
            }
            permReceiver = null;
        }
    }

    // ------------------------------------------------------------ 打开 / 关闭

    /** @return null 表示成功，否则返回失败原因 */
    public String open() {
        close();
        UsbDevice d = findDevice(ctx);
        if (d == null) {
            return "未检测到眼镜设备（VID 0x1BBB / PID 0xAF50）";
        }
        if (!usb.hasPermission(d)) {
            return "尚未获得 USB 权限";
        }
        device = d;

        UsbInterface best = null;
        UsbEndpoint in = null, out = null;
        for (int i = 0; i < d.getInterfaceCount(); i++) {
            UsbInterface it = d.getInterface(i);
            UsbEndpoint eIn = null, eOut = null;
            for (int j = 0; j < it.getEndpointCount(); j++) {
                UsbEndpoint ep = it.getEndpoint(j);
                boolean isIn = ep.getDirection() == UsbConstants.USB_DIR_IN;
                if (isIn && eIn == null) {
                    eIn = ep;
                } else if (!isIn && eOut == null) {
                    eOut = ep;
                }
            }
            if (eIn != null && eOut != null) {
                if (best == null || it.getInterfaceClass() == UsbConstants.USB_CLASS_HID) {
                    best = it;
                    in = eIn;
                    out = eOut;
                }
            }
        }
        if (best == null) {
            return "设备没有可用的双向端点：" + describeDevice(d);
        }

        UsbDeviceConnection c = usb.openDevice(d);
        if (c == null) {
            return "openDevice 失败（设备可能已被其他 App 占用，先关掉雷鸟官方 App）";
        }
        boolean claimed = c.claimInterface(best, true);
        if (!claimed) {
            claimed = c.claimInterface(best, false);
        }
        if (!claimed) {
            c.close();
            return "claimInterface 失败（接口被内核驱动或其他 App 占用）";
        }
        conn = c;
        intf = best;
        epIn = in;
        epOut = out;
        open = true;
        sendMode = -1;

        // HID SET_IDLE(0)：Windows 的 HID 类驱动打开设备时会补这一手，裸端点没有。
        // 部分固件要收到它才肯按速率上报，失败也无妨。
        try {
            int r = c.controlTransfer(0x21, 0x0A, 0x0000, best.getId(), null, 0, 300);
            Log.i(TAG, "SET_IDLE -> " + r);
        } catch (Exception ignored) {
        }

        listener.onStatus("已打开 " + describe());
        return null;
    }

    public boolean isOpen() {
        return open;
    }

    public long frames() {
        return frameCount;
    }

    public String sendModeName() {
        return modeName(sendMode);
    }

    public String describe() {
        if (!open) {
            return "未打开";
        }
        return "itf" + intf.getId()
                + " IN=0x" + Integer.toHexString(epIn.getAddress())
                + "(mps " + epIn.getMaxPacketSize() + ")"
                + " OUT=0x" + Integer.toHexString(epOut.getAddress())
                + "(mps " + epOut.getMaxPacketSize() + ")"
                + " 下发=" + modeName(sendMode);
    }

    public static String describeDevice(UsbDevice d) {
        if (d == null) {
            return "无设备";
        }
        StringBuilder sb = new StringBuilder();
        sb.append(String.format(Locale.US, "VID=%04X PID=%04X if=%d ",
                d.getVendorId(), d.getProductId(), d.getInterfaceCount()));
        for (int i = 0; i < d.getInterfaceCount(); i++) {
            UsbInterface it = d.getInterface(i);
            sb.append("itf").append(i).append("[cls=").append(it.getInterfaceClass())
                    .append(" ep=").append(it.getEndpointCount()).append("] ");
            for (int j = 0; j < it.getEndpointCount(); j++) {
                UsbEndpoint ep = it.getEndpoint(j);
                sb.append(ep.getDirection() == UsbConstants.USB_DIR_IN ? "IN" : "OUT")
                        .append("(0x").append(Integer.toHexString(ep.getAddress()))
                        .append(",mps=").append(ep.getMaxPacketSize())
                        .append(",t=").append(ep.getType()).append(") ");
            }
        }
        return sb.toString();
    }

    private static String modeName(int m) {
        switch (m) {
            case 0:
                return "bulk64";
            case 1:
                return "bulk65";
            case 2:
                return "bulk64无首字节";
            case 3:
                return "ctrlSET_REPORT";
            case 4:
                return "ctrl含ID";
            default:
                return "未确定";
        }
    }

    // ------------------------------------------------------------ 命令下发

    /** 出站载荷：64 字节 `01 66 <cmd>`（首字节 0x01 是载荷的一部分，不是 Report ID）。 */
    private static byte[] report(byte cmd) {
        byte[] buf = new byte[REPORT_LEN];
        buf[0] = 0x01;
        buf[1] = 0x66;
        buf[2] = cmd;
        return buf;
    }

    /**
     * 面板命令载荷：`01 66 09 <档位>`。
     *
     * 刻意不复用 report(cmd, params)：实测 2.1.2 画面正常、2.2.x 黑屏，两者唯一的
     * 差异就是这段写入。传感器链路的报文必须保持逐字节不变，所以这里单独复制一份。
     */
    private static byte[] panelReport(byte level) {
        byte[] buf = report(CMD_PANEL_LUMINANCE);
        buf[3] = level;
        return buf;
    }

    /** 尝试顺序：最可能的在前；「无首字节」这种乱码写法放最后，避免它把端点打 STALL。 */
    private static final int[] ORDER = {0, 4, 3, 1, 2};

    /**
     * 启用传感器：**以「有没有数据回来」判断通道**，而不是以写入返回值判断。
     * 写入成功不等于设备认（裸端点可能被固件忽略），所以依次轮换多种方式，
     * 直到某个方式真的把数据催出来为止。
     */
    private void kick() {
        if (conn == null || epOut == null) {
            return;
        }
        int mode;
        if (locked) {
            mode = sendMode;
        } else {
            mode = ORDER[cursor % ORDER.length];
            cursor++;
            sendMode = mode;
        }
        int w = sendByMode(mode, CMD_SENSOR_ON);
        if (!locked) {
            listener.onStatus("尝试下发 " + modeName(mode) + "（写返回 " + w + "）");
        }
    }

    private int sendByMode(int mode, byte cmd) {
        try {
            switch (mode) {
                case 0: {
                    // 描述符对应的正确写法：64 字节，首字节 0x01 属载荷
                    byte[] buf = report(cmd);
                    return conn.bulkTransfer(epOut, buf, buf.length, 300);
                }
                case 1: {
                    // Windows 版 65 字节（多出一个尾字节），前 64 字节与 case 0 相同
                    byte[] buf = new byte[REPORT_LEN + 1];
                    System.arraycopy(report(cmd), 0, buf, 0, REPORT_LEN);
                    return conn.bulkTransfer(epOut, buf, buf.length, 300);
                }
                case 2: {
                    // 不带首字节 0x01：0x66 落到 buf[0]，命令码落到 buf[1]
                    byte[] buf = new byte[REPORT_LEN];
                    buf[0] = 0x66;
                    buf[1] = cmd;
                    return conn.bulkTransfer(epOut, buf, buf.length, 300);
                }
                case 3: {
                    // HID SET_REPORT，wValue 低字节当 Report ID=1
                    byte[] buf = new byte[REPORT_LEN];
                    buf[0] = 0x66;
                    buf[1] = cmd;
                    return conn.controlTransfer(0x21, 0x09, 0x0201, intf.getId(),
                            buf, buf.length, 300);
                }
                default: {
                    // HID SET_REPORT，ID 放在数据里（wValue = 0x0200）
                    byte[] buf = report(cmd);
                    return conn.controlTransfer(0x21, 0x09, 0x0200, intf.getId(),
                            buf, buf.length, 300);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "sendByMode " + mode + " 异常", e);
            return -1;
        }
    }

    /**
     * 设置眼镜面板档位（1~13，见 PANEL_OF_LEVEL）。
     *
     * **只在用户明确操作时调用**：这条命令直接改面板寄存器，个别机型上可能导致
     * 显示异常（2.2.x 在会话启动时自动下发，结果整屏全黑）。写失败只记日志，
     * 不影响 IMU 采集。
     *
     * @return 写入返回值（负数表示失败）
     */
    public synchronized int setBrightnessLevel(int level) {
        if (conn == null || epOut == null) {
            return -1;
        }
        int panel = panelOfLevel(level);
        byte[] buf = panelReport((byte) panel);
        int w;
        try {
            if (sendMode < 0 || sendMode == 0 || sendMode == 1) {
                w = conn.bulkTransfer(epOut, buf, buf.length, 300);
            } else if (sendMode == 2) {
                byte[] alt = new byte[REPORT_LEN];
                alt[0] = 0x66;
                alt[1] = CMD_PANEL_LUMINANCE;
                alt[2] = (byte) panel;
                w = conn.bulkTransfer(epOut, alt, alt.length, 300);
            } else if (sendMode == 3) {
                byte[] alt = new byte[REPORT_LEN];
                alt[0] = 0x66;
                alt[1] = CMD_PANEL_LUMINANCE;
                alt[2] = (byte) panel;
                w = conn.controlTransfer(0x21, 0x09, 0x0201, intf.getId(),
                        alt, alt.length, 300);
            } else {
                w = conn.controlTransfer(0x21, 0x09, 0x0200, intf.getId(),
                        buf, buf.length, 300);
            }
        } catch (Exception e) {
            Log.e(TAG, "面板命令写入异常", e);
            return -1;
        }
        Log.i(TAG, "面板档位 Lv" + level + " → panel " + panel
                + "（通道 " + sendMode + "），写返回 " + w);
        return w;
    }

    private void sendQuiet(byte cmd) {
        if (conn == null || epOut == null) {
            return;
        }
        sendByMode(sendMode < 0 ? 0 : sendMode, cmd);
    }

    // ------------------------------------------------------------ 设备信息（融合自 rayneo_imu）

    /** GetDeviceInfo 应答解析结果。 */
    public static class DeviceInfo {
        /** deviceType：与 TDP 升级平台前端映射表一致（0x3A = taurus4p0pro / Air 4 Pro）。 */
        public int deviceType;
        /** cuType 子类型（Air 4 Pro 实测 0x01）。 */
        public int cuType;
        /** 固件 build 串，如 "Jan  9 2026"。 */
        public String build = "";

        public String modelName() {
            return GlassUsb.modelName(deviceType);
        }

        @Override
        public String toString() {
            return "deviceType=0x" + Integer.toHexString(deviceType)
                    + "(" + modelName() + ") cuType=0x" + Integer.toHexString(cuType)
                    + " build=" + build;
        }
    }

    /** deviceType → 型号。码表来自 TDP 升级平台前端，rayneo_imu/protocol.py 同源。 */
    public static String modelName(int deviceType) {
        switch (deviceType) {
            case 0x2E: return "aries";          // Air 1s
            case 0x30: return "aries1p5";       // Air 1.5
            case 0x31: return "aries1p8";       // Air 1.8
            case 0x34: return "taurus2p0pro";   // Air 2 Pro
            case 0x35: return "taurus2p0";      // Air 2
            case 0x36: return "taurus3p0";      // Air 3
            case 0x37: return "taurus3p0pro";   // Air 3 Pro
            case 0x38: return "taurus2p0pro";
            case 0x39: return "taurus4p0";      // Air 4
            case 0x3A: return "taurus4p0pro";   // Air 4 Pro
            case 0x40: return "Gemini1p0";      // GT
            case 0x41: return "Gemini2p0";      // GT Max
            default:
                return "unknown";
        }
    }

    private static boolean isMonthTriple(byte[] buf, int i) {
        // "Jan".."Dec" 3 字节快速判定（首字母范围 + 后两字节任意字母）
        int b0 = buf[i] & 0xFF;
        return (b0 == 'J' || b0 == 'F' || b0 == 'M' || b0 == 'A' || b0 == 'S'
                || b0 == 'O' || b0 == 'N' || b0 == 'D');
    }

    private static int findMonth(byte[] buf) {
        for (int i = 0; i < buf.length - 2; i++) {
            if (isMonthTriple(buf, i)) {
                int b1 = buf[i + 1] & 0xFF, b2 = buf[i + 2] & 0xFF;
                boolean lo1 = b1 >= 'a' && b1 <= 'z';
                boolean lo2 = b2 >= 'a' && b2 <= 'z';
                if (lo1 && lo2) {
                    return i;
                }
            }
        }
        return -1;
    }

    /**
     * 同步查询设备信息（GetDeviceInfo，cmd 0x00）。
     *
     * 解析规则与 rayneo_imu/protocol.py 一致：以 build 日期串位置 m 为锚点，
     * deviceType = buf[m-3]，cuType = buf[m-1]，build = buf[m..m+10]。
     * Air 4 Pro 实测：deviceType=0x3A(58)，cuType=0x01，build="Jan  9 2026"。
     *
     * 注意：必须在**未采集**（!running）时调用——它会独占读通道做轮询。
     * 若采集已启动，请在 stop() 之后调用。
     */
    public DeviceInfo queryDeviceInfo(long timeoutMs) {
        if (conn == null || epIn == null || epOut == null) {
            return null;
        }
        if (running) {
            Log.w(TAG, "queryDeviceInfo: 采集运行中，先 stop()");
            return null;
        }
        long deadline = SystemClock.elapsedRealtime() + timeoutMs;
        // 逐模式尝试，直到收到状态帧
        for (int attempt = 0; attempt < ORDER.length * 3; attempt++) {
            int mode = ORDER[attempt % ORDER.length];
            sendByMode(mode, CMD_GET_DEVICE_INFO);
            byte[] buf = new byte[REPORT_LEN];
            long pollEnd = SystemClock.elapsedRealtime() + 400;
            while (SystemClock.elapsedRealtime() < pollEnd) {
                int n = conn.bulkTransfer(epIn, buf, buf.length, 120);
                if (n < 3) {
                    continue;
                }
                // 帧头 0x99：base 为 0x99 所在下标（裸端点可能带 0x01 前缀）
                int base = -1;
                for (int c = 0; c < 3 && c + 1 < n; c++) {
                    if ((buf[c] & 0xFF) == 0x99) {
                        base = c;
                        break;
                    }
                }
                if (base < 0 || base + 1 >= n || (buf[base + 1] & 0xFF) != 0xC8) {
                    continue;
                }
                int m = findMonth(buf);
                if (m < 3) {
                    continue;
                }
                DeviceInfo info = new DeviceInfo();
                info.deviceType = buf[m - 3] & 0xFF;
                info.cuType = buf[m - 1] & 0xFF;
                StringBuilder sb = new StringBuilder();
                for (int k = 0; k < 11 && m + k < n; k++) {
                    int ch = buf[m + k] & 0xFF;
                    if (ch >= 0x20 && ch < 0x7F) {
                        sb.append((char) ch);
                    }
                }
                info.build = sb.toString().trim();
                Log.i(TAG, "GetDeviceInfo -> " + info);
                listener.onStatus("设备型号 " + info.modelName()
                        + "  build " + info.build);
                return info;
            }
            if (SystemClock.elapsedRealtime() > deadline) {
                break;
            }
        }
        Log.w(TAG, "GetDeviceInfo 无应答");
        return null;
    }

    /** 当前出站通道编号（-1 表示还没试过）；引擎记住它，下次待机连接直接复用。 */
    public int activeMode() {
        return sendMode;
    }

    /** 通道是否已经验证可用（收到过数据）。 */
    public boolean isLocked() {
        return locked;
    }

    /** 标准请求 CLEAR_FEATURE(ENDPOINT_HALT)：错误的下发会让设备 STALL IN 端点。 */
    private void clearHalt() {
        if (conn == null || epIn == null) {
            return;
        }
        try {
            int r = conn.controlTransfer(0x02, 0x01, 0x0000,
                    epIn.getAddress() & 0xFF, null, 0, 300);
            Log.i(TAG, "clearHalt(IN 0x" + Integer.toHexString(epIn.getAddress()) + ") -> " + r);
        } catch (Exception e) {
            Log.w(TAG, "clearHalt 失败", e);
        }
    }

    // ------------------------------------------------------------ 采集

    public void start() {
        if (!open || running) {
            return;
        }
        running = true;
        prevStamp = 0;
        frameCount = 0;
        lastEnableAt = 0;
        locked = false;
        cursor = 0;
        sendMode = -1;
        kick();
        thread = new Thread(this::readLoop, "glass-imu");
        thread.start();
    }

    public void stop() {
        running = false;
        Thread t = thread;
        thread = null;
        if (t != null) {
            // 读线程最坏卡在一个 300ms 的 bulkTransfer 里；多等几轮，
            // 等不到就不该去关连接（否则读线程与 close 并发操作 conn）
            long deadline = SystemClock.elapsedRealtime() + 1200;
            while (t.isAlive() && SystemClock.elapsedRealtime() < deadline) {
                try {
                    t.join(200);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
            if (t.isAlive()) {
                Log.w(TAG, "读线程未在 1.2s 内退出，跳过本次连接释放");
                return;
            }
        }
        closeLocked();
    }

    /** 关闭连接（只允许在读线程确认退出后调用）。 */
    private void closeLocked() {
        if (conn != null) {
            try {
                sendQuiet(CMD_SENSOR_OFF);
                conn.releaseInterface(intf);
            } catch (Exception ignored) {
            }
            try {
                conn.close();
            } catch (Exception ignored) {
            }
        }
        conn = null;
        intf = null;
        epIn = null;
        epOut = null;
        open = false;
    }

    public void close() {
        stop();          // 内部在读线程退出后关连接
        closeLocked();   // 只 open 没 start 的场景也要关
    }

    /**
     * 读循环。
     *
     * 关键：**不要把「超时」当成掉线**。传感器 460Hz，正常应该几十毫秒一帧；
     * 一直超时说明命令没生效或设备在重枚举，此时每 1.5 秒重发一次启用命令，
     * 只有「立即失败」（STALL/断链）累计多次才判定需要重连。
     */
    private void readLoop() {
        int hardErrors = 0;
        boolean announced = false;

        while (running) {
            // 取局部引用：close()/stop() 可能在别处把字段置空，循环中途判空比直接用字段稳
            UsbDeviceConnection c = conn;
            UsbEndpoint in = epIn;
            if (c == null || in == null) {
                return;
            }
            long t0 = SystemClock.elapsedRealtime();
            int n;
            try {
                n = c.bulkTransfer(in, rx, rx.length, READ_TIMEOUT_MS);
            } catch (Exception e) {
                listener.onFatal("读取异常：" + e.getMessage());
                return;
            }
            long spent = SystemClock.elapsedRealtime() - t0;
            if (!running) {
                break;
            }

            if (n < 0) {
                if (spent < TIMEOUT_THRESHOLD_MS) {
                    hardErrors++;
                    if (hardErrors == 3) {
                        // 端点被 STALL 后必须显式清 halt，否则后续读全部立即失败
                        clearHalt();
                        listener.onStatus("读取立即失败，已尝试清除端点 halt");
                    }
                    if (hardErrors > 8) {
                        listener.onFatal("USB 读取持续失败（设备可能已重新枚举，需重新插拔）");
                        return;
                    }
                } else if (SystemClock.elapsedRealtime() - lastEnableAt > 1200) {
                    // 一直超时说明命令没生效或设备在重枚举：周期性重发启用命令
                    lastEnableAt = SystemClock.elapsedRealtime();
                    kick();
                }
                continue;
            }

            hardErrors = 0;
            locked = true;
            if (!announced) {
                announced = true;
                listener.onStatus("收到数据（首帧 " + n + " 字节，下发方式 "
                        + modeName(sendMode) + "）");
            }
            parse(n);
        }
    }

    /** 解析一帧；非 IMU 帧直接丢弃。 */
    private void parse(int n) {
        int base;
        if (n >= 3 && (rx[1] & 0xFF) == 0x99) {
            base = 1;              // 含 Report ID：rx[0]=0x01
        } else if (n >= 3 && (rx[0] & 0xFF) == 0x99) {
            base = 0;              // 省略 Report ID
        } else {
            if (otherFrames++ == 0) {
                listener.onStatus("收到非 0x99 报文：" + hexDump(rx, Math.min(n, 16)));
            }
            return;
        }
        if ((rx[base + 1] & 0xFF) != 0x65) {
            // 0xC8 状态帧 / 亮度 ACK —— 说明链路是通的，只是不是 IMU 载荷
            if (otherFrames++ == 0) {
                listener.onStatus("收到状态帧 0x" + Integer.toHexString(rx[base + 1] & 0xFF)
                        + "：" + hexDump(rx, Math.min(n, 16)));
            }
            return;
        }
        otherFrames = 0;
        int shift = base - 1;      // base=1 → 0；base=0 → -1
        if (n < 0x3D + shift) {
            return;
        }
        for (int i = 0; i < 3; i++) {
            accel[i] = readF32(rx, 0x05 + i * 4 + shift);
            gyro[i] = readF32(rx, 0x11 + i * 4 + shift) * (float) (Math.PI / 180.0);
        }
        int stamp = readU32(rx, 0x29 + shift);

        float dt = 1f / DEFAULT_HZ;
        if (prevStamp != 0) {
            int d = stamp - prevStamp;
            if (d > 0 && d < 500) {
                dt = d / 10000f;
            }
        }
        prevStamp = stamp;
        frameCount++;

        listener.onSample(accel, gyro, dt);
    }

    public static final float DEFAULT_HZ = 460f;

    private static float readF32(byte[] b, int off) {
        int bits = (b[off] & 0xFF)
                | ((b[off + 1] & 0xFF) << 8)
                | ((b[off + 2] & 0xFF) << 16)
                | ((b[off + 3] & 0xFF) << 24);
        return Float.intBitsToFloat(bits);
    }

    private static int readU32(byte[] b, int off) {
        return (b[off] & 0xFF)
                | ((b[off + 1] & 0xFF) << 8)
                | ((b[off + 2] & 0xFF) << 16)
                | ((b[off + 3] & 0xFF) << 24);
    }

    // ------------------------------------------------------------ 离线探针

    /**
     * 一次性 USB 探针，回答三个问题：
     *   1. 描述符与报告描述符长什么样（确认 Report ID 与报文长度）
     *   2. 不发命令时端点有没有数据（区分「设备静默」与「命令没生效」）
     *   3. 三种下发方式各自能否写成功、写完有没有回应（含 GetDeviceInfo 的状态帧）
     * 只能在未运行时调用（会独占设备）。返回值可直接贴出来。
     */
    private static String hexDump(byte[] b, int len) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < len; i++) {
            sb.append(String.format(Locale.US, "%02X ", b[i] & 0xFF));
        }
        return sb.toString().trim();
    }
}
