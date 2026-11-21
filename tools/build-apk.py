#!/usr/bin/env python3
"""Собирает APK для Android без gradle — только build-tools из Android SDK.

  python3 tools/build-apk.py

Нужны:
  * JDK (javac, keytool)
  * Android SDK build-tools (aapt2, d8, zipalign, apksigner) и platforms/android-34

Пути ищутся автоматически; при желании можно задать переменными
ANDROID_HOME / JAVA_HOME.

Готовый файл: dist/MobulaHelper.apk
"""
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
AND = os.path.join(ROOT, "android")
SRC = os.path.join(AND, "src")
RES = os.path.join(AND, "res")
BUILD = os.path.join(AND, "build")
DIST = os.path.join(ROOT, "dist")
KEYSTORE = os.path.join(AND, "keystore", "mobula.jks")
KEYPASS = "mobula-helper"
ALIAS = "mobula"

PACKAGE = "ru.mobula6.helper"
APK_NAME = "MobulaHelper.apk"

_JAVA = []


def die(msg):
    print("ОШИБКА: " + msg)
    sys.exit(1)


def run(args, **kw):
    env = dict(os.environ)
    # Android build-tools (d8, aapt2, apksigner) — это скрипты, которым нужен
    # java в PATH, иначе «Unable to locate a Java Runtime».
    jh = _JAVA[0] if _JAVA else ""
    if jh:
        env["JAVA_HOME"] = os.path.dirname(jh)
        env["PATH"] = jh + os.pathsep + env.get("PATH", "")
    kw.setdefault("env", env)
    r = subprocess.run(args, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        print(" ".join(args))
        print((r.stdout or "")[-3000:])
        print((r.stderr or "")[-3000:])
        die("команда не выполнилась: " + args[0])
    return r


def find_java():
    if os.environ.get("JAVA_HOME"):
        cand = os.path.join(os.environ["JAVA_HOME"], "bin")
        if os.path.exists(os.path.join(cand, "javac")):
            return cand
    for base in ("/opt/homebrew/opt/openjdk/bin", "/usr/local/opt/openjdk/bin"):
        if os.path.exists(os.path.join(base, "javac")):
            return base
    javac = shutil.which("javac")
    if javac:
        return os.path.dirname(javac)
    die("не нашёл javac. Поставь JDK: brew install openjdk")


def find_sdk():
    roots = []
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(env):
            roots.append(os.environ[env])
    roots += [
        "/opt/homebrew/share/android-commandlinetools",
        "/usr/local/share/android-commandlinetools",
        os.path.expanduser("~/Library/Android/sdk"),
    ]
    for root in roots:
        if os.path.isdir(os.path.join(root, "build-tools")):
            return root
    die("не нашёл Android SDK. Поставь: brew install --cask android-commandlinetools")


def newest(dirpath):
    items = sorted(glob.glob(os.path.join(dirpath, "*")))
    items = [i for i in items if os.path.isdir(i)]
    if not items:
        return None
    return sorted(items, key=lambda p: [int(x) if x.isdigit() else 0
                                        for x in os.path.basename(p).replace("-", ".").split(".")])[-1]


def main():
    java = find_java()
    _JAVA.append(java)
    sdk = find_sdk()
    bt = newest(os.path.join(sdk, "build-tools"))
    plat = newest(os.path.join(sdk, "platforms"))
    if not bt:
        die("нет build-tools в " + sdk)
    if not plat:
        die("нет platforms в " + sdk)

    android_jar = os.path.join(plat, "android.jar")
    aapt2 = os.path.join(bt, "aapt2")
    d8 = os.path.join(bt, "d8")
    zipalign = os.path.join(bt, "zipalign")
    apksigner = os.path.join(bt, "apksigner")
    javac = os.path.join(java, "javac")
    keytool = os.path.join(java, "keytool")

    print("SDK:  " + sdk)
    print("tools: " + bt)
    print("java:  " + java)

    if os.path.isdir(BUILD):
        shutil.rmtree(BUILD)
    os.makedirs(BUILD)
    os.makedirs(DIST, exist_ok=True)

    # 1. ресурсы
    compiled = os.path.join(BUILD, "res.zip")
    run([aapt2, "compile", "--dir", RES, "-o", compiled])

    # 2. манифест + страница + ресурсы -> APK без кода
    gen = os.path.join(BUILD, "gen")
    os.makedirs(gen)
    assets = os.path.join(BUILD, "assets")
    os.makedirs(assets)
    shutil.copy2(os.path.join(ROOT, "index.html"), os.path.join(assets, "index.html"))

    base = os.path.join(BUILD, "base.apk")
    run([aapt2, "link",
         "-o", base,
         "-I", android_jar,
         "--manifest", os.path.join(AND, "AndroidManifest.xml"),
         "-R", compiled,
         "-A", assets,
         "--java", gen,
         "--min-sdk-version", "23",
         "--target-sdk-version", "34",
         "--version-code", "2",
         "--version-name", "1.1.0",
         "--auto-add-overlay"])

    # 3. компиляция Java
    r_java_files = glob.glob(os.path.join(gen, "**", "*.java"), recursive=True)
    if not r_java_files:
        die("aapt2 не сделал R.java — проверь манифест и res")
    java_files = glob.glob(os.path.join(SRC, "**", "*.java"), recursive=True) + r_java_files
    classes = os.path.join(BUILD, "classes")
    os.makedirs(classes)
    run([javac,
         "-Xlint:-options",
         "--release", "11",
         "-classpath", android_jar,
         "-d", classes] + java_files)

    # 4. dex
    classes_list = []
    for root, _dirs, files in os.walk(classes):
        for f in files:
            if f.endswith(".class"):
                classes_list.append(os.path.join(root, f))
    dex = os.path.join(BUILD, "dex")
    os.makedirs(dex)
    run([d8, "--lib", android_jar, "--min-api", "23",
         "--output", dex] + classes_list)

    # 5. код внутрь APK, потом выравнивание (порядок важен: zipalign
    #    должен идти после dex и до подписи, иначе apksigner ругается)
    unsigned = os.path.join(BUILD, "unsigned.apk")
    shutil.copy2(base, unsigned)
    import zipfile
    with zipfile.ZipFile(unsigned, "a", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(dex, "classes.dex"), "classes.dex")
    run([zipalign, "-f", "-p", "4", unsigned,
         os.path.join(BUILD, "aligned.apk")])

    # 6. ключ
    if not os.path.exists(KEYSTORE):
        os.makedirs(os.path.dirname(KEYSTORE), exist_ok=True)
        run([keytool, "-genkeypair", "-keystore", KEYSTORE,
             "-storepass", KEYPASS, "-keypass", KEYPASS,
             "-alias", ALIAS, "-keyalg", "RSA", "-keysize", "2048",
             "-validity", "10000",
             "-dname", "CN=Mobula Helper, OU=Fpv, O=Mobula, C=RU"])
        print("создан ключ: " + KEYSTORE)

    final = os.path.join(DIST, APK_NAME)
    if os.path.exists(final):
        os.remove(final)
    run([apksigner, "sign",
         "--ks", KEYSTORE,
         "--ks-pass", "pass:" + KEYPASS,
         "--key-pass", "pass:" + KEYPASS,
         "--ks-key-alias", ALIAS,
         "--out", final,
         os.path.join(BUILD, "aligned.apk")])
    run([apksigner, "verify", final])

    size = os.path.getsize(final) / 1024 / 1024
    print("\nГотово: %s (%.2f МБ)" % (final, size))
    print("Поставить на телефон: скопируй файл и открой (нужно разрешить установку из файлов).")


if __name__ == "__main__":
    main()
