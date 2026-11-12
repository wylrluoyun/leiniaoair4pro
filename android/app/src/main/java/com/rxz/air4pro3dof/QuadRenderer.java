package com.rxz.air4pro3dof;

import android.graphics.Bitmap;
import android.graphics.SurfaceTexture;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.opengl.Matrix;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * 把手机屏幕画面画成一块「钉在空间里的屏幕」。
 *
 * 相机旋转来自 HeadPose 的视图矩阵；屏幕四边形固定在场景 +Z 方向 distance 米处，
 * 因此转头时它在视野里反向移动 —— 这就是 3DoF 悬停的视觉本质。
 *
 * 坐标约定：场景系 = 复位那一刻的机体系，+Z 为朝向、+Y 为上。
 * 因为相机朝 +Z 看（而不是 GL 默认的 -Z），屏幕右侧对应场景 -X，
 * 所以纹理 U 方向需要取反（见 VERTICES）。
 *
 * 资源生命周期（旧实现完全没管，反复启停会泄漏）：
 *   - release() 由会话收尾调用：停掉帧回调线程、释放 Surface/SurfaceTexture、
 *     通知 CaptureService 清掉 pendingSurface 与 VirtualDisplay；
 *   - program/texture 的删除在 GL 线程执行（onDrawFrame 看到 released 标记时），
 *     不在任意线程调 glDelete*。
 */
public class QuadRenderer implements GLSurfaceView.Renderer, SurfaceTexture.OnFrameAvailableListener {

    private static final String TAG = "QuadRenderer";

    private static final float[] VERTICES = {
            // x,  y,  z,     u,  v
            -1f, -1f, 0f, 1f, 0f,
            1f, -1f, 0f, 0f, 0f,
            -1f, 1f, 0f, 1f, 1f,
            1f, 1f, 0f, 0f, 1f,
    };

    private static final String VS =
            "uniform mat4 uMvp;\n" +
            "uniform mat4 uUvMat;\n" +
            "attribute vec4 aPos;\n" +
            "attribute vec2 aUv;\n" +
            "varying vec2 vUv;\n" +
            "varying vec2 vPos;\n" +
            "void main() {\n" +
            "  gl_Position = uMvp * aPos;\n" +
            "  vPos = aUv;\n" +
            "  vUv = (uUvMat * vec4(aUv, 0.0, 1.0)).xy;\n" +
            "}\n";

    private static final String FS =
            "#extension GL_OES_EGL_image_external : require\n" +
            "precision mediump float;\n" +
            "varying vec2 vUv;\n" +
            "varying vec2 vPos;\n" +
            "uniform samplerExternalOES uTex;\n" +
            "uniform float uSolid;\n" +
            "void main() {\n" +
            "  if (uSolid > 1.5) {\n" +                     // 光标小点：圆形、带柔边
            "    float d = length(vPos - vec2(0.5));\n" +
            "    float a = smoothstep(0.5, 0.40, d);\n" +
            "    if (a < 0.02) discard;\n" +
            "    gl_FragColor = vec4(1.0, 0.86, 0.20, a);\n" +
            "  } else if (uSolid > 0.5) {\n" +             // 无画面时的底板
            "    gl_FragColor = vec4(0.10, 0.12, 0.16, 1.0);\n" +
            "  } else {\n" +
            "    gl_FragColor = texture2D(uTex, vUv);\n" +
            "  }\n" +
            "}\n";

    /** 画面参数改由 Stage 提供（手机端滑块实时写），这里不再持有副本。 */
    private int lastCapW, lastCapH;
    private float contentAspect;

    public volatile int surfaceW, surfaceH;

    private final HeadPose pose;
    private final int capW, capH;

    private final float[] proj = new float[16];
    private final float[] view = new float[16];
    private final float[] model = new float[16];
    private final float[] vp = new float[16];
    private final float[] mvp = new float[16];
    private final float[] uvMat = new float[16];

    FloatBuffer vertexBuf;
    /**
     * 下面这些 GL 句柄原来是 private，改成包内可见是因为 {@link RecorderGl} 要复用它们。
     *
     * 为什么能直接复用：RecorderGl 的 EGLContext 是通过 eglCreateContext(..., mainContext, ...)
     * 建出来的**共享上下文**（同一个 share group），program / 纹理 / VBO 在 GL 里是
     * share group 级对象，跨上下文照样有效，不需要重新编译或重新上传。
     * 反过来，如果各自建一套，纹理是 EXTERNAL_OES 且由 SurfaceTexture 绑定在 GL 线程上，
     * 另一个上下文根本看不到同一份内容。
     */
    int program;
    int aPos, aUv, uMvp, uUvMat, uTex, uSolid;

    int textureId;

    /**
     * 给录像线程用的**画面快照**：GL 线程每帧把当前 mvp / uvMat / 是否有内容写进这里，
     * 录像线程按自己的节拍读一份去画。
     *
     * 为什么要快照而不是共享 mvp / uvMat 本体：那两个数组是 GL 线程每帧原地改写的，
     * 录像线程直接读会读到"画到一半"的矩阵（撕裂）。拷贝到独立数组、一次性写完，
     * 录像线程读到的永远是某一帧的完整状态。
     * 轻微代价：录像画面可能比主画面晚一两帧 —— 对录像完全无所谓。
     */
    final float[] recMvp = new float[16];
    final float[] recUvMat = new float[16];
    volatile float recSolid = 1f;

    /**
     * 录像线程专用的顶点缓冲 —— **不能和主画面的 vertexBuf 共用**。
     *
     * 为什么：FloatBuffer 的 position 是**缓冲区对象自己的状态**，不是每线程的。
     * glVertexAttribPointer 需要先把 position 挪到 0 再挪到 3，这两步之间如果被另一个
     * 线程插进来改了 position，顶点数据就会错位（画面撕裂/顶点飞到屏幕外）。
     * 主画面每帧在 GL 线程挪一次、录像线程每帧在录像线程挪一次，正好撞上。
     * 内容完全相同（都是 VERTICES），只是各自持有一份 position 状态，代价 80 字节。
     */
    final FloatBuffer recVertexBuf;

    /**
     * 捕获用的 SurfaceTexture。
     *
     * ⚠️ 必须是 volatile：它被 GL 线程（onSurfaceCreated / healCaptureSurface）写，
     * 同时被主线程（CaptureService.applySize → syncBufferSize）读来做
     * setDefaultBufferSize。不加 volatile 时主线程可能永远看到旧引用（甚至 null），
     * 于是横屏时缓冲区尺寸改不到，表现为"画面拉长 + 卡死"。
     */
    private volatile SurfaceTexture surfaceTexture;
    private Surface surface;
    /** 已交接给 CaptureService / ExtendHost 的那个 Surface（release 时要通知对方清引用）。 */
    private Surface handedSurface;
    private final HandlerThread cbThread;
    private final Handler cbHandler;
    private volatile boolean newFrame;
    private volatile boolean released;

    // ---------------------------------------------------------------- 截图 / 录像

    /**
     * 主 Surface 的 EGL 三元组 —— **权威副本**，只在 onSurfaceChanged 里记录一次。
     *
     * 为什么必须存下来、不能每帧用 eglGetCurrentSurface(EGL_DRAW) 现取：
     * 那个 API 返回的是"此刻绑定在上下文上的"表面，而 drawIntoRecorder 的 finally
     * 要靠它切回去。一旦某次切回失败，current surface 就永久停在编码器表面上，
     * 下一次 eglGetCurrentSurface 取到的就是编码器表面，finally 又照着它"切回去"
     * —— 自证循环，画面再也不交换，帧数永久停在原地。
     *
     * onSurfaceChanged 是唯一能保证"当前一定在主表面上"的时刻（GLSurfaceView
     * 刚建好/改完尺寸，还没进过录像分支），在这里抓一次即可。
     */
    private javax.microedition.khronos.egl.EGLSurface mainEglSurface;
    private javax.microedition.khronos.egl.EGLDisplay mainEglDisplay;
    private javax.microedition.khronos.egl.EGLContext mainEglContext;


    /**
     * 真正把画面画进编码器 Surface 的帧数（诊断用，跨实例静态）。
     *
     * 为什么要单独记：GlassRecorder.frameIndex 记的是"编码器吐出来的帧"，
     * 而这里记的是"我们往编码器 Surface 里塞了几帧"。两个数字一对比就能定位：
     *   · attempted=0                 → drawIntoRecorder 根本没跑（surfaceReady 假 / 守卫拦住）
     *   · attempted>0 且 written=0    → 塞进去了但编码器没吐（EGL 层没真正提交）
     * 之前只有 written 一个数，0 帧时完全分不清是哪一段断的。
     */
    public static volatile long recFramesAttempted;
    /** eglSwapBuffers 返回 false 的次数（EGL 提交失败的直接证据）。 */
    public static volatile long recSwapFails;
    private volatile GlassRecorder recorder;
    /**
     * 引擎线程要求"下一次 GL 帧去建 / 去拆录像上下文"。
     *
     * 为什么不直接在 setRecorder 里建：RecorderGl 需要主上下文的 EGLDisplay / EGLContext
     * 当 share_context，而这两个句柄只在 GL 线程有效（其它线程拿不到当前上下文）。
     * 所以 setRecorder 只登记意愿，真正动手在 onDrawFrame 里。
     */
    private volatile boolean recRequested;

    /**
     * 真正把画面画进编码器的那个东西 —— 跑在**自己的线程、自己的共享 EGLContext** 上。
     *
     * 为什么不在本渲染器里直接画（v6/v8 两次都栽在这）：
     * MediaCodec 的输入 Surface 必须用带 EGL_RECORDABLE_ANDROID 的 config 建 window surface，
     * 否则 eglSwapBuffers 第一次调用就永久阻塞（dequeueBuffer 永远等不到 buffer），
     * 连带整个 GL 线程冻死 —— 现象就是"一开录像主画面卡住、帧数一动不动"。
     * 而主 context 的 config 是窗口用的，通常不带 RECORDABLE；强行共用就会死。
     *
     * 解法：用 eglCreateContext(display, 带RECORDABLE的config, mainContext, ...) 建一个
     * **share group 相同的独立上下文**，program / 纹理 / VBO 直接复用，但 EGLSurface
     * 和 swap 都在自己的线程上，即使卡也只卡录像，主画面照常渲染。
     *
     * 只在 GL 线程读写（创建于 onDrawFrame，销毁于 release / setRecorder(null)）。
     */
    private volatile RecorderGl recorderGl;

    /**
     * 录像上下文是否已经真的拆干净（GL 线程在 old.stop() 返回后置 true）。
     *
     * 为什么需要这个标志：{@link GlassRecorder#stop()} 会调 codec.stop()，而此刻
     * RecorderGl 的工作线程可能正卡在 eglSwapBuffers 上往编码器 Surface 里写。
     * 那两者一撞就是 native 层崩溃或死锁。所以 GlassEngine 必须先等这里变成 true
     * 再去停编码器 —— 见 {@link #awaitRecorderTornDown(long)}。
     *
     * 初始值 true：还没开始录像，等于"已拆"。
     */
    private volatile boolean recTornDown = true;

    /** 当前活动的渲染器。CaptureService 在主线程改尺寸时要拿到它去同步 SurfaceTexture。 */
    private static volatile QuadRenderer shared;

    /** 截图请求：置位后下一帧 onDrawFrame 在画完主画面时顺手读像素。 */
    private volatile boolean shotRequested;
    private volatile String shotResult;

    /**
     * 由引擎线程调用：把编码器 Surface 交给录像侧，由 {@link RecorderGl} 建共享上下文。
     *
     * 注意这里只登记 Surface，真正的 eglCreateContext / eglCreateWindowSurface 在
     * GL 线程的下一帧里做（见 onDrawFrame），因为需要拿到主上下文的 EGLDisplay/EGLContext
     * 作为 share_context，那两个句柄只在 GL 线程有效。
     */
    public void setRecorder(GlassRecorder r) {
        if (r != null) {
            recFramesAttempted = 0;
            recSwapFails = 0;
        }
        // 只有在真的需要 GL 线程动手时才落闸：
        //   · 要开始录（r != null）→ 等它建
        //   · 要停且现在确实还挂着一个（recorderGl != null）→ 等它拆
        // 其余情况（本来就没在录）闸门保持 true，GlassEngine 那边就不会白等 1.5 秒。
        if (r != null || recorderGl != null) {
            recTornDown = false;
        }
        recorder = r;
        // 置位后由 GL 线程在 onDrawFrame 里创建 / 销毁 RecorderGl。
        // 传 null 也走同一条路径：GL 线程看到 recorder==null 且 recorderGl!=null 就拆掉。
        recRequested = true;
    }

    public GlassRecorder recorder() {
        return recorder;
    }

    /** 请求截一张图；下一帧画完后异步回调路径写进 {@link #takeShotResult()}。 */
    public void requestShot() {
        shotResult = null;
        shotRequested = true;
    }

    public String takeShotResult() {
        return shotResult;
    }

    /**
     * 等录像上下文拆干净。返回 true = 已拆（或本来就没在录），false = 超时。
     *
     * 谁需要它：{@link GlassEngine#stopRecording} 在调 {@code rec.stop()}（内部会
     * codec.stop() + release surface）之前必须等这里。理由：
     * RecorderGl 的工作线程可能正卡在 {@code eglSwapBuffers} 上往编码器 Surface 里写，
     * 此时把 codec 停掉就是让生产者往已释放的 BufferQueue 里写 —— native 层崩溃或死锁。
     *
     * 为什么不在 stopRecording 里直接 join RecorderGl 的线程：那个线程只能由 GL 线程
     * 安全销毁（EGLSurface 有线程亲和），引擎线程 join 它拿不到 GL 线程的配合。
     * 所以改成"置标记 → GL 线程下一帧拆 → 这里等标记"，用 GL 线程做实际拆除。
     *
     * @param timeoutMs 最多等多久（GL 线程 60fps 时一帧 16ms，600ms 足够跑几十帧）
     */
    public boolean awaitRecorderTornDown(long timeoutMs) {
        if (recTornDown) {
            return true;
        }
        long deadline = android.os.SystemClock.elapsedRealtime() + Math.max(0, timeoutMs);
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            if (recTornDown) {
                return true;
            }
            try {
                Thread.sleep(10);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return recTornDown;
    }

    public QuadRenderer(HeadPose pose, int capW, int capH) {
        this.pose = pose;
        this.capW = capW;
        this.capH = capH;
        this.contentAspect = capW / (float) capH;
        shared = this;

        ByteBuffer bb = ByteBuffer.allocateDirect(VERTICES.length * 4);
        bb.order(ByteOrder.nativeOrder());
        vertexBuf = bb.asFloatBuffer();
        vertexBuf.put(VERTICES);
        vertexBuf.position(0);

        // 录像线程自己那份顶点缓冲（内容相同，position 状态独立，见字段注释）
        ByteBuffer rb = ByteBuffer.allocateDirect(VERTICES.length * 4);
        rb.order(ByteOrder.nativeOrder());
        recVertexBuf = rb.asFloatBuffer();
        recVertexBuf.put(VERTICES);
        recVertexBuf.position(0);

        cbThread = new HandlerThread("st-cb");
        cbThread.start();
        cbHandler = new Handler(cbThread.getLooper());
    }

    /** 会话收尾：停帧回调、释放表面、通知捕获侧清引用。GL 对象在 GL 线程删（见 onDrawFrame）。 */
    public void release() {
        if (released) {
            return;
        }
        released = true;
        if (shared == this) {
            shared = null;
        }
        // 录像上下文必须在 GL 对象失效前拆掉：RecorderGl 是共享 share group 的，
        // 它引用的 program / 纹理 / VBO 就在本渲染器里。反过来先删 GL 对象，
        // RecorderGl 再画一帧就会拿已删除的句柄，轻则黑帧重则驱动报错。
        RecorderGl rg = recorderGl;
        recorderGl = null;
        if (rg != null) {
            rg.stop();
        }
        recRequested = false;
        if (surfaceTexture != null) {
            try {
                surfaceTexture.setOnFrameAvailableListener(null);
                surfaceTexture.release();
            } catch (Exception ignored) {
            }
            surfaceTexture = null;
        }
        if (handedSurface != null) {
            // 把捕获服务里的 pendingSurface / VirtualDisplay 一并清掉，
            // 否则下一会话服务启动时会拿这个已失效的表面去建屏（旧实现漏了这一步）
            CaptureService.clearSurface(handedSurface);
            handedSurface = null;
        }
        if (surface != null) {
            try {
                surface.release();
            } catch (Exception ignored) {
            }
            surface = null;
        }
        cbThread.quitSafely();
    }

    // ------------------------------------------------------------ GL 回调

    @Override
    public void onSurfaceCreated(GL10 gl, EGLConfig config) {
        Log.i(TAG, "onSurfaceCreated");
        // 上下文重建（或上次没走完 release）时，把同上下文里残留的 GL 对象删干净再重建
        deleteGlObjects();

        program = buildProgram();
        aPos = GLES20.glGetAttribLocation(program, "aPos");
        aUv = GLES20.glGetAttribLocation(program, "aUv");
        uMvp = GLES20.glGetUniformLocation(program, "uMvp");
        uUvMat = GLES20.glGetUniformLocation(program, "uUvMat");
        uTex = GLES20.glGetUniformLocation(program, "uTex");
        uSolid = GLES20.glGetUniformLocation(program, "uSolid");

        int[] tex = new int[1];
        GLES20.glGenTextures(1, tex, 0);
        textureId = tex[0];
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);

        surfaceTexture = new SurfaceTexture(textureId);
        surfaceTexture.setDefaultBufferSize(capW, capH);
        surfaceTexture.setOnFrameAvailableListener(this, cbHandler);
        surface = new Surface(surfaceTexture);

        // 交给捕获服务：它会在主线程建 VirtualDisplay
        if (Stage.extendMode) {
            // 扩展屏：由本应用自建私有虚拟屏，内容是自己启动的 Activity / 目标应用
            ExtendHost.onSurface(Stage.appContext, surface, capW, capH, Stage.pendingComponent);
            handedSurface = surface;
        } else {
            CaptureService.setSurface(surface, capW, capH);
            handedSurface = surface;
        }

        Matrix.setIdentityM(uvMat, 0);
        GLES20.glClearColor(0f, 0f, 0f, 1f);
    }

    private void deleteGlObjects() {
        if (program != 0) {
            GLES20.glDeleteProgram(program);
            program = 0;
        }
        if (textureId != 0) {
            GLES20.glDeleteTextures(1, new int[]{textureId}, 0);
            textureId = 0;
        }
    }

    @Override
    public void onSurfaceChanged(GL10 gl, int width, int height) {
        Log.i(TAG, "onSurfaceChanged " + width + "x" + height);
        surfaceW = width;
        surfaceH = height;
        GLES20.glViewport(0, 0, width, height);
        // 这里是唯一能确定"当前上下文绑在主表面上"的时刻：GLSurfaceView 刚建好
        // 或刚改完尺寸，还没进过录像分支。把三元组抓下来当权威副本，之后所有
        // eglMakeCurrent 的"切回去"都用它，不再靠 eglGetCurrentSurface 现取
        // —— 那个 API 一旦被污染就自证循环，画面永久冻结。
        try {
            javax.microedition.khronos.egl.EGL10 egl =
                    (javax.microedition.khronos.egl.EGL10) javax.microedition.khronos.egl.EGLContext
                            .getEGL();
            if (egl != null) {
                mainEglDisplay = egl.eglGetCurrentDisplay();
                mainEglContext = egl.eglGetCurrentContext();
                mainEglSurface = egl.eglGetCurrentSurface(
                        javax.microedition.khronos.egl.EGL10.EGL_DRAW);
                Log.i(TAG, "记录主表面 EGL 三元组 surface=" + mainEglSurface
                        + " display=" + mainEglDisplay);
            }
        } catch (Throwable t) {
            Log.w(TAG, "记录主表面 EGL 三元组失败: " + t.getMessage());
        }
        // 尺寸变了：录像侧的编码器尺寸是建时固定的，继续往旧尺寸的 surface 里画
        // 只会得到错位/全黑。这里只置重建标记，真正的销毁+重建在 onDrawFrame 里做
        // —— RecorderGl 的 EGLSurface 只能在创建它的线程上销毁。
        if (recorder != null) {
            recRequested = true;
        }
    }

    /**
     * 由 CaptureService 在主线程调用：捕获尺寸要变了，先把 SurfaceTexture 的缓冲区改到新尺寸。
     *
     * 必须早于虚拟屏按新尺寸生产，否则会出现"生产者新尺寸 / 消费者旧尺寸"的错配，
     * 表现为画面被拉长、随后 BufferQueue 堵死不再出帧。
     * setDefaultBufferSize 是线程安全的（内部有锁），可以在非 GL 线程调用。
     */
    static void syncBufferSize(int w, int h) {
        if (w <= 0 || h <= 0) {
            return;
        }
        QuadRenderer r = shared;
        if (r == null) {
            return;
        }
        SurfaceTexture st = r.surfaceTexture;
        if (st != null) {
            try {
                st.setDefaultBufferSize(w, h);
                Log.i(TAG, "SurfaceTexture 缓冲区 → " + w + "x" + h);
            } catch (Throwable t) {
                Log.w(TAG, "setDefaultBufferSize 失败: " + t.getMessage());
            }
        }
        r.lastCapW = w;
        r.lastCapH = h;
        r.contentAspect = w / (float) h;
    }

    /** 看门狗请求换一块捕获表面（只能由 GL 线程真正执行）。 */
    private volatile boolean healRequested;

    /**
     * 由看门狗在主线程调用：画面长时间没有新帧时，把整块 SurfaceTexture 换掉。
     *
     * 为什么必须换 SurfaceTexture 而不是 resize：
     * BufferQueue 一旦堵死（生产者还在写、消费者已不取），对同一个 SurfaceTexture
     * 反复 setDefaultBufferSize 或对 VirtualDisplay 反复 resize 都救不回来 ——
     * 实测 17:44:00 那次，forceRebuild 调了 resize 之后帧数仍然停在 13203。
     * 只有换一个新的 SurfaceTexture（即新的 BufferQueue），再让虚拟屏
     * VirtualDisplay.setSurface() 指过去，画面才会重新流动。
     */
    static void requestHeal() {
        QuadRenderer r = shared;
        if (r != null) {
            r.healRequested = true;
        }
    }

    /** 在 GL 线程换掉 SurfaceTexture / Surface，并把新表面交给捕获侧。 */
    private void healCaptureSurface() {
        if (released || textureId == 0) {
            return;
        }
        // 扩展屏模式用的是 ExtendHost 自建的 VirtualDisplay，走的是"整体重建"那条路
        // （ExtendHost.onSurface → release + 新建 + 重新拉起目标应用），代价很大。
        // 看门狗那条自愈只在 CaptureService 镜像/悬停模式下触发，这里再兜一道，
        // 避免以后有人放宽条件时把扩展屏反复重拉。
        if (Stage.extendMode) {
            Log.i(TAG, "扩展屏模式不走换表面自愈（由 ExtendHost 负责重建）");
            return;
        }
        Surface oldSurface = surface;
        SurfaceTexture oldSt = surfaceTexture;
        int w = CaptureService.capW > 0 ? CaptureService.capW : capW;
        int h = CaptureService.capH > 0 ? CaptureService.capH : capH;
        if (w <= 0 || h <= 0) {
            return;
        }
        // 先把旧表面从虚拟屏上摘下来，免得它继续往一个即将销毁的消费者里写
        CaptureService.detachSurface(oldSurface);
        if (oldSt != null) {
            try {
                oldSt.setOnFrameAvailableListener(null);
            } catch (Throwable ignored) {
            }
        }
        SurfaceTexture st = new SurfaceTexture(textureId);
        st.setDefaultBufferSize(w, h);
        st.setOnFrameAvailableListener(this, cbHandler);
        surfaceTexture = st;
        Surface s = new Surface(st);
        surface = s;
        handedSurface = s;
        newFrame = false;
        // ⚠️ 旧对象**不能**在这里立刻 release。
        // detachSurface 只是往主线程 post 了一个 setSurface(null)，此刻虚拟屏可能
        // 还在往旧 BufferQueue 里写；同步 release 掉会让生产者写进已销毁的队列，
        // 轻则丢帧，重则 native 崩溃。推迟到 800ms 后（detach + 重绑早已完成），
        // 并放到 cbHandler 上做，避免阻塞 GL 线程。
        final SurfaceTexture oldStFinal = oldSt;
        final Surface oldSurfaceFinal = oldSurface;
        if (oldStFinal != null || oldSurfaceFinal != null) {
            try {
                cbHandler.postDelayed(() -> {
                    if (oldStFinal != null) {
                        try {
                            oldStFinal.release();
                        } catch (Throwable ignored) {
                        }
                    }
                    if (oldSurfaceFinal != null) {
                        try {
                            oldSurfaceFinal.release();
                        } catch (Throwable ignored) {
                        }
                    }
                    Log.i(TAG, "旧捕获表面已释放");
                }, 800);
            } catch (Throwable t) {
                Log.w(TAG, "安排旧表面释放失败: " + t.getMessage());
            }
        }
        Stage.log("已换新捕获表面 " + w + "x" + h);
        Log.i(TAG, "healCaptureSurface 换新 SurfaceTexture " + w + "x" + h);
        CaptureService.setSurface(s, w, h);
    }

    @Override
    public void onDrawFrame(GL10 gl) {
        lastDrawAtMs = android.os.SystemClock.elapsedRealtime();
        if (released) {
            // 录像上下文属于本上下文所在的 share group，必须在这里拆（不能在任意线程调
            // eglDestroySurface / eglDestroyContext）
            RecorderGl rg = recorderGl;
            recorderGl = null;
            if (rg != null) {
                rg.stop();
            }
            // 会话已经结束，闸门必须落下来，否则 GlassEngine 那边会白等 1.5 秒
            recTornDown = true;
            deleteGlObjects();
            return;
        }
        // 引擎线程改了录像意图（开始 / 停止 / 尺寸变了）：在这里落实。
        // 必须先于下面的绘制，否则本帧的画还落在上一块 surface 上。
        if (recRequested) {
            recRequested = false;
            recTornDown = false;
            RecorderGl old = recorderGl;
            recorderGl = null;
            if (old != null) {
                old.stop();
            }
            GlassRecorder r = recorder;
            if (r != null && r.inputSurface() != null && mainEglDisplay != null
                    && mainEglContext != null) {
                RecorderGl ng = new RecorderGl(this, r.width(), r.height());
                String err = ng.start(r.inputSurface(), mainEglDisplay, mainEglContext);
                if (err == null) {
                    recorderGl = ng;
                    Log.i(TAG, "录像上下文就绪 " + r.width() + "x" + r.height());
                    Stage.log("录像已接上（独立共享上下文）");
                } else {
                    Log.w(TAG, "录像上下文创建失败: " + err);
                    Stage.log("录像启动失败：" + err);
                }
            } else if (r != null) {
                Log.w(TAG, "录像上下文无法创建：inputSurface=" + r.inputSurface()
                        + " mainDisplay=" + mainEglDisplay + " mainContext=" + mainEglContext);
                Stage.log("录像上下文无法创建（缺主 EGL 句柄或输入表面）");
            }
            // 拆完 / 建完都要在这里落闸：GlassEngine 停录像时会等它变 true 才去停编码器，
            // 避免 RecorderGl 工作线程还在往编码器 Surface 里写、codec 已经被 stop 掉。
            recTornDown = true;
        }
        if (healRequested) {
            healRequested = false;
            healCaptureSurface();
        }
        if (newFrame && surfaceTexture != null) {
            try {
                surfaceTexture.updateTexImage();
                surfaceTexture.getTransformMatrix(uvMat);
                hasContent = true;
                textureFrames++;
            } catch (Exception e) {
                Log.w(TAG, "updateTexImage: " + e.getMessage());
            }
            newFrame = false;
        }

        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);

        // 首帧可能还没跑 onSurfaceChanged，除零会得到 Inf 矩阵，先兜底
        int w = surfaceW > 0 ? surfaceW : capW;
        int h = surfaceH > 0 ? surfaceH : capH;
        if (w <= 0 || h <= 0) {
            return;
        }
        float aspect = w / (float) h;

        // 捕获尺寸会随手机横竖屏变化（CaptureService 会 resize 虚拟屏），
        // 这里跟随更新缓冲区尺寸与内容宽高比，横屏内容才能真的横过来。
        int cw = CaptureService.capW > 0 ? CaptureService.capW : capW;
        int ch = CaptureService.capH > 0 ? CaptureService.capH : capH;
        if ((cw <= 0 || ch <= 0) && Stage.appContext != null) {
            int[] s = CaptureSize.of(Stage.appContext);
            cw = s[0];
            ch = s[1];
        }
        if (cw > 0 && ch > 0 && (cw != lastCapW || ch != lastCapH)) {
            lastCapW = cw;
            lastCapH = ch;
            if (surfaceTexture != null) {
                surfaceTexture.setDefaultBufferSize(cw, ch);
            }
            contentAspect = cw / (float) ch;
        }
        contentAspectNow = contentAspect;

        // 兜底：有些 ROM 在应用退到后台后不再给我们 display 变更回调，
        // 这里每 30 帧自查一次捕获尺寸，发现横竖屏变了就主动让服务 resize。
        //
        // 注意 extendMode 也必须查：改造前这里写的是 `!Stage.extendMode && ...`，
        // 扩展屏模式下整段被跳过，手机转横屏后 capW/capH 不刷新、contentAspect
        // 一直停在竖屏值，表现就是"画面横过来了但缩小并挤在左下角"。
        if (++rotateCheckTick >= 30) {
            rotateCheckTick = 0;
            if (Stage.appContext != null && CaptureService.isRunning()) {
                int[] want = CaptureSize.of(Stage.appContext);
                if (want[0] != CaptureService.capW || want[1] != CaptureService.capH) {
                    CaptureService.refreshSize(Stage.appContext);
                }
            }
        }

        boolean ready = pose.getViewMatrix(view);
        float fovYDeg = Stage.fovYDeg;
        float d = Stage.distanceM;
        float fill = Stage.fill;
        Matrix.perspectiveM(proj, 0, fovYDeg, aspect, 0.1f, 100f);

        // 屏幕形状跟随内容方向，两个方向各自按"长边填满"来定尺寸，
        // 避免横屏时被压成一条：
        //   竖屏内容：高度填满，宽度按比例（超宽时再收敛）
        //   横屏内容：宽度填满，高度按比例（超高时再收敛）
        //
        // 关键修正：判断方向要用 **surface 的 aspect**（渲染目标实际形状），
        // 不能用 contentAspect。扩展屏模式下 CaptureSize.of() 返回的是眼镜屏
        // 尺寸（见 CaptureSize 第 33-38 行），contentAspect 恒为 16:9，
        // 手机转横屏时它根本不变化 —— 用它会永远走"横屏分支"，
        // 于是画面虽然横了却按错误的长边算尺寸，缩小并挤到左下角。
        // 内容 aspect 只用来算宽高比，不用来判方向。
        float tanV = (float) Math.tan(Math.toRadians(fovYDeg) / 2.0);
        float tanH = tanV * aspect;
        float fullH = 2f * d * tanV * 0.95f * fill;
        float fullW = 2f * d * tanH * 0.95f * fill;
        float sh, sw;
        boolean landscapeSurface = aspect > 1f;
        if (!landscapeSurface) {
            // 竖屏渲染目标：高度填满
            sh = fullH;
            sw = sh * contentAspect;
            if (sw > fullW) {
                sw = fullW;
                sh = sw / contentAspect;
            }
        } else {
            // 横屏渲染目标：宽度填满
            sw = fullW;
            sh = sw / contentAspect;
            if (sh > fullH) {
                sh = fullH;
                sw = sh * contentAspect;
            }
        }

        Matrix.setIdentityM(model, 0);
        Matrix.translateM(model, 0, 0f, 0f, d);
        Matrix.scaleM(model, 0, sw / 2f, sh / 2f, 1f);

        Matrix.multiplyMM(vp, 0, proj, 0, view, 0);
        Matrix.multiplyMM(mvp, 0, vp, 0, model, 0);

        if (program == 0) {
            return;
        }
        GLES20.glUseProgram(program);

        vertexBuf.position(0);
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, 20, vertexBuf);
        GLES20.glEnableVertexAttribArray(aPos);
        vertexBuf.position(3);
        GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 20, vertexBuf);
        GLES20.glEnableVertexAttribArray(aUv);

        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0);
        GLES20.glUniformMatrix4fv(uUvMat, 1, false, uvMat, 0);

        // 有画面就直接显示（哪怕姿态还没就绪），这样"灰屏"只代表一件事：捕获没进来
        boolean showTexture = hasContent;
        GLES20.glUniform1f(uSolid, showTexture ? 0f : 1f);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId);
        GLES20.glUniform1i(uTex, 0);

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);

        // 触控板光标：画在屏幕平面稍前一点，避免被面板挡住
        if (Stage.cursorVisible) {
            // 面板的 +X 在观察者看来是"左"（相机朝 +Z 看，场景 +X 落在屏幕左侧），
            // 所以光标的横向坐标要反过来算，否则手指向右移、小点向左跑。
            float cxp = (0.5f - Stage.cursorU) * sw;
            float cyp = (0.5f - Stage.cursorV) * sh;
            float r = sh * 0.014f;
            Matrix.setIdentityM(model, 0);
            Matrix.translateM(model, 0, cxp, cyp, d - 0.005f);
            Matrix.scaleM(model, 0, r, r, 1f);
            Matrix.multiplyMM(mvp, 0, vp, 0, model, 0);

            GLES20.glEnable(GLES20.GL_BLEND);
            GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA);
            GLES20.glUniform1f(uSolid, 2f);
            GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            GLES20.glDisable(GLES20.GL_BLEND);
            GLES20.glUniform1f(uSolid, showTexture ? 0f : 1f);
        }

        GLES20.glDisableVertexAttribArray(aPos);
        GLES20.glDisableVertexAttribArray(aUv);

        // 画完了才做截图 / 录像：此时默认 framebuffer 里就是这一帧的成品
        // （含 3DoF 位移、光标、透视缩放），与用户眼里看到的一致。
        if (shotRequested) {
            shotRequested = false;
            shotResult = captureCurrentFrame();
        }
        // 录像：**不在这里画**，只把这一帧的画面状态拷成快照、置一个标志。
        //
        // 为什么不在这里画：把同一个上下文 makeCurrent 到编码器 Surface 上再画一遍，
        // 会在 Android 14 + MediaCodec 输入 Surface 上把第一次 eglSwapBuffers 卡死，
        // 连带整个 GL 线程（=主画面）一起冻结。详见 RecorderGl 的类注释。
        // 现在真正的绘制在 RecorderGl 自己的线程、自己的共享上下文里做，
        // 这边只做两件不阻塞的事：拷矩阵、置标志。
        if (recorderGl != null) {
            System.arraycopy(mvp, 0, recMvp, 0, 16);
            System.arraycopy(uvMat, 0, recUvMat, 0, 16);
            recSolid = hasContent ? 0f : 1f;
            recorderGl.requestFrame();
        }
    }

    /** 把当前默认 framebuffer 读成 PNG 落盘；返回路径或 null。 */
    private String captureCurrentFrame() {
        int w = surfaceW > 0 ? surfaceW : capW;
        int h = surfaceH > 0 ? surfaceH : capH;
        if (w <= 0 || h <= 0 || Stage.appContext == null) {
            return null;
        }

        // ── 性能关键：整块搬运，不要逐像素
        //
        // 老实现是 `px.get(base + x)` + `bmp.setPixels(row,...)` 双重逐像素循环，
        // 1920×1080 就是 ~200 万次 JNI 边界穿越 —— 实测能吃掉几百毫秒，
        // 而引擎侧只等 400ms 轮询，于是"文件已写成、界面却报超时失败"。
        //
        // 现在改成：glReadPixels 直接读进 IntBuffer → copyPixelsFromBuffer
        // 一次性拷进 Bitmap（都在 native/受管内存之间批量拷贝），
        // 再用 Matrix 翻转而不是自己转行序。
        java.nio.IntBuffer px = java.nio.ByteBuffer
                .allocateDirect(w * h * 4)
                .order(java.nio.ByteOrder.nativeOrder())
                .asIntBuffer();
        try {
            GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA,
                    GLES20.GL_UNSIGNED_BYTE, px);
        } catch (Throwable t) {
            Log.w(TAG, "glReadPixels: " + t.getMessage());
            return null;
        }
        if (px.limit() < w * h) {
            Log.w(TAG, "glReadPixels 读回的数据不足: " + px.limit() + " < " + w * h);
            return null;
        }

        // GL 的 RGBA 顺序在 Android 上就是 Bitmap 的 ARGB_8888 内存布局
        // （每像素一个 int，字节序 R,G,B,A），可以直接 copyPixelsFromBuffer。
        Bitmap raw = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        px.rewind();
        raw.copyPixelsFromBuffer(px);

        // GL 原点在左下、Bitmap 在左上：竖向镜像一次即可。
        // 用 Matrix 让 GPU/Skia 干这活，比自己转行序快一个数量级。
        android.graphics.Matrix m = new android.graphics.Matrix();
        m.setScale(1f, -1f);
        Bitmap bmp = Bitmap.createBitmap(raw, 0, 0, w, h, m, false);
        if (bmp != raw) {
            raw.recycle();
        }

        String path = GlassCapture.saveShot(Stage.appContext, bmp, "shot");
        bmp.recycle();
        return path;
    }
    private boolean hasContent;

    /** 累计收到的投屏帧数（跨实例，供界面诊断"有没有帧"用）。 */
    public static volatile long textureFrames;

    /** 当前内容宽高比（>1 横屏，<1 竖屏），供界面显示。 */
    public static volatile float contentAspectNow = 1f;

    private int rotateCheckTick;

    /** 仅供诊断：GL 线程是否还在跑（每次 onDrawFrame 刷新）。 */
    public static volatile long lastDrawAtMs;

    @Override
    public void onFrameAvailable(SurfaceTexture st) {
        if (!released) {
            newFrame = true;
        }
    }

    // ------------------------------------------------------------ 着色器

    private static int buildProgram() {
        int vs = compile(GLES20.GL_VERTEX_SHADER, VS);
        int fs = compile(GLES20.GL_FRAGMENT_SHADER, FS);
        if (vs == 0 || fs == 0) {
            return 0;
        }
        int p = GLES20.glCreateProgram();
        GLES20.glAttachShader(p, vs);
        GLES20.glAttachShader(p, fs);
        GLES20.glLinkProgram(p);
        int[] ok = new int[1];
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.e(TAG, "link: " + GLES20.glGetProgramInfoLog(p));
            GLES20.glDeleteProgram(p);
            return 0;
        }
        return p;
    }

    private static int compile(int type, String src) {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, src);
        GLES20.glCompileShader(s);
        int[] ok = new int[1];
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) {
            Log.e(TAG, "compile: " + GLES20.glGetShaderInfoLog(s));
            GLES20.glDeleteShader(s);
            return 0;
        }
        return s;
    }
}
