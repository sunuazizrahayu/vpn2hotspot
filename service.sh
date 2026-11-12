#!/system/bin/sh

# VPN2Hotspot
# Route hotspot / USB tethering clients through a VpnService tun interface.
#
# Optional config: /data/adb/vpn2hotspot/config.conf
#   TUN_NAME=auto          # auto | tun0 | wg0 ...
#   NAT=1                  # 1 = MASQUERADE client traffic to the tunnel address
#   DNS_REDIRECT=1         # 1 = redirect client UDP/53 to DNS_SERVER
#   DNS_SERVER=1.1.1.1
#   CLIENT_IFACES=""       # e.g. "ap0 rndis0"; empty = auto detect
#   VPN_TABLE=5000
#   RET_TABLE=5001

DATA_DIR=${DATA_DIR:-/data/adb/vpn2hotspot}

# Runtime files live in their own directory, separate from the module payload
# so module updates can replace /data/adb/modules/vpn2hotspot safely.
mkdir -p "$DATA_DIR" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null

CONF=${CONF:-$DATA_DIR/config.conf}
[ -f "$CONF" ] && . "$CONF"

TUN_NAME="${TUN_NAME:-auto}"
NAT="${NAT:-1}"
DNS_REDIRECT="${DNS_REDIRECT:-1}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
CLIENT_IFACES="${CLIENT_IFACES:-}"
VPN_TABLE="${VPN_TABLE:-5000}"
RET_TABLE="${RET_TABLE:-5001}"

STATE_FILE=${STATE_FILE:-$DATA_DIR/state}
PID_FILE=${PID_FILE:-$DATA_DIR/pid}
LOG_FILE=${LOG_FILE:-$DATA_DIR/service.log}
STOP_FLAG=${STOP_FLAG:-$DATA_DIR/stopping}

# Resolve our own path so "start"/"toggle" can relaunch this script detached.
SELF=$0
case "$SELF" in
    */*) SELF="$(cd "${SELF%/*}" 2>/dev/null && pwd)/${SELF##*/}" ;;
    *) if [ -f "$SELF" ]; then SELF="$(pwd)/$SELF"; else SELF=/data/adb/modules/vpn2hotspot/service.sh; fi ;;
esac

# The module description is rewritten with a live status suffix so the manager
# (KernelSU, Magisk, APatch, ...) shows whether the service is on or off.
MODULE_PROP=${MODULE_PROP:-${SELF%/*}/module.prop}
[ -f "$MODULE_PROP" ] || MODULE_PROP=/data/adb/modules/vpn2hotspot/module.prop
BASE_DESC="Share your VPN connection with your tethered devices."

FWD_CHAIN=VPNGW_FWD
NAT_CHAIN=VPNGW_NAT
DNS_CHAIN=VPNGW_DNS
MSS_CHAIN=VPNGW_MSS
IP6_CHAIN=VPNGW6_FWD

IP=/system/bin/ip
IPT=/system/bin/iptables
IP6T=/system/bin/ip6tables
[ -x "$IP" ] || IP=ip
[ -x "$IPT" ] || IPT=iptables
[ -x "$IP6T" ] || IP6T=ip6tables

ALL_ROUTES=
ALL_ADDRS=
ALL_RULES=

log() {
    echo "vpn2hotspot: $(date '+%H:%M:%S') $*"
    [ -x /system/bin/log ] && /system/bin/log -t vpn2hotspot "$*" 2>/dev/null
    return 0
}

read_table_index() {
    local iface="$1" index name
    [ -r /data/misc/net/rt_tables ] || return 1
    while read -r index name; do
        [ "$name" = "$iface" ] && { echo "$index"; return 0; }
    done < /data/misc/net/rt_tables
    return 1
}

refresh_routes() {
    ALL_ROUTES=$("$IP" -o -4 route show table all 2>/dev/null)
    ALL_ADDRS=$("$IP" -o -4 addr show 2>/dev/null)
    ALL_RULES=$("$IP" rule show 2>/dev/null)
}

# The helpers below parse the snapshots taken by refresh_routes() instead of
# spawning "ip", "sed", and "grep" once per interface. That keeps a status
# refresh and a start check fast on devices with many interfaces.

iface_addr() {
    local idx name key addr rest

    while read -r idx name key addr rest; do
        [ "$name" = "$1" ] || continue
        [ "$key" = "inet" ] || continue
        echo "$addr"
        return 0
    done <<EOF
$ALL_ADDRS
EOF
    return 1
}

iface_network() {
    local iface="$1" line net

    iface_addr "$iface" >/dev/null || return 1

    # Prefer the connected route installed by netd, works for any prefix length.
    while IFS= read -r line; do
        case "$line" in
            *" dev $iface "*|*" dev $iface") ;;
            *) continue ;;
        esac
        net=${line%% *}
        case "$net" in
            */*) echo "$net"; return 0 ;;
        esac
    done <<EOF
$ALL_ROUTES
EOF

    # Fallback: assume the usual /24 used by Android tethering.
    net=$(iface_addr "$iface")
    case "$net" in
        */*) ;;
        *) return 1 ;;
    esac
    local addr=${net%/*} prefix=${net#*/}
    if [ "$prefix" = "24" ]; then
        echo "${addr%.*}.0/24"
    else
        echo "$net"
    fi
}

is_uplink() {
    local line

    while IFS= read -r line; do
        case "$line" in
            "default "*" dev $1 "*|"default "*" dev $1") return 0 ;;
        esac
    done <<EOF
$ALL_ROUTES
EOF
    return 1
}

detect_tun() {
    local n
    if [ -n "$TUN_NAME" ] && [ "$TUN_NAME" != "auto" ]; then
        [ -n "$(iface_addr "$TUN_NAME")" ] || return 1
        echo "$TUN_NAME"
        return 0
    fi

    for n in $(ls /sys/class/net 2>/dev/null); do
        case "$n" in
            tun[0-9]*|wg[0-9]*|ppp[0-9]*) ;;
            *) continue ;;
        esac
        [ -n "$(iface_addr "$n")" ] || continue
        [ -n "$(read_table_index "$n")" ] || continue
        echo "$n"
        return 0
    done
    return 1
}

list_clients() {
    local n cidr

    if [ -n "$CLIENT_IFACES" ]; then
        for n in $CLIENT_IFACES; do
            [ -e "/sys/class/net/$n" ] || continue
            cidr=$(iface_network "$n") || continue
            echo "$n $cidr"
        done
        return 0
    fi

    for n in $(ls /sys/class/net 2>/dev/null); do
        case "$n" in
            lo|tun[0-9]*|wg[0-9]*|ppp[0-9]*|rmnet*|ccmni*|dummy*|ifb*|sit*|ip6*|p2p*|rev_rmnet*|bond*|veth*) continue ;;
        esac
        [ -e "/sys/class/net/$n" ] || continue
        cidr=$(iface_network "$n") || continue
        is_uplink "$n" && continue
        echo "$n $cidr"
    done
}

cleanup_ip_forward_stub() {
    # Older versions bind-mounted a stub over the sysctl, which made
    # /proc/sys/net/ipv4/ip_forward read back as 0.
    if grep -q ' /proc/sys/net/ipv4/ip_forward ' /proc/mounts 2>/dev/null; then
        umount /proc/sys/net/ipv4/ip_forward 2>/dev/null
    fi
    rm -f /dev/ip_forward_stub 2>/dev/null
}

del_jump() {
    local cmd="$1" table="$2" parent="$3" chain="$4"

    # Only remove the jump. The chain itself is left in place: once it is
    # unreferenced it is harmless, and the next apply reuses and flushes it.
    # This avoids several slow iptables calls on every stop.
    while "$cmd" -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
}

cleanup_legacy() {
    # Remove rules created by the old vpn-gateway module (<= 1.1).
    # Deleting them costs dozens of iptables calls, so first check whether any
    # are actually installed. Our own rules live in custom chains and do not
    # match these patterns.
    local t c need=

    "$IPT" -S FORWARD 2>/dev/null | grep -qE ' (-i|-o) (tun[0-9]+|wg0) ' && need=1
    "$IPT" -t nat -S PREROUTING 2>/dev/null | grep -q 'DNAT' && need=1
    if [ -x "$IP6T" ]; then
        "$IP6T" -S FORWARD 2>/dev/null | grep -q 'icmp6-no-route' && need=1
    fi
    [ -n "$need" ] || return 0

    for t in tun0 tun1 tun2 tun3 wg0; do
        "$IPT" -D FORWARD -i "$t" -j ACCEPT 2>/dev/null
        for c in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
            "$IPT" -D FORWARD -s "$c" -o "$t" -j ACCEPT 2>/dev/null
            "$IPT" -t nat -D PREROUTING ! -i "$t" -s "$c" -p udp --dport 53 \
                -j DNAT --to 1.1.1.1 2>/dev/null
            "$IPT" -t nat -D PREROUTING ! -i "$t" -s "$c" -p udp --dport 53 \
                -j DNAT --to-destination 1.1.1.1 2>/dev/null
        done
    done
    if [ -x "$IP6T" ]; then
        while "$IP6T" -D FORWARD -j REJECT --reject-with icmp6-no-route 2>/dev/null; do :; done
    fi
}

cleanup_rules() {
    local line pref
    "$IP" rule show 2>/dev/null | while IFS= read -r line; do
        pref=${line%%:*}
        case "$pref" in
            5[0-9][0-9][0-9])
                case "$line" in
                    *"lookup $VPN_TABLE"*|*"lookup $RET_TABLE"*|*"lookup tun"*|*"lookup wg"*|*"iif tun"*|*"iif wg"*|*"goto 6000"*)
                        "$IP" rule del pref "$pref" 2>/dev/null
                        ;;
                esac
                ;;
            6000)
                case "$line" in
                    *"nop"*) "$IP" rule del pref 6000 2>/dev/null ;;
                esac
                ;;
        esac
    done
}

cleanup_all() {
    cleanup_rules
    del_jump "$IPT" filter FORWARD "$FWD_CHAIN"
    del_jump "$IPT" nat POSTROUTING "$NAT_CHAIN"
    del_jump "$IPT" nat PREROUTING "$DNS_CHAIN"
    del_jump "$IPT" mangle FORWARD "$MSS_CHAIN"
    [ -x "$IP6T" ] && del_jump "$IP6T" filter FORWARD "$IP6_CHAIN"
    "$IP" route flush table "$VPN_TABLE" 2>/dev/null
    "$IP" route flush table "$RET_TABLE" 2>/dev/null
}

# Cheap check used before cleanup: skip the expensive chain teardown when
# nothing from this module is installed.
rules_present() {
    "$IPT" -C FORWARD -j "$FWD_CHAIN" >/dev/null 2>&1 && return 0
    "$IPT" -t mangle -C FORWARD -j "$MSS_CHAIN" >/dev/null 2>&1 && return 0
    "$IPT" -t nat -C POSTROUTING -j "$NAT_CHAIN" >/dev/null 2>&1 && return 0
    "$IPT" -t nat -C PREROUTING -j "$DNS_CHAIN" >/dev/null 2>&1 && return 0
    "$IP" rule show 2>/dev/null | grep -q "lookup $RET_TABLE" && return 0
    "$IP" route show table "$VPN_TABLE" 2>/dev/null | grep -q . && return 0
    return 1
}

ensure_chain() {
    local cmd="$1" table="$2" chain="$3"
    "$cmd" -t "$table" -n -L "$chain" >/dev/null 2>&1 ||
        "$cmd" -t "$table" -N "$chain" 2>/dev/null
    "$cmd" -t "$table" -F "$chain" 2>/dev/null
}

healthy() {
    local tun="$1" clients="$2"

    [ -n "$tun" ] || return 1

    # Both the routes and the rules come from refresh_routes(), so a check does
    # not spawn "ip" again.
    case "$ALL_ROUTES" in
        *"default "*" dev $tun table $VPN_TABLE "*|*"default "*" dev $tun table $VPN_TABLE") ;;
        *) return 1 ;;
    esac
    case "$ALL_RULES" in
        *"iif $tun lookup $RET_TABLE"*) ;;
        *) return 1 ;;
    esac

    "$IPT" -C FORWARD -j "$FWD_CHAIN" >/dev/null 2>&1 || return 1
    if [ "$NAT" = "1" ]; then
        "$IPT" -t nat -C POSTROUTING -j "$NAT_CHAIN" >/dev/null 2>&1 || return 1
    fi
    # Client rules only exist while a client interface is detected.
    if [ -n "$clients" ]; then
        case "$ALL_RULES" in
            *"lookup $VPN_TABLE"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

apply() {
    local tun="$1" clients="$2" iface cidr pref

    rules_present && cleanup_all

    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

    # All forwarded client traffic goes to the tun. The VPN app itself may
    # exclude RFC1918 ranges from its own table, so do not rely on it.
    "$IP" route replace default dev "$tun" table "$VPN_TABLE" || return 1

    # Keep LAN-to-LAN and reverse traffic on the client interface.
    while read -r iface cidr; do
        [ -n "$iface" ] || continue
        "$IP" route replace "$cidr" dev "$iface" table "$VPN_TABLE" || return 1
        "$IP" route replace "$cidr" dev "$iface" table "$RET_TABLE" || return 1
    done <<EOF
$clients
EOF

    ensure_chain "$IPT" filter "$FWD_CHAIN"
    "$IPT" -I FORWARD -j "$FWD_CHAIN" || return 1
    "$IPT" -A "$FWD_CHAIN" -i "$tun" -j ACCEPT || return 1

    ensure_chain "$IPT" mangle "$MSS_CHAIN"
    "$IPT" -t mangle -I FORWARD -j "$MSS_CHAIN" || return 1
    "$IPT" -t mangle -A "$MSS_CHAIN" -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    ensure_chain "$IPT" nat "$NAT_CHAIN"
    "$IPT" -t nat -I POSTROUTING -j "$NAT_CHAIN" || return 1

    if [ "$DNS_REDIRECT" = "1" ]; then
        ensure_chain "$IPT" nat "$DNS_CHAIN"
        "$IPT" -t nat -I PREROUTING -j "$DNS_CHAIN" || return 1
    fi

    while read -r iface cidr; do
        [ -n "$iface" ] || continue
        "$IPT" -A "$FWD_CHAIN" -s "$cidr" -o "$tun" -j ACCEPT || return 1

        if [ "$NAT" = "1" ]; then
            "$IPT" -t nat -A "$NAT_CHAIN" -s "$cidr" -o "$tun" \
                -j MASQUERADE || return 1
        fi

        if [ "$DNS_REDIRECT" = "1" ]; then
            "$IPT" -t nat -A "$DNS_CHAIN" -s "$cidr" ! -i "$tun" \
                -p udp --dport 53 -j DNAT --to-destination "$DNS_SERVER" || return 1
        fi
    done <<EOF
$clients
EOF

    if [ -x "$IP6T" ]; then
        ensure_chain "$IP6T" filter "$IP6_CHAIN"
        "$IP6T" -I FORWARD -j "$IP6_CHAIN" 2>/dev/null
        "$IP6T" -A "$IP6_CHAIN" -j REJECT --reject-with icmp6-no-route 2>/dev/null
    fi

    "$IP" rule add iif lo goto 6000 pref 5000 || return 1
    "$IP" rule add iif "$tun" lookup "$RET_TABLE" pref 5010 || return 1
    "$IP" rule add iif "$tun" goto 6000 pref 5020 || return 1

    pref=5030
    while read -r iface cidr; do
        [ -n "$iface" ] || continue
        "$IP" rule add iif "$iface" lookup "$VPN_TABLE" pref "$pref" || return 1
        pref=$((pref + 1))
        "$IP" rule add from "$cidr" lookup "$VPN_TABLE" pref "$pref" || return 1
        pref=$((pref + 1))
    done <<EOF
$clients
EOF

    "$IP" rule add nop pref 6000 || return 1

    return 0
}

write_state() {
    printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null
}

read_state() {
    [ -r "$STATE_FILE" ] || return 1
    tr -d ' \t\r\n' < "$STATE_FILE" 2>/dev/null
}

# Show the service state in the module description with a single colored icon:
#   ✔️  service is running (green check)
#   ❌  service is stopped (red cross)
# The U+FE0F variation selector is required, otherwise these symbols fall back
# to the monochrome text glyphs.
# module.prop is replaced atomically, so a reader (or a concurrent update) can
# never see a partially written file and lose id/name/version/author.
update_description() {
    local mode="$1" current= desc tmp line has_id= has_name= has_version=
    [ -r "$MODULE_PROP" ] || return 0

    if [ "$mode" = "on" ]; then
        desc="✔️ $BASE_DESC"
    else
        desc="❌ $BASE_DESC"
    fi

    # Read the current value with the shell instead of sed/head; this runs on
    # every start and stop, so the saved process spawns add up.
    while IFS= read -r line; do
        case "$line" in
            description=*) current=${line#description=} ;;
        esac
    done < "$MODULE_PROP"
    [ "$current" = "$desc" ] && return 0

    tmp="${MODULE_PROP}.tmp.$$"
    : > "$tmp" 2>/dev/null || return 0
    while IFS= read -r line; do
        case "$line" in
            description=*) continue ;;
        esac
        printf '%s\n' "$line"
    done < "$MODULE_PROP" > "$tmp" 2>/dev/null
    printf 'description=%s\n' "$desc" >> "$tmp" 2>/dev/null

    # Refuse to swap in an incomplete copy.
    while IFS= read -r line; do
        case "$line" in
            id=*) has_id=1 ;;
            name=*) has_name=1 ;;
            version=*) has_version=1 ;;
        esac
    done < "$tmp"
    if [ ! -s "$tmp" ] || [ -z "$has_id" ] || [ -z "$has_name" ] || [ -z "$has_version" ]; then
        rm -f "$tmp"
        return 0
    fi

    chmod 644 "$tmp" 2>/dev/null
    chown 0:0 "$tmp" 2>/dev/null
    mv -f "$tmp" "$MODULE_PROP" 2>/dev/null || rm -f "$tmp"
    return 0
}

# List PIDs of the long running "service.sh run" process. The command line is
# matched on purpose so "start"/"stop"/"toggle" processes never match. The
# plain "service.sh" form catches instances started by older versions.
service_pids() {
    ps -eo pid,args 2>/dev/null | while read -r pid args; do
        case "$args" in
            *service.sh*" run"|*service.sh) echo "$pid" ;;
        esac
    done
}

is_running() {
    local pid cmd
    pid=$(head -n 1 "$PID_FILE" 2>/dev/null)
    case "$pid" in
        ''|*[!0-9]*) pid= ;;
    esac
    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
        cmd=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$cmd" in
            *service.sh*) echo "$pid"; return 0 ;;
        esac
    fi

    pid=$(service_pids | head -n 1)
    [ -n "$pid" ] || return 1
    echo "$pid"
    return 0
}

start_service() {
    local pid i tun wait_for_rules=

    [ "$1" = "wait" ] && wait_for_rules=1
    if pid=$(is_running); then
        write_state on
        echo "already running (pid $pid)"
        return 0
    fi

    write_state on
    rm -f "$PID_FILE" "$STOP_FLAG"
    : > "$LOG_FILE" 2>/dev/null

    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$SELF" run >> "$LOG_FILE" 2>&1 < /dev/null &
    else
        nohup sh "$SELF" run >> "$LOG_FILE" 2>&1 < /dev/null &
    fi

    # The toggle UI only needs to know that the worker is alive, so return at
    # the first PID sighting. "start wait" (used by the Action screen) stays
    # until the rules are installed so its summary is accurate.
    i=0
    while [ "$i" -lt 40 ]; do
        if pid=$(is_running); then
            if [ -z "$wait_for_rules" ]; then
                echo "started (pid $pid)"
                return 0
            fi
            refresh_routes
            tun=$(detect_tun)
            if [ -z "$tun" ] || healthy "$tun" "$(list_clients)"; then
                echo "started (pid $pid)"
                return 0
            fi
        fi
        sleep 0.15 2>/dev/null || sleep 1
        i=$((i + 1))
    done

    if pid=$(is_running); then
        echo "started (pid $pid)"
        return 0
    fi

    write_state off
    update_description off
    echo "failed to start (see $LOG_FILE)"
    return 1
}

stop_service() {
    local pid pids alive i

    write_state off

    # The PID file is authoritative and avoids a full process scan; fall back
    # to scanning only when it is missing or stale.
    if pid=$(is_running); then
        pids=$pid
    else
        pids=$(service_pids)
    fi

    if [ -z "$pids" ]; then
        rules_present && cleanup_all
        rm -f "$PID_FILE" "$STOP_FLAG"
        update_description off
        echo "already stopped"
        return 0
    fi

    # Let the worker exit immediately; this process does the teardown below.
    : > "$STOP_FLAG" 2>/dev/null
    for pid in $pids; do
        kill "$pid" 2>/dev/null
    done

    # Keep the wait short; the worker exits as soon as it sees STOP_FLAG and
    # the rules are removed by this process below.
    i=0
    while [ "$i" -lt 40 ]; do
        alive=
        for pid in $pids; do
            [ -d "/proc/$pid" ] && alive="$alive $pid"
        done
        [ -z "$alive" ] && break
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done

    for pid in $alive; do
        kill -9 "$pid" 2>/dev/null
    done

    rm -f "$STOP_FLAG"
    rules_present && cleanup_all
    rm -f "$PID_FILE"
    printf '%s vpn2hotspot: stopped\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE" 2>/dev/null
    update_description off
    echo "stopped"
    return 0
}

status_service() {
    local pid tun clients n

    if pid=$(is_running); then
        echo "state=running"
        echo "pid=$pid"
    else
        echo "state=stopped"
        echo "pid="
    fi

    refresh_routes
    tun=$(detect_tun)
    clients=$(list_clients)
    n=$(printf '%s\n' "$clients" | grep -c . 2>/dev/null)

    echo "tun=${tun}"
    echo "clients=$(printf '%s' "$clients" | tr '\n' ',')"
    echo "client_count=${n:-0}"
    echo "applied=$(if [ -n "$tun" ] && healthy "$tun" "$clients"; then echo yes; else echo no; fi)"
    if "$IPT" -t nat -C POSTROUTING -j "$NAT_CHAIN" >/dev/null 2>&1; then
        echo "nat=1"
    else
        echo "nat=0"
    fi
    echo "dns_redirect=$DNS_REDIRECT"
    echo "dns_server=$DNS_SERVER"
    echo "state_file=$(read_state)"
}

run_loop() {
    local tun clients sig last_sig need_apply sleep_pid

    rm -f "$STOP_FLAG"
    echo $$ > "$PID_FILE"
    write_state on
    update_description on
    # A plain "sleep 5" delays the TERM trap until sleep exits, so stopping
    # could take up to five seconds. Waiting on a background sleep lets the
    # signal be handled immediately.
    #
    # During a normal stop, stop_service raises STOP_FLAG and performs the
    # cleanup itself after this process exits. That keeps the teardown in one
    # place and makes stopping much faster. If the worker is signalled by
    # anything else, the trap still cleans up before exiting.
    trap '[ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null; if [ -f "$STOP_FLAG" ]; then rm -f "$PID_FILE"; exit 0; fi; rules_present && cleanup_all; rm -f "$PID_FILE"; update_description off; exit 0' TERM INT HUP

    cleanup_ip_forward_stub
    cleanup_legacy
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

    log "started (pid $$)"

    last_sig=
    while :; do
        refresh_routes

        tun=$(detect_tun)
        if [ -n "$tun" ]; then
            clients=$(list_clients)
            sig="$tun|$clients"
        else
            clients=
            sig="none"
        fi

        need_apply=0
        if [ "$sig" != "$last_sig" ]; then
            need_apply=1
        elif [ -n "$tun" ] && ! healthy "$tun" "$clients"; then
            need_apply=1
        fi

        if [ "$need_apply" = "1" ]; then
            if [ -n "$tun" ]; then
                if apply "$tun" "$clients"; then
                    log "active tun=$tun nat=$NAT clients=[$clients]"
                    update_description on
                else
                    log "setup failed (tun=$tun), cleaning up"
                    cleanup_all
                    update_description on
                fi
            else
                rules_present && cleanup_all
                log "waiting for a VPN tun interface"
                update_description on
            fi
            last_sig=$sig
        fi

        [ -n "$tun" ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
        sleep 5 &
        sleep_pid=$!
        wait "$sleep_pid"
    done
}

case "${1:-}" in
    run)
        run_loop
        ;;
    start)
        start_service "$2"
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service > /dev/null
        sleep 1
        start_service
        ;;
    toggle)
        if is_running > /dev/null; then
            stop_service
        else
            start_service
        fi
        ;;
    state)
        if is_running > /dev/null; then
            echo running
        else
            echo stopped
        fi
        ;;
    status)
        status_service
        ;;
    "")
        # Boot invocation. Respect a user requested "off" state.
        if [ "$(read_state)" = "off" ]; then
            update_description off
            log "disabled by user, not starting"
            exit 0
        fi
        exec sh "$SELF" run >> "$LOG_FILE" 2>&1
        ;;
    *)
        echo "usage: $0 [run|start|stop|restart|toggle|state|status]" >&2
        exit 2
        ;;
esac
