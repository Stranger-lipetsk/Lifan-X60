package ru.lifanx60.storagegrouplab;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.util.Arrays;

/** Fixed synthetic path in a disposable emulator; no real USB access. */
public final class MainActivity extends Activity {
    private static final String TAG = "X60StorageGroupLab";
    private static final byte[] DATA = new byte[] {88, 54, 48, 45, 76, 65, 66, 10};
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu"))) {
            Log.e(TAG, "REFUSED_NON_EMULATOR");
            finish();
            return;
        }
        try {
            BufferedReader status = new BufferedReader(new FileReader("/proc/self/status"));
            String line;
            while ((line = status.readLine()) != null)
                if (line.startsWith("Groups:")) Log.i(TAG, line);
            status.close();
            Log.i(TAG, "UID=" + Process.myUid());
            File target = new File("/mnt/media_rw/sdcard/x60-synthetic-probe.txt");
            FileOutputStream out = new FileOutputStream(target);
            out.write(DATA);
            out.getFD().sync();
            out.close();
            FileInputStream in = new FileInputStream(target);
            byte[] read = new byte[DATA.length];
            int count = in.read(read);
            int extra = in.read();
            in.close();
            if (count != DATA.length || extra != -1 || !Arrays.equals(DATA, read))
                throw new IllegalStateException("Synthetic readback mismatch");
            Log.i(TAG, "SYNTHETIC_WRITE_READ_OK");
        } catch (Exception e) {
            Log.e(TAG, "SYNTHETIC_WRITE_READ_FAILED", e);
        }
        finish();
    }
}
