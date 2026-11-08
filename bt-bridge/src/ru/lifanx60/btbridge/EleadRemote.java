package ru.lifanx60.btbridge;

import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;

/** Minimal client for the verified Elead IelBluetoothService Binder API (Android 4.4 image). */
final class EleadRemote {
    static final String SERVICE_DESCRIPTOR = "com.nforetek.bt.aidl.IelBluetoothService";
    static final String CALLBACK_DESCRIPTOR = "com.nforetek.bt.aidl.IelBluetoothServiceCallback";

    // Transaction numbers recovered from the published service's Stub/Proxy code.
    private static final int TX_REGISTER_CALLBACK = 1;
    private static final int TX_UNREGISTER_CALLBACK = 2;
    private static final int TX_HAS_SPP_PROFILE = 9;
    private static final int TX_PAIR = 15;
    private static final int TX_SPP_CONNECT = 83;
    private static final int TX_SPP_DISCONNECT = 84;
    private static final int TX_SPP_IS_CONNECTED = 86;
    private static final int TX_SPP_SEND = 87;

    private final IBinder binder;

    EleadRemote(IBinder binder) {
        if (binder == null) throw new IllegalArgumentException("null Elead binder");
        this.binder = binder;
    }

    boolean hasSppProfile() throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(SERVICE_DESCRIPTOR);
            return transactBoolean(TX_HAS_SPP_PROFILE, data, reply);
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    boolean requestPair(String address) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(SERVICE_DESCRIPTOR);
            data.writeString(address);
            return transactBoolean(TX_PAIR, data, reply);
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    void registerCallback(String clientName, IBinder callback) throws RemoteException {
        transactClientCallback(TX_REGISTER_CALLBACK, clientName, callback);
    }

    void unregisterCallback(String clientName, IBinder callback) throws RemoteException {
        transactClientCallback(TX_UNREGISTER_CALLBACK, clientName, callback);
    }

    private void transactClientCallback(int code, String clientName, IBinder callback) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(SERVICE_DESCRIPTOR);
            data.writeString(clientName);
            data.writeStrongBinder(callback);
            if (!binder.transact(code, data, reply, 0)) throw new RemoteException("Elead callback transaction rejected: " + code);
            reply.readException();
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    boolean connectSpp(String address) throws RemoteException {
        return transactAddressBoolean(TX_SPP_CONNECT, address);
    }

    boolean disconnectSpp(String address) throws RemoteException {
        return transactAddressBoolean(TX_SPP_DISCONNECT, address);
    }

    boolean isSppConnected(String address) throws RemoteException {
        return transactAddressBoolean(TX_SPP_IS_CONNECTED, address);
    }

    private boolean transactAddressBoolean(int code, String address) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(SERVICE_DESCRIPTOR);
            data.writeString(address);
            return transactBoolean(code, data, reply);
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private boolean transactBoolean(int code, Parcel data, Parcel reply) throws RemoteException {
        if (!binder.transact(code, data, reply, 0)) throw new RemoteException("Elead transaction rejected: " + code);
        reply.readException();
        return reply.readInt() != 0;
    }

    void sendSppData(String address, byte[] bytes) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(SERVICE_DESCRIPTOR);
            data.writeString(address);
            data.writeByteArray(bytes);
            if (!binder.transact(TX_SPP_SEND, data, reply, 0)) throw new RemoteException("Elead SPP send rejected");
            reply.readException();
        } finally {
            reply.recycle();
            data.recycle();
        }
    }
}
