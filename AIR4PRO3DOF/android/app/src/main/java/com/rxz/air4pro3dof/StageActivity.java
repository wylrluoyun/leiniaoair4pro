package com.rxz.air4pro3dof;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.view.WindowManager;

/**
 * 眼镜那块屏上的画面载体。
 *
 * 它被 {@code ActivityOptions.setLaunchDisplayId} 直接投到外接屏上，
 * 因此拥有独立的窗口与任务栈：手机端界面切到后台（去开抖音、B 站）时，
 * 这里的画面依然保持可见，3DoF 悬停不会中断。
 */
public class StageActivity extends Activity {

    private static final String TAG = "StageActivity";
    private ScreenGlView glView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Stage.launched = true;
        android.view.Display disp = DisplayUtils.displayOfContext(this);
        if (disp == null || disp.getDisplayId() == android.view.Display.DEFAULT_DISPLAY) {
            // 没落到副屏（部分 ROM 忽略 setLaunchDisplayId）：主动退出，让手机端回退到 Presentation
            Log.w(TAG, "未落到眼镜屏，退出以触发回退");
            Stage.launched = false;
            finish();
            return;
        }
        Log.i(TAG, "onCreate on display " + disp);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setBackgroundDrawableResource(android.R.color.black);
        glView = new ScreenGlView(this, Stage.pose);
        setContentView(glView);
        Stage.attach(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        Log.i(TAG, "onResume 开始渲染");
        if (glView != null) {
            glView.onResume();
        }
    }

    @Override
    protected void onPause() {
        // 这行日志是关键：GLSurfaceView.onPause 会停掉渲染线程，
        // 渲染线程一停，扩展屏的生产者（目标应用）就会因为 buffer 队列满而卡住——
        // 表现正是"画面冻住、声音继续"。
        Log.w(TAG, "onPause 停止渲染");
        if (glView != null) {
            glView.onPause();
        }
        super.onPause();
    }

    @Override
    protected void onStop() {
        Log.w(TAG, "onStop");
        super.onStop();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        Log.i(TAG, "onWindowFocusChanged hasFocus=" + hasFocus);
    }

    /**
     * Manifest 里声明了 configChanges="orientation|screenSize|..."，
     * 所以旋转时系统**不会重建 Activity**，只回调这里。
     *
     * 以前没覆写这个方法，GLSurfaceView 就永远收不到新的窗口尺寸：
     * 眼镜屏上的窗口按新比例铺开，而 renderer 的 surfaceW/surfaceH 还停在旧值，
     * 于是画面按旧比例拉伸填满 → 用户看到的就是"横过来了但比例被拉长"。
     *
     * 这里主动把新尺寸推给 renderer：GLSurfaceView 自己不会因为我们改配置就重画，
     * 必须显式通知它重新取一次 buffer 尺寸。
     */
    @Override
    public void onConfigurationChanged(android.content.res.Configuration cfg) {
        super.onConfigurationChanged(cfg);
        if (glView == null) {
            return;
        }
        android.graphics.Point sz = new android.graphics.Point();
        if (glView.getDisplay() != null) {
            glView.getDisplay().getSize(sz);
        }
        Log.i(TAG, "onConfigurationChanged orientation=" + cfg.orientation
                + " 窗口=" + sz.x + "x" + sz.y);
        // requestLayout 会让 GLSurfaceView 重新测量；SurfaceHolder 尺寸随之变化，
        // 随后 GL 线程会收到 onSurfaceChanged，renderer 就能拿到正确的新尺寸。
        glView.requestLayout();
        glView.requestRender();
    }

    @Override
    protected void onDestroy() {
        Log.w(TAG, "onDestroy");
        Stage.detach(this);
        if (glView != null) {
            glView.renderer().release();
            glView = null;
        }
        super.onDestroy();
    }
}
