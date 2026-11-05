package ru.lifanx60.homelab;

import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.res.AssetManager;
import android.content.res.Resources;
import android.os.Bundle;
import android.util.Log;
import dalvik.system.DexClassLoader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/** Isolated method harness. Does not invoke Home.onCreate or any OEM hardware service. */
public final class MainActivity extends Activity {
    private static final String TAG = "HomeDalvikLab";
    private static final String[] PACKAGES = {"com.amaze.filemanager", "ru.lifanx60.panel"};

    private File copyAsset(String name) throws Exception {
        File file = new File(getFilesDir(), name);
        try (InputStream input = getAssets().open(name); FileOutputStream output = new FileOutputStream(file)) {
            byte[] buf = new byte[16384];
            int n;
            while ((n = input.read(buf)) != -1) output.write(buf, 0, n);
        }
        return file;
    }

    private static Method method(Class<?> c, String name, Class<?>... args) throws Exception {
        Method m = c.getDeclaredMethod(name, args);
        m.setAccessible(true);
        return m;
    }

    private static Field field(Class<?> c, String name) throws Exception {
        Field f = c.getDeclaredField(name);
        f.setAccessible(true);
        return f;
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        boolean patched = getIntent().getBooleanExtra("patched", false);
        try {
            runCase(patched);
            Log.i(TAG, "RESULT " + (patched ? "PATCHED" : "ORIGINAL") + " PASS");
        } catch (Throwable e) {
            Log.e(TAG, "RESULT " + (patched ? "PATCHED" : "ORIGINAL") + " FAIL", e);
        } finally {
            finish();
        }
    }

    private void runCase(boolean patched) throws Exception {
        File home = copyAsset(patched ? "home-patched.apk" : "home-original.apk");
        File fw2 = copyAsset("framework2.jar");
        File fw = copyAsset("framework.jar");
        DexClassLoader loader = new DexClassLoader(home.getAbsolutePath() + ":" + fw2.getAbsolutePath() + ":" + fw.getAbsolutePath(),
            getDir(patched ? "dex-patched" : "dex-original", 0).getAbsolutePath(), null, getClassLoader());
        AssetManager manager = AssetManager.class.newInstance();
        int cookie = (Integer) method(AssetManager.class, "addAssetPath", String.class).invoke(manager, home.getAbsolutePath());
        require(cookie != 0, "failed to add Home resources");
        final Resources resources = new Resources(manager, getResources().getDisplayMetrics(), getResources().getConfiguration());
        Context wrapper = new ContextWrapper(this) {
            @Override public Resources getResources() { return resources; }
            @Override public AssetManager getAssets() { return resources.getAssets(); }
        };
        Method attach = method(ContextWrapper.class, "attachBaseContext", Context.class);
        Class<?> appClass = loader.loadClass("tw.com.elead.el830.home.HomeApp");
        Object app = appClass.newInstance();
        attach.invoke(app, wrapper);
        method(appClass, "initDefault_EL830CLF01").invoke(app);
        List<?> names = (List<?>) appClass.getMethod("getEleadApps").invoke(app);
        for (String pkg : PACKAGES) require(names.contains(pkg) == patched, "unexpected default list membership: " + pkg);
        method(appClass, "loadEleadApplications").invoke(app);
        Method getInfo = appClass.getMethod("getEleadApplication", String.class);
        if (patched) {
            for (String pkg : PACKAGES) {
                Object info = getInfo.invoke(app, pkg);
                require(info != null, "missing ApplicationInfo: " + pkg);
                Class<?> type = info.getClass();
                require((Boolean) field(type, "bMenuItem").get(info), "not a menu item: " + pkg);
                require((Boolean) field(type, "enable").get(info), "disabled: " + pkg);
                require("tw.com.elead.el830.home".equals(field(type, "menu").get(info)), "incorrect menu: " + pkg);
                Intent intent = (Intent) field(type, "intent").get(info);
                require(intent != null && intent.getComponent() != null && pkg.equals(intent.getComponent().getPackageName()), "wrong target intent: " + pkg);
                require(field(type, "title").get(info) != null, "missing title: " + pkg);
                Log.i(TAG, "ApplicationInfo " + pkg + " -> " + intent.getComponent().flattenToShortString());
            }
        }
        Class<?> homeClass = loader.loadClass("tw.com.elead.el830.home.Home");
        Object activity = homeClass.newInstance();
        attach.invoke(activity, wrapper);
        field(homeClass, "homeApp").set(activity, app);
        field(homeClass, "mApplications").set(null, null);
        method(homeClass, "loadApplications", boolean.class).invoke(activity, false);
        List<?> items = (List<?>) field(homeClass, "mApplications").get(null);
        require(items != null, "Home list is null");
        ArrayList<String> displayed = new ArrayList<>();
        for (Object item : items) {
            Object pkg = field(item.getClass(), "Package").get(item);
            if (pkg instanceof String) displayed.add((String) pkg);
        }
        for (String pkg : PACKAGES) require(displayed.contains(pkg) == patched, "unexpected UI membership: " + pkg);
        Log.i(TAG, "UI entries " + displayed);
        String target = getIntent().getStringExtra("open");
        if (target != null) {
            require(patched, "launch test requires patched Home");
            require(target.equals(PACKAGES[0]) || target.equals(PACKAGES[1]), "unexpected target");
            boolean ok = (Boolean) appClass.getMethod("gotoEleadApplication", String.class).invoke(app, target);
            require(ok, "gotoEleadApplication returned false for " + target);
            Log.i(TAG, "LAUNCHED " + target + " PASS");
        }
    }
}
