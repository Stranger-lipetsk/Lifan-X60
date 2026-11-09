package ru.lifanx60.btbridge;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/** User-started bridge: Elead's SPP AIDL <-> Torque's loopback TCP/Wi-Fi transport. */
public final class BridgeService extends Service {
    public static final String ACTION_START = "ru.lifanx60.btbridge.START";
    public static final String ACTION_STOP = "ru.lifanx60.btbridge.STOP";
    public static final String ACTION_STATUS = "ru.lifanx60.btbridge.STATUS";
    public static final String EXTRA_ADDRESS = "address";
    public static final String EXTRA_STATUS = "status";

    private static final String ELEAD_PACKAGE = "tw.com.elead.el830.elbluetooth";
    private static final String ELEAD_SERVICE = "tw.com.elead.el830.elbluetooth.elBluetoothService";
    private static final String ELEAD_ACTION = "tw.com.elead.el830.elbluetooth.IElBluetoothService";
    private static final int NOTIFICATION_ID = 4301;
    private static final int TCP_PORT = 35000;

    private final Handler handler = new Handler();
    private final ArrayBlockingQueue<byte[]> toTorque = new ArrayBlockingQueue<byte[]>(128);
    private String address;
    private String status = "Мост остановлен.";
    private EleadRemote remote;
    private boolean bound;
    private boolean callbackRegistered;
    private boolean active;
    private boolean bondReceiverRegistered;
    private IBinder eleadBinder;
    private ServerSocket serverSocket;
    private Socket tcpClient;
    private Thread tcpThread;
    private volatile boolean tcpRunning;
    private final VendorCallback callback = new VendorCallback();

    private final ServiceConnection eleadConnection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder service) {
            eleadBinder = service;
            remote = new EleadRemote(service);
            try {
                remote.registerCallback(getPackageName(), callback);
                callbackRegistered = true;
                boolean sppAdvertised = false;
                try {
                    sppAdvertised = remote.hasSppProfile();
                } catch (RemoteException ignored) {
                    // The capability query is advisory; the explicit SPP request below is authoritative.
                }
                if (!sppAdvertised) {
                    publish("Elead сообщил SPP-флаг=false. Не блокирую явный тест: запрашиваю сопряжение, затем попробую SPP (без HFP/A2DP)…");
                }
                beginPairOrSpp();
            } catch (RemoteException e) {
                failAndStop("Ошибка вызова штатного Elead Bluetooth-сервиса: " + safeMessage(e));
            }
        }

        @Override public void onServiceDisconnected(ComponentName name) {
            remote = null;
            eleadBinder = null;
            callbackRegistered = false;
            stopTcpServer();
            publish("Связь со штатным Elead Bluetooth-сервисом потеряна; мост остановлен.");
        }
    };

    private final BroadcastReceiver bondReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (!BluetoothDevice.ACTION_BOND_STATE_CHANGED.equals(intent.getAction())) return;
            BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
            if (device == null || address == null || !address.equalsIgnoreCase(device.getAddress())) return;
            int state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR);
            int previous = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR);
            if (state == BluetoothDevice.BOND_BONDED) {
                handler.removeCallbacks(pairTimeout);
                publish("Сопряжение создано. Запрашиваю только Bluetooth SPP (без HFP/A2DP)…");
                requestSppConnect();
            } else if (state == BluetoothDevice.BOND_BONDING) {
                publish("Идёт сопряжение. Подтвердите системный запрос, если он появился.");
            } else if (state == BluetoothDevice.BOND_NONE && previous == BluetoothDevice.BOND_BONDING) {
                handler.removeCallbacks(pairTimeout);
                failAndStop("Сопряжение отклонено или завершилось ошибкой; SPP не запускал.");
            }
        }
    };

    private final Runnable pairTimeout = new Runnable() {
        @Override public void run() {
            if (!isBonded()) failAndStop("Сопряжение не завершилось за 45 секунд. Проверьте системный запрос PIN/подтверждения; Torque пока не подключался.");
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        IntentFilter filter = new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        registerReceiver(bondReceiver, filter);
        bondReceiverRegistered = true;
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopBridge(true);
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        if (!ACTION_START.equals(action)) return START_NOT_STICKY;

        String requestedAddress = intent.getStringExtra(EXTRA_ADDRESS);
        if (!BluetoothAdapter.checkBluetoothAddress(requestedAddress)) {
            publish("Некорректный Bluetooth-адрес; мост не запускал.");
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        if (active && requestedAddress.equalsIgnoreCase(address)) {
            publish(status);
            return START_NOT_STICKY;
        }
        if (active) stopBridge(true);

        address = requestedAddress.toUpperCase();
        active = true;
        startForeground(NOTIFICATION_ID, makeNotification("Подключаю Elead SPP к " + address));
        publish("Подключаюсь к штатному Elead SPP-сервису…");
        bindEleadService();
        return START_NOT_STICKY;
    }

    private void bindEleadService() {
        Intent intent = new Intent(ELEAD_ACTION);
        intent.setComponent(new ComponentName(ELEAD_PACKAGE, ELEAD_SERVICE));
        try {
            bound = bindService(intent, eleadConnection, Context.BIND_AUTO_CREATE);
            if (!bound) failAndStop("Штатный Elead Bluetooth-сервис не найден или недоступен.");
        } catch (SecurityException e) {
            failAndStop("Android запретил подключение к Elead Bluetooth-сервису.");
        }
    }

    private void beginPairOrSpp() {
        if (remote == null || !active) return;
        if (isBonded()) {
            requestSppConnect();
            return;
        }
        publish("Запрашиваю сопряжение через штатный Elead-сервис. Если появится запрос, подтвердите его на ГУ.");
        try {
            boolean accepted = remote.requestPair(address);
            if (!accepted) {
                failAndStop("Штатный сервис не принял запрос сопряжения. Системные настройки не менялись.");
                return;
            }
            handler.removeCallbacks(pairTimeout);
            handler.postDelayed(pairTimeout, 45000L);
            if (isBonded()) {
                handler.removeCallbacks(pairTimeout);
                requestSppConnect();
            }
        } catch (RemoteException e) {
            failAndStop("Не удалось запросить сопряжение: " + safeMessage(e));
        }
    }

    private boolean isBonded() {
        try {
            BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
            if (adapter == null || address == null) return false;
            BluetoothDevice device = adapter.getRemoteDevice(address);
            return device.getBondState() == BluetoothDevice.BOND_BONDED;
        } catch (Exception e) {
            return false;
        }
    }

    private void requestSppConnect() {
        if (remote == null || !active || address == null) return;
        try {
            if (remote.isSppConnected(address)) {
                startTcpServer();
                return;
            }
            boolean accepted = remote.connectSpp(address);
            if (!accepted) {
                failAndStop("Elead SPP-сервис отклонил запрос подключения.");
                return;
            }
            publish("Запрос SPP отправлен; ожидаю соединение с ELM327…");
            pollSpp(0);
        } catch (RemoteException e) {
            failAndStop("Ошибка запроса SPP: " + safeMessage(e));
        }
    }

    private void pollSpp(final int attempt) {
        handler.postDelayed(new Runnable() {
            @Override public void run() {
                if (!active || remote == null) return;
                try {
                    if (remote.isSppConnected(address)) {
                        startTcpServer();
                    } else if (attempt < 40) {
                        pollSpp(attempt + 1);
                    } else {
                        failAndStop("SPP-соединение не установилось за 20 секунд.");
                    }
                } catch (RemoteException e) {
                    failAndStop("Не удалось проверить состояние SPP: " + safeMessage(e));
                }
            }
        }, attempt == 0 ? 500L : 500L);
    }

    private void startTcpServer() {
        if (!active || tcpRunning) return;
        tcpRunning = true;
        tcpThread = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    ServerSocket server = new ServerSocket();
                    server.setReuseAddress(true);
                    server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), TCP_PORT), 1);
                    serverSocket = server;
                    publish("SPP подключён; TCP 127.0.0.1:" + TCP_PORT + " готов. В Torque задайте тип WiFi и тот же IP/порт.");
                    while (tcpRunning) {
                        Socket client = server.accept();
                        client.setTcpNoDelay(true);
                        toTorque.clear();
                        tcpClient = client;
                        publish("Torque подключён к локальному TCP-мосту; данные идут через Elead SPP.");
                        startTcpOutputPump(client);
                        pumpTorqueToSpp(client);
                        closeClient(client);
                        if (tcpRunning) publish("TCP-клиент отключился; ожидаю Torque на 127.0.0.1:" + TCP_PORT + ".");
                    }
                } catch (Exception e) {
                    if (tcpRunning) failAndStop("Локальный TCP-мост не запустился: " + safeMessage(e));
                } finally {
                    stopTcpServer();
                }
            }
        }, "bt-bridge-tcp-server");
        tcpThread.setDaemon(true);
        tcpThread.start();
    }

    private void pumpTorqueToSpp(final Socket client) {
        byte[] buffer = new byte[512];
        try {
            InputStream input = client.getInputStream();
            int count;
            while (tcpRunning && !client.isClosed() && (count = input.read(buffer)) != -1) {
                if (count == 0) continue;
                byte[] data = new byte[count];
                System.arraycopy(buffer, 0, data, 0, count);
                EleadRemote current = remote;
                if (current == null || !active) throw new IllegalStateException("Elead service disconnected");
                current.sendSppData(address, data);
            }
        } catch (Exception e) {
            if (tcpRunning && !client.isClosed()) publish("TCP-клиент Torque завершил соединение: " + safeMessage(e));
        }
    }

    private void startTcpOutputPump(final Socket client) {
        Thread writer = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    OutputStream output = client.getOutputStream();
                    while (tcpRunning && tcpClient == client && !client.isClosed()) {
                        byte[] bytes = toTorque.poll(500L, TimeUnit.MILLISECONDS);
                        if (bytes != null) {
                            output.write(bytes);
                            output.flush();
                        }
                    }
                } catch (Exception e) {
                    if (tcpRunning && tcpClient == client) publish("Ошибка передачи данных в Torque: " + safeMessage(e));
                }
            }
        }, "bt-bridge-tcp-output");
        writer.setDaemon(true);
        writer.start();
    }

    private void onSppData(String fromAddress, byte[] bytes) {
        if (!active || address == null || !address.equalsIgnoreCase(fromAddress) || bytes == null || bytes.length == 0) return;
        if (tcpClient != null && !toTorque.offer(bytes.clone())) {
            publish("Переполнена очередь ответов SPP; часть данных отброшена. Остановите Torque и перезапустите мост.");
        }
    }

    private void closeClient(Socket client) {
        if (tcpClient == client) tcpClient = null;
        try { client.close(); } catch (Exception ignored) { }
    }

    private synchronized void stopTcpServer() {
        tcpRunning = false;
        Socket client = tcpClient;
        tcpClient = null;
        if (client != null) try { client.close(); } catch (Exception ignored) { }
        ServerSocket server = serverSocket;
        serverSocket = null;
        if (server != null) try { server.close(); } catch (Exception ignored) { }
        if (tcpThread != null) tcpThread.interrupt();
        tcpThread = null;
        toTorque.clear();
    }

    private void stopBridge(boolean disconnectSpp) {
        boolean wasActive = active || bound || remote != null || tcpRunning;
        active = false;
        handler.removeCallbacks(pairTimeout);
        stopTcpServer();
        if (remote != null && address != null) {
            try {
                if (disconnectSpp) remote.disconnectSpp(address);
            } catch (Exception ignored) { }
            if (callbackRegistered) {
                try { remote.unregisterCallback(getPackageName(), callback); } catch (Exception ignored) { }
            }
        }
        callbackRegistered = false;
        remote = null;
        eleadBinder = null;
        if (bound) {
            try { unbindService(eleadConnection); } catch (Exception ignored) { }
            bound = false;
        }
        stopForeground(true);
        if (wasActive) publish("Мост остановлен. Сопряжение Bluetooth сохранено; телефонные профили не тронуты.");
    }

    private void failAndStop(String message) {
        stopBridge(false);
        publish(message);
        stopSelf();
    }

    private Notification makeNotification(String text) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_menu_info_details)
                .setContentTitle("OBD Bluetooth Bridge")
                .setContentText(text)
                .setContentIntent(pending)
                .setOngoing(true)
                .build();
    }

    private void publish(String message) {
        status = message;
        getSharedPreferences("bridge", MODE_PRIVATE).edit().putString("status", message).commit();
        Intent intent = new Intent(ACTION_STATUS);
        intent.setPackage(getPackageName());
        intent.putExtra(EXTRA_STATUS, message);
        sendBroadcast(intent);
        if (active) {
            NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (manager != null) manager.notify(NOTIFICATION_ID, makeNotification(message));
        }
    }

    private String safeMessage(Exception e) {
        String message = e.getMessage();
        return message == null ? e.getClass().getSimpleName() : message;
    }

    @Override public void onDestroy() {
        if (active || bound || remote != null || tcpRunning) stopBridge(true);
        if (bondReceiverRegistered) {
            try { unregisterReceiver(bondReceiver); } catch (Exception ignored) { }
            bondReceiverRegistered = false;
        }
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    private final class VendorCallback extends Binder {
        VendorCallback() { attachInterface(null, EleadRemote.CALLBACK_DESCRIPTOR); }

        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            if (code == INTERFACE_TRANSACTION) {
                if (reply != null) reply.writeString(EleadRemote.CALLBACK_DESCRIPTOR);
                return true;
            }
            data.enforceInterface(EleadRemote.CALLBACK_DESCRIPTOR);
            switch (code) {
                case 86: // onSppStateChanged(address, uuid, state, previousState)
                    String stateAddress = data.readString();
                    data.readString();
                    int state = data.readInt();
                    int previous = data.readInt();
                    if (address != null && address.equalsIgnoreCase(stateAddress)) {
                        publish("Состояние Elead SPP изменилось: " + previous + " → " + state + ".");
                        handler.post(new Runnable() { @Override public void run() { pollSpp(0); } });
                    }
                    break;
                case 87: // onSppErrorResponse(address, errorCode)
                    String errorAddress = data.readString();
                    int errorCode = data.readInt();
                    if (address != null && address.equalsIgnoreCase(errorAddress)) {
                        publish("Elead SPP вернул ошибку " + errorCode + ".");
                    }
                    break;
                case 88: // retSppConnectedDeviceAddressList
                    data.readInt();
                    data.createStringArray();
                    data.createStringArray();
                    break;
                case 89: // onSppDataReceived(address, bytes)
                    String dataAddress = data.readString();
                    byte[] bytes = data.createByteArray();
                    onSppData(dataAddress, bytes);
                    break;
                case 90: // onSppSendData(address, result)
                    data.readString();
                    data.readInt();
                    break;
                case 91: // onSppAppleIapAuthenticationRequest(address)
                    data.readString();
                    break;
                default:
                    return super.onTransact(code, data, reply, flags);
            }
            if (reply != null) reply.writeNoException();
            return true;
        }
    }
}
