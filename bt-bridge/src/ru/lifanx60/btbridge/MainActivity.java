package ru.lifanx60.btbridge;

import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

public final class MainActivity extends Activity {
    private BluetoothAdapter bluetooth;
    private final Map<String, BluetoothDevice> devices = new LinkedHashMap<String, BluetoothDevice>();
    private final ArrayList<String> rows = new ArrayList<String>();
    private ArrayAdapter<String> listAdapter;
    private EditText addressInput;
    private EditText pinInput;
    private TextView statusView;
    private boolean receiversRegistered;

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            if (BluetoothDevice.ACTION_FOUND.equals(action)) {
                BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                if (device != null) addDevice(device);
            } else if (BluetoothAdapter.ACTION_DISCOVERY_FINISHED.equals(action)) {
                setStatus("Поиск завершён. Выберите ELM327 из списка.");
            } else if (BridgeService.ACTION_STATUS.equals(action)) {
                String message = intent.getStringExtra(BridgeService.EXTRA_STATUS);
                if (message != null) setStatus(message);
            }
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        bluetooth = BluetoothAdapter.getDefaultAdapter();
        buildUi();
        if (bluetooth == null) {
            setStatus("В этом устройстве не найден Bluetooth-адаптер.");
        } else if (!bluetooth.isEnabled()) {
            setStatus("Включите Bluetooth штатным переключателем ГУ; приложение само его не включает.");
        } else {
            loadBondedDevices();
            setStatus("Выберите ELM327. Мост не подключает телефонные профили HFP/A2DP.");
        }
    }

    private void buildUi() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(12);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("OBD Bluetooth Bridge — тестовый мост SPP → TCP");
        title.setTextSize(22);
        title.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(title, new LinearLayout.LayoutParams(-1, dp(42)));

        statusView = new TextView(this);
        statusView.setTextSize(16);
        statusView.setPadding(0, dp(6), 0, dp(8));
        root.addView(statusView, new LinearLayout.LayoutParams(-1, -2));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        Button scan = new Button(this);
        scan.setText("Найти устройства");
        actions.addView(scan, new LinearLayout.LayoutParams(0, dp(54), 1));
        Button stop = new Button(this);
        stop.setText("Остановить мост");
        actions.addView(stop, new LinearLayout.LayoutParams(0, dp(54), 1));
        root.addView(actions, new LinearLayout.LayoutParams(-1, -2));

        ListView list = new ListView(this);
        listAdapter = new ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, rows);
        list.setAdapter(listAdapter);
        root.addView(list, new LinearLayout.LayoutParams(-1, dp(170)));
        list.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                if (position >= 0 && position < rows.size()) {
                    String row = rows.get(position);
                    int start = row.lastIndexOf('(');
                    int end = row.lastIndexOf(')');
                    if (start >= 0 && end > start) addressInput.setText(row.substring(start + 1, end));
                }
            }
        });

        TextView addressLabel = new TextView(this);
        addressLabel.setText("Bluetooth-адрес выбранного ELM327:");
        addressLabel.setTextSize(15);
        root.addView(addressLabel, new LinearLayout.LayoutParams(-1, dp(32)));
        addressInput = new EditText(this);
        addressInput.setSingleLine(true);
        addressInput.setHint("например, 00:11:22:AA:BB:CC");
        addressInput.setTextSize(17);
        root.addView(addressInput, new LinearLayout.LayoutParams(-1, dp(52)));

        TextView pinLabel = new TextView(this);
        pinLabel.setText("PIN адаптера (необязательно; укажите только известный код):");
        pinLabel.setTextSize(15);
        root.addView(pinLabel, new LinearLayout.LayoutParams(-1, dp(32)));
        pinInput = new EditText(this);
        pinInput.setSingleLine(true);
        pinInput.setInputType(android.text.InputType.TYPE_CLASS_NUMBER | android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        pinInput.setHint("код, использованный при подключении телефона");
        pinInput.setTextSize(17);
        root.addView(pinInput, new LinearLayout.LayoutParams(-1, dp(52)));

        Button start = new Button(this);
        start.setText("Сопрячь и запустить SPP-мост");
        root.addView(start, new LinearLayout.LayoutParams(-1, dp(56)));

        TextView instructions = new TextView(this);
        instructions.setText("PIN указывайте только если знаете точный код адаптера; он используется в памяти для этого запроса и не сохраняется. После статуса «SPP подключён; TCP 127.0.0.1:35000 готов» в Torque задайте тип WiFi, IP 127.0.0.1 и порт 35000 — включать Wi-Fi не нужно. Остановка моста не удаляет сопряжение.\n\nПриложение обращается только к штатному Elead SPP-сервису и не меняет системные файлы.");
        instructions.setTextSize(14);
        instructions.setPadding(0, dp(8), 0, dp(6));
        root.addView(instructions, new LinearLayout.LayoutParams(-1, -2));
        setContentView(scroll);

        scan.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { startDiscovery(); }
        });
        start.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { startBridge(); }
        });
        stop.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { stopBridge(); }
        });
    }

    private void startDiscovery() {
        if (bluetooth == null || !bluetooth.isEnabled()) {
            setStatus("Bluetooth выключен. Включите его в штатных настройках ГУ.");
            return;
        }
        if (bluetooth.isDiscovering()) bluetooth.cancelDiscovery();
        devices.clear();
        rows.clear();
        listAdapter.notifyDataSetChanged();
        loadBondedDevices();
        setStatus("Ищем Bluetooth-устройства…");
        bluetooth.startDiscovery();
    }

    private void loadBondedDevices() {
        if (bluetooth == null || !bluetooth.isEnabled()) return;
        try {
            Set<BluetoothDevice> bonded = bluetooth.getBondedDevices();
            if (bonded != null) for (BluetoothDevice device : bonded) addDevice(device);
        } catch (SecurityException e) {
            setStatus("Система не разрешила прочитать список Bluetooth-устройств.");
        }
    }

    private void addDevice(BluetoothDevice device) {
        String address = device.getAddress();
        if (address == null || devices.containsKey(address)) return;
        devices.put(address, device);
        String name;
        try { name = device.getName(); } catch (SecurityException e) { name = null; }
        if (name == null || name.length() == 0) name = "(без имени)";
        String bonded = device.getBondState() == BluetoothDevice.BOND_BONDED ? "сопряжён" : "доступен";
        rows.add(name + " — " + bonded + " (" + address + ")");
        if (listAdapter != null) listAdapter.notifyDataSetChanged();
    }

    private void startBridge() {
        String address = addressInput.getText().toString().trim().toUpperCase();
        if (!BluetoothAdapter.checkBluetoothAddress(address)) {
            setStatus("Выберите устройство из списка или введите корректный Bluetooth-адрес.");
            return;
        }
        if (bluetooth == null || !bluetooth.isEnabled()) {
            setStatus("Сначала включите Bluetooth в штатных настройках ГУ.");
            return;
        }
        if (bluetooth.isDiscovering()) bluetooth.cancelDiscovery();
        Intent intent = new Intent(this, BridgeService.class);
        String pin = pinInput.getText().toString().trim();
        if (pin.length() > 16) {
            setStatus("PIN слишком длинный. Введите только известный код длиной до 16 цифр.");
            return;
        }
        intent.setAction(BridgeService.ACTION_START);
        intent.putExtra(BridgeService.EXTRA_ADDRESS, address);
        if (pin.length() > 0) intent.putExtra(BridgeService.EXTRA_PIN, pin);
        startService(intent);
        pinInput.setText("");
        setStatus("Запрошен запуск моста для " + address + ". PIN не сохраняется; подтвердите сопряжение, если появится запрос.");
    }

    private void stopBridge() {
        Intent intent = new Intent(this, BridgeService.class);
        intent.setAction(BridgeService.ACTION_STOP);
        startService(intent);
        setStatus("Остановка запрошена. Сохранённое сопряжение не удаляется.");
    }

    private void setStatus(String text) {
        if (statusView != null) statusView.setText(text);
    }

    @Override protected void onResume() {
        super.onResume();
        if (!receiversRegistered) {
            IntentFilter filter = new IntentFilter();
            filter.addAction(BluetoothDevice.ACTION_FOUND);
            filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
            filter.addAction(BridgeService.ACTION_STATUS);
            registerReceiver(receiver, filter);
            receiversRegistered = true;
        }
        String last = getSharedPreferences("bridge", MODE_PRIVATE).getString("status", null);
        if (last != null) setStatus(last);
    }

    @Override protected void onPause() {
        if (receiversRegistered) {
            try { unregisterReceiver(receiver); } catch (IllegalArgumentException ignored) { }
            receiversRegistered = false;
        }
        super.onPause();
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}
