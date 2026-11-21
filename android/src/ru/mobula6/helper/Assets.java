package ru.mobula6.helper;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/** Страница приложения лежит внутри APK, в assets/index.html. */
public final class Assets {

    private Assets() {}

    public static byte[] index(Context ctx) {
        try (InputStream in = ctx.getAssets().open("index.html")) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
            return b.toByteArray();
        } catch (Exception e) {
            String msg = "<h1>Файл страницы не найден</h1><p>" + e.getMessage() + "</p>";
            return msg.getBytes();
        }
    }
}
