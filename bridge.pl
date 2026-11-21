#!/usr/bin/perl
#
# Mobula6 — локальный помощник (версия на Perl).
#
# Нужен на компьютерах, где нет Python: на macOS Perl есть всегда.
# Делает то же, что bridge.py: отдаёт страницу и говорит с дроном по USB.
#
# Запуск:  perl bridge.pl [порт]

use strict;
use warnings;
use utf8;
use POSIX qw(:termios_h);
use JSON::PP;
use IO::Socket::INET;
use HTTP::Tiny;
use FindBin qw($RealBin);
use File::Spec;

my $HERE = $RealBin;
my $BAUD = 115200;

# русский текст в консоли — в UTF-8, иначе Perl ругается на wide character
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $SER;          # файловый дескриптор порта
my $SER_NAME;     # имя порта
my $LAST_PORT;    # последний рабочий порт — чтобы вернуться к нему после консоли

# ---------------------------------------------------------------- порт дрона

sub find_fc_ports {
    my @found;

    # Ручное указание порта: MOBULA6_PORT=/dev/ttyUSB0 (или COM5).
    my $forced = $ENV{MOBULA6_PORT} // '';
    $forced =~ s/^\s+|\s+$//g;
    # Если порт исчез (дрон отключили), дальше его не тащим — иначе вместо
    # «дрон не найден» будет техническая ошибка про отсутствующий файл.
    push @found, $forced if length $forced && ($forced =~ /^COM/i || -e $forced);

    if ($^O eq 'MSWin32') {
        # Windows: COM-порты. Дрон обычно называется «USB Serial Device»
        # или «Betaflight», но проще перебрать всё, что помощник увидит.
        for my $n (1 .. 64) {
            push @found, "COM$n" if -e "\\\\.\\COM$n";
        }
        return @found;
    }

    opendir(my $dh, '/dev') or return @found;
    while (defined(my $f = readdir $dh)) {
        next unless $f =~ /^cu\./;
        next unless $f =~ /usbmodem|usbserial|SLAB_USBtoUART|wchusbserial|usb\./;
        push @found, "/dev/$f";
    }
    closedir $dh;
    return @found;
}

sub msp_probe {
    my ($fh, $timeout) = @_;
    $timeout = 0.6 unless defined $timeout;

    my $probe = pack('C*', 0x24, 0x4D, 0x3C, 0x00, 0x01, 0x01);   # MSP_API_VERSION
    my $written = syswrite($fh, $probe);
    return 0 unless defined $written && $written == length($probe);

    my $end = time() + $timeout;
    my $buf = '';
    while (time() < $end) {
        my $rin = '';
        vec($rin, fileno($fh), 1) = 1;
        my $rout = $rin;
        my $wait = ($end - time()) < 0.05 ? ($end - time()) : 0.05;
        next unless select($rout, undef, undef, $wait) > 0;

        my $chunk = '';
        my $got = sysread($fh, $chunk, 256);
        last unless defined $got && $got > 0;
        $buf .= $chunk;

        # настоящий дрон отвечает заголовком $M>
        return 1 if index($buf, "\x24\x4D\x3E") >= 0;
    }
    return 0;
}

sub open_serial {
    my ($want) = @_;

    if (defined $SER) {
        return $SER_NAME;
    }

    my @cands = ();
    push @cands, $want if $want;
    push @cands, find_fc_ports();
    my %seen;
    @cands = grep { !$seen{$_}++ } @cands;

    die "Дрон не найден. Проверь USB-кабель.\n" unless @cands;

    my $err = '';
    my @wrong;
    for my $dev (@cands) {
        next unless -e $dev;

        my $fh;
        # O_NOCTTY обязателен: иначе порт станет управляющим терминалом процесса
        if (!sysopen($fh, $dev, POSIX::O_RDWR() | POSIX::O_NOCTTY())) {
            $err = "$dev: $!";
            next;
        }

        my $t = POSIX::Termios->new();
        if (!$t->getattr(fileno($fh))) {
            $err = "$dev: не прочитать настройки";
            close $fh;
            next;
        }

        # raw-режим: без эха, без построчной обработки, 8 бит
        $t->setiflag(IGNBRK | IGNPAR);
        $t->setoflag(0);
        $t->setlflag(0);
        $t->setcflag(CS8 | CREAD | CLOCAL);
        $t->setcc(VMIN, 0);
        $t->setcc(VTIME, 0);
        $t->setispeed($BAUD);
        $t->setospeed($BAUD);

        if (!$t->setattr(fileno($fh), TCSANOW())) {
            $err = "$dev: не применить настройки";
            close $fh;
            next;
        }

        # Проверяем, что это правда дрон. Иначе за него можно принять
        # джойстик (режим симулятора) или другое USB-устройство.
        if (!msp_probe($fh)) {
            push @wrong, $dev;
            close $fh;
            next;
        }

        $SER = $fh;
        $SER_NAME = $dev;
        return $dev;
    }

    if (@wrong && !$err) {
        die "Нашёл устройство, но это не дрон. Отключи режим джойстика (симулятора) и подключись снова.\n";
    }
    die "Не смог открыть порт: $err\n";
}

sub close_serial {
    if (defined $SER) {
        close $SER;
    }
    $SER = undef;
    $SER_NAME = undef;
}

# ---------------------------------------------------------------- CLI dump

sub drain_serial {
    my ($seconds) = @_;
    my $end = time() + $seconds;
    while (time() < $end) {
        my $rin = '';
        vec($rin, fileno($SER), 1) = 1;
        my $rout = $rin;
        my $wait = ($end - time());
        $wait = 0.1 if $wait > 0.1;
        last unless select($rout, undef, undef, $wait) > 0;
        my $junk = '';
        last unless sysread($SER, $junk, 4096);
    }
}

# Входит в консоль дрона («#»), выполняет команду и возвращает её текст.
sub cli_run {
    my ($cmd, $wait, $timeout) = @_;
    $wait = 1.5 unless defined $wait;
    $timeout = 25 unless defined $timeout;

    open_serial();

    my $junk = '';
    while (1) {
        my $rin = '';
        vec($rin, fileno($SER), 1) = 1;
        my $rout = $rin;
        last unless select($rout, undef, undef, 0) > 0;
        last unless sysread($SER, $junk, 4096);
    }

    syswrite($SER, '#');
    select(undef, undef, undef, 0.15);
    syswrite($SER, '#');
    select(undef, undef, undef, 0.15);
    syswrite($SER, "\r\n");
    drain_serial($wait);

    syswrite($SER, $cmd . "\r\n");

    my $buf = '';
    my $end = time() + $timeout;
    my $idle = time() + 2.0;
    while (time() < $end && time() < $idle) {
        my $rin = '';
        vec($rin, fileno($SER), 1) = 1;
        my $rout = $rin;
        my $ok = select($rout, undef, undef, 0.2);
        next unless $ok && $ok > 0;
        my $chunk = '';
        my $got = sysread($SER, $chunk, 4096);
        last unless defined $got && $got > 0;
        $buf .= $chunk;
        $idle = time() + 2.0;
    }

    # «exit noreboot» выводит из консоли без перезагрузки (прошивки 2026.x).
    # Старые прошивки на неё просто выходят, но перезагружаются — поэтому
    # после выхода ждём, пока дрон снова начнёт отвечать по MSP.
    eval { syswrite($SER, "exit noreboot\r\n"); select(undef, undef, undef, 0.4) };
    close_serial();

    my $back = time() + 10;
    while (time() < $back) {
        last if eval { open_serial(); 1 };
        select(undef, undef, undef, 0.4);
    }
    return $buf;
}

# ---------------------------------------------------------------- прошивки

my $BF_API      = 'https://build.betaflight.com/api';
my $BF_RELEASES = 'https://github.com/betaflight/betaflight/releases/download';

sub http_get {
    my ($url, $timeout) = @_;
    $timeout = 30 unless defined $timeout;
    # curl есть и на macOS, и на Linux, и на Windows 10+.
    # Он сам проверяет сертификаты, поэтому HTTPS остаётся безопасным.
    my $curl = `curl --version 2>/dev/null`;
    if ($curl) {
        my $tmp = File::Spec->catfile(File::Spec->tmpdir, "mobula6_" . int(rand(1_000_000)));
        my $code = `curl -sS -L --max-time $timeout -A Mobula6Helper -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null`;
        if ($code =~ /^(\d+)$/ && $1 == 200 && -f $tmp) {
            my $data = '';
            if (open(my $fh, '<:raw', $tmp)) { local $/; $data = <$fh>; close $fh; }
            unlink $tmp;
            return ($data, 200);
        }
        unlink $tmp if -f $tmp;
        return (undef, $code || 0);
    }
    my $ua = HTTP::Tiny->new(timeout => $timeout, agent => 'Mobula6Helper/1.0');
    my $r = $ua->get($url);
    return (undef, $r->{status}) unless $r->{success};
    return ($r->{content}, 200);
}

# Скачивание файла: curl — иначе HTTP::Tiny.
sub http_download {
    my ($url, $path, $timeout) = @_;
    $timeout = 120 unless defined $timeout;
    my $curl = `curl --version 2>/dev/null`;
    if ($curl) {
        my $code = `curl -sS -L --max-time $timeout -A Mobula6Helper -o "$path" -w '%{http_code}' "$url" 2>/dev/null`;
        return ($code =~ /^(\d+)$/ && $1 == 200) ? 1 : 0;
    }
    my $ua = HTTP::Tiny->new(timeout => $timeout, agent => 'Mobula6Helper/1.0');
    my $r = $ua->mirror($url, $path);
    return $r->{success} ? 1 : 0;
}

sub ver_key {
    my ($s) = @_;
    my @p = map { /^\d+$/ ? $_ : 0 } split /\./, ($s // '');
    push @p, 0 while @p < 4;
    return join('.', map { sprintf('%05d', $_) } @p[0 .. 3]);
}

sub firmware_list {
    my ($target, $board, $fallback) = @_;

    # В прошивках 2026.x поле target в MSP_BOARD_INFO — имя чипа (STM32F411),
    # а название платы лежит в boardName (CRAZYBEEF4SX1280). Сервер знает
    # только название платы, поэтому нужное имя выбираем здесь.
    my @names;
    for my $n ($board, $target, $fallback) {
        next unless defined $n && length $n;
        next if $n =~ /^(STM32|AT32)/i;   # имя чипа серверу не нужно
        next if $n =~ m{[/\\]};
        next if grep { $_ eq $n } @names;
        push @names, $n;
    }

    return { ok => JSON::PP::false,
             error => 'Не понял, какая у тебя плата. Нажми «Подключить дрон» заново.' }
        unless @names;

    my @errors;
    for my $name (@names) {
        $name =~ s/[^A-Za-z0-9_]//g;
        next unless length $name;

        my ($body, $code) = http_get("$BF_API/targets/$name");
        if (!defined $body) {
            push @errors, "$name (код $code)";
            next;
        }

        my $data = eval { JSON::PP->new->utf8->decode($body) };
        if (!$data || !$data->{releases}) {
            push @errors, "$name (непонятный ответ)";
            next;
        }

        my @out;
        for my $r (@{ $data->{releases} }) {
            next if $r->{withdrawn};
            next unless $r->{release};
            push @out, {
                release  => "$r->{release}",
                type     => "$r->{type}" // '',
                date     => "$r->{date}" // '',
                unstable => (($r->{type} // '') ne 'Stable') ? JSON::PP::true : JSON::PP::false,
            };
        }

        if (!@out) {
            push @errors, "$name (список пуст)";
            next;
        }

        @out = sort { ver_key($b->{release}) cmp ver_key($a->{release}) } @out;
        return { ok => JSON::PP::true, target => $name, board => $name, releases => \@out };
    }

    return { ok => JSON::PP::false,
             error => 'Сервер прошивок не знает такую плату: ' . join('; ', @errors[0 .. ($#errors > 2 ? 2 : $#errors)]) };
}

sub backup_dir {
    my $dir = File::Spec->catdir($HERE, 'backups');
    mkdir $dir unless -d $dir;
    return $dir;
}

sub firmware_url {
    my ($target, $release) = @_;
    $target  = 'CRAZYBEEF4SX1280' unless $target;
    $target  = 'CRAZYBEEF4SX1280' if $target =~ /^(STM32|AT32)/i;
    $release = '' unless defined $release;
    $target  =~ s/[^A-Za-z0-9_]//g;
    $release =~ s/[^A-Za-z0-9._-]//g;
    return undef unless $release;

    my $mcu = '';
    my ($body) = http_get("$BF_API/builds/$release/$target", 20);
    if (defined $body) {
        my $info = eval { JSON::PP->new->utf8->decode($body) };
        $mcu = $info->{mcu} if $info && $info->{mcu};
    }
    $mcu =~ s/[^A-Za-z0-9]//g if $mcu;

    # Сначала проверяем, какой файл реально есть в релизе.
    my @cands;
    push @cands, "betaflight_${release}_${mcu}_${target}.hex" if $mcu;
    push @cands, "betaflight_${release}_${target}.hex";
    push @cands, map { "betaflight_${release}_${_}_${target}.hex" }
        qw(STM32F411 STM32F405 STM32F745 STM32H743);

    for my $f (@cands) {
        my ($h) = http_get_head("$BF_RELEASES/$release/$f");
        return "$BF_RELEASES/$release/$f" if $h;
    }
    return "$BF_RELEASES/$release/$cands[0]";
}

# Быстрая проверка ссылки без скачивания файла.
sub http_get_head {
    my ($url) = @_;
    my $curl = `curl --version 2>/dev/null`;
    if ($curl) {
        my $code = `curl -sS -L -I --max-time 20 -A Mobula6Helper -o /dev/null -w '%{http_code}' "$url" 2>/dev/null`;
        return ($code =~ /^(\d+)$/ && $1 == 200) ? 1 : 0;
    }
    my $ua = HTTP::Tiny->new(timeout => 20, agent => 'Mobula6Helper/1.0');
    my $r = $ua->request('HEAD', $url);
    return $r->{success} ? 1 : 0;
}

sub firmware_get {
    my ($target, $release) = @_;
    my $url = firmware_url($target, $release);
    return { ok => JSON::PP::false, error => 'не выбрана версия' } unless $url;

    my ($name) = $url =~ m{/([^/]+)$};
    $name = "betaflight_${release}.hex" unless $name;
    $name =~ s/[^A-Za-z0-9._-]//g;

    my $dir  = backup_dir();
    my $path = File::Spec->catfile($dir, $name);

    my $ok = http_download($url, $path, 120);

    if (!$ok || !(-f $path) || (-s $path) < 50000) {
        unlink $path if -f $path;
        return { ok => JSON::PP::false, error => 'Не скачалось: файла нет или он слишком маленький' };
    }

    return { ok => JSON::PP::true, path => $path, size => (-s $path), url => $url };
}

# ---------------------------------------------------------------- MSP-кадры

# Длина полного MSP-пакета в начале строки, либо undef если ещё не весь.
sub frame_len {
    my ($buf) = @_;
    return undef if length($buf) < 3;
    return undef unless ord(substr($buf, 0, 1)) == 0x24;   # '$'

    my $kind = ord(substr($buf, 1, 1));

    if ($kind == 0x4D) {    # 'M' — MSP v1: $M< size cmd payload crc
        return undef if length($buf) < 6;
        my $size = ord(substr($buf, 3, 1));
        return undef if $size > 250;
        my $total = 6 + $size;
        return length($buf) >= $total ? $total : undef;
    }

    if ($kind == 0x58) {    # 'X' — MSP v2: $X< flags cmd16 size16 payload crc
        return undef if length($buf) < 9;
        my $size = ord(substr($buf, 6, 1)) | (ord(substr($buf, 7, 1)) << 8);
        my $total = 9 + $size;
        return length($buf) >= $total ? $total : undef;
    }

    return undef;
}

# Ищет в буфере первый законченный пакет.
sub extract_frame {
    my ($buf) = @_;
    my $pos = 0;
    while (1) {
        my $i = index($buf, '$', $pos);
        return undef if $i < 0;
        my $sub = substr($buf, $i);
        my $n = frame_len($sub);
        return substr($sub, 0, $n) if defined $n;
        $pos = $i + 1;
    }
}

sub read_reply {
    my ($timeout) = @_;
    my $end = time() + $timeout;
    my $buf = '';

    while (time() < $end) {
        my $left = $end - time();
        my $wait = $left < 0.05 ? $left : 0.05;

        my $rin = '';
        vec($rin, fileno($SER), 1) = 1;
        my $rout = $rin;

        my $n = select($rout, undef, undef, $wait);
        next unless $n && $n > 0;

        my $chunk = '';
        my $got = sysread($SER, $chunk, 512);
        last unless defined $got && $got > 0;

        $buf .= $chunk;
        my $f = extract_frame($buf);
        return $f if defined $f;
    }

    return $buf;
}

# ---------------------------------------------------------------- загрузчик
#
# Чтобы прошить дрон, его надо перевести в режим загрузчика (DFU) и записать
# файл программой dfu-util. dfu-util лежит рядом, в папке tools — свой для
# каждой системы, поэтому ничего устанавливать не нужно.

sub tool_exe {
    my ($name) = @_;
    my @cand;

    # Ручное указание прошивальщика: MOBULA6_DFU=/путь/к/dfu-util
    my $forced = $ENV{MOBULA6_DFU} // '';
    return $forced if length $forced && -f $forced;

    if ($^O eq 'MSWin32') {
        push @cand, File::Spec->catfile($HERE, 'tools', 'win', "$name.exe");
    } elsif ($^O eq 'darwin') {
        my $arch = `uname -m 2>/dev/null`;
        $arch = '' unless defined $arch;
        chomp $arch;
        my $sub = ($arch eq 'arm64') ? 'mac-arm64' : 'mac-x64';
        push @cand, File::Spec->catfile($HERE, 'tools', $sub, $name);
        push @cand, File::Spec->catfile($HERE, 'tools', 'mac-arm64', $name);
        push @cand, File::Spec->catfile($HERE, 'tools', 'mac-x64', $name);
    } else {
        push @cand, File::Spec->catfile($HERE, 'tools', 'linux', $name);
    }
    push @cand, File::Spec->catfile($HERE, 'tools', "$name.exe");
    push @cand, File::Spec->catfile($HERE, "$name.exe");
    push @cand, File::Spec->catfile($HERE, $name);

    for my $p (@cand) {
        return $p if -f $p;
    }

    # последний шанс — системный
    my $which = `$name --version 2>&1`;
    if (defined $which && $which =~ /dfu-util/) {
        return $name;
    }
    return undef;
}

sub dfu_ready {
    my $exe = tool_exe('dfu-util');
    return { found => $exe ? JSON::PP::true : JSON::PP::false,
             path  => $exe // '', os => $^O };
}

# Список DFU-устройств: печатаем как есть, решение принимает вызывающий.
sub dfu_list_text {
    my $exe = tool_exe('dfu-util');
    return '' unless $exe;
    my $out = `"$exe" -l 2>&1`;
    return defined $out ? $out : '';
}

sub dfu_present {
    my $txt = dfu_list_text();
    $txt =~ s/\s+//g;
    return $txt =~ /0483:df11/i ? 1 : 0;
}

# MSP_REBOOT (68) с кодом 1 — «перезагрузись в загрузчик».
# Кадр: $M< size cmd payload crc, где crc = size ^ cmd ^ payload.
sub enter_dfu {
    open_serial();
    my $probe = pack('C*', 0x24, 0x4D, 0x3C, 0x01, 0x44, 0x01, 0x01 ^ 0x44 ^ 0x01);
    syswrite($SER, $probe);
    select(undef, undef, undef, 0.25);
    my $junk = '';
    eval { sysread($SER, $junk, 64) };
    close_serial();
    select(undef, undef, undef, 1.5);
    return 1;
}

sub wait_for_dfu {
    my ($seconds) = @_;
    $seconds = 15 unless defined $seconds;
    my $end = time() + $seconds;
    while (time() < $end) {
        return 1 if dfu_present();
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

# Запись прошивки. Возвращает текст лога и признак успеха.
sub flash_hex {
    my ($path) = @_;
    my $exe = tool_exe('dfu-util');
    return (0, 'Не найден dfu-util — программа, которая пишет прошивку в дрон.', 'no-dfu-tool')
        unless $exe;
    return (0, "Файл прошивки не найден: $path", 'no-file')
        unless $path && -f $path;

    my $log = `"$exe" -a 0 -d 0483:df11 -s 0x08000000:leave -D "$path" 2>&1`;
    my $ok  = (defined $log && $log =~ /File downloaded successfully|Download done/i) ? 1 : 0;
    $log = '' unless defined $log;
    return ($ok, $log, $ok ? '' : 'dfu-failed');
}

# ---------------------------------------------------------------- HTTP

sub http_reply {
    my ($sock, $code, $ctype, $body) = @_;
    my @reason = (200, 'OK', 400, 'Bad Request', 404, 'Not Found', 500, 'Internal Server Error');
    my %why = @reason;
    my $msg = $why{$code} || 'OK';

    $body = '' unless defined $body;
    # текстовые ответы в юникоде надо перевести в байты UTF-8,
    # иначе Content-Length считается по символам, а не по байтам
    utf8::encode($body) if utf8::is_utf8($body);
    print $sock "HTTP/1.1 $code $msg\r\n";
    print $sock "Content-Type: $ctype\r\n";
    print $sock "Content-Length: " . length($body) . "\r\n";
    print $sock "Cache-Control: no-store\r\n";
    print $sock "Connection: close\r\n";
    print $sock "\r\n";
    print $sock $body;
}

sub json_reply {
    my ($sock, $obj, $code) = @_;
    $code = 200 unless defined $code;
    http_reply($sock, $code, 'application/json; charset=utf-8', JSON::PP->new->utf8->encode($obj));
}

sub read_body {
    my ($sock, $len) = @_;
    return '' unless $len && $len > 0;
    my $body = '';
    while (length($body) < $len) {
        my $chunk = '';
        my $got = sysread($sock, $chunk, $len - length($body));
        last unless defined $got && $got > 0;
        $body .= $chunk;
    }
    return $body;
}

sub content_type {
    my ($path) = @_;
    return 'text/html; charset=utf-8' if $path =~ /\.html?$/i;
    return 'text/plain; charset=utf-8' if $path =~ /\.(txt|md|pl|py|command)$/i;
    return 'application/json; charset=utf-8' if $path =~ /\.json$/i;
    return 'image/png' if $path =~ /\.png$/i;
    return 'image/jpeg' if $path =~ /\.jpe?g$/i;
    return 'application/octet-stream';
}

sub serve_file {
    my ($sock, $path) = @_;

    $path =~ s/\?.*$//;
    $path = '/index.html' if $path eq '/' || $path eq '';

    # никаких выходов за пределы папки приложения
    return http_reply($sock, 404, 'text/plain; charset=utf-8', 'нет файла')
        if $path =~ /\.\./;

    (my $name = $path) =~ s{^/+}{};
    my $full = File::Spec->catfile($HERE, $name);

    return http_reply($sock, 404, 'text/plain; charset=utf-8', 'нет файла')
        unless -f $full;

    open(my $fh, '<:raw', $full) or
        return http_reply($sock, 404, 'text/plain; charset=utf-8', 'нет файла');
    local $/;
    my $data = <$fh>;
    close $fh;
    $data = '' unless defined $data;

    http_reply($sock, 200, content_type($name), $data);
}

# ---------------------------------------------------------------- обработка

sub hex2bytes {
    my ($hex) = @_;
    return pack('H*', $hex);
}

sub bytes2hex {
    my ($s) = @_;
    return unpack('H*', $s);
}

sub handle {
    my ($sock) = @_;
    my $request = '';
    while (length($request) < 65536) {
        my $chunk = '';
        my $got = sysread($sock, $chunk, 4096);
        last unless defined $got && $got > 0;
        $request .= $chunk;
        last if $request =~ /\r\n\r\n/;
    }
    return unless length($request);

    my ($head, $body) = split(/\r\n\r\n/, $request, 2);
    $body = '' unless defined $body;

    my ($line) = split(/\r\n/, $head, 2);
    my ($method, $path) = $line =~ m{^(\S+)\s+(\S+)};

    return http_reply($sock, 400, 'text/plain; charset=utf-8', 'плохой запрос')
        unless $method && $path;

    my $len = 0;
    if ($head =~ /Content-Length:\s*(\d+)/i) {
        $len = $1;
    }

    # Тело обычно приходит в том же пакете, что и заголовки.
    # Дочитываем только недостающий хвост — иначе ждём в сокете вечно.
    if (length($body) < $len) {
        $body .= read_body($sock, $len - length($body));
    }

    # ---- ping ----
    if ($path =~ m{^/api/ping}) {
        my @ports = find_fc_ports();
        json_reply($sock, {
            ok        => JSON::PP::true,
            bridge    => JSON::PP::true,
            perl      => JSON::PP::true,
            ports     => \@ports,
            open      => (defined $SER ? JSON::PP::true : JSON::PP::false),
            active    => defined $SER_NAME ? $SER_NAME : undef,
        });
        return;
    }

    if ($path =~ m{^/api/ports}) {
        my @ports = find_fc_ports();
        json_reply($sock, { ports => \@ports });
        return;
    }

    if ($path =~ m{^/api/dfu}) {
        json_reply($sock, dfu_ready());
        return;
    }

    # ---- прошить дрон ----
    if ($path =~ m{^/api/flash} && $method eq 'POST') {
        my $in = eval { JSON::PP->new->utf8->decode($body) } || {};
        my $file = $in->{path} // '';

        # Сначала проверяем файл и прошивальщик: не хочется гонять дрон
        # в загрузчик ради того, чтобы потом узнать, что шить нечем.
        if (!$file || !-f $file) {
            json_reply($sock, { ok => JSON::PP::false, error => 'no-file',
                log => 'Файл прошивки не найден: ' . ($file || '(пусто)') });
            return;
        }
        if (!tool_exe('dfu-util')) {
            json_reply($sock, { ok => JSON::PP::false, error => 'no-dfu-tool',
                log => 'Не найден dfu-util — программа, которая пишет прошивку в дрон.' });
            return;
        }

        my ($step_ok, $why) = (1, '');

        eval { enter_dfu(); 1 } or do { $step_ok = 0; $why = "$@"; $why =~ s/\s+$//; };

        if (!$step_ok) {
            json_reply($sock, { ok => JSON::PP::false,
                error => 'Не смог перевести дрон в загрузчик', log => $why });
            return;
        }

        if (!wait_for_dfu(15)) {
            json_reply($sock, { ok => JSON::PP::false, error => 'no-dfu-device',
                log => 'Дрон не появился в режиме загрузчика. Попробуй зажать кнопку BOOT при подключении USB.' });
            return;
        }

        my ($ok, $log, $err) = flash_hex($file);
        json_reply($sock, { ok => $ok ? JSON::PP::true : JSON::PP::false,
                            error => $err, log => $log, entered => JSON::PP::true });
        return;
    }

    # ---- connect ----
    if ($path =~ m{^/api/connect} && $method eq 'POST') {
        my $in = eval { JSON::PP->new->utf8->decode($body) } || {};
        my $dev = eval { close_serial(); open_serial($in->{port}) };
        if ($@) {
            (my $e = $@) =~ s/\s+$//;
            json_reply($sock, { ok => JSON::PP::false, error => $e });
        } else {
            json_reply($sock, { ok => JSON::PP::true, port => $dev });
        }
        return;
    }

    # ---- прошивки ----
    if ($path =~ m{^/api/firmware/list} && $method eq 'POST') {
        my $in = eval { JSON::PP->new->utf8->decode($body) } || {};
        json_reply($sock, firmware_list($in->{target}, $in->{board}, $in->{fallback}));
        return;
    }

    if ($path =~ m{^/api/firmware/get} && $method eq 'POST') {
        my $in = eval { JSON::PP->new->utf8->decode($body) } || {};
        json_reply($sock, firmware_get($in->{target}, $in->{release}));
        return;
    }

    # ---- дамп настроек в файл ----
    if ($path =~ m{^/api/dump} && $method eq 'POST') {
        my $in = eval { JSON::PP->new->utf8->decode($body) } || {};
        my $text = eval { cli_run('dump', 2.0, 25) };

        if ($@ || length($text // '') < 200) {
            my $why = $@ ? "$@" : 'Дрон не отдал настройки';
            $why =~ s/\s+$//;
            json_reply($sock, { ok => JSON::PP::false, error => $why });
            return;
        }

        my $name = $in->{name} // 'Mobula6_dump.txt';
        $name =~ s{.*[\\/]}{};
        $name =~ s/[^A-Za-z0-9._-]/_/g;
        $name = 'Mobula6_dump.txt' unless length $name;

        my $dir  = backup_dir();
        my $path_on_disk = File::Spec->catfile($dir, $name);
        if (open(my $fh, '>:raw', $path_on_disk)) {
            print $fh $text;
            close $fh;
        } else {
            json_reply($sock, { ok => JSON::PP::false, error => "Не смог записать файл: $!" });
            return;
        }

        json_reply($sock, {
            ok   => JSON::PP::true,
            path => $path_on_disk,
            size => length($text),
            text => $text,
        });
        return;
    }

    if ($path =~ m{^/api/disconnect}) {
        close_serial();
        json_reply($sock, { ok => JSON::PP::true });
        return;
    }

    # ---- msp ----
    if ($path =~ m{^/api/msp} && $method eq 'POST') {
        my $in = eval { JSON::PP->new->utf8->decode($body) } || {};
        my $frame = eval { hex2bytes($in->{frame} // '') };
        if (!$frame) {
            json_reply($sock, { ok => JSON::PP::false, error => 'bad frame' }, 400);
            return;
        }
        my $timeout = defined $in->{timeout} ? $in->{timeout} / 1000.0 : 1.5;

        my $dev = eval { open_serial($in->{port}) };
        if ($@) {
            (my $e = $@) =~ s/\s+$//;
            close_serial();
            json_reply($sock, { ok => JSON::PP::false, error => $e });
            return;
        }

        # сбрасываем то, что осталось в буфере порта
        my $junk = '';
        while (1) {
            my $rin = '';
            vec($rin, fileno($SER), 1) = 1;
            my $rout = $rin;
            last unless select($rout, undef, undef, 0) > 0;
            last unless sysread($SER, $junk, 512);
        }

        my $written = syswrite($SER, $frame);
        if (!defined $written || $written != length($frame)) {
            close_serial();
            json_reply($sock, { ok => JSON::PP::false, error => 'не смог отправить' });
            return;
        }

        my $reply = read_reply($timeout);
        json_reply($sock, {
            ok    => JSON::PP::true,
            port  => $dev,
            reply => bytes2hex($reply),
        });
        return;
    }

    serve_file($sock, $path);
}

# ---------------------------------------------------------------- запуск

my $start = 8000;
my $open_browser = 0;
for my $a (@ARGV) {
    if ($a eq '--open') { $open_browser = 1; next; }
    $start = $a if $a =~ /^\d+$/;
}

# Уже есть работающий помощник? Второй только помешает: два процесса начнут
# делить USB-порт дрона, и часть ответов MSP потеряется.
for my $p ($start .. $start + 50) {
    my $probe = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $p,
        Proto => 'tcp', Timeout => 0.3,
    );
    next unless $probe;
    print $probe "GET /api/ping HTTP/1.0\r\n\r\n";
    my $answer = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 1;
        while (my $line = <$probe>) { $answer .= $line; last if length $answer > 800; }
        alarm 0;
    };
    alarm 0;
    close $probe;
    next unless $answer =~ /"bridge"/;

    if (open(my $pf, '>', 'port.txt')) {
        print $pf $p;
        close $pf;
    }
    print "=" x 46, "\n";
    print "  Помощник уже запущен: http://localhost:$p/index.html\n";
    print "=" x 46, "\n\n";
    print "Второй раз запускать не нужно — открой страницу по адресу выше.\n";
    print "Если что-то не работает, закрой то окно консоли и запусти снова.\n\n";
    if ($open_browser) {
        my $url = "http://localhost:$p/index.html";
        if    ($^O eq 'MSWin32') { system('cmd', '/c', 'start', '""', $url); }
        elsif ($^O eq 'darwin')  { system('open', $url); }
    }
    exit 0;
}

my $port  = $start;
my $srv;

for my $try ($start .. $start + 50) {
    $srv = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => $try,
        Proto     => 'tcp',
        Listen    => 16,
        ReuseAddr => 1,
    );
    if ($srv) { $port = $try; last; }
    $srv = undef;
}

if (!$srv) {
    print "Не нашёл свободный порт ($start..", $start + 50, ").\n";
    exit 1;
}

# Скрипт запуска читает этот файл, чтобы открыть браузер на верном адресе.
eval {
    if (open(my $pf, '>:utf8', File::Spec->catfile($HERE, 'port.txt'))) {
        print $pf $port;
        close $pf;
    }
};

my @ports = find_fc_ports();

print "=" x 46, "\n";
print "  Адрес: http://localhost:$port/index.html\n";
print "=" x 46, "\n\n";
if (@ports) {
    print "Дрон виден: ", join(', ', @ports), "\n";
} else {
    print "Дрон пока не виден. Вставь USB-кабель.\n";
}
print "\nЭто окно не закрывай, пока настраиваешь дрон.\n";
print "Остановить: Ctrl+C\n\n";
$| = 1;

# --open: сразу открыть страницу в браузере (запуск на Windows и Linux
# без отдельного скрипта). На macOS браузер открывает start.command.
if ($open_browser) {
    my $url = "http://localhost:$port/index.html";
    if    ($^O eq 'MSWin32') { system('cmd', '/c', 'start', '""', $url); }
    elsif ($^O eq 'darwin')  { system('open', $url); }
    else {
        my $xdg = `command -v xdg-open 2>/dev/null`;
        $xdg = '' unless defined $xdg;
        chomp $xdg;
        system('xdg-open', $url) if length $xdg;
    }
}

$SIG{INT} = sub { close_serial(); exit 0; };
$SIG{TERM} = sub { close_serial(); exit 0; };

while (1) {
    my $client = $srv->accept();
    next unless $client;
    eval { handle($client); 1 } or do { };
    close $client;
}
