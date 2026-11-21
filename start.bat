@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

title Mobula6 - помощник

rem ============================================================
rem  Запуск помощника на Windows: двойной клик по этому файлу.
rem
rem  Python ставить не нужно — он лежит рядом, в папке
rem  runtime\win\python. Если рядом его нет, берём системный.
rem
rem  Это окно должно оставаться открытым: закроешь — помощник
rem  остановится.
rem ============================================================

set "PYCMD="

rem ---- 1. Python, который идёт в комплекте ----
if not exist "runtime\win\python\python.exe" goto try_py
"runtime\win\python\python.exe" -c "pass" >nul 2>nul
if errorlevel 1 goto try_py
set "PYCMD=runtime\win\python\python.exe"
goto python_ready

rem ---- 2. системный Python ----
:try_py
py -3 -c "pass" >nul 2>nul
if not errorlevel 1 set "PYCMD=py -3"
if defined PYCMD goto python_ready

:try_python
python -c "pass" >nul 2>nul
if not errorlevel 1 set "PYCMD=python"
if defined PYCMD goto python_ready

:try_python3
python3 -c "pass" >nul 2>nul
if not errorlevel 1 set "PYCMD=python3"
if defined PYCMD goto python_ready

echo.
echo Не нашёл Python.
echo.
echo Проверь, что папка runtime\win\python на месте: она идёт в комплекте.
echo Если её нет, установи Python с сайта python.org и запусти снова.
echo.
pause
exit /b 1

:python_ready
rem ---- библиотека для USB (pyserial) ----
rem  Обычно она уже лежит рядом, в папке _lib: bridge.py берёт её оттуда сам.
if exist "_lib\serial\__init__.py" goto have_serial
%PYCMD% -c "import serial" >nul 2>nul
if not errorlevel 1 goto have_serial

echo Ставлю библиотеку для связи с дроном (pyserial)…
%PYCMD% -m pip install --quiet --user pyserial >nul 2>nul
%PYCMD% -c "import serial" >nul 2>nul
if not errorlevel 1 goto have_serial

echo.
echo Python есть, но библиотеку поставить не удалось.
echo Проверь интернет и запусти снова.
echo.
pause
exit /b 1

:have_serial
echo Движок: Python
echo.

if exist "port.txt" del "port.txt" >nul 2>nul

rem Помощник сам откроет страницу в браузере и напишет адрес.
%PYCMD% bridge.py 8000 --open

echo.
echo Помощник остановлен. Запусти этот файл снова, если нужен.
pause
exit /b 0
