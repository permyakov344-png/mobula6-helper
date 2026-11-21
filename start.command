#!/bin/bash
# Запуск помощника Mobula6: локальный помощник + браузер.
#
# Работает двумя путями:
#   * есть рабочий Python  -> bridge.py   (pyserial, ставится сам)
#   * Python нет (мак мини)-> bridge.pl   (Perl, на macOS есть всегда)
cd "$(dirname "$0")" || exit 1

fail() {
  echo
  echo "$1"
  echo
  read -r -p "Нажми Enter, чтобы закрыть..." _
  exit 1
}

# ---------------------------------------------------------------- выбор движка
#
# На новых macOS /usr/bin/python3 существует, но это заглушка: она открывает
# окно «установите инструменты разработчика». Поэтому сначала смотрим, есть ли
# настоящие инструменты, и только потом трогаем python3.
PY=""
PY_BIN="$(command -v python3 2>/dev/null)"
if [ -n "$PY_BIN" ]; then
  if [ "$PY_BIN" = "/usr/bin/python3" ]; then
    # системный python3 — заглушка, если нет инструментов разработчика.
    # Запускать его нельзя: он открывает окно установки.
    if xcode-select -p >/dev/null 2>&1; then
      PY="$PY_BIN"
    fi
  elif "$PY_BIN" -c "pass" >/dev/null 2>&1; then
    # другой Python (python.org, Homebrew) — проверяем, что он живой
    PY="$PY_BIN"
  fi
fi

if [ -n "$PY" ]; then
  # библиотека для USB может лежать рядом, в папке _lib
  if [ -d "_lib" ] && $PY -c "import sys; sys.path.insert(0,'_lib'); import serial" >/dev/null 2>&1; then
    echo "Библиотека для дрона: из папки _lib"
  elif $PY -c "import serial" >/dev/null 2>&1; then
    echo "Библиотека для дрона: уже установлена"
  else
    echo "Ставлю библиотеку для связи с дроном (pyserial)…"
    if ! $PY -m pip install --quiet --user pyserial >/dev/null 2>&1; then
      echo "Python есть, но библиотеку поставить не удалось."
      echo "Перехожу на версию без Python (Perl)."
      PY=""
    fi
  fi
fi

if [ -n "$PY" ]; then
  ENGINE="$PY bridge.py"
  ENGINE_NAME="Python"
elif command -v perl >/dev/null 2>&1; then
  # быстрая проверка, что Perl умеет всё нужное
  if perl -MPOSIX=:termios_h -MJSON::PP -MIO::Socket::INET -e 1 >/dev/null 2>&1; then
    ENGINE="perl bridge.pl"
    ENGINE_NAME="Perl (без установки)"
  else
    fail "Perl на этом компьютере неполный. Не могу запустить помощника."
  fi
else
  fail "Нет ни Python, ни Perl. Не могу запустить помощника."
fi

echo "Движок: $ENGINE_NAME"

# ---------------------------------------------------------------- уже запущен?
#
# Если помощник уже работает (прошлое окно не закрыли), второй запускать нельзя:
# два процесса начнут делить один USB-порт, и половина ответов дрона потеряется.
# Тогда просто открываем ту страницу, что уже есть.
existing_port() {
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  for p in $(seq 8000 8050); do
    if curl -fsS -m 1 "http://127.0.0.1:$p/api/ping" 2>/dev/null | grep -q '"bridge"'; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

OLD_PORT="$(existing_port)"
if [ -n "$OLD_PORT" ]; then
  URL="http://localhost:$OLD_PORT/index.html"
  echo
  echo "Помощник уже запущен — открываю его страницу:"
  echo "  $URL"
  echo
  echo "Второй раз запускать не нужно. Если хочешь перезапустить —"
  echo "закрой то окно консоли и запусти этот файл снова."
  if [ "$(uname -s)" = "Darwin" ]; then
    BROWSER=""
    for APP in "Google Chrome" "Microsoft Edge" "Chromium" "Yandex" "Opera" "Opera GX"; do
      if [ -d "/Applications/$APP.app" ]; then BROWSER="$APP"; break; fi
    done
    if [ -n "$BROWSER" ]; then open -a "$BROWSER" "$URL"; else open "$URL"; fi
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$URL" >/dev/null 2>&1 &
  fi
  read -r -p "Нажми Enter, чтобы закрыть..." _
  exit 0
fi

# ---------------------------------------------------------------- запуск
#
# Порт выбирает сам помощник и пишет его в port.txt — так адрес всегда верный,
# даже если 8000 занят другой программой.
rm -f port.txt
LOG="/tmp/mobula6_bridge.log"

$ENGINE 8000 >"$LOG" 2>&1 &
BRIDGE_PID=$!
trap 'kill "$BRIDGE_PID" 2>/dev/null' EXIT INT TERM

PORT=""
for _ in $(seq 1 120); do
  if [ -s port.txt ]; then
    PORT="$(cat port.txt 2>/dev/null | tr -dc '0-9')"
    [ -n "$PORT" ] && break
  fi
  sleep 0.15
done

if [ -z "$PORT" ]; then
  echo "Помощник не запустился. Лог:"
  cat "$LOG" 2>/dev/null
  fail "Попробуй запустить ещё раз."
fi

URL="http://localhost:$PORT/index.html"

# Проверяем, что страница уже отдаётся. Если curl на компьютере нет
# (бывает на минимальных Linux), просто верим помощнику: порт он уже написал.
READY=0
if command -v curl >/dev/null 2>&1; then
  for _ in $(seq 1 80); do
    if curl -fsS -o /dev/null "$URL" 2>/dev/null; then READY=1; break; fi
    sleep 0.15
  done
else
  READY=1
fi

if [ "$READY" -ne 1 ]; then
  echo "Помощник не отвечает. Лог:"
  cat "$LOG" 2>/dev/null
  fail "Попробуй запустить ещё раз."
fi

cat "$LOG"

# ---------------------------------------------------------------- браузер
#
# Web Serial нужен только как запасной путь — основной идёт через помощника,
# поэтому подойдёт любой браузер. Но Chromium-браузеры предпочтительнее.
BROWSER=""
for APP in "Google Chrome" "Microsoft Edge" "Chromium" "Yandex" "Opera" "Opera GX"; do
  if [ -d "/Applications/$APP.app" ]; then BROWSER="$APP"; break; fi
done

if [ "$(uname -s)" = "Darwin" ]; then
  if [ -n "$BROWSER" ]; then
    open -a "$BROWSER" "$URL"
  else
    open "$URL"
  fi
else
  # Linux: пробуем обычные способы открыть ссылку
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 &
  elif command -v gio >/dev/null 2>&1; then
    gio open "$URL" >/dev/null 2>&1 &
  elif [ -n "$BROWSER" ] && command -v "$BROWSER" >/dev/null 2>&1; then
    "$BROWSER" "$URL" >/dev/null 2>&1 &
  else
    echo "Открой в браузере адрес: $URL"
  fi
fi

wait "$BRIDGE_PID"
