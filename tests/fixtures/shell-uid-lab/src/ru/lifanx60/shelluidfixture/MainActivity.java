package ru.lifanx60.shelluidfixture;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;

/** Reports only its own UID. Disposable emulator fixture; no privileged operation. */
public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu"))) {
            Log.e("X60ShellUidLab", "REFUSED_NON_EMULATOR");
        } else {
            Log.i("X60ShellUidLab", "OWN_UID=" + Process.myUid());
        }
        finish();
    }
}
