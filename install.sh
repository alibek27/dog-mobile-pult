#!/bin/bash
# Установка мобильного пульта на собаку.
#
# Ставит три вещи:
#   1. страницу пульта  -> $APP/mobile.html
#   2. лёгкие копии камер: второй mediamtx + два конвейера (нужен NVENC)
#   3. напоминает про патчи к службам ctl и ptt (их применяет человек)
#
# Запускать НА САМОЙ СОБАКЕ, от пользователя unitree:
#     NAME=shym1 ./install.sh
#
# NAME — префикс ваших служб. У нас службы зовутся shym1-ctl, shym1-dash,
# shym1-ptt, значит NAME=shym1. Скрипт ставит свои службы с тем же префиксом.
set -eu

NAME=${NAME:-shym1}
APP=${APP:-$HOME/${NAME}_assistant}
HERE=$(cd "$(dirname "$0")" && pwd)
SUDO=${SUDO:-sudo}

echo "== собака: $NAME, каталог приложения: $APP"
[ -d "$APP" ] || { echo "нет каталога $APP — проверьте NAME/APP" >&2; exit 1; }

# ── 1. страница ─────────────────────────────────────────────────────────
install -m644 "$HERE/mobile.html" "$APP/mobile.html"
echo "страница: $APP/mobile.html"

# ── 2. лёгкие копии камер ───────────────────────────────────────────────
# ЗАЧЕМ. Телефон обычно висит на мобильном интернете. Два полных потока
# (у нас 2.0 и 1.4 Мбит/с) забивают отдачу, и в очередь встаёт ВСЁ: джойстик,
# рация, кнопки. Лёгкие копии 640x360 берут ~0.2-0.4 Мбит/с каждая.
#
# ⚠️ Нужен аппаратный кодировщик (nvv4l2h264enc). На Orin NX он есть, на Orin
# Nano блок NVENC вырезан — там придётся жать процессором (x264enc) и платить
# за это ядром. Проверить: gst-inspect-1.0 nvv4l2h264enc
if gst-inspect-1.0 nvv4l2h264enc >/dev/null 2>&1; then
    echo "аппаратный кодировщик найден"
else
    echo "⚠️  nvv4l2h264enc не найден — лёгкие копии будут грузить процессор" >&2
fi

install -m644 "$HERE/video-tiny/mediamtx-tiny.yml" "$HOME/mediamtx-tiny.yml"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in mediamtx-tiny.service camera-tiny@.service; do
    sed "s/@NAME@/$NAME/g" "$HERE/video-tiny/$f" > "$tmp/${NAME}-$f"
done
for i in go2 usb; do
    cp "$HERE/video-tiny/camera-tiny-$i.env" "$tmp/${NAME}-camera-tiny-$i"
done

$SUDO install -m755 -o root -g root "$HERE/video-tiny/camera-tiny.sh" \
        "/usr/local/bin/${NAME}-camera-tiny.sh"
$SUDO install -m644 -o root -g root "$tmp/${NAME}-mediamtx-tiny.service" \
        "/etc/systemd/system/${NAME}-mediamtx-tiny.service"
$SUDO install -m644 -o root -g root "$tmp/${NAME}-camera-tiny@.service" \
        "/etc/systemd/system/${NAME}-camera-tiny@.service"
for i in go2 usb; do
    $SUDO install -m644 -o root -g root "$tmp/${NAME}-camera-tiny-$i" \
            "/etc/default/${NAME}-camera-tiny-$i"
done
# Доступ службы пульта к порту платы ESP32 (фары, стробоскоп). Порт
# принадлежит группе dialout, служба работает от unitree, которого там нет, —
# без этой добавки кнопки света молча не работают («Permission denied»).
# Группу даём ТОЛЬКО службе, пользователя не меняем.
$SUDO mkdir -p "/etc/systemd/system/${NAME}-ctl.service.d"
printf '[Service]\nSupplementaryGroups=dialout\n' > "$tmp/esp-port.conf"
$SUDO install -m644 -o root -g root "$tmp/esp-port.conf" \
        "/etc/systemd/system/${NAME}-ctl.service.d/esp-port.conf"

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now "${NAME}-mediamtx-tiny"
$SUDO systemctl restart "${NAME}-camera-tiny@go2" "${NAME}-camera-tiny@usb"

echo "== проверка (через 25 с конвейеры успевают подняться)"
sleep 25
curl -s -m5 127.0.0.1:9994/v3/paths/list |
    python3 -c 'import json,sys; print("лёгкие потоки:", [(i["name"], i["ready"]) for i in json.load(sys.stdin)["items"]])'

cat <<TXT

== осталось вручную: патчи к службам ==

  patches/ctl-raciya-gromkost-zaderzhka.patch  — к ${NAME}-ctl.py
      рация потоком (/speak/chunk), громкость сирены и рации (/vol),
      TCP_NODELAY (минус ~100 мс на каждую команду), фары и стробоскоп
      через ESP32 (/esp/...), тревога SOS (/sos)

  patches/ptt-stranica-telefona-i-zaderzhka.patch — к ${NAME}-ptt.py
      выдача /m, маршрут /mtx2/ на лёгкий раздатчик, рукопожатие TLS в
      потоке соединения (иначе один оборвавшийся телефон вешает вход всем),
      TCP_NODELAY

  Применять так (с бэкапом и проверкой синтаксиса):
      sudo cp -p /usr/local/bin/${NAME}-ctl.py /usr/local/bin/${NAME}-ctl.py.bak
      sudo patch /usr/local/bin/${NAME}-ctl.py < patches/ctl-*.patch
      python3 -m py_compile /usr/local/bin/${NAME}-ctl.py
      sudo systemctl restart ${NAME}-ctl

  ⚠️ Перед перезапуском ${NAME}-ctl убедитесь, что собака стоит или лежит
     спокойно и движение выключено: служба управления перезапускается.

  Адрес пульта: https://<адрес робота>:9996/m
TXT
