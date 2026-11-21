package ru.mobula6.helper;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.Bundle;
import android.view.ViewGroup;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.TextView;

import java.util.List;

/**
 * Единственный экран: WebView со страницей и локальный сервер на 127.0.0.1.
 *
 * Так страница остаётся той же самой, что и на компьютере: она ходит в
 * /api/*, а кто отвечает — Python на ноутбуке или этот файл на телефоне —
 * ей без разницы.
 */
public class MainActivity extends Activity {

    private static final String ACTION_USB_PERM = "ru.mobula6.helper.USB_PERM";

    private UsbSerial usb;
    private Bridge bridge;
    private WebView web;
    private TextView log;
    private final Receiver receiver = new Receiver();

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);

        usb = new UsbSerial(this);
        usb.setActivity(this);
        bridge = new Bridge(this, usb, this::say);

        log = new TextView(this);
        log.setTextSize(11);
        log.setPadding(24, 24, 24, 24);
        log.setText("Запускаю помощник…");

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        web.setWebViewClient(new WebViewClient());

        // Пока сервер не поднялся, показываем текст, потом — страницу.
        setContentView(log);

        receiver.activity = this;
        IntentFilter f = new IntentFilter(ACTION_USB_PERM);
        f.addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        f.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED);
        // EXPORTED, а не NOT_EXPORTED: разрешение на USB присылает система,
        // то есть другой процесс. С NOT_EXPORTED на Android 14 диалог
        // показывается, а ответ до приложения не доходит.
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, f, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(receiver, f);
        }

        Thread t = new Thread(bridge, "bridge");
        t.start();

        waitForPort(t);
        askPermissionIfNeeded();
    }

    /** Открывает страницу, когда сервер уже слушает порт. */
    private void waitForPort(Thread t) {
        Thread ui = new Thread(() -> {
            for (int i = 0; i < 100; i++) {
                if (bridge.isReady()) break;
                try {
                    Thread.sleep(50);
                } catch (InterruptedException ignored) {
                }
            }
            try {
                t.join(500);
            } catch (InterruptedException ignored) {
            }
            runOnUiThread(() -> {
                if (!bridge.isReady()) {
                    say("Не смог поднять локальный сервер: " + bridge.lastError());
                    return;
                }
                setContentView(web, new ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT));
                web.loadUrl("http://127.0.0.1:" + bridge.port() + "/");
            });
        }, "ui");
        ui.start();
    }

    /** Спрашивает у Android разрешение на доступ к дрону. */
    void askPermissionIfNeeded() {
        UsbManager mgr = (UsbManager) getSystemService(Context.USB_SERVICE);
        List<UsbDevice> list = usb.candidates();
        if (list.isEmpty()) {
            say("Дрон не найден. Воткни USB-кабель (нужен OTG-переходник).");
            return;
        }
        UsbDevice dev = list.get(0);
        if (mgr.hasPermission(dev)) {
            say("Дрон найден, доступ есть");
            return;
        }
        say("Спрашиваю доступ к дрону…");
        usb.requestPermission(this, dev);
    }

    void say(String line) {
        runOnUiThread(() -> {
            if (log != null) log.setText(line);
        });
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) {
            web.goBack();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        try { unregisterReceiver(receiver); } catch (Exception ignored) {}
        if (bridge != null) bridge.stop();
        if (usb != null) usb.close();
        if (web != null) web.destroy();
        super.onDestroy();
    }

    /**
     * Приёмник системных событий. Отдельным классом, а не анонимным:
     * d8 в build-tools 34 падает на анонимных классах в этой активности.
     */
    static final class Receiver extends BroadcastReceiver {
        MainActivity activity;

        @Override
        public void onReceive(Context c, Intent i) {
            if (activity == null) return;
            String a = i.getAction();
            if (ACTION_USB_PERM.equals(a)) {
                boolean ok = i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
                activity.say(ok ? "Доступ к дрону разрешён"
                        : "Доступ запрещён — нажми «Подключить дрон» ещё раз");
            } else if (UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(a)) {
                activity.say("Дрон подключён");
                activity.askPermissionIfNeeded();
            } else if (UsbManager.ACTION_USB_DEVICE_DETACHED.equals(a)) {
                activity.say("Дрон отключён");
                activity.usb.close();
            }
        }
    }
}
