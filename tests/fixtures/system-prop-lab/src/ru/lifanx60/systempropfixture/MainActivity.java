package ru.lifanx60.systempropfixture;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.util.Log;
import java.lang.reflect.Method;

/** Emulator-only fixture, not intended for distribution or real devices. */
public final class MainActivity extends Activity {
    private static final String TAG = "X60SystemPropLab";
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            Class<?> props = Class.forName("android.os.SystemProperties");
            Method get = props.getMethod("get", String.class, String.class);
            Method set = props.getMethod("set", String.class, String.class);
            String qemu = (String) get.invoke(null, "ro.kernel.qemu", "");
            if (!Build.FINGERPRINT.startsWith("generic") ||
                !(Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu")) || !qemu.equals("1")) {
                Log.e(TAG, "REFUSED_NON_EMULATOR");
                return;
            }
            if (getIntent().getBooleanExtra("firewall_probe", false)) {
                probeFirewall();
                return;
            }
            SharedPreferences saved = getSharedPreferences("synthetic-props", MODE_PRIVATE);
            if (getIntent().getBooleanExtra("restore", false)) {
                if (Process.myUid() != 1000 || !saved.getBoolean("saved", false)) {
                    Log.e(TAG, "RESTORE_REFUSED"); return;
                }
                String oldPort = saved.getString("port", "");
                String oldRoot = saved.getString("root", "");
                set.invoke(null, "service.adb.tcp.port", oldPort);
                set.invoke(null, "service.adb.root", oldRoot);
                String portAfter = (String) get.invoke(null, "service.adb.tcp.port", "");
                String rootAfter = (String) get.invoke(null, "service.adb.root", "");
                if (!oldPort.equals(portAfter) || !oldRoot.equals(rootAfter)) {
                    Log.e(TAG, "RESTORE_MISMATCH"); return;
                }
                Log.i(TAG, "SYNTHETIC_PROPERTIES_RESTORED");
                if (!saved.edit().clear().commit()) { Log.e(TAG, "STATE_CLEAR_FAILED"); return; }
                if (getIntent().getBooleanExtra("restart_daemon", false)) {
                    Log.i(TAG, "RESTORE_RESTART_REQUESTED");
                    set.invoke(null, "ctl.restart", "adbd");
                }
                return;
            }
            String before = (String) get.invoke(null, "service.adb.tcp.port", "");
            String rootBefore = (String) get.invoke(null, "service.adb.root", "");
            if (Process.myUid() == 1000) {
                if (saved.getBoolean("saved", false) || !saved.edit().putBoolean("saved", true)
                        .putString("port", before).putString("root", rootBefore).commit()) {
                    Log.e(TAG, "BASELINE_SAVE_FAILED"); return;
                }
            }
            try { set.invoke(null, "service.adb.tcp.port", "43127"); }
            catch (Exception error) { Log.i(TAG, "SET_EXCEPTION=" + error.getClass().getName()); }
            String after = (String) get.invoke(null, "service.adb.tcp.port", "");
            Log.i(TAG, "OWN_UID=" + Process.myUid() + " BEFORE=" + before + " AFTER=" + after);
            if (Process.myUid() == 1000 && after.equals("43127")) {
                set.invoke(null, "service.adb.root", "1");
                String root = (String) get.invoke(null, "service.adb.root", "");
                Log.i(TAG, "SYNTHETIC_ROOT_PROPERTY=" + root);
                if (root.equals("1") && getIntent().getBooleanExtra("restart_daemon", false)) {
                    Log.i(TAG, "RESTART_REQUESTED");
                    set.invoke(null, "ctl.restart", "adbd");
                } else {
                    Log.i(TAG, "NO_RESTART_REQUESTED");
                }
            }
        } catch (Exception error) { Log.e(TAG, "FIXTURE_ERROR", error); }
        finally { finish(); }
    }

    private void probeFirewall() {
        boolean enabled = false;
        try {
            if (Process.myUid() != 1000 ||
                checkCallingOrSelfPermission("android.permission.CONNECTIVITY_INTERNAL") !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED) {
                Log.e(TAG, "FIREWALL_REFUSED_UID_OR_PERMISSION"); return;
            }
            Class<?> serviceManager = Class.forName("android.os.ServiceManager");
            Object binder = serviceManager.getMethod("getService", String.class)
                .invoke(null, "network_management");
            if (binder == null) { Log.e(TAG, "FIREWALL_NO_NETWORK_MANAGEMENT_SERVICE"); return; }
            Class<?> stub = Class.forName("android.os.INetworkManagementService$Stub");
            Class<?> binderClass = Class.forName("android.os.IBinder");
            Object service = stub.getMethod("asInterface", binderClass).invoke(null, binder);
            Method isEnabled = service.getClass().getMethod("isFirewallEnabled");
            Method setEnabled = service.getClass().getMethod("setFirewallEnabled", boolean.class);
            Method setInterface = service.getClass().getMethod("setFirewallInterfaceRule", String.class, boolean.class);
            boolean wasEnabled = (Boolean) isEnabled.invoke(service);
            if (wasEnabled) { Log.e(TAG, "FIREWALL_REFUSED_ALREADY_ENABLED"); return; }
            java.util.Enumeration<java.net.NetworkInterface> interfaces = java.net.NetworkInterface.getNetworkInterfaces();
            String external = null;
            String externalAddress = null;
            while (interfaces != null && interfaces.hasMoreElements()) {
                java.net.NetworkInterface iface = interfaces.nextElement();
                if (iface.isLoopback() || !iface.isUp()) continue;
                java.util.Enumeration<java.net.InetAddress> addresses = iface.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    java.net.InetAddress address = addresses.nextElement();
                    if (address instanceof java.net.Inet4Address && !address.isLoopbackAddress()) {
                        external = iface.getName(); externalAddress = address.getHostAddress(); break;
                    }
                }
                if (external != null) break;
            }
            if (external == null) { Log.e(TAG, "FIREWALL_NO_EXTERNAL_IPV4_INTERFACE"); return; }
            java.net.ServerSocket server = new java.net.ServerSocket();
            try {
                server.setReuseAddress(true);
                server.bind(new java.net.InetSocketAddress(java.net.InetAddress.getByName("0.0.0.0"), 0));
                int port = server.getLocalPort();
                server.setSoTimeout(12000);
                enabled = true;
                setEnabled.invoke(service, true);
                setInterface.invoke(service, external, true);
                boolean blockedLoopback = !loopbackConnects("127.0.0.1", port);
                boolean blockedOwnAddress = !loopbackConnects(externalAddress, port);
                Log.i(TAG, "FIREWALL_DROP_LOOPBACK_WHILE_" + external + "_ALLOWED=" + blockedLoopback);
                Log.i(TAG, "FIREWALL_DROP_OWN_INTERFACE_ADDRESS=" + blockedOwnAddress + " address=" + externalAddress);
                if (!blockedLoopback || !blockedOwnAddress) { Log.e(TAG, "FIREWALL_LOCAL_ACCESS_NOT_BLOCKED"); return; }
                Log.i(TAG, "FIREWALL_REMOTE_WAITING_PORT=" + port + " interface=" + external);
                boolean remoteAccepted = acceptRemotePeer(server);
                Log.i(TAG, "FIREWALL_REMOTE_INTERFACE_ACCEPTED=" + remoteAccepted);
                if (!remoteAccepted) Log.e(TAG, "FIREWALL_REMOTE_INTERFACE_PROBE_FAILED");
                setInterface.invoke(service, "lo", true);
                boolean allowed = loopbackConnects("127.0.0.1", port);
                Log.i(TAG, "FIREWALL_ALLOW_LOOPBACK_CONTROL=" + allowed);
                if (!allowed) Log.e(TAG, "FIREWALL_ALLOW_RULE_FAILED");
            } finally {
                server.close();
            }
            setEnabled.invoke(service, false); enabled = false;
            Log.i(TAG, "FIREWALL_RESTORED_DISABLED=" + !(Boolean) isEnabled.invoke(service));
        } catch (Exception error) {
            Log.e(TAG, "FIREWALL_PROBE_ERROR", error);
        } finally {
            if (enabled) {
                try {
                    Class<?> serviceManager = Class.forName("android.os.ServiceManager");
                    Object binder = serviceManager.getMethod("getService", String.class)
                        .invoke(null, "network_management");
                    Class<?> stub = Class.forName("android.os.INetworkManagementService$Stub");
                    Class<?> binderClass = Class.forName("android.os.IBinder");
                    Object service = stub.getMethod("asInterface", binderClass).invoke(null, binder);
                    service.getClass().getMethod("setFirewallEnabled", boolean.class).invoke(service, false);
                    Log.i(TAG, "FIREWALL_CLEANUP_DISABLED");
                } catch (Exception cleanupError) {
                    Log.e(TAG, "FIREWALL_CLEANUP_FAILED", cleanupError);
                }
            }
        }
    }

    private boolean acceptRemotePeer(final java.net.ServerSocket server) throws InterruptedException {
        final boolean[] accepted = new boolean[] { false };
        Thread probe = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    java.net.Socket remote = server.accept();
                    try {
                        remote.getOutputStream().write("X60_FW_OK\n".getBytes("US-ASCII"));
                        remote.getOutputStream().flush();
                        accepted[0] = true;
                    } finally { remote.close(); }
                } catch (java.io.IOException ignored) { accepted[0] = false; }
            }
        }, "x60-firewall-remote-probe");
        probe.start();
        probe.join(13000);
        if (probe.isAlive()) probe.interrupt();
        return accepted[0];
    }

    private boolean loopbackConnects(final String host, final int port) throws InterruptedException {
        final boolean[] connected = new boolean[] { false };
        final boolean[] finished = new boolean[] { false };
        Thread probe = new Thread(new Runnable() {
            @Override public void run() {
                java.net.Socket client = new java.net.Socket();
                try {
                    client.connect(new java.net.InetSocketAddress(host, port), 1200);
                    connected[0] = true;
                } catch (java.io.IOException expected) {
                    connected[0] = false;
                } finally {
                    try { client.close(); } catch (java.io.IOException ignored) { }
                    finished[0] = true;
                }
            }
        }, "x60-firewall-loopback-probe");
        probe.start();
        probe.join(4000);
        if (probe.isAlive()) probe.interrupt();
        return finished[0] && connected[0];
    }
}
