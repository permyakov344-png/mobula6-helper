#!/usr/bin/env python3
"""Собирает архивы для GitHub Releases: по одному на систему.

Зачем: в репозитории лежат готовые dfu-util под четыре системы и встроенный
Python для Windows (22 МБ). Скачивать всё это ради одного компьютера незачем,
поэтому в релиз кладутся отдельные архивы с понятными именами.

Запуск:  python3 tools/make-release.py            (архивы в dist/)
         python3 tools/make-release.py --version 1.0.0
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DIST = os.path.join(ROOT, "dist")

# Что кладём в каждый архив: (имя архива, папка внутри, список путей из корня)
COMMON = [
    "index.html",
    "bridge.py",
    "bridge.pl",
    "start.command",
    "start.bat",
    "README.md",
    "_lib",
    "docs",
]

# APK кладём в каждый архив, чтобы телефон можно было настроить из той же
# скачанной папки — отдельно его искать не нужно. Если APK ещё не собран,
# он просто не попадёт в архив.
APK = "dist/MobulaHelper.apk"

TARGETS = [
    ("Mobula6-Windows", "windows", ["runtime/win", "tools/win"]),
    ("Mobula6-macOS-AppleSilicon", "mac-arm64", ["tools/mac-arm64"]),
    ("Mobula6-macOS-Intel", "mac-x64", ["tools/mac-x64"]),
    ("Mobula6-Linux", "linux", ["tools/linux"]),
]

SKIP_NAMES = {".DS_Store", "__pycache__", "port.txt", "backups"}
EXEC = {0o755}


def walk(path):
    """Файлы внутри пути (или сам путь, если это файл)."""
    full = os.path.join(ROOT, path)
    if os.path.isfile(full):
        yield path, full
        return
    for base, dirs, files in os.walk(full):
        dirs[:] = [d for d in dirs if d not in SKIP_NAMES]
        for name in files:
            if name in SKIP_NAMES or name.endswith(".pyc"):
                continue
            rel = os.path.relpath(os.path.join(base, name), ROOT)
            yield rel, os.path.join(base, name)


def add(zf, rel, full, prefix):
    """Кладёт файл в архив, сохраняя бит исполнения и LF у .command/.pl."""
    arcname = os.path.join(prefix, rel)
    info = zipfile.ZipInfo.from_file(full, arcname)
    info.compress_type = zipfile.ZIP_DEFLATED
    mode = os.stat(full).st_mode & 0o777
    if rel.endswith((".command", ".pl")) or mode & 0o111:
        mode |= 0o755
    info.external_attr = (0o100000 | mode) << 16
    with open(full, "rb") as src:
        zf.writestr(info, src.read())


def build(version):
    os.makedirs(DIST, exist_ok=True)
    made = []
    for name, tag, extra in TARGETS:
        prefix = f"{name}-{version}"
        out = os.path.join(DIST, f"{prefix}.zip")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for rel in COMMON + extra:
                for rel_file, full in walk(rel):
                    add(zf, rel_file, full, prefix)
            apk = os.path.join(ROOT, APK)
            if os.path.isfile(apk):
                add(zf, "MobulaHelper.apk", apk, prefix)
            # короткая записка внутри архива: что делать дальше
            note = ("1. Распакуй папку целиком.\n"
                    f"2. {'Запусти start.bat (двойной клик)' if tag == 'windows' else 'Запусти start.command (двойной клик)'}.\n"
                    "3. Подключи дрон по USB и нажми «Подключить дрон».\n\n"
                    "Подробно — в README.md внутри папки.\n")
            info = zipfile.ZipInfo(os.path.join(prefix, "КАК-ЗАПУСТИТЬ.txt"))
            info.external_attr = (0o100000 | 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, note.encode("utf-8"))
        size = os.path.getsize(out)
        made.append((out, size))
        print(f"{os.path.basename(out):44} {size / 1048576:6.1f} МБ")
    return made


if __name__ == "__main__":
    ver = "1.0.0"
    if "--version" in sys.argv:
        ver = sys.argv[sys.argv.index("--version") + 1]
    build(ver)
