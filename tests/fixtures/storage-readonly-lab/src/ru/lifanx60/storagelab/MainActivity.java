package ru.lifanx60.storagelab;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.os.StatFs;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;

/** Disposable emulator-only probe. No permissions, no writes, no network, no user files. */
public final class MainActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        TextView text = new TextView(this);
        text.setTextSize(16);
        text.setPadding(16, 16, 16, 16);
        scroll.addView(text);
        setContentView(scroll);
        if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu"))) {
            text.setText("LAB ONLY: this fixture refuses non-generic hardware.");
            return;
        }
        StringBuilder report = new StringBuilder();
        report.append("LAB ONLY - emulyator\n");
        report.append("/data: dannye tekushego prostranstva montirovaniya\n");
        try {
            StatFs fs = new StatFs("/data");
            long size = fs.getBlockSizeLong();
            report.append("TOTAL_KIB=").append(fs.getBlockCountLong() * size / 1024L).append('\n');
            report.append("FREE_KIB=").append(fs.getFreeBlocksLong() * size / 1024L).append('\n');
            report.append("AVAILABLE_KIB=").append(fs.getAvailableBlocksLong() * size / 1024L).append('\n');
        } catch (RuntimeException e) {
            report.append("STATFS_UNAVAILABLE\n");
        }
        report.append("PROBE_MOUNTS_BEGIN\n");
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/mounts"))) {
            String line;
            int count = 0;
            while ((line = reader.readLine()) != null) {
                String selected = MountFilter.select(line);
                if (selected != null) {
                    report.append(selected).append('\n');
                    count++;
                }
            }
            if (count == 0) report.append("NO_MATCH\n");
        } catch (IOException | SecurityException e) {
            report.append("MOUNTS_UNAVAILABLE\n");
        }
        report.append("PROBE_MOUNTS_END\n");
        report.append("Net stroki p5 ne dokazyvaet chto ego net.\n");
        text.setText(report.toString());
    }
}
