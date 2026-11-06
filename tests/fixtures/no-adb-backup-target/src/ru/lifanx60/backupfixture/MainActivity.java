package ru.lifanx60.backupfixture;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import java.io.FileOutputStream;

/** Synthetic data only. This fixture is never packaged as a user deliverable. */
public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu"))) {
            Log.e("X60SyntheticTarget", "Refusing non-generic emulator");
            finish();
            return;
        }
        try {
            FileOutputStream out = openFileOutput("lab-marker.txt", MODE_PRIVATE);
            out.write("X60_BACKUP_ONLY_FIXTURE\n".getBytes("UTF-8"));
            out.close();
            if (!getSharedPreferences("lab_probe", 0).edit().putString("lab_probe", "X60_ONLY_SYNTHETIC_PREF").commit()) {
                throw new IllegalStateException("SharedPreferences write failed");
            }
            Log.i("X60SyntheticTarget", "FIXTURE_READY");
        } catch (Exception e) {
            Log.e("X60SyntheticTarget", "FIXTURE_FAILURE", e);
        }
        finish();
    }
}
