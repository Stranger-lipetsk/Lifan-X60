package ru.lifanx60.radiodiagnostics;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.Handler;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.List;

/** Removable, user-triggered Wi-Fi state and scan probe. Does not connect to a network. */
public final class MainActivity extends Activity {
    private WifiManager wifi;
    private TextView report;
    private Button runButton;
    private final Handler handler = new Handler();
    private boolean diagnosticRunning;
    private boolean scanRequested;
    private boolean scanResultReceived;
    private boolean receiverRegistered;
    private long deadline;

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            String action = intent == null ? null : intent.getAction();
            if (WifiManager.WIFI_STATE_CHANGED_ACTION.equals(action)) {
                render("Получено системное событие о состоянии Wi-Fi.");
                if (diagnosticRunning && wifi != null
                        && wifi.getWifiState() == WifiManager.WIFI_STATE_ENABLED) {
                    requestScan();
                }
            } else if (WifiManager.SCAN_RESULTS_AVAILABLE_ACTION.equals(action)) {
                scanResultReceived = true;
                render("Получено событие о завершении поиска сетей.");
            }
        }
    };

    private final Runnable poll = new Runnable() {
        @Override public void run() {
            if (!diagnosticRunning) return;
            int state = wifi == null ? WifiManager.WIFI_STATE_UNKNOWN : wifi.getWifiState();
            if (state == WifiManager.WIFI_STATE_ENABLED) requestScan();
            render(null);
            if (System.currentTimeMillis() >= deadline) {
                diagnosticRunning = false;
                runButton.setEnabled(true);
                render("Проверка завершена (20 секунд). Сети не подключались.");
                return;
            }
            handler.postDelayed(this, 1000L);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        buildUi();
        IntentFilter filter = new IntentFilter();
        filter.addAction(WifiManager.WIFI_STATE_CHANGED_ACTION);
        filter.addAction(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION);
        try {
            registerReceiver(receiver, filter);
            receiverRegistered = true;
        } catch (Exception e) {
            append("Не удалось подписаться на события Wi-Fi: " + safeMessage(e));
        }
        render("Ничего не включалось. Нажмите кнопку, чтобы отправить один запрос на включение и выполнить поиск; к сетям приложение не подключается.");
    }

    private void buildUi() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(18), dp(12), dp(18), dp(14));
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Проверка Wi-Fi на магнитоле");
        title.setTextSize(23);
        title.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(title, new LinearLayout.LayoutParams(-1, dp(42)));

        TextView note = new TextView(this);
        note.setText("Съёмная диагностика. Не меняет драйверы или системные файлы, не подключается к сети и не требует интернета. Кнопка только запрашивает включение Wi-Fi на время проверки и просит Android начать сканирование.");
        note.setTextSize(15);
        root.addView(note, new LinearLayout.LayoutParams(-1, dp(84)));

        runButton = new Button(this);
        runButton.setText("Проверить включение и поиск сетей");
        runButton.setTextSize(17);
        root.addView(runButton, new LinearLayout.LayoutParams(-1, dp(56)));
        runButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { startDiagnostic(); }
        });

        Button refresh = new Button(this);
        refresh.setText("Обновить состояние без изменений");
        refresh.setTextSize(16);
        root.addView(refresh, new LinearLayout.LayoutParams(-1, dp(50)));
        refresh.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { render("Состояние обновлено без запроса включения."); }
        });

        report = new TextView(this);
        report.setTextSize(16);
        report.setTextIsSelectable(true);
        report.setPadding(0, dp(12), 0, 0);
        root.addView(report, new LinearLayout.LayoutParams(-1, -2));
        setContentView(scroll);
    }

    private void startDiagnostic() {
        if (wifi == null) {
            append("Android не предоставил системную службу Wi-Fi (WifiManager=null). Никаких изменений не сделано.");
            return;
        }
        diagnosticRunning = true;
        scanRequested = false;
        scanResultReceived = false;
        deadline = System.currentTimeMillis() + 20000L;
        runButton.setEnabled(false);
        String before = describeState(wifi.getWifiState());
        boolean accepted;
        try {
            accepted = wifi.setWifiEnabled(true);
            append("Запрос setWifiEnabled(true) отправлен. Ответ Android: " + accepted + ". Состояние до запроса: " + before + ".");
        } catch (SecurityException e) {
            append("Android запретил запрос включения Wi-Fi: " + safeMessage(e) + ".");
            diagnosticRunning = false;
            runButton.setEnabled(true);
            return;
        } catch (Exception e) {
            append("Ошибка запроса включения Wi-Fi: " + safeMessage(e) + ".");
            diagnosticRunning = false;
            runButton.setEnabled(true);
            return;
        }
        if (wifi.getWifiState() == WifiManager.WIFI_STATE_ENABLED) requestScan();
        render(null);
        handler.removeCallbacks(poll);
        handler.post(poll);
    }

    private void requestScan() {
        if (scanRequested || wifi == null) return;
        scanRequested = true;
        try {
            boolean accepted = wifi.startScan();
            append("Wi-Fi включён по данным Android. Запрос startScan(): " + accepted + ".");
        } catch (SecurityException e) {
            append("Android запретил поиск сетей: " + safeMessage(e) + ".");
        } catch (Exception e) {
            append("Ошибка запроса поиска сетей: " + safeMessage(e) + ".");
        }
    }

    private void render(String event) {
        if (report == null) return;
        if (event != null) lastEvent = event;
        StringBuilder b = new StringBuilder();
        b.append("Состояние Android: ");
        if (wifi == null) {
            b.append("служба Wi-Fi отсутствует (null)\n");
        } else {
            try {
                b.append(describeState(wifi.getWifiState())).append("\n");
                b.append("isWifiEnabled(): ").append(wifi.isWifiEnabled()).append("\n");
                if (wifi.getWifiState() == WifiManager.WIFI_STATE_ENABLED) {
                    List<ScanResult> results = wifi.getScanResults();
                    b.append("Число видимых сетей: ").append(results == null ? "нет данных" : String.valueOf(results.size())).append("\n");
                } else {
                    b.append("Список сетей не запрашивался: радио не включено.\n");
                }
            } catch (SecurityException e) {
                b.append("ошибка доступа: ").append(safeMessage(e)).append("\n");
            } catch (Exception e) {
                b.append("ошибка чтения состояния: ").append(safeMessage(e)).append("\n");
            }
        }
        b.append("\nСобытие поиска: ").append(scanResultReceived ? "получено" : "не получено").append("\n");
        if (lastEvent != null) b.append("Последнее событие: ").append(lastEvent).append("\n");
        b.append("\nПриложение не подключает сеть и не читает/не меняет калибровочные файлы.");
        report.setText(b.toString());
    }

    private String lastEvent;

    private void append(String line) {
        if (report == null) { lastEvent = line; return; }
        lastEvent = line;
        render(null);
    }

    private static String describeState(int state) {
        switch (state) {
            case WifiManager.WIFI_STATE_DISABLED: return "DISABLED (выключен)";
            case WifiManager.WIFI_STATE_DISABLING: return "DISABLING (выключается)";
            case WifiManager.WIFI_STATE_ENABLED: return "ENABLED (включён)";
            case WifiManager.WIFI_STATE_ENABLING: return "ENABLING (включается)";
            default: return "UNKNOWN (неизвестно; код " + state + ")";
        }
    }

    private static String safeMessage(Throwable t) {
        String m = t == null ? null : t.getMessage();
        return m == null || m.length() == 0 ? t.getClass().getSimpleName() : m;
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    @Override public void onDestroy() {
        handler.removeCallbacks(poll);
        diagnosticRunning = false;
        if (receiverRegistered) {
            try { unregisterReceiver(receiver); } catch (Exception ignored) { }
            receiverRegistered = false;
        }
        super.onDestroy();
    }
}
