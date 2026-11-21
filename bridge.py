#!/usr/bin/env python3
"""
Mobula6 — локальный помощник.

Отдаёт страницу приложения и даёт ей доступ к дрону по USB.
Так подключение работает без окна выбора порта: браузер вообще
не трогает USB, всё делает этот скрипт.

Запуск:  python3 bridge.py [порт]
"""
import http.server
import socketserver
import sys
import os
import json
import threading
import time
import binascii

# Кириллица в окне консоли: на Windows кодировка по умолчанию cp866/cp1251,
# и печать русского текста падала бы с UnicodeEncodeError.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

HERE = os.path.dirname(os.path.abspath(__file__))

# Библиотека pyserial может лежать рядом, в папке _lib —
# тогда на новом компьютере ничего не надо устанавливать.
_LIB = os.path.join(HERE, "_lib")
if os.path.isdir(_LIB) and _LIB not in sys.path:
    sys.path.insert(0, _LIB)

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("Нет pyserial. Выполни:  python3 -m pip install pyserial")
    sys.exit(1)
BAUD = 115200
FC_VID = 0x0483  # STM32 Virtual COM Port (Betaflight)

_lock = threading.Lock()
_ser = None
_port_name = None


def find_fc_ports():
    """Все последовательные порты, похожие на полётный контроллер.

    Работает одинаково на Windows (COM3, COM4…), macOS (/dev/cu.usbmodem…)
    и Linux (/dev/ttyACM0): у всех у них есть vid/pid или характерное имя.
    """
    found = []
    # Ручное указание порта: MOBULA6_PORT=/dev/ttyUSB0 (или COM5).
    # Нужно для редких случаев, когда порт называется нестандартно.
    forced = os.environ.get("MOBULA6_PORT", "").strip()
    if forced:
        # Если порт исчез (дрон отключили), не надо тащить его дальше —
        # иначе вместо «дрон не найден» будет техническая ошибка про файл.
        if forced.upper().startswith("COM") or os.path.exists(forced):
            found.append(forced)
    for p in list_ports.comports():
        dev = p.device or ""
        if not dev:
            continue
        if p.vid == FC_VID:
            found.append(dev)
            continue
        # Linux/macOS: имена виртуального COM-порта Betaflight
        low = dev.lower()
        if (dev.startswith("/dev/cu.usb") or dev.startswith("/dev/ttyACM")
                or dev.startswith("/dev/ttyUSB") or "usbmodem" in low
                or "usbserial" in low):
            found.append(dev)
            continue
        # Windows: описание устройства, если vid не отдался
        desc = (p.description or "").lower()
        if "betaflight" in desc or "stm32" in desc:
            found.append(dev)
    # убираем дубли, сохраняя порядок
    seen, out = set(), []
    for d in found:
        if d not in seen:
            seen.add(d)
            out.append(d)
    return out


def frame_len(buf):
    """Длина полного MSP-пакета в начале buf, либо None если он ещё не весь."""
    if len(buf) < 3:
        return None
    if buf[0] != 0x24:  # '$'
        return None
    kind = buf[1]
    if kind == 0x4D:  # 'M' — MSP v1: $M< size cmd payload crc
        if len(buf) < 6:
            return None
        size = buf[3]
        if size > 250:
            return None
        total = 6 + size
        return total if len(buf) >= total else None
    if kind == 0x58:  # 'X' — MSP v2: $X< flags cmd16 size16 payload crc
        if len(buf) < 9:
            return None
        size = buf[6] | (buf[7] << 8)
        total = 9 + size
        return total if len(buf) >= total else None
    return None


def read_reply(port, timeout):
    """Читает из порта до полного MSP-пакета или до таймаута."""
    end = time.time() + timeout
    buf = bytearray()
    while time.time() < end:
        try:
            chunk = port.read(256)
        except Exception:
            break
        if chunk:
            buf.extend(chunk)
            # ищем начало пакета и проверяем, собрался ли он
            i = buf.find(b"$")
            while i >= 0:
                sub = buf[i:]
                n = frame_len(sub)
                if n:
                    return bytes(sub[:n])
                i = buf.find(b"$", i + 1)
    return bytes(buf)


def msp_probe(port, timeout=0.6):
    """Проверяет, что в порту действительно дрон: шлёт MSP_API_VERSION.

    Без этой проверки за дрон легко принять любое USB-устройство
    (например, джойстик BETAFPV в режиме симулятора), которое просто
    сыплет своими данными в порт.
    """
    # flush() здесь нельзя: на некоторых портах он ждёт вечно
    # (джойстик ничего не вычитывает), и приложение зависает.
    deadline = time.time() + timeout
    end = deadline
    try:
        port.reset_input_buffer()
        port.write(b"$M<" + bytes([0, 1, 1]))   # MSP_API_VERSION
        while time.time() < end:
            try:
                chunk = port.read(256)
            except Exception:
                return None
            if not chunk:
                continue
            if b"$M>" in chunk:
                return chunk
            # чужое устройство может сыпать данными без остановки —
            # не даём ему растянуть проверку дольше отведённого времени
            end = min(end, time.time() + 0.15)
    except Exception:
        return None
    return None


def ensure_open(preferred=None):
    """Открывает дрон, если ещё не открыт. Возвращает имя порта."""
    global _ser, _port_name
    if _ser is not None and _ser.is_open:
        return _port_name

    candidates = [preferred] if preferred else []
    candidates += [p for p in find_fc_ports() if p != preferred]
    candidates = [c for c in candidates if c]

    if not candidates:
        raise RuntimeError("Дрон не найден. Проверь USB-кабель.")

    last = None
    wrong = []
    for dev in candidates:
        try:
            s = serial.Serial(dev, BAUD, timeout=0.05, write_timeout=1)
        except Exception as e:
            last = e
            continue

        if not msp_probe(s):
            # это не дрон (джойстик, модем, мышь) — закрываем и идём дальше
            wrong.append(dev)
            try:
                s.close()
            except Exception:
                pass
            continue

        s.reset_input_buffer()
        _ser = s
        _port_name = dev
        return dev

    if wrong and not last:
        raise RuntimeError(
            "Нашёл устройство, но это не дрон. "
            "Отключи режим джойстика (симулятора) и подключись снова."
        )
    raise RuntimeError(f"Не смог открыть порт: {last}")


def close_serial():
    global _ser, _port_name
    if _ser is not None:
        try:
            _ser.close()
        except Exception:
            pass
    _ser = None
    _port_name = None


# ---------------------------------------------------------------- CLI dump
#
# Обычный CLI Betaflight: в порт отправляется "#", дрон входит в консоль,
# потом "dump" печатает все настройки текстом. Это то же самое, что делает
# Betaflight Configurator, когда сохраняет бэкап.

def cli_run(cmd, wait=1.2, timeout=20.0):
    """Открывает консоль дрона, выполняет команду, возвращает текст ответа."""
    global _ser
    dev = ensure_open()
    s = _ser
    try:
        s.reset_input_buffer()
        s.write(b"#")
        time.sleep(0.15)
        s.write(b"#")
        time.sleep(0.15)
        s.write(b"\r\n")
        # баннер консоли — читаем, пока не замолчит
        _drain(s, wait)
        s.write(cmd.encode("ascii", "replace") + b"\r\n")

        buf = bytearray()
        end = time.time() + timeout
        idle_until = time.time() + 2.0
        while time.time() < end and time.time() < idle_until:
            chunk = s.read(4096)
            if chunk:
                buf.extend(chunk)
                idle_until = time.time() + 2.0
            else:
                continue
        return bytes(buf).decode("utf-8", "replace")
    finally:
        leave_cli(s)


def leave_cli(s):
    """Выводит дрон из консоли, чтобы дальше снова работал MSP.

    Новые прошивки (2026.x) понимают «exit noreboot» — выходят без перезагрузки.
    Старые на эту команду просто выходят из консоли, но перезагружаются.
    Поэтому после выхода ждём, пока порт снова начнёт отвечать по MSP.
    """
    try:
        s.write(b"exit noreboot\r\n")
        time.sleep(0.4)
    except Exception:
        pass
    try:
        s.close()
    except Exception:
        pass
    close_serial()

    end = time.time() + 10.0
    while time.time() < end:
        try:
            ensure_open()
            return
        except Exception:
            time.sleep(0.4)


def _drain(s, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            if not s.read(4096):
                continue
        except Exception:
            break


# ---------------------------------------------------------------- файлы
#
# Скачивание прошивки и сохранение дампов делаем здесь, а не в браузере:
# так файл лежит рядом с приложением и его сразу можно отдать прошивальщику.

def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, exist_ok=True)
    return path


def safe_name(name, default="file"):
    name = os.path.basename(str(name or default))
    name = name.replace("..", "_")
    keep = "-_. " 
    name = "".join(c for c in name if c.isalnum() or c in keep or ord(c) > 127)
    name = name.strip() or default
    return name[:120]


def download_file(url, name):
    """Скачивает файл в папку backups и возвращает путь."""
    import urllib.request

    folder = ensure_dir(os.path.join(HERE, "backups"))
    path = os.path.join(folder, safe_name(name))
    req = urllib.request.Request(url, headers={"User-Agent": "Mobula6Helper/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as f:
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            f.write(chunk)
    return path


def find_dfu_util():
    """Ищет dfu-util: сначала рядом с приложением, потом в системе.

    В папке tools лежат готовые копии для Windows, macOS (Intel и Apple Silicon)
    и Linux — тогда прошивать можно без установки чего-либо.
    """
    exe_name = "dfu-util.exe" if os.name == "nt" else "dfu-util"
    # Ручное указание прошивальщика: MOBULA6_DFU=/путь/к/dfu-util
    forced = os.environ.get("MOBULA6_DFU", "").strip()
    if forced and os.path.isfile(forced):
        return forced
    if os.name == "nt":
        subs = (os.path.join("tools", "win"), "tools", "")
    elif sys.platform == "darwin":
        import platform as _pf
        arm = _pf.machine() in ("arm64", "aarch64")
        first = os.path.join("tools", "mac-arm64" if arm else "mac-x64")
        subs = (first, os.path.join("tools", "mac-arm64"),
                os.path.join("tools", "mac-x64"), "tools", "")
    else:
        subs = (os.path.join("tools", "linux"), "tools", "")

    for sub in subs:
        p = os.path.join(HERE, sub, exe_name) if sub else os.path.join(HERE, exe_name)
        if os.path.isfile(p):
            try:
                if os.name != "nt":
                    os.chmod(p, 0o755)
            except Exception:
                pass
            return p

    from shutil import which
    for n in (["dfu-util.exe", "dfu-util"] if os.name == "nt" else ["dfu-util"]):
        p = which(n)
        if p:
            return p
    return None


def dfu_ready():
    """Есть ли прошивальщик и что он о себе говорит."""
    exe = find_dfu_util()
    return {"found": bool(exe), "path": exe or "",
            "os": os.name, "platform": sys.platform}


def list_dfu_devices(exe, timeout=6):
    """Список DFU-устройств по версии dfu-util (без разбора --list, он разный)."""
    import subprocess
    try:
        out = subprocess.run([exe, "-l"], capture_output=True, text=True,
                             timeout=timeout, errors="replace")
        return (out.stdout or "") + (out.stderr or "")
    except Exception as e:
        return ""


def flash_hex(path):
    """Шьёт .hex через dfu-util. Дрон должен уйти в загрузчик: см. enter_dfu()."""
    import subprocess

    exe = find_dfu_util()
    if not exe:
        return {"ok": False, "error": "no-dfu-tool",
                "log": "Не найден dfu-util — программа, которая пишет прошивку в дрон."}
    if not os.path.isfile(path):
        return {"ok": False, "error": "no-file", "log": "Файл прошивки не найден: " + path}

    cmd = [exe, "-a", "0", "-d", "0483:df11", "-s", "0x08000000:leave", "-D", path]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180,
                             errors="replace")
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout", "log": "Прошивка не закончилась за 3 минуты."}
    log = (out.stdout or "") + (out.stderr or "")
    return {"ok": out.returncode == 0, "error": "" if out.returncode == 0 else "dfu-failed",
            "log": log, "cmd": " ".join(cmd)}


def enter_dfu():
    """Переводит дрон в режим загрузчика: MSP_REBOOT с кодом 1."""
    dev = ensure_open()
    s = _ser
    s.reset_input_buffer()
    # $M< size cmd payload crc;  crc = size ^ cmd ^ payload
    payload = bytes([MSP_REBOOT_BOOTLOADER])
    body = bytes([len(payload), MSP_REBOOT]) + payload
    chk = 0
    for b in body:
        chk ^= b
    s.write(b"$M<" + body + bytes([chk]))
    time.sleep(0.3)
    try:
        s.read(64)
    except Exception:
        pass
    close_serial()
    time.sleep(1.5)
    return dev


MSP_REBOOT = 68
MSP_REBOOT_BOOTLOADER = 1


def wait_for_dfu(exe, seconds=15):
    end = time.time() + seconds
    while time.time() < end:
        txt = list_dfu_devices(exe)
        if "0483:df11" in txt.lower().replace(" ", ""):
            return True
        if "[0483:df11]" in txt:
            return True
        time.sleep(0.5)
    return False


# ---------------------------------------------------------------- прошивки
#
# Список версий берём с build.betaflight.com — там официальные сборки под
# конкретную плату. Файл качаем с GitHub releases, имя собирается по плате.

BF_API = "https://build.betaflight.com/api"
BF_RELEASES = "https://github.com/betaflight/betaflight/releases/download"


def _get_json(url, timeout=20):
    import urllib.request

    req = urllib.request.Request(url, headers={
        "User-Agent": "Mobula6Helper/1.0",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def _open_url(url, timeout=60):
    import urllib.request

    req = urllib.request.Request(url, headers={"User-Agent": "Mobula6Helper/1.0"})
    return urllib.request.urlopen(req, timeout=timeout)


def _target_names(target, board=None, fallback=None):
    """Имена, под которыми плату знает сервер Betaflight.

    В прошивках 2026.x поле target в MSP_BOARD_INFO — это имя чипа
    (STM32F411), а название платы лежит в boardName (CRAZYBEEF4SX1280).
    Сервер знает только название платы, поэтому нужное имя выбираем здесь.
    """
    names = []
    for n in (board, target, fallback):
        n = (n or "").strip()
        if not n or n in names:
            continue
        # Имя чипа сервер не знает — такие варианты отбрасываем сразу.
        if n.upper().startswith(("STM32", "AT32")):
            continue
        if "/" in n or "\\" in n:
            continue
        names.append(n)
    return names


def firmware_list(target, board=None, fallback=None):
    """Версии прошивки для платы, свежие сверху."""
    names = _target_names(target, board, fallback)
    if not names:
        return {"ok": False,
                "error": "Не понял, какая у тебя плата. Нажми «Подключить дрон» заново."}

    errors = []
    for name in names:
        try:
            data = _get_json(f"{BF_API}/targets/{name}")
        except Exception as e:
            errors.append(f"{name}: {e}")
            continue

        releases = data.get("releases") or []
        out = []
        for r in releases:
            if r.get("withdrawn"):
                continue
            out.append({
                "release": r.get("release"),
                "type": r.get("type") or "",
                "date": r.get("date") or "",
                "unstable": (r.get("type") or "") != "Stable",
            })

        if not out:
            errors.append(f"{name}: список пуст")
            continue

        out.sort(key=lambda x: _ver_key(x["release"]), reverse=True)
        return {"ok": True, "target": name, "board": name, "releases": out}

    return {"ok": False,
            "error": "Сервер прошивок не знает такую плату. " + "; ".join(errors[:3])}


def _ver_key(s):
    parts = []
    for p in str(s or "").replace("-", ".").split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    while len(parts) < 4:
        parts.append(0)
    return tuple(parts)


def firmware_url(target, release):
    """Прямая ссылка на .hex официальной сборки.

    Имя файла в релизах выглядит так:
      betaflight_2026.6.2_STM32F411_CRAZYBEEF4SX1280.hex
    Микроконтроллер берём из API сборок, без него имени не собрать.
    """
    target = (target or "CRAZYBEEF4SX1280").strip()
    if target.upper().startswith(("STM32", "AT32")):
        target = "CRAZYBEEF4SX1280"
    rel = str(release or "").strip()
    if not rel:
        return None

    mcu = ""
    try:
        info = _get_json(f"{BF_API}/builds/{rel}/{target}")
        mcu = (info.get("mcu") or "").strip()
    except Exception:
        mcu = ""

    cands = []
    if mcu:
        cands.append(f"{BF_RELEASES}/{rel}/betaflight_{rel}_{mcu}_{target}.hex")
    # запасные варианты: без MCU и с частыми STM32
    cands.append(f"{BF_RELEASES}/{rel}/betaflight_{rel}_{target}.hex")
    for m in ("STM32F411", "STM32F405", "STM32F745", "STM32H743"):
        cands.append(f"{BF_RELEASES}/{rel}/betaflight_{rel}_{m}_{target}.hex")

    for url in cands:
        try:
            import urllib.request
            req = urllib.request.Request(
                url, method="HEAD",
                headers={"User-Agent": "Mobula6Helper/1.0"})
            with urllib.request.urlopen(req, timeout=20) as r:
                if getattr(r, "status", 200) == 200:
                    return url
        except Exception:
            continue
    return cands[0]



def firmware_get(target, release):
    """Скачивает .hex в backups."""
    url = firmware_url(target, release)
    if not url:
        return {"ok": False, "error": "не выбрана версия"}

    name = url.rsplit("/", 1)[-1] or f"betaflight_{release}_{target}.hex"
    try:
        path = download_file(url, name)
    except Exception as e:
        return {"ok": False, "error": f"Не скачалось: {e}"}

    size = os.path.getsize(path)
    if size < 50000:
        try:
            os.remove(path)
        except Exception:
            pass
        return {"ok": False, "error": "Файл слишком маленький — похоже, этой версии нет"}

    return {"ok": True, "path": path, "size": size, "url": url}



class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    # ---------- GET ----------
    def end_headers(self):
        # Страница меняется при обновлении приложения, поэтому браузер
        # не должен держать её в кэше: иначе он показывает старую версию
        # и «не видит» исправлений.
        self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    def do_GET(self):
        if self.path.startswith("/api/ping"):
            with _lock:
                ports = find_fc_ports()
                self._json({
                    "ok": True,
                    "bridge": True,
                    "ports": ports,
                    "open": _ser is not None and _ser.is_open,
                    "active": _port_name,
                    "os": os.name,
                    "platform": sys.platform,
                    "dfu": dfu_ready(),
                })
            return
        if self.path.startswith("/api/ports"):
            self._json({"ports": find_fc_ports()})
            return
        if self.path.startswith("/api/dfu"):
            self._json(dfu_ready())
            return
        super().do_GET()

    # ---------- POST ----------
    def do_POST(self):
        if self.path.startswith("/api/connect"):
            data = self._body()
            with _lock:
                try:
                    close_serial()
                    dev = ensure_open(data.get("port"))
                    self._json({"ok": True, "port": dev})
                except Exception as e:
                    self._json({"ok": False, "error": str(e)}, 200)
            return

        if self.path.startswith("/api/disconnect"):
            with _lock:
                close_serial()
            self._json({"ok": True})
            return

        # ---- бэкап настроек: CLI dump в файл ----
        if self.path.startswith("/api/dump"):
            data = self._body()
            with _lock:
                try:
                    text = cli_run("dump", wait=2.0, timeout=25.0)
                except Exception as e:
                    self._json({"ok": False, "error": str(e)}, 200)
                    return
            if len(text.strip()) < 200:
                self._json({"ok": False, "error": "Дрон не отдал настройки",
                            "text": text[:2000]}, 200)
                return
            folder = ensure_dir(os.path.join(HERE, "backups"))
            name = safe_name(data.get("name") or "dump.txt", "dump.txt")
            path = os.path.join(folder, name)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            self._json({"ok": True, "path": path, "size": len(text), "text": text})
            return

        # ---- список прошивок ----
        if self.path.startswith("/api/firmware/list"):
            data = self._body()
            self._json(firmware_list(data.get("target"), data.get("board"),
                                     data.get("fallback")), 200)
            return

        # ---- скачать прошивку ----
        if self.path.startswith("/api/firmware/get"):
            data = self._body()
            self._json(firmware_get(data.get("target"), data.get("release")), 200)
            return

        # ---- скачать прошивку в папку backups ----
        if self.path.startswith("/api/download"):
            data = self._body()
            url = data.get("url") or ""
            if not url.startswith("http"):
                self._json({"ok": False, "error": "Плохая ссылка"}, 200)
                return
            try:
                path = download_file(url, data.get("name") or "firmware.hex")
            except Exception as e:
                self._json({"ok": False, "error": str(e)}, 200)
                return
            self._json({"ok": True, "path": path,
                        "size": os.path.getsize(path)}, 200)
            return

        # ---- прошить дрон ----
        if self.path.startswith("/api/flash"):
            data = self._body()
            path = data.get("path") or ""
            # Сначала проверяем файл: обидно перезагрузить дрон в загрузчик
            # ради того, чтобы потом узнать, что прошивки-то нет.
            if not path or not os.path.isfile(path):
                self._json({"ok": False, "error": "no-file",
                            "log": "Файл прошивки не найден: " + (path or "(пусто)")}, 200)
                return
            exe = find_dfu_util()
            if not exe:
                self._json({"ok": False, "error": "no-dfu-tool",
                            "log": "Не найден dfu-util — программа, которая пишет прошивку в дрон."}, 200)
                return
            with _lock:
                try:
                    step1 = enter_dfu()
                except Exception as e:
                    self._json({"ok": False, "error": "Не смог перевести дрон в загрузчик",
                                "log": str(e)}, 200)
                    return
            entered = wait_for_dfu(exe, 15)
            if not entered:
                self._json({"ok": False, "error": "no-dfu-device",
                            "log": "Дрон не появился в режиме загрузчика. "
                                   "Попробуй зажать кнопку BOOT при подключении USB."}, 200)
                return
            res = flash_hex(path)
            res["entered"] = entered
            self._json(res, 200)
            return

        if self.path.startswith("/api/msp"):
            data = self._body()
            frame_hex = data.get("frame", "")
            timeout = float(data.get("timeout", 1.5)) / 1000.0
            try:
                frame = binascii.unhexlify(frame_hex)
            except Exception:
                self._json({"ok": False, "error": "bad frame"}, 400)
                return

            with _lock:
                try:
                    dev = ensure_open(data.get("port"))
                    _ser.reset_input_buffer()
                    _ser.write(frame)
                    _ser.flush()
                    reply = read_reply(_ser, timeout)
                    self._json({
                        "ok": True,
                        "port": dev,
                        "reply": binascii.hexlify(reply).decode("ascii"),
                    })
                except Exception as e:
                    close_serial()
                    self._json({"ok": False, "error": str(e)}, 200)
            return

        self._json({"ok": False, "error": "unknown"}, 404)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def find_running_bridge(start, count=60):
    """Уже запущенный помощник на одном из портов start..start+count.

    Два помощника на одном компьютере — плохо: они делят USB-порт дрона,
    ответы MSP достаются то одному, то другому, и приложение решает,
    что дрона нет. Поэтому второй экземпляр не запускается, а открывает
    уже работающий.
    """
    import urllib.request
    for port in range(start, start + count):
        try:
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/api/ping", timeout=0.35) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
            if isinstance(data, dict) and data.get("bridge"):
                return port, data
        except Exception:
            continue
    return None, None


def main():
    args = [a for a in sys.argv[1:]]
    open_browser = "--open" in args
    args = [a for a in args if not a.startswith("-")]
    start = int(args[0]) if args else 8000

    # Уже есть работающий помощник? Тогда второй не нужен: он только
    # помешает, забрав себе часть ответов дрона.
    old_port, old_info = find_running_bridge(start)
    if old_port:
        try:
            with open(os.path.join(HERE, "port.txt"), "w", encoding="utf-8") as f:
                f.write(str(old_port))
        except Exception:
            pass
        print("=" * 46)
        print(f"  Помощник уже запущен: http://localhost:{old_port}/index.html")
        print("=" * 46)
        print()
        print("Второй раз запускать не нужно — открой страницу по адресу выше.")
        print("Если что-то не работает, закрой то окно консоли и запусти снова.")
        print()
        sys.stdout.flush()
        if open_browser:
            try:
                import webbrowser
                webbrowser.open(f"http://localhost:{old_port}/index.html")
            except Exception:
                pass
        return

    httpd = None
    port = start
    for _ in range(60):
        try:
            # только этот компьютер: браузеру хватает localhost,
            # а лишний вопрос «разрешить доступ в сеть?» на Windows не появится
            httpd = Server(("127.0.0.1", port), Handler)
            break
        except OSError:
            port += 1
    if httpd is None:
        print("Не нашёл свободный порт.")
        sys.exit(1)

    # Скрипт запуска читает этот файл, чтобы открыть браузер на верном адресе.
    try:
        with open(os.path.join(HERE, "port.txt"), "w", encoding="utf-8") as f:
            f.write(str(port))
    except Exception:
        pass

    ports = find_fc_ports()
    print("=" * 46)
    print(f"  Адрес: http://localhost:{port}/index.html")
    print("=" * 46)
    print()
    if ports:
        print("Дрон виден: " + ", ".join(ports))
    else:
        print("Дрон пока не виден. Вставь USB-кабель.")
    print()
    print("Это окно не закрывай, пока настраиваешь дрон.")
    print("Остановить: Ctrl+C")
    print()
    sys.stdout.flush()

    # --open: сразу открыть страницу в браузере. Так запуск на Windows
    # обходится без второго bat-файла и лишних окон.
    if open_browser:
        try:
            import webbrowser
            webbrowser.open(f"http://localhost:{port}/index.html")
        except Exception:
            pass

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        close_serial()
        httpd.server_close()


if __name__ == "__main__":
    main()
