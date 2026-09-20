#!/bin/bash
# Залить пульт на собаку ИЗ ЭТОЙ ПАПКИ.
#
# Запускать НА НОУТБУКЕ. Папка репозитория — единственное место, где живёт
# рабочая версия: правим здесь, заливаем отсюда, фиксируем в git. Раньше файлы
# лежали в двух местах, и копия на GitHub отставала от того, что стоит на
# роботе, — а через неделю уже не скажешь, какая версия настоящая.
#
#   ./залить.sh              только страницу (быстро, без sudo на собаке)
#   ./залить.sh --видео      ещё и лёгкие копии камер (ставит службы)
#
# Переменные окружения (задаются перед командой):
#   HOST   адрес собаки       (по умолчанию 100.122.173.35)
#   NAME   префикс служб      (по умолчанию shym1)
#   HOSTS  адреса для WebRTC  (по умолчанию берём с самой собаки)
#
# Имена переменных тут латиницей НАМЕРЕННО: bash не принимает кириллицу в
# именах, хотя в комментариях и названиях файлов она работает.
set -eu

HOST=${HOST:-100.122.173.35}
NAME=${NAME:-shym1}
DOGUSER=${DOGUSER:-unitree}
TARGET="$DOGUSER@$HOST"
HERE=$(cd "$(dirname "$0")" && pwd)
APP="/home/$DOGUSER/${NAME}_assistant"
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" "$@"; }

echo "== собака $NAME на $HOST"

# ── страница ────────────────────────────────────────────────────────────
scp -q -o ConnectTimeout=15 "$HERE/mobile.html" "$TARGET:$APP/mobile.html"
echo "страница залита: $APP/mobile.html"

if [ "${1:-}" = "--видео" ] || [ "${1:-}" = "--video" ]; then
    # Адреса, которые робот называет браузеру как свои. Без них картинка через
    # тайлнет чёрная: кандидаты собираются с интерфейсов, а tailscale0 туда не
    # попадает. Берём с самой собаки, чтобы не держать их в репозитории.
    if [ -z "${HOSTS:-}" ]; then
        HOSTS=$(ssh_ 'tailscale ip -4 2>/dev/null | head -1; ip -4 -br addr | awk "\$1!=\"lo\" && \$1 !~ /docker|tailscale/ {print \$3}" | cut -d/ -f1' | paste -sd, -)
    fi
    echo "адреса для видео: $HOSTS"

    TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
    sed "s/@NAME@/$NAME/g" "$HERE/video-tiny/mediamtx-tiny.service" > "$TMPD/$NAME-mediamtx-tiny.service"
    sed "s/@NAME@/$NAME/g" "$HERE/video-tiny/camera-tiny@.service"  > "$TMPD/$NAME-camera-tiny@.service"
    sed "s|^webrtcAdditionalHosts:.*|webrtcAdditionalHosts: [$HOSTS]|" \
        "$HERE/video-tiny/mediamtx-tiny.yml" > "$TMPD/mediamtx-tiny.yml"
    cp "$HERE/video-tiny/camera-tiny.sh"      "$TMPD/$NAME-camera-tiny.sh"
    cp "$HERE/video-tiny/camera-tiny-go2.env" "$TMPD/$NAME-camera-tiny-go2"
    cp "$HERE/video-tiny/camera-tiny-usb.env" "$TMPD/$NAME-camera-tiny-usb"

    scp -q -o ConnectTimeout=15 "$TMPD"/* "$TARGET:/tmp/"
    # ⚠️ Пароль sudo спрашивает сама собака; в этом файле его нет и быть не должно.
    ssh_ "set -e
        install -m644 /tmp/mediamtx-tiny.yml \$HOME/mediamtx-tiny.yml
        sudo sh -c '
          install -m755 -o root -g root /tmp/$NAME-camera-tiny.sh /usr/local/bin/$NAME-camera-tiny.sh
          install -m644 -o root -g root /tmp/$NAME-mediamtx-tiny.service /etc/systemd/system/
          install -m644 -o root -g root /tmp/$NAME-camera-tiny@.service /etc/systemd/system/
          install -m644 -o root -g root /tmp/$NAME-camera-tiny-go2 /etc/default/
          install -m644 -o root -g root /tmp/$NAME-camera-tiny-usb /etc/default/
          systemctl daemon-reload
          systemctl enable --now $NAME-mediamtx-tiny
          systemctl restart $NAME-camera-tiny@go2 $NAME-camera-tiny@usb'
        rm -f /tmp/$NAME-camera-tiny* /tmp/$NAME-mediamtx-tiny.service /tmp/mediamtx-tiny.yml"
    echo "лёгкие копии обновлены"
fi

# ── проверка ────────────────────────────────────────────────────────────
echo "== проверка"
curl -sk -m15 -o /dev/null -w "  страница /m: %{http_code} за %{time_total}s\n" "https://$HOST:9996/m" || true
ssh_ "curl -s -m5 127.0.0.1:9994/v3/paths/list 2>/dev/null | python3 -c 'import json,sys; print(\"  лёгкие потоки:\", [(i[\"name\"], i[\"ready\"]) for i in json.load(sys.stdin)[\"items\"]])'" 2>/dev/null || true
echo "Адрес пульта: https://$HOST:9996/m"
