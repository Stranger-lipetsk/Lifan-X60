package ru.lifanx60.backupcallerfixture;

import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import java.io.File;
import java.lang.reflect.Method;

/** Lab-only: synthetic data in a real Navitel APK on a disposable emulator only. */
public final class MainActivity extends Activity {
    private static final String TAG = "X60BackupCaller";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu"))) {
            Log.e(TAG, "REFUSED_NON_EMULATOR");
            finish();
            return;
        }
        boolean granted = checkCallingOrSelfPermission("android.permission.BACKUP") == PackageManager.PERMISSION_GRANTED;
        Log.i(TAG, "BACKUP_PERMISSION=" + granted);
        if (!granted) {
            finish();
            return;
        }
        new Thread(new Runnable() {
            @Override public void run() { performBackup(); }
        }).start();
    }

    private void performBackup() {
        ParcelFileDescriptor fd = null;
        try {
            File directory = new File("/data/local/tmp/x60-vfat-model/sdcard");
            if (directory == null) throw new IllegalStateException("No emulator external directory");
            File file = new File(directory, "synthetic.ab");
            fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_CREATE |
                    ParcelFileDescriptor.MODE_TRUNCATE | ParcelFileDescriptor.MODE_WRITE_ONLY);
            Class<?> manager = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) manager.getMethod("getService", String.class).invoke(null, "backup");
            Class<?> stub = Class.forName("android.app.backup.IBackupManager$Stub");
            Object service = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
            Class<?> iface = Class.forName("android.app.backup.IBackupManager");
            Method fullBackup = iface.getMethod("fullBackup", ParcelFileDescriptor.class,
                    boolean.class, boolean.class, boolean.class, boolean.class, boolean.class, String[].class);
            Log.i(TAG, "STARTING_SYNTHETIC_BACKUP");
            fullBackup.invoke(service, fd, false, false, false, false, false,
                    new String[] {"com.navitel"});
            Log.i(TAG, "BACKUP_CALL_RETURNED");
        } catch (Exception e) {
            Log.e(TAG, "BACKUP_CALL_FAILED", e);
        } finally {
            try { if (fd != null) fd.close(); } catch (Exception ignored) { }
        }
    }
}
