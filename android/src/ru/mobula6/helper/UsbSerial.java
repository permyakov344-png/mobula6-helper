package ru.mobula6.helper;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Build;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;

/**
 * Дрон по USB: поиск порта, открытие, обмен кадрами MSP.
 *
 * Betaflight представляется как USB CDC ACM (виртуальный COM-порт).
 * Драйвер в систему не входит, поэтому CDC-команды отправляем сами:
 * SET_LINE_CODING и SET_CONTROL_LINE_STATE. Без них контроллер не
 * начинает передавать данные.
 */
public final class UsbSerial {

    public static final int VID_STM = 0x0483;
    public static final int VID_BETAFPV = 0x2E3C;
    public static final int VID_ARDUINO = 0x2341;

    private static final String ACTION_USB_PERM = "ru.mobula6.helper.USB_PERM";

    private final Context ctx;
    private final UsbManager mgr;

    private UsbDeviceConnection conn;
    private UsbEndpoint epIn;
    private UsbEndpoint epOut;
    private UsbInterface iface;
    private UsbInterface commIface;
    private int commId = 0;
    private String openName;
    private int baud = 115200;
    private Activity act;

    private final Object ioLock = new Object();

    public UsbSerial(Context c) {
        this.ctx = c.getApplicationContext();
        this.mgr = (UsbManager) ctx.getSystemService(Context.USB_SERVICE);
    }

    /** Экран нужен, чтобы показать системный запрос доступа к USB. */
    public void setActivity(Activity a) {
        this.act = a;
    }

    /** Устройства, похожие на полётный контроллер. */
    public List<UsbDevice> candidates() {
        List<UsbDevice> out = new ArrayList<>();
        HashMap<String, UsbDevice> all = mgr.getDeviceList();
        for (UsbDevice d : all.values()) {
            int vid = d.getVendorId();
            boolean cdc = false;
            for (int i = 0; i < d.getInterfaceCount(); i++) {
                UsbInterface in = d.getInterface(i);
                if (in.getInterfaceClass() == UsbConstants.USB_CLASS_CDC_DATA
                        || in.getInterfaceClass() == 0x0A /* CDC */) {
                    cdc = true;
                }
            }
            if (vid == VID_STM || vid == VID_BETAFPV || vid == VID_ARDUINO || cdc) {
                out.add(d);
            }
        }
        return out;
    }

    public String describe() {
        List<UsbDevice> list = candidates();
        if (list.isEmpty()) return null;
        UsbDevice d = list.get(0);
        return String.format("%04X:%04X %s", d.getVendorId(), d.getProductId(),
                d.getProductName() == null ? "" : d.getProductName());
    }

    public boolean isOpen() {
        return conn != null;
    }

    public String portName() {
        return openName;
    }

    /** Открывает первое подходящее устройство. Возвращает null или текст ошибки. */
    public String open() {
        if (conn != null) return null;
        List<UsbDevice> list = candidates();
        if (list.isEmpty()) return "Дрон не найден. Проверь USB-кабель (нужен OTG).";

        UsbDevice dev = list.get(0);
        if (!mgr.hasPermission(dev)) {
            // Диалог показывает система. Ответ придёт в MainActivity.Receiver,
            // поэтому просим доступ и просим нажать кнопку ещё раз — иначе
            // человек не поймёт, почему «не подключилось».
            if (act != null) requestPermission(act, dev);
            return "Разреши доступ к дрону в окне на экране, потом нажми «Подключить дрон» ещё раз.";
        }
        return openDevice(dev);
    }

    public void requestPermission(Activity act, UsbDevice dev) {
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 0,
                new Intent(ACTION_USB_PERM), flags);
        mgr.requestPermission(dev, pi);
    }

    private String openDevice(UsbDevice dev) {
        // CDC-устройство состоит из двух интерфейсов: управляющего (класс 2,
        // через него идут команды скорости и DTR/RTS) и данных (класс 10,
        // в нём лежит пара bulk IN/OUT). Номер управляющего интерфейса нужен
        // как wIndex в controlTransfer — на части телефонов он не 0, и без
        // этого порт открывается, но молчит.
        UsbInterface dataIface = null;
        UsbInterface comm = null;
        UsbEndpoint in = null, out = null;
        for (int i = 0; i < dev.getInterfaceCount(); i++) {
            UsbInterface it = dev.getInterface(i);
            if (comm == null && it.getInterfaceClass() == UsbConstants.USB_CLASS_COMM) {
                comm = it;
            }
            UsbEndpoint a = null, b = null;
            for (int e = 0; e < it.getEndpointCount(); e++) {
                UsbEndpoint ep = it.getEndpoint(e);
                if (ep.getType() != UsbConstants.USB_ENDPOINT_XFER_BULK) continue;
                if (ep.getDirection() == UsbConstants.USB_DIR_IN) a = ep;
                else b = ep;
            }
            if (a != null && b != null && dataIface == null) {
                dataIface = it; in = a; out = b;
            }
        }
        if (dataIface == null) return "Устройство не похоже на дрон (нет COM-порта).";

        UsbDeviceConnection c = mgr.openDevice(dev);
        if (c == null) return "Не смог открыть USB. Закрой другие приложения с дроном.";

        // Управляющий интерфейс может отсутствовать (нестандартная сборка) —
        // тогда работаем как раньше, с номером 0.
        if (comm != null && !c.claimInterface(comm, true)) {
            c.close();
            return "USB занят другой программой.";
        }
        if (!c.claimInterface(dataIface, true)) {
            if (comm != null) c.releaseInterface(comm);
            c.close();
            return "USB занят другой программой.";
        }

        this.conn = c;
        this.epIn = in;
        this.epOut = out;
        this.iface = dataIface;
        this.commIface = comm;
        this.commId = comm == null ? 0 : comm.getId();
        this.openName = String.format("%04X:%04X", dev.getVendorId(), dev.getProductId());

        // CDC: сообщаем скорость и поднимаем линии DTR/RTS.
        setLineCoding(baud);
        setControlLines(true);

        synchronized (ioLock) {
            drainInput();
        }
        return null;
    }

    private void setLineCoding(int baudRate) {
        byte[] p = new byte[7];
        p[0] = (byte) (baudRate & 0xFF);
        p[1] = (byte) ((baudRate >> 8) & 0xFF);
        p[2] = (byte) ((baudRate >> 16) & 0xFF);
        p[3] = (byte) ((baudRate >> 24) & 0xFF);
        p[4] = 0; // 1 стоп-бит
        p[5] = 0; // без чётности
        p[6] = 8; // 8 бит
        control(0x20, 0, p);
    }

    private void setControlLines(boolean on) {
        control(0x22, on ? 0x03 : 0x00, null);
    }

    /** SET_LINE_CODING / SET_CONTROL_LINE_STATE уходят на управляющий интерфейс. */
    private void control(int request, int value, byte[] data) {
        try {
            conn.controlTransfer(0x21, request, value, commId,
                    data, data == null ? 0 : data.length, 1000);
        } catch (Exception ignored) {
        }
    }

    public void close() {
        synchronized (ioLock) {
            try {
                if (conn != null) {
                    setControlLines(false);
                    if (iface != null) conn.releaseInterface(iface);
                    if (commIface != null) conn.releaseInterface(commIface);
                    conn.close();
                }
            } catch (Exception ignored) {
            }
            conn = null; epIn = null; epOut = null; iface = null; commIface = null;
            commId = 0; openName = null;
        }
    }

    /** Отправляет кадр и ждёт ответ целиком (до таймаута). */
    public byte[] exchange(byte[] frame, int timeoutMs) {
        synchronized (ioLock) {
            if (conn == null) throw new IllegalStateException("Порт не открыт");
            try {
                int sent = conn.bulkTransfer(epOut, frame, frame.length, 2000);
                if (sent < 0) throw new IllegalStateException("Не смог отправить в дрон");
            } catch (Exception e) {
                throw new IllegalStateException("Не смог отправить в дрон: " + e.getMessage());
            }

            ByteArrayOutputStream acc = new ByteArrayOutputStream();
            byte[] buf = new byte[512];
            long end = System.currentTimeMillis() + timeoutMs;

            while (System.currentTimeMillis() < end) {
                int n;
                try {
                    n = conn.bulkTransfer(epIn, buf, buf.length, 120);
                } catch (Exception e) {
                    n = -1;
                }
                if (n > 0) {
                    acc.write(buf, 0, n);
                    byte[] got = acc.toByteArray();
                    int start = frameStart(got);
                    if (start >= 0) {
                        int need = frameLength(got, start);
                        if (need > 0 && got.length >= start + need) {
                            byte[] exact = new byte[need];
                            System.arraycopy(got, start, exact, 0, need);
                            return exact;
                        }
                    }
                }
            }
            return acc.toByteArray();
        }
    }

    /** Начало MSP-кадра в буфере, или -1. */
    public static int frameStart(byte[] b) {
        for (int i = 0; i + 2 < b.length; i++) {
            if (b[i] == '$' && (b[i + 1] == 'M' || b[i + 1] == 'X') && b[i + 2] == '>') {
                return i;
            }
        }
        return -1;
    }

    /** Полная длина MSP-кадра, начиная с start, или 0 если ещё не весь пришёл. */
    public static int frameLength(byte[] b, int start) {
        if (start < 0 || start + 3 >= b.length) return 0;
        if (b[start + 1] == 'M') {
            if (b.length < start + 5) return 0;
            int size = b[start + 3] & 0xFF;
            return 5 + size + 1;
        }
        if (b.length < start + 8) return 0;
        int size = (b[start + 6] & 0xFF) | ((b[start + 7] & 0xFF) << 8);
        return 8 + size + 1;
    }

    /** Полная длина первого MSP-кадра в буфере, или 0. */
    public static int frameLength(byte[] b) {
        int start = frameStart(b);
        if (start < 0) return 0;
        return frameLength(b, start);
    }

    private void drainInput() {
        if (conn == null || epIn == null) return;
        byte[] junk = new byte[512];
        for (int i = 0; i < 8; i++) {
            int n = conn.bulkTransfer(epIn, junk, junk.length, 20);
            if (n <= 0) break;
        }
    }

    /** Пробует MSP_API_VERSION: отвечает ли на этом порту дрон. */
    public boolean probe() {
        try {
            byte[] frame = Msp.frame(1, new byte[0]);
            byte[] reply = exchange(frame, 700);
            return reply != null && frameLength(reply) > 0;
        } catch (Exception e) {
            return false;
        }
    }

    public void resetInput() {
        synchronized (ioLock) {
            drainInput();
        }
    }
}
