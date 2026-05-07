#!/bin/sh
# BGP selective routing setup for OpenWrt + AmneziaWG + BIRD2
# Run directly on router: wget -O /tmp/bgp-setup.sh <URL> && sh /tmp/bgp-setup.sh

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}${BOLD}[?]${NC} $1 "; }
ok()    { printf "${GREEN}${BOLD}[✓]${NC} $1\n"; }
warn()  { printf "${YELLOW}${BOLD}[!]${NC} $1\n"; }
err()   { printf "${RED}${BOLD}[✗]${NC} $1\n"; }
header(){ printf "\n${BOLD}═══ $1 ═══${NC}\n"; }

ask() {
    _prompt="$1"
    _default="$2"
    if [ -n "$_default" ]; then
        info "$_prompt [$_default]:"
    else
        info "$_prompt:"
    fi
    read -r _answer
    [ -z "$_answer" ] && _answer="$_default"
    printf "%s" "$_answer"
}

ask_yesno() {
    _prompt="$1"
    _default="${2:-y}"
    info "$_prompt [${_default}]?"
    read -r _answer
    [ -z "$_answer" ] && _answer="$_default"
    case "$_answer" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# ============================
clear
printf "${BOLD}"
cat << 'BANNER'

  ╔═══════════════════════════════════════════════╗
  ║   BGP Selective Routing Setup                ║
  ║   OpenWrt + WireGuard/AmneziaWG + BIRD2      ║
  ╚═══════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

# ============================
# Detect
# ============================
header "Auto-detecting network"
WAN_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
WAN_DEV=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
LAN_MASK=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f2 | head -1)
LAN_SUBNET=$(echo "$LAN_IP" | sed 's/\.[0-9]*$/.0/')

printf "  WAN:     ${GREEN}${WAN_DEV}${NC} gw ${GREEN}${WAN_GW}${NC}\n"
printf "  LAN:     ${GREEN}${LAN_IP}/${LAN_MASK}${NC}\n"

if [ -z "$WAN_GW" ] || [ -z "$LAN_IP" ]; then
    err "Cannot detect WAN/LAN. Configure manually."
    exit 1
fi

# ============================
# Basic config
# ============================
header "WireGuard / Tunnel"
WG_DEV=$(ask "Tunnel interface" "wg0")
printf "\n"

WG_LOCAL_IP=$(ip -4 addr show "$WG_DEV" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
if [ -n "$WG_LOCAL_IP" ]; then
    printf "  Detected: ${GREEN}${WG_LOCAL_IP}${NC}\n"
else
    WG_LOCAL_IP=$(ask "Router tunnel IP" "10.8.0.2")
    printf "\n"
fi

WG_SUBNET=$(echo "$WG_LOCAL_IP" | sed 's/\.[0-9]*$/.0/')
WG_GW=$(ask "Tunnel gateway (server IP)" "${WG_SUBNET%.*}.1")
printf "\n"

TABLE=$(ask "Kernel routing table" "100")
printf "\n"
PRIORITY=$(ask "ip rule priority" "1000")
printf "\n"

LOCAL_AS=$(ask "Local AS number" "65433")
printf "\n"

# ============================
# BGP Peers
# ============================
header "BGP Peers"

TOTAL_PEERS=0
PEER_NAMES=""
PEER_IPS=""
PEER_ASS=""
PEER_COMMS=""

add_peer() {
    _n="$1"
    printf "\n${BOLD}── Peer $((_n + 1)) ──${NC}\n"

    _name=$(ask "Name (lowercase, no spaces)" "peer$((_n + 1))")
    printf "\n"
    _ip=$(ask "Peer IP address" "")
    printf "\n"
    [ -z "$_ip" ] && { err "Peer IP required"; return 1; }
    _as=$(ask "Peer AS number" "")
    printf "\n"
    [ -z "$_as" ] && { err "AS number required"; return 1; }

    _comm=""
    if ask_yesno "Filter by BGP communities?" "n"; then
        printf "  Format: AS:NN,AS:NN  (example: 65432:100,65432:200)\n"
        _raw=$(ask "Communities" "")
        printf "\n"
        if [ -n "$_raw" ]; then
            _first=1
            OLDIFS="$IFS"
            IFS=','
            for c in $_raw; do
                _a=$(echo "$c" | cut -d: -f1)
                _nn=$(echo "$c" | cut -d: -f2)
                if [ "$_first" = 1 ]; then
                    _comm="($_a, $_nn)"
                    _first=0
                else
                    _comm="$_comm, ($_a, $_nn)"
                fi
            done
            IFS="$OLDIFS"
        fi
    fi

    PEER_NAMES="${PEER_NAMES}${_name}
"
    PEER_IPS="${PEER_IPS}${_ip}
"
    PEER_ASS="${PEER_ASS}${_as}
"
    PEER_COMMS="${PEER_COMMS}${_comm}
"
    TOTAL_PEERS=$((TOTAL_PEERS + 1))
}

add_peer 0

while ask_yesno "Add another BGP peer?" "n"; do
    add_peer $TOTAL_PEERS
done

# ============================
# Options
# ============================
header "Options"

ENABLE_FALLBACK=0
if ask_yesno "Enable fallback (flush BGP routes when tunnel is down)?" "y"; then
    ENABLE_FALLBACK=1
    FALLBACK_INTERVAL=$(ask "Check interval (minutes)" "1")
    printf "\n"
fi

ENABLE_SYSCTL=0
if ask_yesno "Optimize sysctl net buffers?" "y"; then
    ENABLE_SYSCTL=1
fi

# ============================
# Summary
# ============================
header "Summary"

printf "  Router ID:  ${GREEN}${LAN_IP}${NC}\n"
printf "  Tunnel:     ${GREEN}${WG_DEV}${NC} (${WG_LOCAL_IP}) gw ${WG_GW}\n"
printf "  Table:      ${GREEN}${TABLE}${NC} priority ${GREEN}${PRIORITY}${NC}\n"
printf "  LAN → BGP:  ${GREEN}${LAN_SUBNET}/${LAN_MASK}${NC}\n"
printf "  Local AS:   ${GREEN}${LOCAL_AS}${NC}\n"
printf "  BGP peers:  ${GREEN}${TOTAL_PEERS}${NC}\n"

_names=$(echo "$PEER_NAMES" | head -$TOTAL_PEERS)
_ips=$(echo "$PEER_IPS" | head -$TOTAL_PEERS)
_ass=$(echo "$PEER_ASS" | head -$TOTAL_PEERS)
_comms=$(echo "$PEER_COMMS" | head -$TOTAL_PEERS)

_i=0
echo "$_names" | while read -r _pname; do
    _pip=$(echo "$_ips" | sed -n "$((_i + 1))p")
    _pas=$(echo "$_ass" | sed -n "$((_i + 1))p")
    _pcom=$(echo "$_comms" | sed -n "$((_i + 1))p")
    printf "    ${BOLD}%s${NC}: %s AS%s" "$_pname" "$_pip" "$_pas"
    [ -n "$_pcom" ] && printf " [communities]"
    printf "\n"
    _i=$((_i + 1))
done

[ "$ENABLE_FALLBACK" = "1" ] && printf "  Fallback:   ${GREEN}every ${FALLBACK_INTERVAL} min${NC}\n"
[ "$ENABLE_SYSCTL" = "1" ] && printf "  Sysctl:     ${GREEN}optimized${NC}\n"
printf "\n"

if ! ask_yesno "Apply?" "y"; then
    warn "Aborted."
    exit 0
fi

# ============================
# Build configs
# ============================
header "Deploying"

# Static routes for BGP peers
STATIC_BLOCK=""
_i=0
echo "$_ips" | while read -r _pip; do
    [ -z "$_pip" ] && continue
    STATIC_BLOCK="${STATIC_BLOCK}    route ${_pip}/32 via ${WAN_GW};
"
done

# BGP protocol blocks
BGP_BLOCK=""
_i=0
echo "$_names" | while read -r _pname; do
    _pip=$(echo "$_ips" | sed -n "$((_i + 1))p")
    _pas=$(echo "$_ass" | sed -n "$((_i + 1))p")
    _pcom=$(echo "$_comms" | sed -n "$((_i + 1))p")
    [ -z "$_pname" ] && continue

    if [ -n "$_pcom" ]; then
        _import="import filter {
                if bgp_community ~ [${_pcom}] then {
                    gw = ${WG_GW};
                    accept;
                }
                reject;
            }"
    else
        _import="import filter {
                gw = ${WG_GW};
                accept;
            }"
    fi

    BGP_BLOCK="${BGP_BLOCK}
protocol bgp ${_pname} {
    local as ${LOCAL_AS};
    neighbor ${_pip} as ${_pas};
    multihop;
    hold time 240;
    keepalive time 80;

    ipv4 {
        ${_import};
        export none;
    };
    graceful restart on;
}
"
    _i=$((_i + 1))
done

# Build static routes string (outside subshell)
STATIC_STR=""
_i=0
for _pip in $(echo "$_ips" | head -$TOTAL_PEERS); do
    [ -z "$_ip" ] && continue
    STATIC_STR="${STATIC_STR}    route ${_pip}/32 via ${WAN_GW};
"
done

# Build BGP blocks string (outside subshell)
BGP_STR=""
_i=0
for _pname in $(echo "$_names" | head -$TOTAL_PEERS); do
    _pip=$(echo "$_ips" | sed -n "$((_i + 1))p")
    _pas=$(echo "$_ass" | sed -n "$((_i + 1))p")
    _pcom=$(echo "$_comms" | sed -n "$((_i + 1))p")
    [ -z "$_pname" ] && { _i=$((_i + 1)); continue; }

    if [ -n "$_pcom" ]; then
        _import="import filter {
                if bgp_community ~ [${_pcom}] then {
                    gw = ${WG_GW};
                    accept;
                }
                reject;
            }"
    else
        _import="import filter {
                gw = ${WG_GW};
                accept;
            }"
    fi

    BGP_STR="${BGP_STR}
protocol bgp ${_pname} {
    local as ${LOCAL_AS};
    neighbor ${_pip} as ${_pas};
    multihop;
    hold time 240;
    keepalive time 80;

    ipv4 {
        ${_import};
        export none;
    };
    graceful restart on;
}
"
    _i=$((_i + 1))
done

# ===== Install packages =====
printf "${CYAN}Installing BIRD2...${NC}\n"
apk update -q && apk add bird2
ok "BIRD2 installed"

# ===== Write bird.conf =====
printf "${CYAN}Writing /etc/bird.conf...${NC}\n"
cat > /etc/bird.conf << BIRDEOF
log syslog all;
router id ${LAN_IP};

protocol device {
    scan time 60;
}

protocol direct {
    disabled;
    ipv4;
}

protocol static s_uplink {
    ipv4;
${STATIC_STR}}

${BGP_STR}
protocol kernel kbgp {
    kernel table ${TABLE};
    learn;
    scan time 15;
    graceful restart on;
    ipv4 {
        import none;
        export filter {
            if source = RTS_BGP then {
                krt_prefsrc = ${WG_LOCAL_IP};
                accept;
            }
            reject;
        };
    };
}
BIRDEOF
ok "bird.conf written"

# ===== rc.local =====
printf "${CYAN}Writing /etc/rc.local...${NC}\n"
cat > /etc/rc.local << RCEOF
ip route add ${WG_SUBNET}/24 dev ${WG_DEV} table ${TABLE}
ip rule add from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null

exit 0
RCEOF
ok "rc.local written"

# ===== Hotplug =====
printf "${CYAN}Writing hotplug...${NC}\n"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/90-bgp-routing << HPEOF
#!/bin/sh
[ "\$INTERFACE" = "${WG_DEV}" ] && [ "\$ACTION" = "ifup" ] && {
    logger -t bgp-setup "${WG_DEV} up - restoring table ${TABLE}"
    sleep 5
    ip route add ${WG_SUBNET}/24 dev ${WG_DEV} table ${TABLE} 2>/dev/null
    ip rule add from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null
    /usr/sbin/birdc "configure soft" 2>/dev/null
    sleep 10
    logger -t bgp-setup "table ${TABLE}: \$(ip route show table ${TABLE} | wc -l) routes"
}
HPEOF
chmod +x /etc/hotplug.d/iface/90-bgp-routing
ok "hotplug written"

# ===== Fallback =====
if [ "$ENABLE_FALLBACK" = "1" ]; then
    printf "${CYAN}Setting up fallback...${NC}\n"
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/wg-fallback.sh << FBEOF
#!/bin/sh
GW=${WG_GW}
if ! ping -c 1 -W 2 \$GW > /dev/null 2>&1; then
    COUNT=\$(ip route show table ${TABLE} | wc -l)
    if [ "\$COUNT" -gt 1 ]; then
        logger -t wg-fallback "GW \$GW unreachable, flushing \$COUNT routes from table ${TABLE}"
        ip route flush table ${TABLE}
        ip route add ${WG_SUBNET}/24 dev ${WG_DEV} table ${TABLE} 2>/dev/null
    fi
fi
FBEOF
    chmod +x /usr/local/bin/wg-fallback.sh
    (crontab -l 2>/dev/null | grep -v wg-fallback; echo "*/${FALLBACK_INTERVAL} * * * * /usr/local/bin/wg-fallback.sh") | crontab -
    ok "fallback cron (every ${FALLBACK_INTERVAL} min)"
fi

# ===== Sysctl =====
if [ "$ENABLE_SYSCTL" = "1" ]; then
    printf "${CYAN}Configuring sysctl...${NC}\n"
    sysctl -w net.core.rmem_default=4194304 net.core.wmem_default=4194304 \
           net.core.rmem_max=4194304 net.core.wmem_max=4194304 > /dev/null
    printf 'net.core.rmem_default=4194304\nnet.core.wmem_default=4194304\nnet.core.rmem_max=4194304\nnet.core.wmem_max=4194304\n' > /etc/sysctl.conf
    ok "sysctl configured"
fi

# ===== Apply now =====
printf "${CYAN}Applying rules...${NC}\n"
ip route add ${WG_SUBNET}/24 dev ${WG_DEV} table ${TABLE} 2>/dev/null || true
ip rule del from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null || true
ip rule add from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null || true
# Remove stale WG route for LAN subnet if exists
ip route show | grep "${LAN_SUBNET}/.*dev ${WG_DEV}" | while read -r _line; do
    ip route del ${LAN_SUBNET}/24 dev ${WG_DEV} 2>/dev/null || true
done
ok "ip rules applied"

# ===== Start BIRD =====
printf "${CYAN}Starting BIRD...${NC}\n"
/etc/init.d/bird enable
/etc/init.d/bird restart
sleep 5

# ===== Done =====
header "Result"
printf "  ${BOLD}BIRD:${NC}\n"
birdc show protocols 2>&1 | sed 's/^/    /'
printf "\n  ${BOLD}Table %s:${NC} %s routes\n" "$TABLE" "$(ip route show table $TABLE | wc -l)"
printf "  ${BOLD}ip rules:${NC}\n"
ip rule show | sed 's/^/    /'

printf "\n${GREEN}${BOLD}Done!${NC}\n"
