package ru.lifanx60.panelprobe;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/** A manually launched probe, not a HOME activity or boot receiver. */
public final class MainActivity extends Activity {
    private static final String CAR_PACKAGE = "tw.com.elead.el830.home";
    private static final String CAR_ACTIVITY = "tw.com.elead.el830.home.Home";
    private static final String ANDROID_PACKAGE = "com.android.launcher";
    private static final String ANDROID_ACTIVITY = "com.android.launcher2.Launcher";
    private static final String AMAZE_PACKAGE = "com.amaze.filemanager";
    private static final String AMAZE_ACTIVITY = "com.amaze.filemanager.ui.activities.MainActivity";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        box.setPadding(pad, pad, pad, pad);
        scroll.addView(box);

        TextView info = new TextView(this);
        info.setText("Панель Lifan — тест\nОткрывается только вручную. Домашний экран по умолчанию не меняется.");
        info.setTextSize(18);
        info.setGravity(Gravity.CENTER);
        box.addView(info);
        addButton(box, "Штатный экран магнитолы", CAR_PACKAGE, CAR_ACTIVITY, true);
        addButton(box, "Рабочий стол Android", ANDROID_PACKAGE, ANDROID_ACTIVITY, true);
        addButton(box, "Файловый менеджер Amaze", AMAZE_PACKAGE, AMAZE_ACTIVITY, false);
        setContentView(scroll);
    }

    private void addButton(LinearLayout box, String label, final String packageName,
                           final String activityName, final boolean isHome) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setMinHeight((int) (56 * getResources().getDisplayMetrics().density));
        button.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View view) {
                open(packageName, activityName, isHome);
            }
        });
        box.addView(button);
    }

    private void open(String packageName, String activityName, boolean isHome) {
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(isHome ? Intent.CATEGORY_HOME : Intent.CATEGORY_LAUNCHER);
        intent.setComponent(new ComponentName(packageName, activityName));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(intent);
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "Приложение не найдено", Toast.LENGTH_LONG).show();
        } catch (SecurityException e) {
            Toast.makeText(this, "Android запретил открытие приложения", Toast.LENGTH_LONG).show();
        }
    }
}
