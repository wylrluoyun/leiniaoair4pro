package com.rxz.air4pro3dof;

import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import javax.microedition.khronos.egl.EGL10;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.egl.EGLContext;
import javax.microedition.khronos.egl.EGLDisplay;
import javax.microedition.khronos.egl.EGLSurface;

/**
 * 把眼镜画面画进 MediaCodec 的输入 Surface —— **在独立线程、独立 EGLContext 里做**。
 *
 * <h3>为什么要独立线程 + 独立上下文（两次真机事故换来的）</h3>
 * 旧实现是在 GLSurfaceView 自己的 GL 线程里，把同一个上下文 makeCurrent 到编码器
 * Surface 上再画一遍。这条路在 RayNeo Air 4 Pro（Android 14）上必然出问题：
 * <pre>
 * 17:39:46.603 开始录制 1920x1080
 * 17:39:46.616 录像 EGLSurface 就绪 1920x1080     ← surface 建出来了，makeCurrent 也成功
 * 17:39:49.607 心跳 帧=3265 画面静默=3s（GL 最近绘制 3018ms 前）
 * 17:39:54.608 心跳 帧=3265 画面静默=8s（GL 最近绘制 8019ms 前）
 * </pre>
 * 注意 <b>GL 最近绘制</b>也停了 —— 不是"画了没提交"，是整个 onDrawFrame 被卡住。
 * 卡在第一次 <code>eglSwapBuffers(recEglDisplay, recEglSurface)</code> 上，永久阻塞。
 *
 * <h3>根因：EGLConfig 缺 EGL_RECORDABLE_ANDROID</h3>
 * 给 MediaCodec 的输入 Surface 建 window surface 时，EGLConfig 必须带
 * <code>EGL_RECORDABLE_ANDROID (0x3142) = 1</code>。这是 Android 的硬性要求：
 * 缺了它，surface 能创建成功、<code>eglMakeCurrent</code> 也返回 true，
 * 但第一次 <code>dequeueBuffer</code> 永远等不到 buffer —— 表现就是 swap 永久阻塞。
 * <p>
 * 而"必须和主 context 同一个 config"和"config 必须带 RECORDABLE"是**互相冲突**的：
 * 主 context 的 config 是窗口用的，通常不带 RECORDABLE。这就是为什么
 * <ul>
 *   <li>v6 用 currentConfig() 自己挑 → 没带 RECORDABLE → 冻</li>
 *   <li>v8 改用 mainEglConfig 保证 config 一致 → 还是没带 RECORDABLE → 还是冻</li>
 * </ul>
 * 两条路都堵死。破局办法只有一个：**不要和主 context 共用上下文**，
 * 而是用 <code>eglCreateContext</code> 建一个**共享（share group）但独立**的上下文，
 * 这样 config 可以自由选带 RECORDABLE 的，GL 对象（program / 纹理 / VBO）
 * 因为在同一个 share group 里，照样能直接用。
 *
 * <h3>线程隔离带来的第二个好处</h3>
 * 录像的 EGL 调用从此和主画面完全解耦：即使某台设备上 swap 还是卡住，
 * 卡的是本类自己的工作线程，<b>主画面照常渲染</b>，只是录像拿不到帧。
 * 旧实现一卡就是"画面冻结"，这是最糟的失败模式。
 *
 * <h3>线程模型</h3>
 * <ul>
 *   <li>GL 线程每帧调用 {@link #requestFrame()} —— 只置一个 volatile 标志，绝不阻塞；</li>
 *   <li>本类的工作线程按 {@link #FPS} 自走节拍，取最新一份画面状态画一帧并 swap；</li>
 *   <li>stop() 由引擎线程调用，销毁 surface / context 后线程退出。</li>
 * </ul>
 */
final class RecorderGl {

    private static final String TAG = "RecorderGl";

    /** EGL_RECORDABLE_ANDROID：给 MediaCodec 输入 Surface 用的 config 必须带它。 */
    private static final int EGL_RECORDABLE_ANDROID = 0x3142;
    /** EGL_OPENGL_ES2_BIT */
    private static final int EGL_OPENGL_ES2_BIT = 4;
    /** EGL_WINDOW_BIT */
    private static final int EGL_WINDOW_BIT = 0x0400;
    /**
     * EGL_CONTEXT_CLIENT_VERSION (0x3098)。
     *
     * 为什么不用 EGL10.EGL_CONTEXT_CLIENT_VERSION：javax.microedition.khronos.egl.EGL10
     * 这个老接口根本没导出这个常量（只有 android.opengl.EGL14 里有），引用它编译不过。
     */
    private static final int EGL_CONTEXT_CLIENT_VERSION = 0x3098;

    private static final int FPS = 30;
    private static final long TICK_MS = 1000L / FPS;

    /** 画面状态由 GL 线程写、本类线程读，全部走 volatile 快照。 */
    private final QuadRenderer owner;
    private final int width;
    private final int height;

    private EGLDisplay display;
    private EGLConfig config;
    private EGLContext context;
    private EGLSurface surface;

    private HandlerThread thread;
    private Handler handler;

    private volatile boolean running;
    /** GL 线程置位：有新的画面状态可录。 */
    private volatile boolean frameWanted;

    /** 提交成功的帧数（诊断）。 */
    private volatile long submitted;
    /** 真正画了几帧（不管提交成功与否，诊断用）。 */
    private long attempted;
    /** eglSwapBuffers 返回 false 的次数（诊断）。 */
    private volatile long swapFails;
    /** eglMakeCurrent 失败的次数（诊断）。 */
    private volatile long makeCurrentFails;
    private boolean gaveUp;
    /** 「主画面 GL 对象已重建」这条日志只打一次，避免每帧刷屏。 */
    private boolean staleLogged;

    RecorderGl(QuadRenderer owner, int width, int height) {
        this.owner = owner;
        this.width = width;
        this.height = height;
    }

    long submitted() {
        return submitted;
    }

    long swapFails() {
        return swapFails;
    }

    /**
     * 建共享上下文并挂上编码器 Surface；成功返回 null，失败返回原因。
     *
     * @param codecSurface  MediaCodec.createInputSurface() 拿到的那块 Surface
     * @param mainDisplay   主 GL 线程当前的 EGLDisplay（已初始化，可直接复用）
     * @param mainContext   主 GL 线程当前的 EGLContext，作为 share_context
     */
    String start(Surface codecSurface, EGLDisplay mainDisplay, EGLContext mainContext) {
        if (codecSurface == null) {
            return "编码器 Surface 为空";
        }
        if (mainDisplay == null || mainContext == null) {
            return "拿不到主 EGL 上下文（不能共享 GL 对象）";
        }
        EGL10 egl = (EGL10) EGLContext.getEGL();
        if (egl == null) {
            return "EGL 不可用";
        }
        display = mainDisplay;
        try {
            // 关键：自己挑一个带 EGL_RECORDABLE_ANDROID 的 config。
            // 因为本类是独立上下文（只是共享 share group），不受"必须和主 context 同 config"的约束。
            int[] cfgAttrs = {
                    EGL10.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                    EGL10.EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                    EGL10.EGL_RED_SIZE, 8,
                    EGL10.EGL_GREEN_SIZE, 8,
                    EGL10.EGL_BLUE_SIZE, 8,
                    EGL10.EGL_ALPHA_SIZE, 8,
                    EGL_RECORDABLE_ANDROID, 1,
                    EGL10.EGL_NONE
            };
            EGLConfig[] cfgs = new EGLConfig[1];
            int[] num = new int[1];
            if (!egl.eglChooseConfig(display, cfgAttrs, cfgs, 1, num) || num[0] <= 0) {
                // 少数驱动不认 RECORDABLE 这个属性，退回不带它的选择 —— 至少先把上下文建起来，
                // 卡不卡由后面的 swap 计数说话，不要在这里就放弃。
                int[] fallback = {
                        EGL10.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                        EGL10.EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                        EGL10.EGL_RED_SIZE, 8,
                        EGL10.EGL_GREEN_SIZE, 8,
                        EGL10.EGL_BLUE_SIZE, 8,
                        EGL10.EGL_NONE
                };
                if (!egl.eglChooseConfig(display, fallback, cfgs, 1, num) || num[0] <= 0) {
                    return "找不到可用的 EGLConfig";
                }
                Log.w(TAG, "该驱动不支持 EGL_RECORDABLE_ANDROID，已退回普通 config（swap 可能阻塞）");
            }
            config = cfgs[0];

            // 0x3098 = EGL_CONTEXT_CLIENT_VERSION。javax.microedition.khronos.egl.EGL10
            // 这个老接口上**没有**导出该常量（只有 android.opengl.EGL14 里有），
            // 所以这里直接用字面值，并在常量区给了同名常量。
            int[] ctxAttrs = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL10.EGL_NONE};
            context = egl.eglCreateContext(display, config, mainContext, ctxAttrs);
            if (context == null || context == EGL10.EGL_NO_CONTEXT) {
                int err = egl.eglGetError();
                return "eglCreateContext 失败 0x" + Integer.toHexString(err);
            }

            surface = egl.eglCreateWindowSurface(display, config, codecSurface,
                    new int[]{EGL10.EGL_NONE});
            if (surface == null || surface == EGL10.EGL_NO_SURFACE) {
                int err = egl.eglGetError();
                destroyQuietly();
                return "eglCreateWindowSurface 失败 0x" + Integer.toHexString(err);
            }
            // ⚠️ 这里**绝对不能**试 eglMakeCurrent。
            //
            // start() 是被 GL 线程（onDrawFrame）调用的。一旦在这里 makeCurrent 到本类的
            // surface，主 context 就从 GL 线程上被摘掉了；随后的
            // eglMakeCurrent(display, NO_SURFACE, NO_SURFACE, NO_CONTEXT) 更是把 GL 线程
            // 变成"没有当前上下文"的状态 —— 那一帧剩下的 glClear / glUseProgram 全部无效，
            // 画面直接黑掉，而且之后 GLSurfaceView 自己的 swap 也没有上下文可交换。
            //
            // 绑定成败交给工作线程的第一次 drawOnce() 去验：那里有失败计数与放弃逻辑，
            // 而且绑不上只影响录像，不影响主画面。

            running = true;
            thread = new HandlerThread("glass-rec-gl");
            thread.start();
            handler = new Handler(thread.getLooper());
            handler.post(tick);
            Log.i(TAG, "录像上下文就绪 " + width + "x" + height + "（独立线程 + 共享上下文）");
            return null;
        } catch (Throwable t) {
            destroyQuietly();
            return "建录像上下文异常：" + t.getMessage();
        }
    }

    /** GL 线程调用：只置标志，绝不阻塞。 */
    void requestFrame() {
        if (running && !gaveUp) {
            frameWanted = true;
        }
    }

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (!running || gaveUp) {
                // gaveUp 之后 requestFrame() 已经不再置 frameWanted，继续每 33ms 空转
                // 只是白耗 CPU 与唤醒次数，直接停掉这条定时链。
                return;
            }
            if (frameWanted) {
                frameWanted = false;
                drawOnce();
            }
            // ⚠️ handler 必须取局部快照再判空。
            // stop() 会把 handler 字段置 null，而它可能正跑在另一个线程上；这里若直接
            // 读字段 handler.postDelayed(...) 就会 NPE，把录像线程整个打崩（且没有
            // try/catch 兜着），日志里只会看到一条无头异常。
            Handler h = handler;
            if (running && !gaveUp && h != null) {
                h.postDelayed(this, TICK_MS);
            }
        }
    };

    private void drawOnce() {
        EGL10 egl = (EGL10) EGLContext.getEGL();
        if (egl == null || surface == null || context == null) {
            return;
        }
        try {
            if (!egl.eglMakeCurrent(display, surface, surface, context)) {
                makeCurrentFails++;
                if (makeCurrentFails == 1 || makeCurrentFails % 60 == 0) {
                    Log.w(TAG, "录像 eglMakeCurrent 失败 累计 " + makeCurrentFails + " 次");
                }
                if (makeCurrentFails >= 60) {
                    gaveUp = true;
                    Stage.log("录像上下文反复绑定失败，已放弃");
                }
                return;
            }
            // 主画面若在 onSurfaceCreated 里重建过 program / textureId（例如 GL 上下文
            // 被系统回收后恢复），本类持有的还是旧句柄 —— 那是已删除的对象，画出来是黑帧，
            // 严重时驱动报 GL_INVALID_OPERATION。每帧校验一次成本可忽略，能自愈。
            if (owner.program == 0 || owner.textureId == 0) {
                if (!staleLogged) {
                    staleLogged = true;
                    Log.w(TAG, "主画面的 program/texture 已失效（program="
                            + owner.program + " textureId=" + owner.textureId + "），暂停录像绘制");
                    Stage.log("录像暂停：主画面 GL 对象已重建");
                }
                return;
            }
            GLES20.glViewport(0, 0, width, height);
            GLES20.glClearColor(0f, 0f, 0f, 1f);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);

            // program / 纹理 / VBO 都在同一个 share group 里，直接复用主上下文的对象。
            // 但**顶点缓冲要读录像专用那份**（owner.recVertexBuf）：FloatBuffer 的 position
            // 是缓冲区自身状态，两线程同时挪 position 会让顶点错位。见字段注释。
            GLES20.glUseProgram(owner.program);
            owner.recVertexBuf.position(0);
            GLES20.glVertexAttribPointer(owner.aPos, 3, GLES20.GL_FLOAT, false, 20,
                    owner.recVertexBuf);
            GLES20.glEnableVertexAttribArray(owner.aPos);
            owner.recVertexBuf.position(3);
            GLES20.glVertexAttribPointer(owner.aUv, 2, GLES20.GL_FLOAT, false, 20,
                    owner.recVertexBuf);
            GLES20.glEnableVertexAttribArray(owner.aUv);
            GLES20.glUniformMatrix4fv(owner.uMvp, 1, false, owner.recMvp, 0);
            GLES20.glUniformMatrix4fv(owner.uUvMat, 1, false, owner.recUvMat, 0);
            GLES20.glUniform1f(owner.uSolid, owner.recSolid);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, owner.textureId);
            GLES20.glUniform1i(owner.uTex, 0);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            GLES20.glDisableVertexAttribArray(owner.aPos);
            GLES20.glDisableVertexAttribArray(owner.aUv);

            // 诊断计数同步到 QuadRenderer 的静态字段：GlassRecorder.stop() 在"0 帧"时
            // 会打印「GL 已提交 N 帧，swap 失败 M 次」，那两个数就取自这里。
            // attempted 记的是"画了几帧"，成功与否分开统计，这样 0 帧时能分清是
            // "根本没画"（attempted=0）还是"画了但提交不出去"（attempted>0, swapFails 同量）。
            QuadRenderer.recFramesAttempted = ++attempted;
            if (egl.eglSwapBuffers(display, surface)) {
                submitted++;
            } else {
                swapFails++;
                QuadRenderer.recSwapFails = swapFails;
                if (swapFails == 1 || swapFails % 60 == 0) {
                    Log.w(TAG, "录像 eglSwapBuffers 返回 false 累计 " + swapFails + " 次");
                }
            }
        } catch (Throwable t) {
            Log.w(TAG, "录像绘制异常: " + t.getMessage());
        }
    }

    /**
     * 停线程并销毁 surface / context；可重复调用。
     *
     * synchronized：release()（引擎线程）和 onDrawFrame（GL 线程）可能同时调到这里
     * —— 前者看到 released 后直接拆，后者也走 released 分支拆。没有互斥就会出现
     * 两边同时进 destroyQuietly，对同一对 EGLSurface/EGLContext 双重 destroy，
     * 驱动侧直接报错甚至崩。加锁后第二次进来时字段已是 null，自然变成空操作。
     */
    synchronized void stop() {
        running = false;
        Handler h = handler;
        HandlerThread t = thread;
        handler = null;
        thread = null;
        if (h != null) {
            try {
                h.removeCallbacksAndMessages(null);
            } catch (Throwable ignored) {
            }
        }
        boolean joined = true;
        if (t != null) {
            try {
                t.quitSafely();
                t.join(1200);
                joined = !t.isAlive();
            } catch (Throwable ignored) {
                joined = false;
            }
        }
        if (!joined) {
            // 线程没能在 1.2 秒内退出 —— 最可能是它正卡在 eglSwapBuffers 里（dequeueBuffer
            // 等不到 buffer，正是本类要防的那种驱动问题）。
            //
            // 这时**绝对不能** destroy surface / context：那个线程还在里面用它们，
            // 销毁就是让它往已释放的 native 对象上写，轻则 SIGSEGV 重则整机花屏。
            // 宁可泄漏这一份 surface + context（进程退出时由驱动回收），也不能崩。
            Log.w(TAG, "录像线程 1.2 秒未退出（可能卡在 eglSwapBuffers），放弃销毁以免崩溃");
            Stage.log("录像线程卡住，已放弃该次录像（主画面不受影响）");
            return;
        }
        // 线程已经退出，此刻没有任何线程 current 在本上下文上，
        // 所以在调用线程销毁是安全的。
        destroyQuietly();
    }

    /**
     * 销毁本类的 surface / context。**不解绑 current**。
     *
     * 为什么不在这里 eglMakeCurrent(NO_SURFACE, NO_SURFACE, NO_CONTEXT)：
     * stop() 有两个调用点，其中一个是 GL 线程（onDrawFrame 里换 / 拆录像上下文）。
     * eglMakeCurrent 是**线程级**状态，解绑会把 GL 线程上正在用的主 context 一起摘掉，
     * 那一帧剩下的 glClear / glUseProgram 全部无效，画面直接黑，之后 GLSurfaceView
     * 自己的 swap 也没有上下文可交换。真正的解绑只应该发生在录像工作线程自己身上。
     *
     * 走到这里时工作线程已经 join 过（或从没起来），本类的 context 不在任何线程上 current，
     * 直接 destroy 是安全的。
     */
    private void destroyQuietly() {
        EGL10 egl = (EGL10) EGLContext.getEGL();
        try {
            if (egl != null && display != null) {
                if (surface != null && surface != EGL10.EGL_NO_SURFACE) {
                    egl.eglDestroySurface(display, surface);
                }
                if (context != null && context != EGL10.EGL_NO_CONTEXT) {
                    egl.eglDestroyContext(display, context);
                }
            }
        } catch (Throwable ignored) {
        }
        surface = null;
        context = null;
        config = null;
    }
}
