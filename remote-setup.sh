#!/bin/bash
#
# remote-setup.sh
# Configurare "universală" a unei telecomenzi IR (receptor IR integrat în PC,
# ex. ITE8708) pentru kiosk-ul Stremio (X + i3 + rofi) din install-mediarr.sh.
#
# Ce face:
#  1. instalează pachetele lipsă (ir-keytable, xdotool, xinput)
#  2. șterge configurările de telecomandă existente (servicii, reguli udev,
#     blocul din i3). Jurnalul de adaptare (/var/lib/remote-setup) se păstrează.
#  3. identifică receptorul IR și îți cere, pe rând: Sus, Jos, Stânga, Dreapta,
#     OK, Return, Home și o tastă de rezervă (va funcționa ca Esc)
#  4. aplică maparea, o testează interactiv și, dacă o confirmi, o face
#     permanentă (serviciu systemd, încărcat la fiecare boot)
#  5. dacă Return nu funcționează, încearcă automat alte metode și reține în
#     jurnal ce a eșuat, ca rulările viitoare să le sară
#
# Taste mapate:   Sus/Jos/Stânga/Dreapta -> săgeți, OK -> Enter,
#                 Home -> F1 (selectorul rofi din app-control.sh),
#                 Return -> metoda care funcționează (vezi STRAT_* mai jos),
#                 tasta de rezervă -> Esc
# Volum, mute, power: rămân la televizor (nu se mapează nimic).
#
# Atenție: dacă telecomanda comandă și televizorul (ex. telecomandă Samsung),
# alege taste pe care TV-ul nu reacționează (de ex. nu Home/Smart Hub).
#
# Rulare:   sudo bash remote-setup.sh
# Reluare completă (șterge și jurnalul de adaptare):  sudo bash remote-setup.sh --reset
#

set -u

if [ "$EUID" -ne 0 ]; then
    echo "Rulează cu sudo: sudo bash $0"
    exit 1
fi

RESET=0
[ "${1:-}" = "--reset" ] && RESET=1

KIOSK_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -z "$KIOSK_USER" ] || [ "$KIOSK_USER" = "root" ]; then
    echo "Nu am putut determina utilizatorul kiosk-ului. Rulează cu: sudo bash $0 (dintr-un cont normal)."
    exit 1
fi
KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)

STATE_DIR=/var/lib/remote-setup
STATE_FILE="$STATE_DIR/state"
CONF_DIR=/etc/remote-setup
CONF_FILE="$CONF_DIR/remote.conf"
APPLY=/usr/local/sbin/remote-ir-apply
SERVICE=/etc/systemd/system/remote-ir.service

# ---------------------------------------------------------------------------
# Tabele: coduri Linux pentru tastele folosite (X keycode = cod + 8)
# ---------------------------------------------------------------------------
declare -A KEYNUM=(
    [KEY_ESC]=1 [KEY_BACKSPACE]=14 [KEY_ENTER]=28 [KEY_F1]=59 [KEY_F7]=65
    [KEY_UP]=103 [KEY_LEFT]=105 [KEY_RIGHT]=106 [KEY_DOWN]=108 [KEY_BACK]=158
)
declare -A KEYREV=()
for k in "${!KEYNUM[@]}"; do KEYREV[${KEYNUM[$k]}]="$k"; done

# Pașii interactivi
STEPS=(up down left right ok ret home backup)
declare -A PROMPT=(
    [up]="SUS (Up)"
    [down]="JOS (Down)"
    [left]="STÂNGA (Left)"
    [right]="DREAPTA (Right)"
    [ok]="OK (Enter)"
    [ret]="RETURN (înapoi)"
    [home]="HOME (Acasă) - va deschide selectorul rofi"
    [backup]="o tastă la alegere, REZERVĂ pentru Return (va funcționa ca Esc)"
)
declare -A SHORT=(
    [up]="Sus" [down]="Jos" [left]="Stânga" [right]="Dreapta"
    [ok]="OK" [ret]="Return" [home]="Home" [backup]="tasta de rezervă"
)

# Strategii pentru tasta Return (se încearcă în ordine; cele eșuate se rețin)
#   1: KEY_BACK            -> XF86Back, tratat de Chromium ca "înapoi"
#   2: F7 + i3 + xdotool   -> i3 trimite explicit Alt+Stânga către Chromium
#   3: KEY_ESC
#   4: KEY_BACKSPACE
STRAT_NAME=("" "KEY_BACK (XF86Back)" "F7 + xdotool Alt+Stânga prin i3" "KEY_ESC" "KEY_BACKSPACE")
STRAT_KEY=("" "KEY_BACK" "KEY_F7" "KEY_ESC" "KEY_BACKSPACE")
STRAT_I3=("" "" "bindsym F7 exec --no-startup-id xdotool key --clearmodifiers alt+Left" "" "")

# ---------------------------------------------------------------------------
# Stare (jurnal de adaptare) - supraviețuiește ștergerii configurării
# ---------------------------------------------------------------------------
FAILED_RETURN=""
GOOD_RETURN=""
S_PROTOS=""
declare -A C=()
PROTOCOLS=""

if [ "$RESET" -eq 1 ]; then
    rm -rf "$STATE_DIR"
fi
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

save_state() {
    mkdir -p "$STATE_DIR"
    {
        echo "FAILED_RETURN=\"$FAILED_RETURN\""
        echo "GOOD_RETURN=\"$GOOD_RETURN\""
        echo "S_PROTOS=\"${PROTOCOLS:-$S_PROTOS}\""
        for step in "${STEPS[@]}"; do
            echo "SC_$step=\"${C[$step]:-}\""
        done
    } > "$STATE_FILE"
}

ask_yn() {
    local a
    while true; do
        read -r -p "$1 [d/n]: " a
        case "${a,,}" in
            d|da|y|yes) return 0 ;;
            n|nu|no)    return 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# [1] Pachete
# ---------------------------------------------------------------------------
echo ">>> [1/6] Verific pachetele necesare..."
export DEBIAN_FRONTEND=noninteractive
need=()
command -v ir-keytable >/dev/null 2>&1 || need+=(ir-keytable)
command -v xdotool     >/dev/null 2>&1 || need+=(xdotool)
command -v xinput      >/dev/null 2>&1 || need+=(xinput)
if [ "${#need[@]}" -gt 0 ]; then
    echo "    Instalez: ${need[*]}"
    apt-get update -qq
    if ! apt-get install -y "${need[@]}"; then
        echo "!!! Instalarea a eșuat; încerc v4l-utils (conține ir-keytable)..."
        apt-get install -y v4l-utils xdotool xinput || true
    fi
fi
if ! command -v ir-keytable >/dev/null 2>&1; then
    echo "!!! ir-keytable lipsește și nu a putut fi instalat (internet?). Ies."
    exit 1
fi
echo "    OK."

# ---------------------------------------------------------------------------
# Detectare X / i3 (opțional - fără ele, testul se face doar la nivel de kernel)
# ---------------------------------------------------------------------------
XAUTH=$(ls -t "$KIOSK_HOME"/.serverauth.* 2>/dev/null | head -n1 || true)
if [ -z "$XAUTH" ] && [ -f "$KIOSK_HOME/.Xauthority" ]; then
    XAUTH="$KIOSK_HOME/.Xauthority"
fi
XOK=0
if [ -n "$XAUTH" ] && sudo -u "$KIOSK_USER" env DISPLAY=:0 XAUTHORITY="$XAUTH" xinput list >/dev/null 2>&1; then
    XOK=1
fi

I3CFG=""
for f in "$KIOSK_HOME/.config/i3/config" "$KIOSK_HOME/.i3/config"; do
    if [ -f "$f" ]; then I3CFG="$f"; break; fi
done

i3_block_remove() {
    [ -n "$I3CFG" ] || return 0
    sed -i '/^# remote-setup-begin$/,/^# remote-setup-end$/d' "$I3CFG"
}

has_bind() {   # $1 = tasta (ex. F1), căutată în afara blocului nostru
    [ -n "$I3CFG" ] || return 1
    sed '/^# remote-setup-begin$/,/^# remote-setup-end$/d' "$I3CFG" \
        | grep -Eq "^[[:space:]]*bindsym[[:space:]]+(--[a-z-]+[[:space:]]+)*$1[[:space:]]"
}

i3_check_errors() {
    sudo -u "$KIOSK_USER" env DISPLAY=:0 ${XAUTH:+XAUTHORITY="$XAUTH"} i3 -C -c "$I3CFG" 2>&1 | grep -c "ERROR"
}

i3_set_block() {   # $1 = conținutul blocului (poate fi gol)
    [ -n "$I3CFG" ] || return 1
    i3_block_remove
    [ -n "${1:-}" ] || return 0
    cp -n "$I3CFG" "$I3CFG.remote-setup.bak" 2>/dev/null || true
    local before after
    before=$(i3_check_errors)
    { echo "# remote-setup-begin"; printf '%s\n' "$1"; echo "# remote-setup-end"; } >> "$I3CFG"
    after=$(i3_check_errors)
    if [ "${after:-0}" -gt "${before:-0}" ]; then
        echo "!!! i3 raportează erori noi după modificare - anulez blocul."
        i3_block_remove
        return 1
    fi
    return 0
}

i3_reload() {
    [ "$XOK" -eq 1 ] || return 1
    sudo -u "$KIOSK_USER" env DISPLAY=:0 XAUTHORITY="$XAUTH" i3-msg reload >/dev/null 2>&1
}

build_block() {   # $1 = numărul strategiei
    local lines=""
    if ! has_bind F1 && [ -x "$KIOSK_HOME/app-control.sh" ]; then
        lines+='bindsym F1 exec --no-startup-id "~/app-control.sh toggle"'$'\n'
    fi
    if [ -n "${STRAT_I3[$1]}" ]; then
        lines+="${STRAT_I3[$1]}"$'\n'
    fi
    printf '%s' "$lines"
}

# ---------------------------------------------------------------------------
# [2] Ștergere configurări existente
# ---------------------------------------------------------------------------
echo ">>> [2/6] Șterg configurările de telecomandă existente..."
for u in philips-ir hama-ir remote-ir; do
    systemctl disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u.service"
done
rm -f /etc/udev/rules.d/80-philips-ir.rules /etc/udev/rules.d/80-remote-ir.rules
rm -rf "$CONF_DIR"
rm -f "$APPLY"
systemctl daemon-reload
i3_block_remove
echo "    OK."

# ---------------------------------------------------------------------------
# [3] Identificare receptor IR
# ---------------------------------------------------------------------------
echo ">>> [3/6] Caut receptorul IR..."
RC_LIST=()
for d in /sys/class/rc/rc*; do
    [ -e "$d" ] && RC_LIST+=("$(basename "$d")")
done

if [ "${#RC_LIST[@]}" -eq 0 ]; then
    echo "!!! Nu există niciun receptor IR (/sys/class/rc/rc*)."
    echo "    Dispozitive de intrare văzute de sistem:"
    grep -E "^N: Name=" /proc/bus/input/devices | sed 's/^/      /'
    echo "    Dacă telecomanda este Bluetooth/radio (HID), nu e acoperită de acest script;"
    echo "    pentru IR ai nevoie de un receptor (integrat sau USB, ex. Flirc/MCE)."
    exit 1
fi

for rc in "${RC_LIST[@]}"; do
    name=$(ir-keytable -s "$rc" 2>/dev/null | sed -n 's/^[[:space:]]*Name: *//p')
    echo "    $rc: ${name:-necunoscut}"
done
PRIMARY_RC="${RC_LIST[0]}"
echo "    Folosesc: $PRIMARY_RC"

SUPPORTED=$(ir-keytable -s "$PRIMARY_RC" 2>/dev/null | sed -n 's/.*Supported kernel protocols: *//p')
if [ -z "$SUPPORTED" ]; then SUPPORTED="lirc rc-5 nec rc-6 sony jvc"; fi

# Pentru captură: activăm toate protocoalele suportate, tabela de taste goală
# (ca tastele apăsate la captură să nu declanșeze nimic în Stremio/rofi).
enable_protocols() {   # $1 = receptor, $2 = listă separată prin spațiu
    local args=() p
    for p in $2; do args+=(-p "$p"); done
    ir-keytable -s "$1" "${args[@]}" >/dev/null 2>&1
}
for rc in "${RC_LIST[@]}"; do
    enable_protocols "$rc" "$SUPPORTED"
    ir-keytable -s "$rc" -c >/dev/null 2>&1
done

# ---------------------------------------------------------------------------
# [4] Captura tastelor
# ---------------------------------------------------------------------------
CAP_CODE=""
CAP_PROTO=""

capture_scancode() {   # $1 = receptor; setează CAP_CODE / CAP_PROTO
    local rc="$1" tmp pid i line n=0
    CAP_CODE=""
    CAP_PROTO=""
    tmp=$(mktemp)
    stdbuf -oL ir-keytable -s "$rc" -t >"$tmp" 2>&1 &
    pid=$!
    for i in $(seq 1 200); do
        line=$(grep -m1 -E 'protocol\([^)]*\): scancode = 0x[0-9a-fA-F]+$' "$tmp" 2>/dev/null)
        if [ -n "$line" ]; then
            CAP_PROTO=$(sed -E 's/.*protocol\(([^)]*)\).*/\1/' <<<"$line")
            CAP_CODE=$(sed -E 's/.*scancode = (0x[0-9a-fA-F]+)$/\1/' <<<"$line")
            break
        fi
        line=$(grep -m1 -E 'EV_MSC.*scancode = 0x[0-9a-fA-F]+$' "$tmp" 2>/dev/null)
        if [ -n "$line" ]; then
            n=$((n + 1))
            if [ "$n" -ge 4 ]; then
                CAP_CODE=$(sed -E 's/.*scancode = (0x[0-9a-fA-F]+)$/\1/' <<<"$line")
                break
            fi
        fi
        sleep 0.1
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$tmp"
    [ -n "$CAP_CODE" ] || return 1
    CAP_CODE=$(printf '0x%x' "$((CAP_CODE))")
    return 0
}

norm_proto() {   # varianta raportată -> numele care se activează în kernel
    case "$1" in
        nec|necx|nec32)               echo nec ;;
        rc-5-sz)                      echo rc-5-sz ;;
        rc-5*)                        echo rc-5 ;;
        rc-6*)                        echo rc-6 ;;
        sony*)                        echo sony ;;
        rc-mm*)                       echo rc-mm ;;
        *)                            echo "$1" ;;
    esac
}

echo ">>> [4/6] Captura tastelor telecomenzii"
USE_SAVED=0
all_saved=1
for step in "${STEPS[@]}"; do
    v="SC_$step"
    [ -n "${!v:-}" ] || all_saved=0
done
if [ "$all_saved" -eq 1 ]; then
    echo "    Am găsit coduri salvate dintr-o rulare anterioară:"
    for step in "${STEPS[@]}"; do v="SC_$step"; echo "      ${SHORT[$step]}: ${!v}"; done
    if ask_yn "    Le refolosesc (fără să mai apăs tastele)?"; then
        USE_SAVED=1
        for step in "${STEPS[@]}"; do v="SC_$step"; C[$step]="${!v}"; done
        PROTOCOLS="${S_PROTOS:-lirc}"
    fi
fi

if [ "$USE_SAVED" -eq 0 ]; then
    echo "    Îndreaptă telecomanda spre receptorul IR. Pentru fiecare cerere, apasă"
    echo "    O SINGURĂ DATĂ tasta cerută și așteaptă (aprox. 15 secunde per cerere)."
    declare -A PSEEN=()
    for step in "${STEPS[@]}"; do
        while true; do
            echo
            echo "  ▶ Apasă acum tasta: ${PROMPT[$step]}"
            if ! capture_scancode "$PRIMARY_RC"; then
                echo "    Nu am primit nimic."
                read -r -p "    Enter = reîncerc, q = renunț: " ans
                if [ "${ans:-}" = "q" ]; then echo "Renunț."; exit 1; fi
                continue
            fi
            dup=""
            for other in "${STEPS[@]}"; do
                if [ "${C[$other]:-}" = "$CAP_CODE" ]; then dup="$other"; fi
            done
            if [ -n "$dup" ]; then
                echo "    Codul $CAP_CODE e deja folosit pentru: ${SHORT[$dup]}. Apasă altă tasta."
                sleep 1
                continue
            fi
            C[$step]="$CAP_CODE"
            if [ -n "$CAP_PROTO" ]; then PSEEN[$(norm_proto "$CAP_PROTO")]=1; fi
            echo "    Primit: $CAP_CODE ${CAP_PROTO:+(protocol $CAP_PROTO)}"
            sleep 1.2   # lasă repetările tastei să treacă
            break
        done
    done
    if [ "${#PSEEN[@]}" -gt 0 ]; then
        PROTOCOLS="lirc"
        for p in "${!PSEEN[@]}"; do PROTOCOLS="$PROTOCOLS $p"; done
    else
        PROTOCOLS="$SUPPORTED"
    fi
fi
echo
echo "    Protocoale folosite: $PROTOCOLS"
save_state

# ---------------------------------------------------------------------------
# [5] Aplicare, test, adaptare
# ---------------------------------------------------------------------------
build_map() {   # $1 = numele tastei pentru Return
    MAP="${C[up]}=KEY_UP,${C[down]}=KEY_DOWN,${C[left]}=KEY_LEFT,${C[right]}=KEY_RIGHT"
    MAP="$MAP,${C[ok]}=KEY_ENTER,${C[home]}=KEY_F1,${C[ret]}=$1,${C[backup]}=KEY_ESC"
}

apply_runtime() {
    local rc
    for rc in "${RC_LIST[@]}"; do
        enable_protocols "$rc" "$PROTOCOLS"
        ir-keytable -s "$rc" -c -k "$MAP" >/dev/null 2>&1 || ir-keytable -s "$rc" -c -k "$MAP"
    done
}

read_event_x() {   # afișează numele tastei primite de X, sau nimic la timeout
    local tmp code="" i
    tmp=$(mktemp)
    sudo -u "$KIOSK_USER" env DISPLAY=:0 XAUTHORITY="$XAUTH" \
        stdbuf -oL xinput test-xi2 --root >"$tmp" 2>&1 &
    for i in $(seq 1 200); do
        code=$(awk '/RawKeyPress/{f=1;next} f && /detail:/{print $2; exit}' "$tmp")
        [ -n "$code" ] && break
        sleep 0.1
    done
    pkill -f 'xinput test-xi2 --root' 2>/dev/null
    rm -f "$tmp"
    if [ -n "$code" ]; then
        echo "${KEYREV[$((code - 8))]:-KEYCODE_$((code - 8))}"
    fi
}

read_event_k() {   # varianta la nivel de kernel (când X nu e disponibil)
    local tmp name="" i
    tmp=$(mktemp)
    stdbuf -oL ir-keytable -s "$PRIMARY_RC" -t >"$tmp" 2>&1 &
    local pid=$!
    for i in $(seq 1 200); do
        name=$(grep -m1 -oE 'key_down: KEY_[A-Z0-9_]+' "$tmp" | sed 's/key_down: //')
        [ -n "$name" ] && break
        sleep 0.1
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$tmp"
    [ -n "$name" ] && echo "$name"
}

verify_keys() {   # $1 = tasta pentru Return; întoarce 0 dacă toate corespund
    local retkey="$1" bad=0 step exp got
    declare -A EXP=(
        [up]=KEY_UP [down]=KEY_DOWN [left]=KEY_LEFT [right]=KEY_RIGHT
        [ok]=KEY_ENTER [home]=KEY_F1 [ret]="$retkey" [backup]=KEY_ESC
    )
    if [ "$XOK" -eq 1 ]; then
        echo "    Test la nivel de X (ce primește efectiv ecranul)."
    else
        echo "    X nu e disponibil - testez doar la nivel de kernel."
    fi
    for step in up down left right ret backup ok home; do
        exp="${EXP[$step]}"
        echo "  ▶ Apasă: ${SHORT[$step]}   (aștept $exp)"
        if [ "$XOK" -eq 1 ]; then got=$(read_event_x); else got=$(read_event_k); fi
        if [ -z "$got" ]; then
            echo "    ✗ nimic primit"; bad=1
        elif [ "$got" = "$exp" ]; then
            echo "    ✓ $got"
        else
            echo "    ✗ am primit $got în loc de $exp"; bad=1
        fi
        sleep 1
    done
    # Home a deschis selectorul rofi: îl închidem
    sudo -u "$KIOSK_USER" pkill rofi 2>/dev/null || true
    return "$bad"
}

echo ">>> [5/6] Aplic maparea și o testez"
if [ -z "$I3CFG" ]; then
    echo "    (Nu am găsit configul i3 al utilizatorului - metoda cu xdotool/F7 și legarea F1 sunt sărite.)"
fi

# Ordinea strategiilor: cea care a funcționat data trecută, apoi restul (fără cele eșuate)
ORDER=""
if [ -n "$GOOD_RETURN" ] && ! [[ " $FAILED_RETURN " == *" $GOOD_RETURN "* ]]; then
    ORDER="$GOOD_RETURN"
fi
for s in 1 2 3 4; do
    [[ " $FAILED_RETURN " == *" $s "* ]] && continue
    [ "$s" = "$GOOD_RETURN" ] && continue
    ORDER="$ORDER $s"
done
if [ -z "${ORDER// /}" ]; then
    echo "!!! Toate metodele pentru Return au eșuat la rulările anterioare."
    echo "    Rulează cu --reset ca să le încerci din nou: sudo bash $0 --reset"
    exit 1
fi

FINAL=""
for s in $ORDER; do
    echo
    echo "---- Metoda $s pentru Return: ${STRAT_NAME[$s]} ----"
    if [ "$s" = "2" ]; then
        if [ -z "$I3CFG" ] || has_bind F7 || ! command -v xdotool >/dev/null 2>&1; then
            echo "    Sărit (lipsește configul i3 / xdotool, sau F7 e deja folosit în i3)."
            continue
        fi
    fi
    if [ -n "$I3CFG" ]; then
        if ! i3_set_block "$(build_block "$s")"; then
            if [ "$s" = "2" ]; then echo "    Sărit (blocul i3 a fost refuzat)."; continue; fi
        fi
        i3_reload || echo "    (Nu am putut reîncărca i3 acum; modificarea se aplică după reboot.)"
        sleep 1
    fi
    build_map "${STRAT_KEY[$s]}"
    apply_runtime
    verify_keys "${STRAT_KEY[$s]}" || echo "    Unele taste nu au ajuns cum era de așteptat (vezi mai sus)."

    echo
    echo "  Acum testează pe TV, cu telecomanda:"
    echo "    - săgețile mută selecția, OK deschide, Home arată selectorul rofi"
    echo "    - intră în Stremio pe pagina unui FILM (nu pe pagina principală) și apasă Return"
    if ! ask_yn "  Săgețile, OK și Home funcționează corect?"; then
        echo
        echo "!!! Problema nu ține de Return. Posibile cauze: tasta Home nu ajunge la i3,"
        echo "    sau scriptul app-control.sh nu rulează. Verifică cu tastatura: F1 trebuie să"
        echo "    arate selectorul. Trimite-mi rezultatul testului de mai sus."
        save_state
        exit 1
    fi
    if ask_yn "  Return face 'înapoi' (pe pagina unui film)?"; then
        GOOD_RETURN="$s"
        FINAL="$s"
        break
    fi
    FAILED_RETURN="$FAILED_RETURN $s"
    FAILED_RETURN="${FAILED_RETURN# }"
    save_state
    echo "    Metoda $s a eșuat - reținută în jurnal. Trec la următoarea."
done

if [ -z "$FINAL" ]; then
    echo
    echo "Nicio metodă nu a făcut Return să funcționeze."
    echo "Rămân funcționale: săgeți, OK, Home (rofi) și tasta de rezervă (Esc)."
    if ask_yn "Păstrez totuși configurarea (fără Return funcțional)?"; then
        FINAL=1
        i3_set_block "$(build_block 1)" || true
        build_map "KEY_BACK"
    else
        i3_block_remove
        i3_reload || true
        save_state
        echo "Configurarea nu a fost făcută permanentă."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# [6] Permanentizare
# ---------------------------------------------------------------------------
echo ">>> [6/6] Fac configurarea permanentă..."
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF
# generat de remote-setup.sh
PROTOCOLS="$PROTOCOLS"
MAP="$MAP"
RETURN_STRATEGY="$FINAL"
EOF

cat > "$APPLY" <<'EOF'
#!/bin/bash
# Încarcă tabela de taste a telecomenzii IR (generat de remote-setup.sh)
CONF=/etc/remote-setup/remote.conf
[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF"
sleep 2
for i in $(seq 1 20); do
    ls /sys/class/rc/rc* >/dev/null 2>&1 && break
    sleep 1
done
args=()
for p in $PROTOCOLS; do args+=(-p "$p"); done
for d in /sys/class/rc/rc*; do
    [ -e "$d" ] || continue
    rc=$(basename "$d")
    /usr/bin/ir-keytable -s "$rc" "${args[@]}" >/dev/null 2>&1
    /usr/bin/ir-keytable -s "$rc" -c -k "$MAP"
done
EOF
chmod +x "$APPLY"

IRK=$(command -v ir-keytable)
if [ "$IRK" != "/usr/bin/ir-keytable" ]; then
    sed -i "s#/usr/bin/ir-keytable#$IRK#g" "$APPLY"
fi

cat > "$SERVICE" <<EOF
[Unit]
Description=Keymap telecomandă IR (remote-setup)
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=$APPLY
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable remote-ir.service >/dev/null 2>&1
systemctl restart remote-ir.service
save_state

echo
echo "=== Gata. ==="
echo "Return: metoda $FINAL (${STRAT_NAME[$FINAL]:-fără Return funcțional})"
echo "Hartă: $MAP"
echo "Serviciu: remote-ir.service (activ la fiecare boot)"
echo "Verifică după reboot: sudo reboot"
echo "Jurnal de adaptare: $STATE_FILE   (reluare completă: sudo bash $0 --reset)"
