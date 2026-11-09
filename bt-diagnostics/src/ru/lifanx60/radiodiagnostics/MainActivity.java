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
    private boolean diagnosticStarted;
    private boolean scanRequested;
    private boolean scanResultReceived;
    private boolean receiverRegistered;
    private boolean enableCallThrew;
    private boolean scanCallThrew;
    private long deadline;
    private int initialState = WifiManager.WIFI_STATE_UNKNOWN;
    private Boolean enableRequestAccepted;
    private Boolean scanRequestAccepted;
    private int scanResultCount = -1;
    private String lastEvent = "Проверка ещё не запускалась.";

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            String action = intent == null ? null : intent.getAction();
            if (WifiManager.WIFI_STATE_CHANGED_ACTION.equals(action)) {
                lastEvent = "Android прислал событие изменения состояния Wi-Fi.";
                if (diagnosticRunning && wifi != null
                        && wifi.getWifiState() == WifiManager.WIFI_STATE_ENABLED) {
                    requestScan();
                }
                render();
            } else if (WifiManager.SCAN_RESULTS_AVAILABLE_ACTION.equals(action)) {
                scanResultReceived = true;
                readScanCount();
                lastEvent = "Android прислал событие завершения поиска сетей.";
                render();
            }
        }
    };

    private final Runnable poll = new Runnable() {
        @Override public void run() {
            if (!diagnosticRunning) return;
            int state = wifi == null ? WifiManager.WIFI_STATE_UNKNOWN : wifi.getWifiState();
            if (state == WifiManager.WIFI_STATE_ENABLED) requestScan();
            if (System.currentTimeMillis() >= deadline) {
                diagnosticRunning = false;
                runButton.setEnabled(true);
                lastEvent = "Проверка завершена (20 секунд). Сети не подключались.";
                render();
                return;
            }
            render();
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
            lastEvent = "Не удалось подписаться на события Wi-Fi: " + safeMessage(e);
        }
        render();
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
        note.setText("Съёмная диагностика. Не меняет драйверы или системные файлы, не подключается к сети и не требует интернета. Кнопка запрашивает включение Wi-Fi и сканирование; видимые сети и пароли не сохраняются.");
        note.setTextSize(15);
        root.addView(note, new LinearLayout.LayoutParams(-1, dp(76)));

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
            @Override public void onClick(View v) {
                lastEvent = "Состояние обновлено без запроса включения.";
                render();
            }
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
            lastEvent = "Android не предоставил системную службу Wi-Fi (WifiManager=null).";
            render();
            return;
        }
        diagnosticRunning = true;
        diagnosticStarted = true;
        scanRequested = false;
        scanResultReceived = false;
        scanRequestAccepted = null;
        scanResultCount = -1;
        enableRequestAccepted = null;
        enableCallThrew = false;
        scanCallThrew = false;
        initialState = wifi.getWifiState();
        deadline = System.currentTimeMillis() + 20000L;
        runButton.setEnabled(false);
        try {
            enableRequestAccepted = Boolean.valueOf(wifi.setWifiEnabled(true));
            lastEvent = "Запрос setWifiEnabled(true) выполнен; ответ Android: " + enableRequestAccepted + ".";
        } catch (SecurityException e) {
            enableCallThrew = true;
            lastEvent = "Android запретил setWifiEnabled(true): " + safeMessage(e) + ".";
            diagnosticRunning = false;
            runButton.setEnabled(true);
        } catch (Exception e) {
            enableCallThrew = true;
            lastEvent = "Ошибка setWifiEnabled(true): " + safeMessage(e) + ".";
            diagnosticRunning = false;
            runButton.setEnabled(true);
        }
        if (wifi.getWifiState() == WifiManager.WIFI_STATE_ENABLED) requestScan();
        render();
        handler.removeCallbacks(poll);
        if (diagnosticRunning) handler.post(poll);
    }

    private void requestScan() {
        if (scanRequested || wifi == null) return;
        scanRequested = true;
        try {
            scanRequestAccepted = Boolean.valueOf(wifi.startScan());
            lastEvent = "Wi-Fi отмечен Android как включённый; startScan() ответил " + scanRequestAccepted + ".";
        } catch (SecurityException e) {
            scanCallThrew = true;
            lastEvent = "Android запретил startScan(): " + safeMessage(e) + ".";
        } catch (Exception e) {
            scanCallThrew = true;
            lastEvent = "Ошибка startScan(): " + safeMessage(e) + ".";
        }
    }

    private void readScanCount() {
        try {
            List<ScanResult> results = wifi == null ? null : wifi.getScanResults();
            scanResultCount = results == null ? -1 : results.size();
        } catch (Exception e) {
            scanResultCount = -1;
        }
    }

    private void render() {
        if (report == null) return;
        StringBuilder b = new StringBuilder();
        if (wifi == null) {
            b.append("Служба Android Wi-Fi: отсутствует (WifiManager=null).\n");
        } else {
            try {
                int currentState = wifi.getWifiState();
                b.append("Состояние Android: ").append(describeState(currentState)).append("\n");
                b.append("isWifiEnabled(): ").append(wifi.isWifiEnabled()).append("\n");
                if (diagnosticStarted) {
                    b.append("До проверки: ").append(describeState(initialState)).append("\n");
                    b.append("setWifiEnabled(true): ")
                     .append(enableCallThrew ? "ИСКЛЮЧЕНИЕ" : String.valueOf(enableRequestAccepted)).append("\n");
                    if (currentState == WifiManager.WIFI_STATE_ENABLED) {
                        b.append("startScan(): ")
                         .append(scanCallThrew ? "ИСКЛЮЧЕНИЕ" : String.valueOf(scanRequestAccepted)).append("\n");
                        b.append("Событие результатов поиска: ").append(scanResultReceived ? "получено" : "не получено").append("\n");
                        if (scanResultCount >= 0) b.append("Число видимых сетей: ").append(scanResultCount).append("\n");
                    } else {
                        b.append("startScan(): не отправлялся — Android не сообщил о включённом радио.\n");
                    }
                } else if (currentState == WifiManager.WIFI_STATE_ENABLED) {
                    List<ScanResult> results = wifi.getScanResults();
                    b.append("Число сетей в последнем списке: ").append(results == null ? "нет данных" : String.valueOf(results.size())).append("\n");
                } else {
                    b.append("Сканирование не выполнялось.\n");
                }
            } catch (SecurityException e) {
                b.append("Ошибка доступа к состоянию: ").append(safeMessage(e)).append("\n");
            } catch (Exception e) {
                b.append("Ошибка чтения состояния: ").append(safeMessage(e)).append("\n");
            }
        }
        b.append("\nПоследнее событие: ").append(lastEvent).append("\n");
        b.append("\nПриложение не подключается к сетям и не читает/не меняет калибровочные файлы.");
        report.setText(b.toString());
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
