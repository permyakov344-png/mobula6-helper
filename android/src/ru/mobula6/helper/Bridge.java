package ru.mobula6.helper;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Маленький HTTP-сервер на 127.0.0.1 — тот же, что bridge.py на компьютере.
 *
 * Зачем: страница (index.html) не умеет Web Serial в Android WebView.
 * Она общается с помощником по /api/*, и ей всё равно, кто отвечает —
 * Python на ноутбуке или этот сервер на телефоне. Поэтому страница
 * одна и та же на всех платформах.
 */
public final class Bridge implements Runnable {

    public interface Logger {
        void log(String line);
    }

    private final Context ctx;
    private final UsbSerial usb;
    private final Logger log;
    private ServerSocket server;
    private int port = 8060;
    private volatile boolean running;
    private volatile String err;

    public Bridge(Context c, UsbSerial u, Logger l) {
        this.ctx = c;
        this.usb = u;
        this.log = l;
    }

    public int port() { return port; }

    public boolean isReady() { return running; }

    public String lastError() { return err == null ? "неизвестная ошибка" : err; }

    public void stop() {
        running = false;
        try { if (server != null) server.close(); } catch (Exception ignored) {}
    }

    @Override
    public void run() {
        try {
            server = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"));
            port = server.getLocalPort();
            running = true;
            log.log("Сервер: http://127.0.0.1:" + port);
            while (running) {
                Socket s = server.accept();
                new Thread(() -> handle(s), "http").start();
            }
        } catch (Exception e) {
            err = e.getMessage();
            if (running) log.log("Сервер остановлен: " + e.getMessage());
        }
    }

    private void handle(Socket s) {
        try {
            s.setSoTimeout(30000);
            InputStream in = s.getInputStream();
            OutputStream out = s.getOutputStream();

            String head = readHead(in);
            if (head == null || head.isEmpty()) { s.close(); return; }

            String[] lines = head.split("\r\n");
            String[] first = lines[0].split(" ");
            String method = first[0];
            String path = first.length > 1 ? first[1] : "/";

            int clen = 0;
            for (String l : lines) {
                if (l.toLowerCase().startsWith("content-length:")) {
                    clen = Integer.parseInt(l.substring(15).trim());
                }
            }
            byte[] body = new byte[clen];
            int got = 0;
            while (got < clen) {
                int n = in.read(body, got, clen - got);
                if (n <= 0) break;
                got += n;
            }

            String json = route(path, new String(body, StandardCharsets.UTF_8));
            if (json == null) {
                byte[] page = Assets.index(ctx);
                send(out, 200, "text/html; charset=utf-8", page);
            } else {
                send(out, 200, "application/json; charset=utf-8",
                        json.getBytes(StandardCharsets.UTF_8));
            }
            s.close();
        } catch (Exception e) {
            try { s.close(); } catch (Exception ignored) {}
        }
    }

    private String readHead(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int prev3 = -1, prev2 = -1, prev1 = -1, cur;
        while ((cur = in.read()) >= 0) {
            b.write(cur);
            if (prev3 == '\r' && prev2 == '\n' && prev1 == '\r' && cur == '\n') break;
            prev3 = prev2; prev2 = prev1; prev1 = cur;
            if (b.size() > 65536) break;
        }
        return b.toString("UTF-8");
    }

    private void send(OutputStream out, int code, String type, byte[] body)
            throws IOException {
        String head = "HTTP/1.1 " + code + " OK\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + body.length + "\r\n"
                + "Cache-Control: no-store, must-revalidate\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.UTF_8));
        out.write(body);
        out.flush();
    }

    // ------------------------------------------------------------- маршруты

    private String route(String path, String body) {
        Map<String, String> q = Json.parse(body);

        String clean = path;
        int qm = clean.indexOf('?');
        if (qm >= 0) clean = clean.substring(0, qm);

        if (clean.equals("/api/ping")) {
            Map<String, Object> m = new LinkedTree();
            m.put("ok", true);
            m.put("bridge", true);
            m.put("android", true);
            m.put("open", usb.isOpen());
            m.put("active", usb.portName());
            m.put("ports", usb.describe() == null ? new Object[0]
                    : new Object[]{usb.describe()});
            // на Android dfu-util нет — прошивать с телефона нельзя
            Map<String, Object> dfu = new LinkedTree();
            dfu.put("found", false);
            dfu.put("path", "");
            dfu.put("android", true);
            m.put("dfu", dfu);
            return Json.write(m);
        }

        if (clean.equals("/api/connect")) {
            String err = usb.open();
            Map<String, Object> m = new LinkedTree();
            if (err != null) {
                m.put("ok", false);
                m.put("error", err);
            } else {
                m.put("ok", true);
                m.put("port", usb.portName());
            }
            return Json.write(m);
        }

        if (clean.equals("/api/disconnect")) {
            usb.close();
            Map<String, Object> m = new LinkedTree();
            m.put("ok", true);
            return Json.write(m);
        }

        if (clean.equals("/api/msp")) {
            String frameHex = q.get("frame");
            int timeout = 1500;
            try { timeout = (int) Double.parseDouble(q.get("timeout")); } catch (Exception ignored) {}
            if (timeout <= 0) timeout = 1500;

            Map<String, Object> m = new LinkedTree();
            try {
                usb.resetInput();
                byte[] reply = usb.exchange(Msp.unhex(frameHex), timeout);
                m.put("ok", true);
                m.put("port", usb.portName());
                m.put("reply", Msp.hex(reply));
            } catch (Exception e) {
                m.put("ok", false);
                m.put("error", e.getMessage() == null ? "нет связи" : e.getMessage());
            }
            return Json.write(m);
        }

        // На Android прошивка и дамп через CLI недоступны: нет dfu-util и
        // нет полноценного CLI-моста. Отвечаем понятно, а не молчим.
        if (clean.startsWith("/api/firmware") || clean.startsWith("/api/download")
                || clean.startsWith("/api/flash") || clean.startsWith("/api/dfu")
                || clean.startsWith("/api/dump")) {
            Map<String, Object> m = new LinkedTree();
            m.put("ok", false);
            m.put("error", "Прошивка и бэкап настроек — только на компьютере. "
                    + "С телефона можно всё настроить, но не прошивать.");
            return Json.write(m);
        }

        return null; // всё остальное — файл страницы
    }

    /** Простая карта с сохранением порядка ключей. */
    static final class LinkedTree extends java.util.LinkedHashMap<String, Object> {}

    static final class Json {
        static Map<String, String> parse(String s) {
            Map<String, String> out = new HashMap<>();
            if (s == null || s.trim().isEmpty()) return out;
            // намеренно простой разбор: нам присылают плоский объект строк
            String t = s.trim();
            if (t.startsWith("{")) t = t.substring(1);
            if (t.endsWith("}")) t = t.substring(0, t.length() - 1);
            for (String part : t.split(",")) {
                int i = part.indexOf(':');
                if (i < 0) continue;
                String k = part.substring(0, i).trim().replaceAll("^\"|\"$", "");
                String v = part.substring(i + 1).trim().replaceAll("^\"|\"$", "");
                out.put(k, v);
            }
            return out;
        }

        static String write(Object o) {
            StringBuilder sb = new StringBuilder();
            writeTo(sb, o);
            return sb.toString();
        }

        private static void writeTo(StringBuilder sb, Object o) {
            if (o == null) { sb.append("null"); return; }
            if (o instanceof Map) {
                sb.append('{');
                boolean first = true;
                for (Map.Entry<?, ?> e : ((Map<?, ?>) o).entrySet()) {
                    if (!first) sb.append(',');
                    first = false;
                    sb.append('"').append(esc(String.valueOf(e.getKey()))).append("\":");
                    writeTo(sb, e.getValue());
                }
                sb.append('}');
            } else if (o instanceof Object[]) {
                sb.append('[');
                boolean first = true;
                for (Object x : (Object[]) o) {
                    if (!first) sb.append(',');
                    first = false;
                    writeTo(sb, x);
                }
                sb.append(']');
            } else if (o instanceof Number || o instanceof Boolean) {
                sb.append(o);
            } else {
                sb.append('"').append(esc(String.valueOf(o))).append('"');
            }
        }

        private static String esc(String s) {
            StringBuilder b = new StringBuilder();
            for (char c : s.toCharArray()) {
                switch (c) {
                    case '"': b.append("\\\""); break;
                    case '\\': b.append("\\\\"); break;
                    case '\n': b.append("\\n"); break;
                    case '\r': b.append("\\r"); break;
                    case '\t': b.append("\\t"); break;
                    default:
                        if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                        else b.append(c);
                }
            }
            return b.toString();
        }
    }
}
