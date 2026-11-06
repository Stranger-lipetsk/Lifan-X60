package ru.lifanx60.sulab;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.InputStreamReader;

/** Isolated emulator only. Runs only a fixed identity check, never user data operations. */
public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (!Build.FINGERPRINT.equals("generic/sdk/generic:4.4.2/KK/3462041:eng/test-keys") ||
                !Build.HARDWARE.contains("goldfish")) {
            Log.e("X60SuLab", "REFUSED_NON_EMULATOR"); finish(); return;
        }
        new Thread(new Runnable() {
            @Override public void run() {
                try {
                    Log.i("X60SuLab", "OWN_UID=" + Process.myUid());
                    BufferedReader status = new BufferedReader(new FileReader("/proc/self/status"));
                    String statusLine;
                    while ((statusLine = status.readLine()) != null) {
                        if (statusLine.startsWith("Uid:") || statusLine.startsWith("Gid:") ||
                                statusLine.startsWith("Cap") || statusLine.startsWith("NoNewPrivs:"))
                            Log.i("X60SuLab", "SELF_STATUS=" + statusLine);
                    }
                    status.close();
                    java.lang.Process p = new ProcessBuilder("/system/xbin/x60-lab-su", "0", "/system/bin/id").redirectErrorStream(true).start();
                    BufferedReader in = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line;
                    while ((line = in.readLine()) != null) Log.i("X60SuLab", "RESULT=" + line);
                    Log.i("X60SuLab", "EXIT=" + p.waitFor());
                } catch (Exception e) { Log.e("X60SuLab", "FAILED", e); }
                finish();
            }
        }).start();
    }
}
