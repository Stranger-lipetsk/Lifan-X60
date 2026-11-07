package ru.lifanx60.adbsynclab;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Fixed, read-only synthetic fixture; lab only, never a device backup client. */
public final class SyntheticSyncClient {
    private static final String HOST = "127.0.0.1";
    private static final int PORT = 43127;
    private static final byte[] PATH = "/lab/root-only-synthetic.txt".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] EXPECTED = "X60 isolated synthetic root-only fixture\n".getBytes(StandardCharsets.US_ASCII);

    private static int code(String s) {
        byte[] b = s.getBytes(StandardCharsets.US_ASCII);
        if (b.length != 4) throw new IllegalArgumentException();
        return (b[0] & 255) | (b[1] & 255) << 8 | (b[2] & 255) << 16 | (b[3] & 255) << 24;
    }
    private static void writeInt(DataOutputStream out, int v) throws Exception { out.writeInt(Integer.reverseBytes(v)); }
    private static int readInt(DataInputStream in) throws Exception { return Integer.reverseBytes(in.readInt()); }
    private static int checksum(byte[] b) { int n = 0; for (byte x : b) n += x & 255; return n; }
    private static void send(DataOutputStream out, String cmd, int a, int b, byte[] data) throws Exception {
        int n = code(cmd);
        writeInt(out, n); writeInt(out, a); writeInt(out, b); writeInt(out, data.length);
        writeInt(out, checksum(data)); writeInt(out, ~n); out.write(data); out.flush();
    }
    private static final class Packet {
        int command, a, b; byte[] data;
        Packet(DataInputStream in) throws Exception {
            command = readInt(in); a = readInt(in); b = readInt(in);
            int len = readInt(in), sum = readInt(in), magic = readInt(in);
            if (len < 0 || len > 4096 || magic != ~command) throw new IllegalStateException("Bad packet");
            data = new byte[len]; in.readFully(data);
            if (checksum(data) != sum) throw new IllegalStateException("Bad checksum");
        }
    }
    /** Runs one fixed sync RECV. Returns true only when the exact fixture matched. */
    public static boolean readSyntheticFixture() throws Exception {
        Socket sock = new Socket();
        try {
            sock.connect(new InetSocketAddress(HOST, PORT), 5000);
            sock.setSoTimeout(10000);
            DataInputStream in = new DataInputStream(sock.getInputStream());
            DataOutputStream out = new DataOutputStream(sock.getOutputStream());
            send(out, "CNXN", 0x01000000, 4096, "host::\0".getBytes(StandardCharsets.US_ASCII));
            if (new Packet(in).command != code("CNXN")) throw new IllegalStateException("Auth or connection rejected");
            send(out, "OPEN", 1, 0, "sync:\0".getBytes(StandardCharsets.US_ASCII));
            Packet open = new Packet(in);
            if (open.command != code("OKAY") || open.b != 1 || open.a == 0) throw new IllegalStateException("Sync open failed");
            ByteArrayOutputStream req = new ByteArrayOutputStream();
            DataOutputStream sync = new DataOutputStream(req);
            sync.write("RECV".getBytes(StandardCharsets.US_ASCII)); writeInt(sync, PATH.length); sync.write(PATH);
            send(out, "WRTE", 1, open.a, req.toByteArray());
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            ByteArrayOutputStream result = new ByteArrayOutputStream();
            for (int count = 0; count < 30; count++) {
                Packet packet = new Packet(in);
                if (packet.command == code("OKAY")) continue;
                if (packet.command != code("WRTE") || packet.a != open.a || packet.b != 1) throw new IllegalStateException("Bad transport");
                send(out, "OKAY", 1, open.a, new byte[0]);
                buffer.write(packet.data);
                byte[] pending = buffer.toByteArray(); int offset = 0;
                while (pending.length - offset >= 8) {
                    int kind = (pending[offset] & 255) | (pending[offset+1] & 255) << 8 | (pending[offset+2] & 255) << 16 | (pending[offset+3] & 255) << 24;
                    int len = (pending[offset+4] & 255) | (pending[offset+5] & 255) << 8 | (pending[offset+6] & 255) << 16 | (pending[offset+7] & 255) << 24;
                    if (kind == code("DONE")) {
                        if (len != 0) throw new IllegalStateException("Bad done");
                        return Arrays.equals(result.toByteArray(), EXPECTED);
                    }
                    if ((kind != code("DATA") && kind != code("FAIL")) || len < 0 || len > 4096) throw new IllegalStateException("Bad sync reply");
                    if (pending.length - offset < 8 + len) break;
                    if (kind == code("FAIL")) return false;
                    result.write(pending, offset+8, len); offset += 8 + len;
                    if (result.size() > EXPECTED.length) throw new IllegalStateException("Oversized fixture");
                }
                buffer.reset(); buffer.write(pending, offset, pending.length - offset);
            }
            throw new IllegalStateException("Incomplete response");
        } finally { sock.close(); }
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 1 || (!args[0].equals("0") && !args[0].equals("1"))) throw new IllegalArgumentException();
        boolean read = readSyntheticFixture();
        if (read != args[0].equals("1")) throw new IllegalStateException("Unexpected access result");
        System.out.println("Java loopback synthetic sync: " + (read ? "exact match" : "denied"));
    }
}
