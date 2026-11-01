package com.fpt.mirrorlink.android;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;

/**
 * Переключатель окружений для ГУ Lifan X60 FL (Elead EL-830C-LF01, Android 4.4.2).
 *
 * Зачем: в штатной оболочке Elead Home нет списка приложений, доступа к
 * настройкам Android, Wi-Fi и файловому менеджеру. Пакеты при этом в системе
 * ЕСТЬ: com.android.launcher (штатный лаунчер) и com.android.settings (ElSettings,
 * обрабатывает все android.settings.*).
 *
 * Как работает:
 *   Приложение объявляет себя домашним экраном (CATEGORY_HOME). Если назначить
 *   его лаунчером по умолчанию, то нажатие кнопки «Домой» и загрузка ГУ приводят
 *   сюда — к панели переключения. Через заданное время панель сама уходит в
 *   оболочку магнитолы, поэтому обычная работа не страдает.
 *
 * Все запуски идут через PackageManager (поиск реальных активностей), поэтому
 * приложение не ломается, если имена активностей отличаются.
 */
public class MainActivity extends Activity {

    private static final String PKG_CAR_HOME = "tw.com.elead.el830.home";
    private static final String PKG_AOSP_HOME = "com.android.launcher";
    private static final String PKG_SETTINGS = "com.android.settings";
    private static final String PKG_DOCUMENTS = "com.android.documentsui";

    /** Сколько секунд панель ждёт, прежде чем сама уйти в оболочку магнитолы. */
    private static final int AUTO_BACK_SECONDS = 6;

    private static final String PREFS = "switcher";
    private static final String KEY_AUTOBACK = "autoback_v2";

    private static final int COL_BG = 0xFF0E1216;
    private static final int COL_CAR = 0xFF1E5FA8;
    private static final int COL_ANDROID = 0xFF2E7D32;
    private static final int COL_NEUTRAL = 0xFF37474F;
    private static final int COL_TEXT = 0xFFFFFFFF;
    private static final int COL_DIM = 0xFF9E9E9E;

    private Handler handler;
    private Runnable autoBack;
    private TextView countdownView;
    private int secondsLeft;
    private boolean autoBackEnabled = true;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        handler = new Handler();

        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        autoBackEnabled = prefs.getBoolean(KEY_AUTOBACK, false);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(COL_BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("MirrorLink · Центр системы");
        title.setTextColor(COL_TEXT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setGravity(Gravity.CENTER);
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("Lifan X60 FL · Elead EL-830C-LF01 · Android 4.4.2\n"
                + "Заменяет неработающий MirrorLink — открывает Android");
        sub.setTextColor(COL_DIM);
        sub.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        sub.setGravity(Gravity.CENTER);
        sub.setPadding(0, 0, 0, dp(10));
        root.addView(sub);

        countdownView = new TextView(this);
        countdownView.setTextColor(COL_DIM);
        countdownView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        countdownView.setGravity(Gravity.CENTER);
        countdownView.setPadding(0, 0, 0, dp(12));
        root.addView(countdownView);

        addButton(root, "Магнитола (штатная оболочка)", COL_CAR, new Runnable() {
            public void run() { launchHome(PKG_CAR_HOME); }
        });
        addButton(root, "Стандартный Android (рабочий стол)", COL_ANDROID, new Runnable() {
            public void run() { launchHome(PKG_AOSP_HOME); }
        });
        addButton(root, "Настройки Android", COL_NEUTRAL, new Runnable() {
            public void run() { startAction("android.settings.SETTINGS"); }
        });
        addButton(root, "Настройки Wi-Fi", COL_NEUTRAL, new Runnable() {
            public void run() { startAction("android.settings.WIFI_SETTINGS"); }
        });
        addButton(root, "Приложения: установка и удаление", COL_NEUTRAL, new Runnable() {
            public void run() {
                startAction("android.settings.MANAGE_APPLICATIONS_SETTINGS");
            }
        });
        addButton(root, "Файловый менеджер", COL_NEUTRAL, new Runnable() {
            public void run() { openDocuments(); }
        });
        addButton(root, "Память и USB-накопители", COL_NEUTRAL, new Runnable() {
            public void run() {
                startAction("android.settings.INTERNAL_STORAGE_SETTINGS");
            }
        });
        addButton(root, "Для разработчиков (ADB)", COL_NEUTRAL, new Runnable() {
            public void run() {
                startAction("android.settings.APPLICATION_DEVELOPMENT_SETTINGS");
            }
        });

        final Button toggle = new Button(this);
        toggle.setText(autoBackEnabled
                ? "Автовозврат в магнитолу: включён"
                : "Автовозврат в магнитолу: выключен");
        toggle.setTextColor(COL_TEXT);
        toggle.setAllCaps(false);
        toggle.setBackgroundColor(0xFF263238);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(52));
        tlp.setMargins(0, dp(8), 0, 0);
        toggle.setLayoutParams(tlp);
        toggle.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                autoBackEnabled = !autoBackEnabled;
                getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                        .putBoolean(KEY_AUTOBACK, autoBackEnabled).commit();
                toggle.setText(autoBackEnabled
                        ? "Автовозврат в магнитолу: включён"
                        : "Автовозврат в магнитолу: выключен");
                if (!autoBackEnabled) {
                    cancelAutoBack();
                }
            }
        });
        root.addView(toggle);

        TextView hint = new TextView(this);
        hint.setText("Открывается кнопкой MirrorLink на главном экране магнитолы. "
                + "Вернуться в магнитолу — первая кнопка. "
                + "Чтобы панель открывалась и по кнопке «Домой», включи HOME-режим "
                + "(docs/08).");
        hint.setTextColor(COL_DIM);
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10);
        hint.setPadding(0, dp(12), 0, 0);
        root.addView(hint);

        setContentView(scroll);
        startAutoBack();
    }

    @Override
    protected void onResume() {
        super.onResume();
        startAutoBack();
    }

    @Override
    protected void onPause() {
        super.onPause();
        cancelAutoBack();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        cancelAutoBack();
    }

    // ---------------------------------------------------------------- таймер

    private void startAutoBack() {
        cancelAutoBack();
        if (!autoBackEnabled) {
            countdownView.setText("");
            return;
        }
        secondsLeft = AUTO_BACK_SECONDS;
        autoBack = new Runnable() {
            public void run() {
                if (secondsLeft > 0) {
                    countdownView.setText("Через " + secondsLeft
                            + " с откроется магнитола. Нажми любую кнопку, чтобы остаться.");
                    secondsLeft--;
                    handler.postDelayed(this, 1000);
                } else {
                    countdownView.setText("Открываю магнитолу…");
                    launchHome(PKG_CAR_HOME);
                }
            }
        };
        handler.post(autoBack);
    }

    private void cancelAutoBack() {
        if (autoBack != null) {
            handler.removeCallbacks(autoBack);
            autoBack = null;
        }
        if (countdownView != null) {
            countdownView.setText("");
        }
    }

    // ------------------------------------------------------------- кнопки

    private void addButton(LinearLayout parent, String text, int color, final Runnable action) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(COL_TEXT);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        b.setBackgroundColor(color);
        b.setAllCaps(false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(58));
        lp.setMargins(0, 0, 0, dp(8));
        b.setLayoutParams(lp);
        b.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                cancelAutoBack();
                try {
                    action.run();
                } catch (Throwable t) {
                    toast("Ошибка: " + t.getMessage());
                }
            }
        });
        parent.addView(b);
    }

    /**
     * Запускает лаунчер нужного пакета. Ищем среди приложений с CATEGORY_HOME —
     * это надёжнее, чем жёстко заданное имя активности.
     */
    private void launchHome(String pkg) {
        Intent q = new Intent(Intent.ACTION_MAIN);
        q.addCategory(Intent.CATEGORY_HOME);
        List<ResolveInfo> list = getPackageManager().queryIntentActivities(q, 0);

        for (ResolveInfo ri : list) {
            if (pkg.equals(ri.activityInfo.packageName)) {
                Intent i = new Intent(Intent.ACTION_MAIN);
                i.addCategory(Intent.CATEGORY_HOME);
                i.setComponent(new ComponentName(ri.activityInfo.packageName,
                        ri.activityInfo.name));
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(i);
                finish();
                return;
            }
        }

        // запасной путь — обычный запуск приложения
        Intent launch = getPackageManager().getLaunchIntentForPackage(pkg);
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(launch);
            finish();
            return;
        }

        StringBuilder sb = new StringBuilder("Лаунчер не найден: ");
        sb.append(pkg).append("\nДоступные HOME-приложения:");
        for (ResolveInfo ri : list) {
            sb.append("\n• ").append(ri.activityInfo.packageName);
        }
        toast(sb.toString());
    }

    /** Запуск системного экрана настроек через реально найденный обработчик. */
    private void startAction(String action) {
        Intent q = new Intent(action);
        List<ResolveInfo> list = getPackageManager().queryIntentActivities(q, 0);
        if (list == null || list.isEmpty()) {
            toast("Нет обработчика для " + action);
            return;
        }
        ResolveInfo chosen = list.get(0);
        for (ResolveInfo ri : list) {
            if (PKG_SETTINGS.equals(ri.activityInfo.packageName)) {
                chosen = ri;
                break;
            }
        }
        Intent i = new Intent(action);
        i.setComponent(new ComponentName(chosen.activityInfo.packageName,
                chosen.activityInfo.name));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(i);
    }

    /** Файловый менеджер: DocumentsUI, иначе системный выбор файла. */
    private void openDocuments() {
        Intent i = getPackageManager().getLaunchIntentForPackage(PKG_DOCUMENTS);
        if (i == null) {
            i = new Intent(Intent.ACTION_GET_CONTENT);
            i.setType("*/*");
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(i);
        } catch (Exception e) {
            startAction("android.settings.INTERNAL_STORAGE_SETTINGS");
        }
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_LONG).show();
    }
}
