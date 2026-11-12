package com.rxz.air4pro3dof;

import android.opengl.Matrix;

/**
 * 姿态会话：在线零偏估计 → Mahony 解算 → 中位比较 → 逐轴取反 → 滤波 → 相机视图矩阵。
 *
 * ── 这一版针对"反复运动后画面会自己跑"重做了零偏与冻结逻辑 ──────────────
 *
 * 漂移的三个真实来源（都是实现问题，不是 IMU 的物理极限）：
 *
 *  1. **慢速平移被当成零偏学走**。老版只要瞬时角速度 < 2.9°/s 就立刻用该样本更新
 *     零偏——缓慢转头时陀螺读数同样很小，零偏把这段真实运动吸收进去；
 *     手一停，姿态就以学到的那个速率反向匀速跑。
 *     现在要求：**持续静止 ≥ 0.25s** 且**陀螺方差很小**（抖动而非匀速运动）才学分，
 *     并且零偏每秒钟允许的变化量有上限（起步 0.5 rad/s²、稳定后 0.03 rad/s²）。
 *
 *  2. **Mahony 积分项卷绕**。见 {@link Mahony} 的注释，KI 已置 0，零偏只在这里估。
 *
 *  3. **停下后滤波器还在爬**。One Euro 有惯性，冻结只停了陀螺积分，输出仍在收敛
 *     到新值，肉眼就是"停住了画面又滑几度"。现在冻结期间直接**latch 输出**
 *     （保持上一帧的视图矩阵），恢复运动时滤波从 latch 值继续，无跳变。
 *
 * 物理上限：眼镜没有磁力计/相机，**偏航角没有绝对参考**，只能靠零偏精度 + 手动复位。
 * 想再上一层：换 ESKF（误差状态卡尔曼，把零偏建进状态量），但那也只能把偏航漂移
 * 压到"零偏估计精度"这一量级，不能给出绝对朝向。
 *
 * 线程：IMU 线程调 {@link #onSample}（~460Hz），GL 线程调 {@link #getViewMatrix}（每帧），
 * 界面线程调 {@link #recenter} 等。全部由 sLock 串行化。
 */
public final class HeadPose {

    /** 进入"静止"的陀螺阈值：约 2.9°/s（用于冻结画面，太松会卡住慢速转头）。 */
    private static final float STILL_RAD = 0.05f;
    /** 退出"静止"的阈值（迟滞）：约 2°/s，慢速平移也要解冻，否则画面会卡住。 */
    private static final float STILL_EXIT_RAD = 0.035f;
    /**
     * **零偏学习**的陀螺阈值：约 0.86°/s，贴近噪声底。
     * 老版用 2.9°/s，导致 1–2°/s 的慢速平移被当成"静止"学进零偏，
     * 手一停画面就按学到的速率反向匀速跑——这是"运动几次后画面自己动"的主因。
     */
    private static final float BIAS_STILL_RAD = 0.015f;
    /** 零偏学习还要求陀螺窗口方差足够小：std < 0.01 rad/s（约 0.57°/s）。 */
    private static final float STILL_VAR_MAX = 0.01f * 0.01f;
    /** 持续静止多久才认为"这是真的静止"：0.25s。 */
    private static final float STILL_TIME_S = 0.25f;
    /** 冻结门槛：静止 0.3s 后屏蔽陀螺积分。 */
    private static final float FREEZE_TIME_S = 0.30f;

    /**
     * **首次零偏校准**门槛：只看陀螺方差、不看残差，累计这么久就采信 gMean 作为零偏。
     *
     * 为什么不能用残差判据：残差是相对**当前** bias 的。bias 一开始就是错的
     * （老版本拿第一帧播种，而按「开始投屏」的瞬间手通常还在动），残差必然大于
     * BIAS_STILL_RAD，于是"残差小才允许学"变成循环依赖 —— 零偏永远学不进去，
     * gyroUsed 恒定输出这个偏差，积分成恒速偏航，看起来就是画面自己往一边滑。
     *
     * 方差则与 bias 无关：方差小就说明陀螺**确实没在动**，此时均值即零偏。
     */
    private static final float CAL_STEADY_S = 0.8f;
    /**
     * 校准用的**宽松**方差门：std &lt; 1.7°/s。
     *
     * 不能用 STILL_VAR_MAX（std &lt; 0.57°/s）：戴着眼镜"尽量不动"时，
     * 头部生理性抖动本来就在 0.2–0.5°/s，门槛卡这么死会导致首次校准长时间不触发，
     * 而校准没完成时 bias 还是 0，漂移反而更大 —— 这是必须避免的死结。
     * 首次校准宁可估得粗一点（后续还有慢速学习精修），也必须真的完成。
     *
     * 放宽的代价由"窗口内累加平均"补回来：单帧噪声 std=1.7°/s，
     * 累加 0.8s（约 370 帧）后均值的标准差约 0.09°/s，
     * 对应 5°/分钟的漂移量级 —— 已经接近这个 IMU 的物理下限。
     */
    private static final float CAL_VAR_MAX = 0.03f * 0.03f;
    /** 自锁逃生：已校准、确在静止、但残差长期超过这个值（°/s），说明零偏估错了。 */
    private static final float ESCAPE_DPS = 1.5f;
    /** 自锁逃生需要持续多久才触发强制重采零偏。 */
    private static final float ESCAPE_S = 3f;

    /** 陀螺统计量的 EMA 系数（约 0.1s 窗口 @460Hz）。 */
    private static final float GYRO_STAT_ALPHA = 0.02f;
    /** 零偏跟随系数（仅在通过静止判定的样本上生效）。 */
    private static final float BIAS_ALPHA = 0.05f;
    /** 零偏变化速率上限：起步阶段放宽，稳定后收紧（rad/s 每秒）。 */
    private static final float BIAS_RATE_FAST = 0.50f;
    private static final float BIAS_RATE_SLOW = 0.03f;
    /** 快速收敛阶段：累计"可学静止"满这么久之前用大速率（覆盖种子取自运动帧的误差）。 */
    private static final float FAST_LEARN_S = 1.0f;

    /** 加速度模长参考的 EMA 系数，只在小角速度时更新，避免运动加速度污染。 */
    private static final float ACC_NORM_ALPHA = 0.02f;
    /** 判定"加速度可信"的相对带宽：偏离参考 15% 以内才用加速度修倾角。 */
    private static final float ACC_TRUST_BAND = 0.15f;

    private final Object sLock = new Object();

    private final Mahony ahrs = new Mahony();
    private final float[] bias = new float[3];
    /** 陀螺 EMA 均值与平方均值（用于估方差：慢速平移 vs 真静止）。 */
    private final float[] gMean = new float[3];
    private final float[] gMean2 = new float[3];

    private final float[] upBody = {0f, 1f, 0f};
    private boolean seeded;
    private float stillTime;
    private float accNormRef;
    /** 累计已学习的静止时长（决定用快速还是慢速跟随零偏）。 */
    private float learnedTime;
    /**
     * 静止窗口内的残差（|ω − 零偏|）EMA，单位 °/s。
     * 这才是"还会不会漂"的指标：零偏估计收敛后它应接近噪声底。
     */
    private float residualDps;
    /**
     * 静止窗口内三轴角速度的**累加和**与样本数。除以样本数即窗口均值。
     *
     * 为什么不直接用 gMean：gMean 是 α=0.02 的 EMA，等效窗口只有约 0.1 秒，
     * 单帧噪声 std=1.7°/s 时其均值误差约 0.24°/s（≈14°/分钟）。
     * 而 0.8 秒累加平均（约 370 帧）能把误差压到 0.09°/s（≈5°/分钟）——
     * 这正是"画面还会自动向左移"能压到什么程度的关键。
     *
     * 首次校准与自锁逃生共用这一个累加器：两者都是"确认静止后采信窗口均值"，
     * 差别只是触发条件（前者是还没校过，后者是校过了但残差长期偏大）。
     */
    private final double[] calSum = new double[3];
    private int calCount;
    /** 静止窗口累计时长（只在陀螺方差小的帧上累加，一旦动了就清零重来）。 */
    private float calTime;
    /** 首次零偏校准是否已完成。false 表示 bias 尚不可信，画面必然还带零偏。 */
    private volatile boolean firstCalibrated;
    /** 界面线程经 isFrozen() 读取，volatile 保证可见性。 */
    private volatile boolean frozen;

    /** 中位基准（场景坐标系三轴在世界系中的表示）。 */
    private final float[] f0 = {0f, 0f, 1f};
    private final float[] u0 = {0f, 1f, 0f};
    private final float[] r0 = {1f, 0f, 0f};
    private boolean recentered;

    // ---- 用户开关（界面线程写，其余线程读）
    /** 前后取反：IMU 的 +Z 若指向人脸，勾上让相机看向屏幕。 */
    public volatile boolean invertForward = false;
    public volatile boolean invertYaw = false;
    public volatile boolean invertPitch = false;
    public volatile boolean invertRoll = false;
    /** 静止时冻结输出（抑制 yaw 漂移）。 */
    public volatile boolean freezeWhenStill = true;

    // ---- 陀螺轴符号（融合自 rayneo_imu 实测，按 deviceType 由 GlassEngine 设定）
    /**
     * 陀螺仪三轴符号，作用在**原始 gyroRad 上**（减零偏之前）。
     *
     * 为什么要单独一组、而不是复用上面的 invertYaw/Pitch/Roll：
     * 那三个是对**欧拉角**取负，只能整体翻转某个角的符号；
     * 而不同机型之间的差异是**陀螺轴相对加速度计轴的朝向**（Air 4 Pro 实测 (+, -, -)，
     * 即 gyro Y/Z 与 accel 反向）。这个差异必须在送进 AHRS 之前修正，
     * 否则四元数从第一步就错，后面再怎么取反欧拉角都救不回来。
     *
     * 默认 (+, +, +) = Air 1s 基准，与改造前行为完全一致。
     */
    public volatile float gyroSignX = 1f;
    public volatile float gyroSignY = 1f;
    public volatile float gyroSignZ = 1f;

    /** 一次性设置陀螺三轴符号。 */
    public void setGyroSign(float sx, float sy, float sz) {
        gyroSignX = sx;
        gyroSignY = sy;
        gyroSignZ = sz;
    }

    /** 当前陀螺三轴符号，形如 "(+,-,-)"，供日志与状态通道使用。 */
    public String gyroSignText() {
        return "(" + (gyroSignX < 0 ? "-" : "+")
                + "," + (gyroSignY < 0 ? "-" : "+")
                + "," + (gyroSignZ < 0 ? "-" : "+") + ")";
    }

    // ---- 画面行为模式（三种，互斥）
    /** 悬停：画面钉在空间里，转头就滑出视野。 */
    public static final int MODE_HOVER = 0;
    /** 追踪：画面一边留在空间里、一边被惯性拉回眼前。 */
    public static final int MODE_TRACK = 1;
    /** 扩展：不做 3DoF，画面固定贴眼前（等同普通外接屏）。 */
    public static final int MODE_EXTEND = 2;

    /**
     * 画面行为：MODE_HOVER / MODE_TRACK / MODE_EXTEND。
     *
     * 三种模式的输出差异：
     *   悬停  —— 输出 = 头部相对中位的角度，画面在世界里不动；
     *   追踪  —— 输出 = 头部角度 − 跟随基准（跟随基准以 τ 惯性追向头部角度），
     *            转头瞬间画面留在原处，再用 τ 滑回正前方；roll 收敛到 0（与眼镜零度对齐）；
     *   扩展  —— 输出恒为 0，画面贴眼前不动，等效于关掉 3DoF。
     * τ 由界面上的「跟随速度」控制（0.15–1.5 s）。
     */
    public volatile int viewMode = MODE_HOVER;
    /** 跟随时间常数（秒）：越大越"懒"，画面追得越慢。 */
    public volatile float followTauS = 0.4f;

    /**
     * 追踪模式下的**残差上限**（度）。
     *
     * 为什么必须限幅：Air 1s 的垂直视场只有约 23°，横向也就四十度出头。
     * 不加限幅时，正常转头（60~120°/s）会让残差瞬间涨到 30~50°，
     * 画面直接飞出视野，等跟随收敛才从屏幕边缘"冒"回来 —— 看起来就是
     * "画面从错误的方向出现"。限幅后画面始终留在视野内，只是被拖后一点再滑正。
     */
    private static final float TRACK_MAX_RESIDUAL_DEG = 14f;

    /** 跟随基准（角度域）与上一帧"取反前"的输出，用于开启瞬间保持连续。 */
    private float followYaw, followPitch;
    /** 追踪模式下的画面翻滚角：从当前值指数收敛到 0（与眼镜对齐）。 */
    private float followRoll;
    private boolean followInit;
    private float prevOutYaw, prevOutPitch;

    private final OneEuro fYaw = new OneEuro(1.2f, 0.06f);
    private final OneEuro fPitch = new OneEuro(1.2f, 0.06f);
    private final OneEuro fRoll = new OneEuro(1.2f, 0.06f);
    private long lastFilterNs;

    /** 冻结期间直接输出这一帧（latch），避免"停下后还滑几度"。 */
    private final float[] latchedView = new float[16];
    private boolean latched;

    /** 最近一次输出的角度（度），供界面显示。 */
    private volatile float outYaw, outPitch, outRoll;
    public volatile long frames;
    public volatile float hz;

    private long hzWindowStart;
    private int hzCount;

    private final float[] R = new float[9];
    private final float[] forward = new float[3];
    private final float[] up = new float[3];
    private final float[] gyroUsed = new float[3];
    private final float[] view = new float[16];

    // ---------------------------------------------------------------- 输入

    /**
     * @param accel   加速度 m/s²（设备原始）
     * @param gyroRad 角速度 rad/s（设备原始，未减零偏）
     * @param dt      采样间隔（秒，来自设备时间戳）
     */
    public void onSample(float[] accel, float[] gyroRad, float dt) {
        synchronized (sLock) {
            frames++;
            tickHz();
            if (!(dt > 0f)) {
                dt = 1f / 460f;
            }

            // 陀螺轴符号修正（融合自 rayneo_imu）：必须在**任何**统计/零偏/AHRS 之前，
            // 保证后面看到的 gyroRad 已经是"与加速度计同手系"的角速度。
            // 符号为 ±1 时乘一次是精确的（不会引入误差）；三轴都是 +1 时整段等价于空操作。
            if (gyroSignX < 0f || gyroSignY < 0f || gyroSignZ < 0f) {
                if (gyroSignX < 0f) gyroRad[0] = -gyroRad[0];
                if (gyroSignY < 0f) gyroRad[1] = -gyroRad[1];
                if (gyroSignZ < 0f) gyroRad[2] = -gyroRad[2];
            }

            // 第一帧建立种子：**零偏不清零**，只把"上"= 当前加速度方向确定下来。
            //
            // 老版本这里 `System.arraycopy(gyroRad, 0, bias, 0, 3)` 拿第一帧当零偏。
            // 但按「开始投屏」的瞬间手通常还在动，几 °/s 的角速度被当成零偏存下来，
            // 之后再也不会被纠正（残差判据自锁），于是画面按这个速率自己往一边滑。
            // 现在改成 bias 保持 0，交由下面的首次校准从"确在静止"的窗口里采 gMean。
            if (!seeded) {
                System.arraycopy(gyroRad, 0, gMean, 0, 3);
                for (int i = 0; i < 3; i++) {
                    gMean2[i] = gyroRad[i] * gyroRad[i];
                }
                bias[0] = bias[1] = bias[2] = 0f;
                copyNormalized(accel, upBody);
                accNormRef = Mahony.norm3(accel);
                seeded = true;
                firstCalibrated = false;
                calTime = 0f;
                calSum[0] = calSum[1] = calSum[2] = 0d;
                calCount = 0;
                ahrs.resetToAccel(accel);
                learnedTime = 0f;
            }

            // 陀螺统计量（均值 / 平方均值 → 方差）
            for (int i = 0; i < 3; i++) {
                gMean[i] += GYRO_STAT_ALPHA * (gyroRad[i] - gMean[i]);
                gMean2[i] += GYRO_STAT_ALPHA * (gyroRad[i] * gyroRad[i] - gMean2[i]);
            }

            // 判定"静止/可学零偏"要看**减掉当前零偏估计之后**的残差：
            // 否则种子偏大时残差永远超过阈值，零偏就再也学不进去了（自锁）
            float resX = gyroRad[0] - bias[0];
            float resY = gyroRad[1] - bias[1];
            float resZ = gyroRad[2] - bias[2];
            float resMag = (float) Math.sqrt(resX * resX + resY * resY + resZ * resZ);

            boolean gyroQuiet = resMag < STILL_RAD;
            boolean gyroSteady = true;
            boolean calSteady = true;
            for (int i = 0; i < 3; i++) {
                float var = gMean2[i] - gMean[i] * gMean[i];
                if (var > STILL_VAR_MAX) {
                    gyroSteady = false;
                }
                if (var > CAL_VAR_MAX) {
                    calSteady = false;
                }
            }
            if (!gyroSteady) {
                calSteady = false;   // 更严的那一档必然是更松那一档的子集
            }
            boolean still = gyroQuiet && gyroSteady;

            // ---- 静止窗口累加：首次校准与自锁逃生共用
            //
            // 判据只用**方差**，不用残差。这是整条漂移链的破环点：
            // 残差是相对当前 bias 算的，bias 一开始就错的话残差恒超门槛，
            // 零偏永远学不进去（自锁）；而方差与 bias 无关，不存在这个循环依赖。
            if (calSteady) {
                calTime += dt;
                for (int i = 0; i < 3; i++) {
                    calSum[i] += gyroRad[i];
                }
                calCount++;
            } else {
                calTime = 0f;           // 中途动了，窗口作废、重新计时
                calSum[0] = calSum[1] = calSum[2] = 0d;
                calCount = 0;
            }

            boolean wantFirst = !firstCalibrated && calTime >= CAL_STEADY_S;
            // 自锁逃生：已校准、确在静止 3 秒、但残差仍偏大 → 说明零偏估错了。
            // 触发场景是校准窗口恰好落在轻微运动上（方差没抓到），或温度漂移让零偏跑掉。
            // 没有磁力计，AHRS 没有任何观测量能纠正 yaw，唯一出路是重新采一次零偏。
            boolean wantEscape = firstCalibrated
                    && calTime >= ESCAPE_S
                    && resMag > (float) Math.toRadians(ESCAPE_DPS);

            if (calCount > 0 && (wantFirst || wantEscape)) {
                // 采信 0.8 秒（或更长）的累加平均，而不是 gMean：
                // gMean 的等效窗口只有约 0.1 秒，噪声底比累加平均高一个数量级。
                for (int i = 0; i < 3; i++) {
                    bias[i] = (float) (calSum[i] / calCount);
                }
                firstCalibrated = true;
                learnedTime = 0f;       // 重新进入快速收敛阶段
                residualDps = 0f;       // 校准后残差理论上归零，让界面立刻看到效果
                calTime = 0f;           // 窗口用掉了，下一次采信要重新攒
                calSum[0] = calSum[1] = calSum[2] = 0d;
                calCount = 0;
            }

            float aNorm = Mahony.norm3(accel);
            if (resMag < STILL_EXIT_RAD && aNorm > 1e-3f) {
                accNormRef += ACC_NORM_ALPHA * (aNorm - accNormRef);
            }

            if (still) {
                stillTime += dt;
                // "上"方向顺势平滑，抵抗手抖（只在静止时更新）
                for (int i = 0; i < 3; i++) {
                    upBody[i] += 0.05f * (accel[i] - upBody[i]);
                }
                normalize(upBody);
            } else {
                stillTime = 0f;
            }

            // 零偏只在「真正静止」时学习：贴近噪声底 + 陀螺方差小 + 持续 0.25s，
            // 并且限制每秒变化量。冻结（画面保持）仍用较松的 2.9°/s 阈值。
            boolean biasLearnable = resMag < BIAS_STILL_RAD && gyroSteady
                    && stillTime >= STILL_TIME_S;
            if (biasLearnable) {
                float rate = learnedTime < FAST_LEARN_S ? BIAS_RATE_FAST : BIAS_RATE_SLOW;
                float maxStep = rate * dt;
                learnedTime += dt;
                for (int i = 0; i < 3; i++) {
                    float step = BIAS_ALPHA * (gMean[i] - bias[i]);
                    if (step > maxStep) {
                        step = maxStep;
                    } else if (step < -maxStep) {
                        step = -maxStep;
                    }
                    bias[i] += step;
                }
            }

            // 残差指标每个静止帧都更新，**不要放在 biasLearnable 里面**。
            // 老版本只在"零偏可学"时更新 residualDps，而自锁时这个条件恒为假，
            // 于是界面上的「静止残差」永远显示 0 —— 最有诊断价值的那个数字恰好隐身了。
            // 现在只要陀螺确实没在动就刷新它，自锁时会稳定停在真实的偏差值上。
            if (gyroSteady && gyroQuiet) {
                float resNow = (float) Math.toDegrees(resMag);
                residualDps = residualDps <= 0f ? resNow : residualDps + 0.02f * (resNow - residualDps);
            }

            // 冻结（带迟滞）：静止够久就停陀螺积分；要明显动起来才解冻
            if (freezeWhenStill && stillTime > FREEZE_TIME_S) {
                frozen = true;
            } else if (frozen && resMag > STILL_EXIT_RAD) {
                frozen = false;
            }

            if (frozen) {
                gyroUsed[0] = 0f;
                gyroUsed[1] = 0f;
                gyroUsed[2] = 0f;
            } else {
                gyroUsed[0] = gyroRad[0] - bias[0];
                gyroUsed[1] = gyroRad[1] - bias[1];
                gyroUsed[2] = gyroRad[2] - bias[2];
            }

            // 运动加速度会污染倾角观测：偏离 1g 太多就先只积分
            boolean trustAccel = accNormRef <= 1e-3f
                    || Math.abs(aNorm - accNormRef) <= ACC_TRUST_BAND * accNormRef;
            ahrs.update(gyroUsed, accel, dt, trustAccel);

            if (!recentered) {
                recenterLocked();
            }
        }
    }

    private void tickHz() {
        long now = System.nanoTime();
        if (hzWindowStart == 0L) {
            hzWindowStart = now;
        }
        if (++hzCount >= 64) {
            hz = hzCount * 1_000_000_000f / (now - hzWindowStart);
            hzWindowStart = now;
            hzCount = 0;
        }
    }

    // ---------------------------------------------------------------- 复位

    /** 把当前朝向设为中位（画面拉回正前方）。 */
    public void recenter() {
        synchronized (sLock) {
            recenterLocked();
        }
    }

    /** 重新采样零偏（不用静止等待，收敛在 0.5 秒内自动完成）；不动画面中位。 */
    public void resetBias() {
        synchronized (sLock) {
            seeded = false;
            firstCalibrated = false;
            calTime = 0f;
            calSum[0] = calSum[1] = calSum[2] = 0d;
            calCount = 0;
            stillTime = 0f;
            learnedTime = 0f;
            residualDps = 0f;
            frozen = false;
        }
    }

    /** 会话开始/结束：连中位一起清掉，下一帧重新定中。 */
    public void resetSession() {
        synchronized (sLock) {
            seeded = false;
            firstCalibrated = false;
            calTime = 0f;
            calSum[0] = calSum[1] = calSum[2] = 0d;
            calCount = 0;
            recentered = false;
            stillTime = 0f;
            frozen = false;
            learnedTime = 0f;
            residualDps = 0f;
            accNormRef = 0f;
            latched = false;
            followInit = false;
            followYaw = followPitch = followRoll = 0f;
            prevOutYaw = prevOutPitch = 0f;
            outYaw = outPitch = outRoll = 0f;
            lastFilterNs = 0L;
            fYaw.reset();
            fPitch.reset();
            fRoll.reset();
        }
    }

    private void recenterLocked() {
        if (!ahrs.started()) {
            return;
        }
        buildRotation(ahrs.q, R);
        readForwardUp();

        // 正交化，保证 lookAt 的基可用
        normalize(forward);
        float d = dot(up, forward);
        up[0] -= d * forward[0];
        up[1] -= d * forward[1];
        up[2] -= d * forward[2];
        normalize(up);

        System.arraycopy(forward, 0, f0, 0, 3);
        System.arraycopy(up, 0, u0, 0, 3);
        cross(f0, u0, r0);   // 屏幕右方向（相机朝 +Z 看时即场景 -X）
        normalize(r0);

        recentered = true;
        stillTime = 0f;
        frozen = false;
        latched = false;
        followInit = false;
        followYaw = followPitch = followRoll = 0f;
        lastFilterNs = 0L;
        fYaw.reset();
        fPitch.reset();
        fRoll.reset();
        outYaw = outPitch = outRoll = 0f;
    }

    private void readForwardUp() {
        forward[0] = R[2];
        forward[1] = R[5];
        forward[2] = R[8];
        if (invertForward) {
            forward[0] = -forward[0];
            forward[1] = -forward[1];
            forward[2] = -forward[2];
        }
        up[0] = R[0] * upBody[0] + R[1] * upBody[1] + R[2] * upBody[2];
        up[1] = R[3] * upBody[0] + R[4] * upBody[1] + R[5] * upBody[2];
        up[2] = R[6] * upBody[0] + R[7] * upBody[1] + R[8] * upBody[2];
    }

    // ---------------------------------------------------------------- 输出

    /**
     * 相机视图矩阵（column-major 4x4）。
     *
     * @return false 表示尚未复位（此时输出单位矩阵，画面居中）
     */
    public boolean getViewMatrix(float[] out) {
        synchronized (sLock) {
            if (!recentered || !ahrs.started()) {
                Matrix.setIdentityM(out, 0);
                return false;
            }
            // 冻结期间直接复用上一帧（latch），彻底消除"停下后画面还滑一段"。
            // 仅悬停模式用：追踪要跑到正前方、扩展每帧都要是正中，都不能拿旧矩阵。
            if (frozen && latched && viewMode == MODE_HOVER) {
                System.arraycopy(latchedView, 0, out, 0, 16);
                return true;
            }

            buildRotation(ahrs.q, R);
            readForwardUp();

            // 投影到中位场景坐标系
            float fx = dot(forward, r0), fy = dot(forward, u0), fz = dot(forward, f0);
            float ux = dot(up, r0), uy = dot(up, u0), uz = dot(up, f0);

            // 朝向 → yaw/pitch，翻滚由"上"方向的倾斜单独算
            float yaw = (float) Math.toDegrees(Math.atan2(fx, fz));
            float pitch = (float) Math.toDegrees(Math.asin(clamp(fy, -1f, 1f)));
            float roll = rollFrom(ux, uy, uz, yaw, pitch);

            long now = System.nanoTime();
            float dt = lastFilterNs == 0L ? 0.016f : (now - lastFilterNs) / 1e9f;
            lastFilterNs = now;
            dt = clamp(dt, 0.004f, 0.05f);

            if (viewMode == MODE_EXTEND) {
                // 扩展模式：不做 3DoF，画面固定贴在眼前 —— 与"普通外接屏"一致。
                //
                // 做法是**把角度归零**，然后照常走下面的 lookAt 构造路径。
                // 不能直接返回单位矩阵：本项目的"屏幕前方"是世界 +Z
                // （QuadRenderer 把 quad 平移到 model 的 +d），而单位视图矩阵
                // 意味着相机朝 −Z 看，屏幕会跑到相机背后 → 眼镜全黑。
                yaw = 0f;
                pitch = 0f;
                roll = 0f;
                followInit = false;
            } else if (viewMode == MODE_TRACK) {
                // ---- 追踪模式：先做跟随，再滤波（顺序不能反）
                // 跟随放在滤波之前，One Euro 才能平滑"跟随后的输出"。
                if (!followInit) {
                    // 开启瞬间保持画面连续：让当前输出等于上一帧的输出，再从这里滑向 0
                    followYaw = yaw - prevOutYaw;
                    followPitch = pitch - prevOutPitch;
                    followRoll = roll;      // 翻滚从当前角度开始收敛，不跳变
                    followInit = true;
                }
                float tau = clamp(followTauS, 0.15f, 1.5f);
                float k = 1f - (float) Math.exp(-dt / tau);
                followYaw += (yaw - followYaw) * k;
                followPitch += (pitch - followPitch) * k;

                // 残差限幅：跟随基准可能被甩得很远（快转），这里只取视野内的那一段。
                // 效果是"画面被拖后最多 TRACK_MAX_RESIDUAL_DEG，然后滑回中心"，
                // 而不是先飞出视野再从边缘冒回来。
                float resYaw = clamp(yaw - followYaw, -TRACK_MAX_RESIDUAL_DEG, TRACK_MAX_RESIDUAL_DEG);
                float resPitch = clamp(pitch - followPitch, -TRACK_MAX_RESIDUAL_DEG, TRACK_MAX_RESIDUAL_DEG);
                yaw = resYaw;
                pitch = resPitch;

                // 翻滚：追踪模式下画面最终要跟眼镜"零度对齐"，所以输出直接朝 0 收敛。
                // 这里是**低通归零**（out ← out·(1−k)），不是"当前角 − 滞后基准"的高通，
                // 因此不会把翻滚噪声放大成画面抖动；0.12s 只是为了开关瞬间不硬跳一下。
                float kr = 1f - (float) Math.exp(-dt / 0.12f);
                followRoll += (0f - followRoll) * kr;
                roll = followRoll;
            } else {
                followInit = false;
            }

            // 记录"取反前"的输出，供下次开启追踪时做连续性衔接
            prevOutYaw = yaw;
            prevOutPitch = pitch;

            // 渲染线程滤波：One Euro，快转时几乎不延迟、静止时压掉抖动
            yaw = fYaw.filter(yaw, dt);
            pitch = fPitch.filter(pitch, dt);
            roll = fRoll.filter(roll, dt);

            if (invertYaw) {
                yaw = -yaw;
            }
            if (invertPitch) {
                pitch = -pitch;
            }
            if (invertRoll) {
                roll = -roll;
            }
            outYaw = yaw;
            outPitch = pitch;
            outRoll = roll;

            // 由角度重建朝向与上方向
            double ry = Math.toRadians(yaw), rp = Math.toRadians(pitch), rr = Math.toRadians(roll);
            float cfx = (float) (Math.sin(ry) * Math.cos(rp));
            float cfy = (float) Math.sin(rp);
            float cfz = (float) (Math.cos(ry) * Math.cos(rp));
            float rx = (float) Math.cos(ry), rz = (float) -Math.sin(ry);

            // up0 = forward × right（yaw/pitch 对应的"无翻滚"上方向）
            float u0x = cfy * rz - cfz * 0f;
            float u0y = cfz * rx - cfx * rz;
            float u0z = cfx * 0f - cfy * rx;
            // 绕 forward 转 roll
            float kx = cfy * u0z - cfz * u0y;
            float ky = cfz * u0x - cfx * u0z;
            float kz = cfx * u0y - cfy * u0x;
            float cr = (float) Math.cos(rr), sr = (float) Math.sin(rr);
            float nux = u0x * cr + kx * sr;
            float nuy = u0y * cr + ky * sr;
            float nuz = u0z * cr + kz * sr;

            Matrix.setLookAtM(view, 0,
                    0f, 0f, 0f,
                    cfx, cfy, cfz,
                    nux, nuy, nuz);
            System.arraycopy(view, 0, out, 0, 16);
            System.arraycopy(view, 0, latchedView, 0, 16);
            latched = true;
            return true;
        }
    }

    /**
     * 翻滚：实际"上"方向相对 yaw/pitch 推出的"无翻滚上方向"绕视线轴的转角（度）。
     */
    private static float rollFrom(float ux, float uy, float uz, float yawDeg, float pitchDeg) {
        double ry = Math.toRadians(yawDeg), rp = Math.toRadians(pitchDeg);
        float fx = (float) (Math.sin(ry) * Math.cos(rp));
        float fy = (float) Math.sin(rp);
        float fz = (float) (Math.cos(ry) * Math.cos(rp));
        float rx = (float) Math.cos(ry), rz = (float) -Math.sin(ry);

        // up0 = forward × right，其中 right = (cos yaw, 0, -sin yaw)
        float u0x = fy * rz;
        float u0y = fz * rx - fx * rz;
        float u0z = -fy * rx;
        float n = (float) Math.sqrt(u0x * u0x + u0y * u0y + u0z * u0z);
        if (n < 1e-6f) {
            return 0f;
        }
        u0x /= n; u0y /= n; u0z /= n;

        float dotp = ux * u0x + uy * u0y + uz * u0z;
        // cross(up0, up) · forward
        float cx = u0y * uz - u0z * uy;
        float cy = u0z * ux - u0x * uz;
        float cz = u0x * uy - u0y * ux;
        float sinp = cx * fx + cy * fy + cz * fz;
        return (float) Math.toDegrees(Math.atan2(sinp, dotp));
    }

    // ---------------------------------------------------------------- 状态

    public float[] yawPitch() {
        return new float[]{outYaw, outPitch};
    }

    public float rollDeg() {
        return outRoll;
    }

    public boolean isFrozen() {
        return frozen;
    }

    /**
     * 当前**估计零偏**（三轴绝对值最大，°/s）。
     * 注意：这是 IMU 自身的零速偏移量，大不代表在漂——它正是被减掉的那部分。
     */
    public float biasDps() {
        synchronized (sLock) {
            float m = Math.abs(bias[0]);
            m = Math.max(m, Math.abs(bias[1]));
            m = Math.max(m, Math.abs(bias[2]));
            return (float) Math.toDegrees(m);
        }
    }

    /** 静止窗口内的残差（°/s）：越小说明零偏估得越准、画面越不会自己跑。 */
    public float residualDps() {
        synchronized (sLock) {
            return residualDps;
        }
    }

    /**
     * 首次零偏校准是否已完成。
     *
     * 界面上的意义：false 表示此刻的零偏偏离真值，画面**一定**还带单向漂移，
     * 这时看到的"自己往一边滑"不是 bug 而是还没校完；true 之后仍有漂移才是真问题。
     * 校准需要眼镜连续 0.6 秒不动，所以戴上后先别晃，让画面自己定住。
     */
    public boolean isFirstCalibrated() {
        return firstCalibrated;
    }

    public boolean isTracking() {
        synchronized (sLock) {
            return recentered && ahrs.started();
        }
    }

    // ---------------------------------------------------------------- 数学

    /** 四元数 (x,y,z,w) → 3x3 行主序旋转矩阵（机体系 → 世界系）。 */
    static void buildRotation(float[] q, float[] m) {
        float x = q[0], y = q[1], z = q[2], w = q[3];
        m[0] = 1f - 2f * (y * y + z * z);
        m[1] = 2f * (x * y - z * w);
        m[2] = 2f * (x * z + y * w);
        m[3] = 2f * (x * y + z * w);
        m[4] = 1f - 2f * (x * x + z * z);
        m[5] = 2f * (y * z - x * w);
        m[6] = 2f * (x * z - y * w);
        m[7] = 2f * (y * z + x * w);
        m[8] = 1f - 2f * (x * x + y * y);
    }

    private static void copyNormalized(float[] src, float[] dst) {
        System.arraycopy(src, 0, dst, 0, 3);
        normalize(dst);
    }

    private static float dot(float[] a, float[] b) {
        return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    }

    private static void cross(float[] a, float[] b, float[] out) {
        float x = a[1] * b[2] - a[2] * b[1];
        float y = a[2] * b[0] - a[0] * b[2];
        float z = a[0] * b[1] - a[1] * b[0];
        out[0] = x; out[1] = y; out[2] = z;
    }

    private static void normalize(float[] v) {
        float n = Mahony.norm3(v);
        if (n < 1e-6f) {
            return;
        }
        v[0] /= n; v[1] /= n; v[2] /= n;
    }

    private static float clamp(float v, float lo, float hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    /**
     * One Euro 滤波：截止频率随速度自适应。
     * 慢速时截止频率低（抖动被压掉），快速时升高（几乎不拖影）。
     * 参考 Casiez et al. 2012，这里只做一维、只用于角度。
     */
    static final class OneEuro {
        private final float minCutoff;
        private final float beta;
        private final float dCutoff = 1.0f;
        private float xPrev;
        private float dxPrev;
        private boolean init;

        OneEuro(float minCutoff, float beta) {
            this.minCutoff = minCutoff;
            this.beta = beta;
        }

        void reset() {
            init = false;
        }

        float filter(float x, float dt) {
            if (!init) {
                init = true;
                xPrev = x;
                dxPrev = 0f;
                return x;
            }
            float dx = (x - xPrev) / dt;
            float edx = lowPass(dx, dxPrev, alpha(dCutoff, dt));
            dxPrev = edx;
            float cutoff = minCutoff + beta * Math.abs(edx);
            float y = lowPass(x, xPrev, alpha(cutoff, dt));
            xPrev = y;
            return y;
        }

        private static float alpha(float cutoff, float dt) {
            float tau = 1f / (2f * (float) Math.PI * cutoff);
            return 1f / (1f + tau / dt);
        }

        private static float lowPass(float x, float prev, float a) {
            return a * x + (1f - a) * prev;
        }
    }
}
