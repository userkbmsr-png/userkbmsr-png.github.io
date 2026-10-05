#!/bin/bash
#
# install-mediarr.sh
# PC Intel x64 - Debian 13 (trixie)
#
# Rulare: sudo bash install-mediarr.sh
#

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Rulează cu sudo: sudo bash $0"
    exit 1
fi

KIOSK_USER="${SUDO_USER:-$(logname)}"
KIOSK_HOME="/home/$KIOSK_USER"
STREMIO_PORT=8000
JELLYFIN_PORT=8096
SCRYER_PORT=8585
MEDIARR_DIR="$KIOSK_HOME/mediarr"

PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1)
if [ -z "$PRIMARY_IP" ]; then
    PRIMARY_IP="127.0.0.1"
    echo "!!! Nu am putut detecta IP-ul principal - Jellyfin/Scryer vor rămâne"
    echo "!!! pe localhost, probabil nu vor porni corect din selector."
fi

echo ">>> [1/10] Actualizare sistem..."
apt update && apt upgrade -y

echo ">>> [2/10] Instalare X, i3, Chromium, rofi (minimal, fără recommends)..."
apt install -y --no-install-recommends \
    xserver-xorg \
    xinit \
    x11-xserver-utils \
    i3 \
    chromium \
    rofi \
    xbindkeys \
    unclutter \
    dbus-x11 \
    curl \
    wget

echo ">>> [3/10] Instalare Docker..."
if ! command -v docker &> /dev/null; then
    wget -qO- https://get.docker.com | sh
    usermod -aG docker "$KIOSK_USER"
else
    echo "Docker deja instalat, sar peste."
fi
systemctl enable --now docker

echo ">>> [4/10] Pornire container Stremio (server + web player)..."
mkdir -p "$KIOSK_HOME"/stremio-data
chown "$KIOSK_USER":"$KIOSK_USER" "$KIOSK_HOME"/stremio-data

docker rm -f stremio-docker 2>/dev/null || true
docker run -d \
    --name=stremio-docker \
    -e NO_CORS=1 \
    -e AUTO_SERVER_URL=1 \
    -v "$KIOSK_HOME"/stremio-data:/root/.stremio-server \
    -p "${STREMIO_PORT}:8080/tcp" \
    --restart unless-stopped \
    tsaridas/stremio-docker:latest

echo ">>> [5/10] Instalare Nuvio (întotdeauna alpha - singura versiune publicată)..."
echo "    (~150MB - poate dura câteva minute, în funcție de conexiune)"
cd /tmp
NUVIO_TAG=$(curl -s -o /dev/null -w '%{redirect_url}' "https://github.com/NuvioMedia/NuvioDesktop/releases/latest" | sed 's#.*/tag/##')
NUVIO_DEB_PATH=""
if [ -n "$NUVIO_TAG" ]; then
    NUVIO_DEB_PATH=$(curl -s "https://github.com/NuvioMedia/NuvioDesktop/releases/expanded_assets/${NUVIO_TAG}" \
        | grep -oE 'href="[^"]*\.deb"' | head -n1 | sed 's/href="//;s/"$//')
fi

if [ -z "$NUVIO_TAG" ] || [ -z "$NUVIO_DEB_PATH" ]; then
    echo "!!! Nu am putut detecta automat ultima versiune Nuvio - sar peste."
    echo "!!! Stremio rămâne complet funcțional."
else
    NUVIO_DEB="nuvio_${NUVIO_TAG}_amd64.deb"
    wget -O "$NUVIO_DEB" "https://github.com${NUVIO_DEB_PATH}"
    if [ -f "$NUVIO_DEB" ] && [ "$(stat -c%s "$NUVIO_DEB" 2>/dev/null || echo 0)" -gt 1000000 ]; then
        dpkg -i "$NUVIO_DEB" || true
        if [ -f /var/lib/dpkg/info/nuvio.postinst ]; then
            sed -i 's/^xdg-desktop-menu install/#&/' /var/lib/dpkg/info/nuvio.postinst
        fi
        if apt-get install -f -y; then
            echo "Nuvio $NUVIO_TAG instalat."
        else
            echo "!!! Configurarea Nuvio a eșuat - Stremio nu e afectat, continui."
        fi
    else
        echo "!!! Fișierul Nuvio pare invalid (prea mic) - sar peste."
    fi
    rm -f "$NUVIO_DEB"
fi

echo ">>> [6/10] Stack *arr (Jellyfin + Sonarr/Radarr/Bazarr/Prowlarr/qBittorrent/Scryer)..."
echo "    Totul sub $MEDIARR_DIR - fără git clone, fără alt script extern."

PUID=$(id -u "$KIOSK_USER")
PGID=$(id -g "$KIOSK_USER")
MEDIA_DIR="$MEDIARR_DIR/media"
CONFIG_DIR="$MEDIARR_DIR/config"

mkdir -p "$MEDIA_DIR"/tvshows "$MEDIA_DIR"/movies "$MEDIA_DIR"/music "$MEDIA_DIR"/blackhole \
         "$MEDIA_DIR"/downloads/torrents "$MEDIA_DIR"/downloads/usenet/complete "$MEDIA_DIR"/downloads/usenet/incomplete
mkdir -p "$CONFIG_DIR"/jellyfin "$CONFIG_DIR"/qbittorrent "$CONFIG_DIR"/sonarr "$CONFIG_DIR"/radarr \
         "$CONFIG_DIR"/bazarr "$CONFIG_DIR"/prowlarr "$CONFIG_DIR"/scryer

cat > "$MEDIARR_DIR/.env" <<EOF
PUID=$PUID
PGID=$PGID
TZ=Europe/Bucharest
MEDIA_DIR=$MEDIA_DIR
CONFIG_DIR=$CONFIG_DIR
EOF

cat > "$MEDIARR_DIR/docker-compose.yaml" <<'COMPOSE_EOF'
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin
    container_name: jellyfin
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${MEDIA_DIR}:/data
      - ${CONFIG_DIR}/jellyfin:/config
    ports:
      - 8096:8096
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    container_name: qbittorrent
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - WEBUI_PORT=8080
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${MEDIA_DIR}:/data
      - ${CONFIG_DIR}/qbittorrent:/config
    ports:
      - 8080:8080
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${MEDIA_DIR}:/data
      - ${CONFIG_DIR}/sonarr:/config
    ports:
      - 8989:8989
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${MEDIA_DIR}:/data
      - ${CONFIG_DIR}/radarr:/config
    ports:
      - 7878:7878
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr
    container_name: bazarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${MEDIA_DIR}:/data
      - ${CONFIG_DIR}/bazarr:/config
    ports:
      - 6767:6767
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr
    container_name: prowlarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${CONFIG_DIR}/prowlarr:/config
    ports:
      - 9696:9696
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=${TZ}
    ports:
      - 8191:8191
    restart: unless-stopped

  scryer:
    image: ghcr.io/scryer-media/scryer:latest
    container_name: scryer
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - SCRYER_BIND=0.0.0.0:8585
      - SCRYER_SERIES_PATH=/data/tvshows
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${MEDIA_DIR}:/data
      - ${CONFIG_DIR}/scryer:/config
    ports:
      - 8585:8585
    restart: unless-stopped
COMPOSE_EOF

chown -R "$KIOSK_USER":"$KIOSK_USER" "$MEDIARR_DIR"

cd "$MEDIARR_DIR"
if docker compose up -d; then
    echo "Stack *arr pornit cu succes."
else
    echo "!!! Pornirea stack-ului *arr a eșuat la prima încercare."
    echo "!!! Scriu un script simplu de reluare: ~$KIOSK_USER/install.sh"
    cat > "$KIOSK_HOME/install.sh" <<RETRY_EOF
#!/bin/bash
set -e
cd "$MEDIARR_DIR"
docker compose up -d
echo "Stack *arr (Jellyfin, Sonarr, Radarr, Bazarr, Prowlarr, qBittorrent, Scryer) pornit cu succes."
RETRY_EOF
    chmod +x "$KIOSK_HOME/install.sh"
    chown "$KIOSK_USER":"$KIOSK_USER" "$KIOSK_HOME/install.sh"
    echo "!!! Restul kiosk-ului (Stremio/Nuvio) nu e afectat - continui."
    echo "!!! Reia mai târziu cu: bash ~/install.sh"
fi
cd /

echo ">>> [7/10] Permisiune poweroff fără parolă pentru $KIOSK_USER..."
cat > /etc/sudoers.d/kiosk-poweroff <<EOF
$KIOSK_USER ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff
EOF
chmod 0440 /etc/sudoers.d/kiosk-poweroff
if ! visudo -c -f /etc/sudoers.d/kiosk-poweroff > /dev/null 2>&1; then
    echo "!!! sudoers pentru poweroff a ieșit invalid - îl șterg."
    rm -f /etc/sudoers.d/kiosk-poweroff
fi

echo ">>> [8/10] Autologin pe tty1 pentru $KIOSK_USER..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl enable getty@tty1.service

echo ">>> [9/10] Pornire automată X + i3 la login pe tty1..."
PROFILE_FILE="$KIOSK_HOME/.bash_profile"
touch "$PROFILE_FILE"
if ! grep -q "exec startx" "$PROFILE_FILE"; then
cat >> "$PROFILE_FILE" <<'EOF'

if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
EOF
fi

cat > "$KIOSK_HOME"/.xbindkeysrc <<EOF
"$KIOSK_HOME/app-control.sh toggle"
    m:0x0 + b:3
EOF

cat > "$KIOSK_HOME"/.xinitrc <<'EOF'
xset s off
xset -dpms
xset s noblank

# Forțează modul video corect - la boot, TV-ul poate raporta un EDID
# nesigur/gol, iar X alege atunci un mod cu polaritate sync greșită
# ("Unsupported" pe TV). Aplicăm direct modul confirmat funcțional
# (1920x1080@60, +hsync -vsync, din EDID-ul real al TV-ului).
sleep 2
OUT=$(xrandr | grep " connected" | cut -d" " -f1)
xrandr --newmode "1080p60_tv" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync -vsync
xrandr --addmode "$OUT" 1080p60_tv
xrandr --output "$OUT" --mode 1080p60_tv

unclutter --timeout 1 &
xbindkeys &
exec i3
EOF

echo ">>> [10/10] Stremio auto-start + selector (rofi) + config i3..."

cat > "$KIOSK_HOME"/app-control.sh <<HEADER_EOF
#!/bin/bash
STREMIO_PORT=${STREMIO_PORT}
JELLYFIN_PORT=${JELLYFIN_PORT}
SCRYER_PORT=${SCRYER_PORT}
HOST_IP=${PRIMARY_IP}
HEADER_EOF

cat >> "$KIOSK_HOME"/app-control.sh <<'BODY_EOF'
CHROMIUM_FLAGS="--kiosk --noerrdialogs --disable-infobars --no-first-run --disable-session-crashed-bubble --check-for-update-interval=31536000"

# Omoară orice e deschis acum (selector inclus) - singurul loc de unde se
# face asta, ca să nu mai existe curse între mai multe comenzi independente
# care porneau/opreau lucruri fără să știe una de alta.
kill_current() {
    pkill rofi 2>/dev/null
    pkill chromium 2>/dev/null
    pkill Nuvio 2>/dev/null
    sleep 0.3
}

launch_stremio() {
    kill_current
    (
        for i in $(seq 1 30); do
            curl -s -o /dev/null "http://localhost:$STREMIO_PORT" && break
            sleep 1
        done
        chromium $CHROMIUM_FLAGS "http://localhost:$STREMIO_PORT"
    ) &
}

launch_nuvio() {
    kill_current
    /opt/nuvio/bin/Nuvio &
}

launch_jellyfin() {
    kill_current
    chromium $CHROMIUM_FLAGS "http://$HOST_IP:$JELLYFIN_PORT" &
}

launch_scryer() {
    kill_current
    chromium $CHROMIUM_FLAGS "http://$HOST_IP:$SCRYER_PORT" &
}

# Nu omoară nimic înainte să afișeze rofi - rofi apare DEASUPRA aplicației
# curente, fără s-o oprească. Doar dacă alegi ceva, acel ceva (prin
# launch_*) oprește ce rula înainte. Escape/clic-în-afară -> rofi dispare,
# aplicația de dinainte rămâne exact cum era.
show_selector() {
    CHOICE=$(printf 'Stremio\nNuvio\nJellyfin\nScryer\nPoweroff\n' | rofi -dmenu -i -p "Alege aplicația" -theme-str 'window {width: 25%;} listview {lines: 5;}')
    case "$CHOICE" in
        Stremio)  launch_stremio ;;
        Nuvio)    launch_nuvio ;;
        Jellyfin) launch_jellyfin ;;
        Scryer)   launch_scryer ;;
        Poweroff) sudo /usr/bin/systemctl poweroff ;;
    esac
}

case "$1" in
    toggle)
        if pgrep -x rofi > /dev/null; then
            pkill rofi
        else
            show_selector
        fi
        ;;
    hide)     pkill rofi 2>/dev/null ;;
    poweroff) sudo /usr/bin/systemctl poweroff ;;
    stremio)  launch_stremio ;;
    nuvio)    launch_nuvio ;;
    jellyfin) launch_jellyfin ;;
    scryer)   launch_scryer ;;
    *)        echo "Folosire: $0 {toggle|hide|poweroff|stremio|nuvio|jellyfin|scryer}" ;;
esac
BODY_EOF
chmod +x "$KIOSK_HOME"/app-control.sh

mkdir -p "$KIOSK_HOME"/.config/i3
cat > "$KIOSK_HOME"/.config/i3/config <<'EOF'
set $mod Mod4

exec --no-startup-id ~/app-control.sh stremio

bindsym $mod+Shift+e exit

# F1 = arată/ascunde selectorul (același efect ca și clic dreapta)
# F2-F5 = lansează direct aplicația respectivă
# F6 = poweroff
bindsym F1 exec --no-startup-id "~/app-control.sh toggle"
bindsym F2 exec --no-startup-id "~/app-control.sh stremio"
bindsym F3 exec --no-startup-id "~/app-control.sh nuvio"
bindsym F4 exec --no-startup-id "~/app-control.sh jellyfin"
bindsym F5 exec --no-startup-id "~/app-control.sh scryer"
bindsym F6 exec --no-startup-id "~/app-control.sh poweroff"

for_window [class="^Stremio$"] fullscreen enable
for_window [class="^com-nuvio-app-MainKt$"] fullscreen enable
EOF

chown -R "$KIOSK_USER":"$KIOSK_USER" \
    "$PROFILE_FILE" \
    "$KIOSK_HOME"/.xinitrc \
    "$KIOSK_HOME"/.xbindkeysrc \
    "$KIOSK_HOME"/.config \
    "$KIOSK_HOME"/app-control.sh

echo
echo "=== Gata. Repornește: sudo reboot ==="
echo "La boot: autologin tty1 -> startx -> i3 -> Stremio direct"
echo "Clic dreapta (oriunde) -> arată/ascunde selectorul: Stremio / Nuvio / Jellyfin / Scryer / Poweroff"
echo "Cu tastatură, dacă e conectată: F1 selector, F2 Stremio, F3 Nuvio, F4 Jellyfin, F5 Scryer, F6 poweroff"
echo
echo "!!! IP folosit pentru Jellyfin/Scryer în selector: $PRIMARY_IP (alocat prin"
echo "!!! DHCP - se poate schimba la un restart de router). Recomandare: fă o"
echo "!!! rezervare DHCP pentru acest PC din panoul routerului (după adresa MAC)."
if [ -f "$KIOSK_HOME/install.sh" ]; then
    echo
    echo "!!! Stack-ul *arr nu a pornit din prima - rulează: bash ~/install.sh"
fi
