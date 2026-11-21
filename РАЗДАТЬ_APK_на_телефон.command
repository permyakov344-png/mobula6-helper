#!/bin/bash
# Раздать MobulaHelper.apk на телефон по Wi-Fi.
#
# Двойной клик -> в окне появится адрес вида
#   http://192.168.1.50:8080/MobulaHelper.apk
# Открой этот адрес в браузере телефона (телефон в той же Wi-Fi сети)
# и скачай файл. Окно не закрывай, пока качается.
cd "$(dirname "$0")" || exit 1

APK="MobulaHelper.apk"
if [ ! -f "$APK" ]; then
  echo
  echo "Рядом нет файла $APK."
  echo "Положи его в эту папку и запусти снова."
  echo
  read -r -p "Нажми Enter, чтобы закрыть..." _
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "Не нашёл perl — без него раздать файл не получится."
  read -r -p "Нажми Enter, чтобы закрыть..." _
  exit 1
fi

PORT=8080
SIZE=$(( $(wc -c < "$APK") / 1024 ))

IP="$(ipconfig getifaddr en0 2>/dev/null)"
[ -z "$IP" ] && IP="$(ipconfig getifaddr en1 2>/dev/null)"
[ -z "$IP" ] && IP="$(ifconfig 2>/dev/null | awk '/inet 192\.|inet 10\./ {print $2; exit}')"
[ -z "$IP" ] && IP="$(hostname)"

clear
echo "=============================================="
echo "  Файл: $APK ($SIZE КБ)"
echo ""
echo "  Открой на телефоне в браузере:"
echo "  http://$IP:$PORT/$APK"
echo "=============================================="
echo ""
echo "Телефон должен быть в той же Wi-Fi сети."
echo "Это окно не закрывай, пока файл качается."
echo "Остановить: Ctrl+C"
echo ""

PERL_PORT="$PORT" PERL_APK="$APK" exec perl -e '
use strict;
use warnings;
use IO::Socket::INET;

my $port = $ENV{PERL_PORT} || 8080;
my $apk  = $ENV{PERL_APK}  || "MobulaHelper.apk";

my $srv = IO::Socket::INET->new(
    LocalAddr => "0.0.0.0",
    LocalPort => $port,
    Proto     => "tcp",
    Listen    => 20,
    ReuseAddr => 1,
) or die "Порт $port занят. Закрой другое окно и запусти снова.\n";

$| = 1;

while (my $c = $srv->accept) {
    my $req = "";
    while (length($req) < 8192) {
        my $chunk = "";
        my $got = sysread($c, $chunk, 1024);
        last unless defined $got && $got > 0;
        $req .= $chunk;
        last if $req =~ /\r\n\r\n/;
    }

    my ($line) = split /\r\n/, $req, 2;
    my ($method, $path) = ($line // "") =~ m{^(\S+)\s+(\S+)};
    $path //= "/";

    if ($path =~ m{^/MobulaHelper\.apk(\?.*)?$} && -f $apk) {
        open(my $fh, "<:raw", $apk) or do { close $c; next; };
        my $size = -s $apk;
        print $c "HTTP/1.0 200 OK\r\n";
        print $c "Content-Type: application/vnd.android.package-archive\r\n";
        print $c "Content-Length: $size\r\n";
        print $c "Content-Disposition: attachment; filename=\"MobulaHelper.apk\"\r\n";
        print $c "Cache-Control: no-store\r\n\r\n";
        my $buf;
        while (read($fh, $buf, 65536)) { print $c $buf; }
        close $fh;
    } elsif ($path eq "/") {
        my $body = "<html><meta name=viewport content=\"width=device-width\"><body style=\"font:16px sans-serif;padding:24px\">"
                 . "<h3>Mobula Helper</h3><p><a href=\"/MobulaHelper.apk\">Скачать APK</a></p></body></html>";
        print $c "HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n";
        print $c "Content-Length: " . length($body) . "\r\n\r\n$body";
    } else {
        print $c "HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\n\r\nнет файла";
    }
    close $c;
}
'
