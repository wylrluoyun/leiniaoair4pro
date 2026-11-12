package com.rxz.air4pro3dof;

import android.content.Context;
import android.opengl.GLSurfaceView;
import android.util.AttributeSet;
import android.util.Log;
import android.view.SurfaceHolder;

/** 眼镜那块屏上的 GL 视图：由 Presentation 或 StageActivity 承载。 */
public class ScreenGlView extends GLSurfaceView {

    private static final String TAG = "ScreenGlView";

    private final QuadRenderer renderer;

    public ScreenGlView(Context ctx, HeadPose pose) {
        super(ctx);
        renderer = init(pose);
    }

    // 只在代码里构建；2 参构造器是为满足 lint ViewConstructor / 布局编辑器
    public ScreenGlView(Context ctx, AttributeSet attrs) {
        super(ctx, attrs);
        renderer = init(new HeadPose());
    }

    private QuadRenderer init(HeadPose pose) {
        setEGLContextClientVersion(2);
        int[] cap = CaptureSize.of(getContext());
        QuadRenderer r = new QuadRenderer(pose, cap[0], cap[1]);
        setRenderer(r);
        setRenderMode(RENDERMODE_CONTINUOUSLY);
        setPreserveEGLContextOnPause(true);
        liveRenderer = r;
        return r;
    }

    public QuadRenderer renderer() {
        return renderer;
    }

    /**
     * 最近一次成功创建、并且还没 release 的 ScreenGlView 的渲染器。
     *
     * 为什么需要它：截图 / 录像都发生在 GL 线程，而画面可能承载在 StageActivity
     * （眼镜那块屏自己的任务栈）里，此时 GlassEngine 的 glView 字段是 null。
     * StageActivity 创建视图时把渲染器登记到静态引用，引擎就能跨任务拿到它。
     */
    private static volatile QuadRenderer liveRenderer;

    public static QuadRenderer live() {
        return liveRenderer;
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        Log.i(TAG, "surfaceCreated");
        super.surfaceCreated(holder);
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        // 表面没了 GL 就画不出来，扩展屏的生产者也会随之卡住——这条日志是分水岭
        Log.w(TAG, "surfaceDestroyed（GL 表面没了，画面会停）");
        super.surfaceDestroyed(holder);
    }
}
