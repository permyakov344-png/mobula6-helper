package ru.mobula6.helper;

/**
 * Кадры MSP v1 и v2 — те же, что в bridge.py и index.html.
 *
 * v1:  $M< | size(1) | cmd(1) | payload | XOR(size, cmd, payload)
 * v2:  $X< | flags(1) cmd(2) size(2) | payload | CRC8 (полином 0xD5)
 *
 * Полином именно 0xD5 (CRC8-DVB-S2): с 0x07 дрон молча игнорирует
 * v2-команды, и бинд «не срабатывает».
 */
public final class Msp {

    private Msp() {}

    public static byte[] frame(int cmd, byte[] payload) {
        if (payload == null) payload = new byte[0];
        if (cmd > 255) return frameV2(cmd, payload);
        return frameV1(cmd, payload);
    }

    public static byte[] frameV1(int cmd, byte[] payload) {
        int n = payload.length;
        byte[] out = new byte[6 + n];
        out[0] = '$'; out[1] = 'M'; out[2] = '<';
        out[3] = (byte) n;
        out[4] = (byte) cmd;
        System.arraycopy(payload, 0, out, 5, n);
        int chk = n ^ cmd;
        for (byte b : payload) chk ^= (b & 0xFF);
        out[5 + n] = (byte) (chk & 0xFF);
        return out;
    }

    public static byte[] frameV2(int cmd, byte[] payload) {
        int n = payload.length;
        byte[] body = new byte[5 + n];
        body[0] = 0;
        body[1] = (byte) (cmd & 0xFF);
        body[2] = (byte) ((cmd >> 8) & 0xFF);
        body[3] = (byte) (n & 0xFF);
        body[4] = (byte) ((n >> 8) & 0xFF);
        System.arraycopy(payload, 0, body, 5, n);

        byte[] out = new byte[3 + body.length + 1];
        out[0] = '$'; out[1] = 'X'; out[2] = '<';
        System.arraycopy(body, 0, out, 3, body.length);
        out[out.length - 1] = (byte) crc8(out, 3, body.length);
        return out;
    }

    /** CRC8-DVB-S2, полином 0xD5. */
    public static int crc8(byte[] data, int off, int len) {
        int crc = 0;
        for (int i = off; i < off + len; i++) {
            crc ^= (data[i] & 0xFF);
            for (int b = 0; b < 8; b++) {
                crc = ((crc & 0x80) != 0) ? ((crc << 1) ^ 0xD5) & 0xFF
                                          : (crc << 1) & 0xFF;
            }
        }
        return crc;
    }

    /** Данные из ответа: без заголовка и контрольной суммы. */
    public static byte[] payload(byte[] reply) {
        if (reply == null || reply.length < 6) return new byte[0];
        int start = -1;
        boolean v2 = false;
        for (int i = 0; i + 2 < reply.length; i++) {
            if (reply[i] == '$' && reply[i + 2] == '>'
                    && (reply[i + 1] == 'M' || reply[i + 1] == 'X')) {
                start = i; v2 = reply[i + 1] == 'X';
                break;
            }
        }
        if (start < 0) return new byte[0];

        if (!v2) {
            int size = reply[start + 3] & 0xFF;
            int from = start + 5;
            if (reply.length < from + size) return new byte[0];
            byte[] out = new byte[size];
            System.arraycopy(reply, from, out, 0, size);
            return out;
        }
        int size = (reply[start + 6] & 0xFF) | ((reply[start + 7] & 0xFF) << 8);
        int from = start + 8;
        if (reply.length < from + size) return new byte[0];
        byte[] out = new byte[size];
        System.arraycopy(reply, from, out, 0, size);
        return out;
    }

    public static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xFF));
        return sb.toString();
    }

    public static byte[] unhex(String s) {
        if (s == null) return new byte[0];
        int n = s.length() / 2;
        byte[] out = new byte[n];
        for (int i = 0; i < n; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }
}
