package com.rxz.air4pro3dof;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

/**
 * 截图 / 录像的落盘工具。
 *
 * 两条路都存：
 *   1. 应用专属外部目录（getExternalFilesDir）—— 任何版本都不需要权限，一定能成；
 *   2. 系统相册（MediaStore）—— Android 10+ 插入自己创建的多媒体项同样不需要权限，
 *      存这里是为了让用户能在相册里直接看到。
 *
 * 只有 Android 9 及以下往公共目录写才需要 WRITE_EXTERNAL_STORAGE，
 * 那条由 GlassEngine 在运行时申请（见 ensureLegacyStoragePermission）。
 */
public final class GlassCapture {

    private static final String TAG = "GlassCapture";
    private static final String ALBUM = "AIR4PRO3DOF";

    private GlassCapture() {
    }

    /** 应用专属目录：{外部存储}/Android/data/<pkg>/files/captures */
    public static File dir(Context ctx) {
        File d = ctx.getExternalFilesDir("captures");
        if (d == null) {
            d = new File(ctx.getFilesDir(), "captures");
        }
        if (!d.exists()) {
            //noinspection ResultOfMethodCallIgnored
            d.mkdirs();
        }
        return d;
    }

    /** 生成一个带时间戳的文件名，扩展名含点，例如 shot_20260109_142530.png。 */
    public static File newFile(Context ctx, String prefix, String ext) {
        String ts = new java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US)
                .format(new java.util.Date());
        return new File(dir(ctx), prefix + "_" + ts + "." + ext);
    }

    /**
     * 保存一张 PNG。
     *
     * @return 应用目录里的绝对路径；失败返回 null
     */
    public static String savePng(Context ctx, Bitmap bmp, String prefix) {
        if (bmp == null) {
            return null;
        }
        File f = newFile(ctx, prefix, "png");
        FileOutputStream fos = null;
        try {
            fos = new FileOutputStream(f);
            bmp.compress(Bitmap.CompressFormat.PNG, 100, fos);
            fos.flush();
        } catch (Throwable t) {
            Log.e(TAG, "写 PNG 失败", t);
            return null;
        } finally {
            closeQuietly(fos);
        }
        publishImage(ctx, f);
        Log.i(TAG, "截图已保存 " + f.getAbsolutePath() + " (" + f.length() + " B)");
        return f.getAbsolutePath();
    }

    /**
     * 保存截图为 JPEG（质量 95）。
     *
     * 为什么不沿用 {@link #savePng}：
     * 眼镜画是 1920×1080，PNG 无损压缩在这个尺寸上要几百毫秒；
     * 而 GlassEngine 只给 400ms 轮询窗口，于是出现
     * **"文件已经写成、界面却报截图超时"** —— 文件在相册里躺得好好的，
     * 用户却看到失败提示。这既是性能问题也是体验问题。
     *
     * JPEG q95 在同一张图上通常 30~60ms，肉眼几乎看不出差别，
     * 而且截图本来就是为了分享，不要求无损。真正需要无损时再走 savePng。
     */
    public static String saveShot(Context ctx, Bitmap bmp, String prefix) {
        if (bmp == null) {
            return null;
        }
        File f = newFile(ctx, prefix, "jpg");
        FileOutputStream fos = null;
        try {
            fos = new FileOutputStream(f);
            bmp.compress(Bitmap.CompressFormat.JPEG, 95, fos);
            fos.flush();
        } catch (Throwable t) {
            Log.e(TAG, "写 JPEG 失败", t);
            return null;
        } finally {
            closeQuietly(fos);
        }
        publishImage(ctx, f);
        Log.i(TAG, "截图已保存 " + f.getAbsolutePath() + " (" + f.length() + " B)");
        return f.getAbsolutePath();
    }

    /** 把已经写好的 mp4 登记进相册；失败不影响文件本身。 */
    public static void publishVideo(Context ctx, File f) {
        if (f == null || !f.exists()) {
            return;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // 9 及以下需要先申请存储权限，这里不主动弹窗，只留文件
            return;
        }
        Uri uri = null;
        try {
            ContentResolver cr = ctx.getContentResolver();
            ContentValues v = new ContentValues();
            v.put(MediaStore.Video.Media.DISPLAY_NAME, f.getName());
            v.put(MediaStore.Video.Media.MIME_TYPE, "video/mp4");
            v.put(MediaStore.Video.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_MOVIES + "/" + ALBUM);
            v.put(MediaStore.Video.Media.IS_PENDING, 1);
            uri = cr.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, v);
            if (uri == null) {
                return;
            }
            OutputStream os = cr.openOutputStream(uri);
            java.io.FileInputStream in = new java.io.FileInputStream(f);
            try {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) {
                    os.write(buf, 0, n);
                }
                os.flush();
            } finally {
                closeQuietly(in);
                closeQuietly(os);
            }
            v.clear();
            v.put(MediaStore.Video.Media.IS_PENDING, 0);
            cr.update(uri, v, null, null);
            Log.i(TAG, "录像已登记相册 " + uri);
        } catch (Throwable t) {
            Log.w(TAG, "登记相册失败（文件仍在应用目录）", t);
        }
    }

    private static void publishImage(Context ctx, File f) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return;
        }
        Uri uri = null;
        try {
            ContentResolver cr = ctx.getContentResolver();
            ContentValues v = new ContentValues();
            v.put(MediaStore.Images.Media.DISPLAY_NAME, f.getName());
            v.put(MediaStore.Images.Media.MIME_TYPE, "image/png");
            v.put(MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/" + ALBUM);
            v.put(MediaStore.Images.Media.IS_PENDING, 1);
            uri = cr.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v);
            if (uri == null) {
                return;
            }
            OutputStream os = cr.openOutputStream(uri);
            java.io.FileInputStream in = new java.io.FileInputStream(f);
            try {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) {
                    os.write(buf, 0, n);
                }
                os.flush();
            } finally {
                closeQuietly(in);
                closeQuietly(os);
            }
            v.clear();
            v.put(MediaStore.Images.Media.IS_PENDING, 0);
            cr.update(uri, v, null, null);
        } catch (Throwable t) {
            Log.w(TAG, "登记相册失败（文件仍在应用目录）", t);
        }
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (Throwable ignored) {
            }
        }
    }
}
