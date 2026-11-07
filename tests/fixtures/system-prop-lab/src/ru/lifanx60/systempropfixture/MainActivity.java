package ru.lifanx60.systempropfixture;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import java.lang.reflect.Method;

/** Emulator-only fixture, not intended for distribution or real devices. */
public final class MainActivity extends Activity {
    private static final String TAG = "X60SystemPropLab";
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            Class<?> props = Class.forName("android.os.SystemProperties");
            Method get = props.getMethod("get", String.class, String.class);
            Method set = props.getMethod("set", String.class, String.class);
            String qemu = (String) get.invoke(null, "ro.kernel.qemu", "");
            if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu")) || !qemu.equals("1")) {
                Log.e(TAG, "REFUSED_NON_EMULATOR");
                return;
            }
            String before = (String) get.invoke(null, "service.adb.tcp.port", "");
            try { set.invoke(null, "service.adb.tcp.port", "43127"); }
            catch (Exception error) { Log.i(TAG, "SET_EXCEPTION=" + error.getClass().getName()); }
            String after = (String) get.invoke(null, "service.adb.tcp.port", "");
            Log.i(TAG, "OWN_UID=" + Process.myUid() + " BEFORE=" + before + " AFTER=" + after);
            if (Process.myUid() == 1000 && after.equals("43127")) {
                set.invoke(null, "service.adb.root", "1");
                String root = (String) get.invoke(null, "service.adb.root", "");
                Log.i(TAG, "SYNTHETIC_ROOT_PROPERTY=" + root);
                if (root.equals("1")) {
                    Log.i(TAG, "RESTART_REQUESTED");
                    set.invoke(null, "ctl.restart", "adbd");
                }
            }
        } catch (Exception error) { Log.e(TAG, "FIXTURE_ERROR", error); }
        finally { finish(); }
    }
}
