package ru.lifan.switcher;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.os.Bundle;
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
 * Переключатель окружений для ГУ Lifan X60 FL (Elead EL-830C-LF01).
 *
 * Даёт точки входа, которых нет в штатной оболочке Elead:
 *   - стандартный лаунчер Android (Launcher2, com.android.launcher);
 *   - лаунчер магнитолы (tw.com.elead.el830.home);
 *   - настройки Android (com.android.settings / ElSettings) — включая Wi-Fi;
 *   - диспетчер приложений и файловый менеджер (DocumentsUI).
 *
 * Все переходы сделаны через PackageManager, а не через жёстко прописанные
 * имена активностей, поэтому приложение устойчиво к переименованиям.
 */
public class MainActivity extends Activity {

    private static final String PKG_CAR_HOME = "tw.com.elead.el830.home";
    private static final String PKG_AOSP_HOME = "com.android.launcher";
    private static final String PKG_SETTINGS = "com.android.settings";
    private static final String PKG_DOCUMENTS = "com.android.documentsui";

    private static final int COL_BG = 0xFF101418;
    private static final int COL_CAR = 0xFF1E5FA8;
    private static final int COL_ANDROID = 0xFF2E7D32;
    private static final int COL_NEUTRAL = 0xFF37474F;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(COL_BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(18);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Переключатель");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        title.setGravity(Gravity.CENTER);
        title.setPadding(0, 0, 0, dp(6));
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("Lifan X60 FL · Elead EL-830C-LF01");
        sub.setTextColor(0xFF9E9E9E);
        sub.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        sub.setGravity(Gravity.CENTER);
        sub.setPadding(0, 0, 0, dp(14));
        root.addView(sub);

        addButton(root, "Магнитола (штатная оболочка)", COL_CAR, new Runnable() {
            public void run() { launchHome(PKG_CAR_HOME); }
        });
        addButton(root, "Стандартный Android", COL_ANDROID, new Runnable() {
            public void run() { launchHome(PKG_AOSP_HOME); }
        });
        addButton(root, "Настройки Android", COL_NEUTRAL, new Runnable() {
            public void run() { startAction("android.settings.SETTINGS", PKG_SETTINGS); }
        });
        addButton(root, "Настройки Wi-Fi", COL_NEUTRAL, new Runnable() {
            public void run() { startAction("android.settings.WIFI_SETTINGS", PKG_SETTINGS); }
        });
        addButton(root, "Приложения (удаление/остановка)", COL_NEUTRAL, new Runnable() {
            public void run() {
                startAction("android.settings.MANAGE_APPLICATIONS_SETTINGS", PKG_SETTINGS);
            }
        });
        addButton(root, "Файловый менеджер", COL_NEUTRAL, new Runnable() {
            public void run() { openDocuments(); }
        });
        addButton(root, "Память и USB-накопители", COL_NEUTRAL, new Runnable() {
            public void run() { startAction("android.settings.INTERNAL_STORAGE_SETTINGS", PKG_SETTINGS); }
        });
        addButton(root, "Для разработчиков (ADB/отладка)", COL_NEUTRAL, new Runnable() {
            public void run() {
                startAction("android.settings.APPLICATION_DEVELOPMENT_SETTINGS", PKG_SETTINGS);
            }
        });

        TextView hint = new TextView(this);
        hint.setText("Совет: чтобы кнопка «Магнитола» и «Стандартный Android» "
                + "работали как переключатель, оставь выбор лаунчера свободным "
                + "(Настройки → Дом).");
        hint.setTextColor(0xFF9E9E9E);
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        hint.setPadding(0, dp(16), 0, 0);
        root.addView(hint);

        setContentView(scroll);
    }

    /** Кнопка с крупным размером — удобно нажимать в авто. */
    private void addButton(LinearLayout parent, String text, int color, final Runnable action) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(Color.WHITE);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        b.setBackgroundColor(color);
        b.setAllCaps(false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(62));
        lp.setMargins(0, 0, 0, dp(10));
        b.setLayoutParams(lp);
        b.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
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
     * Запускает лаунчер указанного пакета.
     * Ищем среди приложений, объявивших себя как HOME — это надёжнее,
     * чем жёстко прописанное имя активности.
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
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(i);
                return;
            }
        }
        toast("Лаунчер не найден: " + pkg + "\n(доступно HOME-приложений: " + list.size() + ")");
    }

    /**
     * Запускает системное действие настроек.
     * Сначала пробуем штатный обработчик (com.android.settings = ElSettings),
     * если его нет — любое приложение, готовое обработать действие.
     */
    private void startAction(String action, String preferPkg) {
        Intent q = new Intent(action);
        List<ResolveInfo> list = getPackageManager().queryIntentActivities(q, 0);
        if (list == null || list.isEmpty()) {
            toast("Нет обработчика: " + action);
            return;
        }
        ResolveInfo chosen = list.get(0);
        for (ResolveInfo ri : list) {
            if (preferPkg.equals(ri.activityInfo.packageName)) {
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

    /** Файловый менеджер: DocumentsUI, иначе стандартный выбор файла. */
    private void openDocuments() {
        Intent i = getPackageManager().getLaunchIntentForPackage(PKG_DOCUMENTS);
        if (i == null) {
            i = new Intent("android.intent.action.GET_CONTENT");
            i.setType("*/*");
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(i);
        } catch (Exception e) {
            // последний вариант — настройки хранилища
            startAction("android.settings.INTERNAL_STORAGE_SETTINGS", PKG_SETTINGS);
        }
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_LONG).show();
    }
}
