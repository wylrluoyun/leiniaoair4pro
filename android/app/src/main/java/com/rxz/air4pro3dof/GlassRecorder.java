package com.rxz.air4pro3dof;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.io.File;
import java.nio.ByteBuffer;

/**
 * 把眼镜端画面录成 MP4。
 *
 * 做法：MediaCodec 用 Surface 模式（COLOR_FormatSurface），拿它的 input Surface，
 * 由 QuadRenderer 在同一个 EGLContext 里多画一遍到这块 Surface 上。
 * 好处是**录到的就是眼镜里真正看到的东西**（含 3DoF 位移、光标），
 * 不是手机屏镜像，也不需要再申请一次 MediaProjection。
 *
 * 线程模型：
 *   - start()/stop() 由引擎主线程调用；
 *   - drain 循环跑在自己的 HandlerThread，只碰 codec/muxer，不碰 GL。
 */
public final class GlassRecorder {

    private static final String TAG = "GlassRecorder";
    private static final String MIME = MediaFormat.MIMETYPE_VIDEO_AVC;
    /** 目标帧率：眼镜端本来就是 60Hz 渲染，30fps 编码足够，还能压低码率。 */
    private static final int FPS = 30;
    private static final int IFRAME_SEC = 1;
    private static final long DEQUEUE_TIMEOUT_US = 10_000;

    private final int width;
    private final int height;
    private final File outFile;

    private MediaCodec codec;
    private MediaMuxer muxer;
    private Surface inputSurface;

    private HandlerThread thread;
    private Handler handler;

    private volatile boolean running;
    private int trackIndex = -1;
    private boolean muxerStarted;
    private long frameIndex;
    private long firstPtsUs = -1;
    /** 上一帧写进 muxer 的 pts（已归零），用来强制单调递增。 */
    private long lastPtsUs = -1;
    /** writeSampleData 失败次数，stop() 时一并报出来。 */
    private long writeFails;
    private String lastError;

    public GlassRecorder(int width, int height, File outFile) {
        // 编码器要求偶数尺寸，奇数会让 configure 直接抛 IllegalState
        this.width = width & ~1;
        this.height = height & ~1;
        this.outFile = outFile;
    }

    public Surface inputSurface() {
        return inputSurface;
    }

    public int width() {
        return width;
    }

    public int height() {
        return height;
    }

    public String filePath() {
        return outFile == null ? null : outFile.getAbsolutePath();
    }

    public boolean isRunning() {
        return running;
    }

    public String lastError() {
        return lastError;
    }

    /** 启动编码器；成功返回 null，失败返回原因。 */
    public String start() {
        if (running) {
            return "已在录制中";
        }
        if (outFile == null) {
            return "输出文件不可用";
        }
        try {
            MediaFormat fmt = MediaFormat.createVideoFormat(MIME, width, height);
            fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            // 8 Mbps 对 1080p30 的屏幕内容足够，再高对眼镜观感没帮助
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000);
            fmt.setInteger(MediaFormat.KEY_FRAME_RATE, FPS);
            fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, IFRAME_SEC);

            codec = MediaCodec.createEncoderByType(MIME);
            codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            inputSurface = codec.createInputSurface();
            codec.start();

            muxer = new MediaMuxer(outFile.getAbsolutePath(),
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            trackIndex = -1;
            muxerStarted = false;
            frameIndex = 0;
            firstPtsUs = -1;
            lastPtsUs = -1;
            writeFails = 0;
            running = true;

            thread = new HandlerThread("glass-rec");
            thread.start();
            handler = new Handler(thread.getLooper());
            handler.post(this::drainLoop);

            Log.i(TAG, "开始录制 " + width + "x" + height + " -> " + outFile.getAbsolutePath());
            return null;
        } catch (Throwable t) {
            lastError = String.valueOf(t.getMessage());
            Log.e(TAG, "启动录制失败", t);
            releaseQuietly();
            return "启动录制失败：" + t.getMessage();
        }
    }

    /** 停止并落盘；返回输出路径（失败时返回 null）。 */
    public String stop() {
        if (!running && codec == null) {
            return null;
        }
        // ⚠️ 顺序不能反：先 signalEndOfInputStream，再把 running 置 false。
        // 反过来的话 drain 线程下一次 dequeueOutputBuffer 超时（10ms 内）就会看到
        // running==false 直接 break，编码器永远收不到 EOS，
        // 于是 INFO_OUTPUT_FORMAT_CHANGED 都没发生 → muxerStarted 恒 false →
        // muxer 从未 start 就被 release → 留下 0 字节的 mp4。
        //
        // ⚠️⚠️ 更关键：**不能**通过 handler.post(this::signalEndOfStream) 来投递。
        // drainLoop 是 `handler.post(this::drainLoop)` 起的**一个永不返回的 Runnable**，
        // 它在 while(true) 里一直 dequeueOutputBuffer，从不把控制权交回 Looper。
        // 于是同一 Looper 上 post 的 signalEndOfStream 永远排不上队，只能等到
        // drainLoop break 之后才执行 —— 而那时 releaseQuietly() 已经调过 codec.stop()，
        // 于是必然打出一条：
        //   signalEndOfInputStream: signalEndOfInputStream() is valid only at
        //   Executing states; currently during stop()
        // 编码器从未收到过 EOS，尾帧全部丢失。
        // signalEndOfInputStream() 本身允许跨线程调用，这里直接同步调。
        signalEndOfStream();
        running = false;
        try {
            if (thread != null) {
                thread.join(2000);
            }
        } catch (Throwable t) {
            Log.w(TAG, "等待 drain 线程退出失败", t);
        }
        long frames = frameIndex;
        long attempted = QuadRenderer.recFramesAttempted;
        long swapFails = QuadRenderer.recSwapFails;
        long wf = writeFails;
        releaseQuietly();
        if (frames <= 0) {
            // 一帧都没写进去：这个 mp4 是坏的（0 字节），
            // 留着只会让人以为"录了但播不了"，直接删掉并报错。
            //
            // 把 GL 侧的计数一起报出来，直接定位断在哪一段：
            //   attempted=0            → drawIntoRecorder 根本没跑（守卫拦住 / surfaceReady 假）
            //   attempted>0, swapFails≈attempted → eglSwapBuffers 全失败（EGL 层提交不出去）
            //   attempted>0, swapFails=0         → 提交成功了但编码器不吐帧（编码器/Surface 问题）
            lastError = "没有录到任何帧（GL 侧已提交 " + attempted + " 帧，其中 swap 失败 "
                    + swapFails + " 次，writeSampleData 失败 " + wf + " 次）";
            try {
                if (outFile != null && outFile.exists()) {
                    //noinspection ResultOfMethodCallIgnored
                    outFile.delete();
                }
            } catch (Throwable ignored) {
            }
            Log.w(TAG, "录制失败：没有录到帧，已删除空文件（GL attempted=" + attempted
                    + " swapFails=" + swapFails + " writeFails=" + wf + "）");
            Stage.log("录制失败：没有录到帧（GL 已提交 " + attempted + " 帧，swap 失败 "
                    + swapFails + " 次，写入失败 " + wf + " 次）");
            return null;
        }
        if (wf > 0) {
            // 有帧写进去了但部分被 muxer 拒收：文件能动但可能卡顿/黑块。
            // 不删除，把情况说清楚让用户自己判断要不要重录。
            Stage.log("录制结束 " + frames + " 帧，其中 " + wf
                    + " 帧写入失败（视频可能不完整）");
        }
        Log.i(TAG, "录制结束 " + frames + " 帧 -> " + filePath());
        return filePath();
    }

    /** GL 线程用：编码器 Surface 是否可用。 */
    public boolean surfaceReady() {
        return running && inputSurface != null && inputSurface.isValid();
    }

    // ------------------------------------------------------------ 内部

    private void signalEndOfStream() {
        try {
            if (codec != null) {
                codec.signalEndOfInputStream();
            }
        } catch (Throwable t) {
            Log.w(TAG, "signalEndOfInputStream: " + t.getMessage());
        }
    }

    private void drainLoop() {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        // 收到 EOS 之后还允许再空转几次，把队列里剩下的帧抽干净
        int idleAfterEos = 0;
        // 停止请求之后连续空转的次数；编码器卡住时用它兜底退出，避免线程永不结束
        int idleAfterStop = 0;
        boolean sawFormat = false;
        while (true) {
            if (codec == null) {
                return;
            }
            int status;
            try {
                status = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US);
            } catch (Throwable t) {
                Log.w(TAG, "dequeueOutputBuffer: " + t.getMessage());
                return;
            }
            if (status == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!running) {
                    // 已经请求停止。**不能**立刻 break —— 编码器还没吐出 EOS，
                    // 提前退出会让 muxer 永远 start 不起来（旧 bug 就出在这）。
                    idleAfterStop++;
                    if (idleAfterStop > 200) {   // 约 2 秒
                        Log.w(TAG, "停止后 2 秒仍无 EOS，强制收尾"
                                + "（已写 " + frameIndex + " 帧, muxerStarted=" + muxerStarted + "）");
                        break;
                    }
                }
                continue;
            }
            idleAfterStop = 0;
            if (status == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                sawFormat = true;
                if (!muxerStarted && muxer != null) {
                    try {
                        trackIndex = muxer.addTrack(codec.getOutputFormat());
                        muxer.start();
                        muxerStarted = true;
                        Log.i(TAG, "muxer 已启动 track=" + trackIndex);
                    } catch (Throwable t) {
                        Log.e(TAG, "muxer 启动失败", t);
                    }
                }
                continue;
            }
            if (status < 0) {
                continue;
            }
            ByteBuffer buf = codec.getOutputBuffer(status);
            if (buf != null && info.size > 0) {
                if (!muxerStarted) {
                    // 有输出但 muxer 没起来：说明 INFO_OUTPUT_FORMAT_CHANGED 没来过。
                    // 这时候写不进去，必须记一笔，否则只剩一个 0 字节文件毫无线索。
                    if (frameIndex == 0) {
                        Log.w(TAG, "收到编码输出但 muxer 未启动，丢弃该帧"
                                + "（sawFormat=" + sawFormat + "）");
                    }
                } else if (trackIndex >= 0) {
                    buf.position(info.offset);
                    buf.limit(info.offset + info.size);
                    // ⚠️ PTS 归一化的两个坑，必须一起躲：
                    //
                    // 坑 1（旧 bug，直接导致 0 秒视频）：
                    //   原来写的是 `if (info.flags == 0 && firstPtsUs < 0)`，
                    //   想"跳过关键帧"再取基准。但编码器吐的第一帧**必然**是关键帧
                    //   （flags=1），于是第一帧没设基准、原始 pts 原样写进 muxer；
                    //   第二帧 flags=0 才把 firstPtsUs 设成第二帧的 pts，减完变 0。
                    //   结果第二帧 pts=0 < 第一帧 pts=33ms → MediaMuxer 抛
                    //   "The pts must be monotonically increasing"，此后每帧都失败，
                    //   样本表写不出来 → moov 里 stbl 是空的 → 播放器读到 0 秒。
                    //   现在改成：不看 flags，**第一帧无条件设基准**。
                    //
                    // 坑 2（兜底）：
                    //   即使基准正确，编码器偶尔也会吐重复 pts（同一帧被重发）。
                    //   muxer 对"相等"也不接受，所以再用 lastPtsUs 强行 +1。
                    if (firstPtsUs < 0) {
                        firstPtsUs = info.presentationTimeUs;
                    }
                    info.presentationTimeUs -= firstPtsUs;
                    if (info.presentationTimeUs <= lastPtsUs) {
                        info.presentationTimeUs = lastPtsUs + 1;
                    }
                    lastPtsUs = info.presentationTimeUs;
                    try {
                        muxer.writeSampleData(trackIndex, buf, info);
                        frameIndex++;
                    } catch (Throwable t) {
                        writeFails++;
                        if (writeFails == 1 || writeFails % 60 == 0) {
                            Log.w(TAG, "writeSampleData 失败 " + writeFails + " 次: "
                                    + t.getMessage() + "（pts=" + info.presentationTimeUs
                                    + " flags=" + info.flags + " size=" + info.size + "）");
                        }
                    }
                }
            }
            try {
                codec.releaseOutputBuffer(status, false);
            } catch (Throwable ignored) {
            }
            if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                // EOS：再空转几次把尾巴抽完，然后退出
                if (++idleAfterEos > 8) {
                    break;
                }
            }
        }
    }

    private void releaseQuietly() {
        running = false;
        try {
            if (codec != null) {
                codec.stop();
            }
        } catch (Throwable ignored) {
        }
        try {
            if (codec != null) {
                codec.release();
            }
        } catch (Throwable ignored) {
        }
        codec = null;
        try {
            if (muxerStarted && muxer != null) {
                muxer.stop();
            }
        } catch (Throwable ignored) {
        }
        try {
            if (muxer != null) {
                muxer.release();
            }
        } catch (Throwable ignored) {
        }
        muxer = null;
        muxerStarted = false;
        try {
            if (inputSurface != null) {
                inputSurface.release();
            }
        } catch (Throwable ignored) {
        }
        inputSurface = null;
        try {
            if (thread != null) {
                thread.quitSafely();
            }
        } catch (Throwable ignored) {
        }
        thread = null;
        handler = null;
    }
}
