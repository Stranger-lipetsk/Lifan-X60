package ru.lifanx60.backupcallerfixture;

import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import java.io.File;

/** Destructive restore fixture: disposable emulator and synthetic archive only. */
public final class RestoreActivity extends Activity {
    private static final String TAG = "X60RestoreCaller";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu"))) {
            Log.e(TAG, "REFUSED_NON_EMULATOR");
            finish();
            return;
        }
        if (checkCallingOrSelfPermission("android.permission.BACKUP") != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "BACKUP_PERMISSION_DENIED");
            finish();
            return;
        }
        new Thread(new Runnable() {
            @Override public void run() { performRestore(); }
        }).start();
    }

    private void performRestore() {
        ParcelFileDescriptor fd = null;
        try {
            File dir = getExternalFilesDir(null);
            if (dir == null) throw new IllegalStateException("No emulator external directory");
            fd = ParcelFileDescriptor.open(new File(dir, "synthetic.ab"), ParcelFileDescriptor.MODE_READ_ONLY);
            Class<?> manager = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) manager.getMethod("getService", String.class).invoke(null, "backup");
            Class<?> stub = Class.forName("android.app.backup.IBackupManager$Stub");
            Object service = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
            Class<?> iface = Class.forName("android.app.backup.IBackupManager");
            Log.i(TAG, "STARTING_SYNTHETIC_RESTORE");
            iface.getMethod("fullRestore", ParcelFileDescriptor.class).invoke(service, fd);
            Log.i(TAG, "RESTORE_CALL_RETURNED");
        } catch (Exception e) {
            Log.e(TAG, "RESTORE_CALL_FAILED", e);
        } finally {
            try { if (fd != null) fd.close(); } catch (Exception ignored) { }
        }
    }
}
