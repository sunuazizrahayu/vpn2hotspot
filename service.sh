#!/system/bin/sh

# VPN Gateway
# Route hotspot / USB tethering clients through a VpnService tun interface.
#
# Optional config: /data/adb/vpn-gateway.conf
#   TUN_NAME=auto          # auto | tun0 | wg0 ...
#   NAT=1                  # 1 = MASQUERADE client traffic to the tunnel address
#   DNS_REDIRECT=1         # 1 = redirect client UDP/53 to DNS_SERVER
#   DNS_SERVER=1.1.1.1
#   CLIENT_IFACES=""       # e.g. "ap0 rndis0"; empty = auto detect
#   VPN_TABLE=5000
#   RET_TABLE=5001

CONF=/data/adb/vpn-gateway.conf
[ -f "$CONF" ] && . "$CONF"

TUN_NAME="${TUN_NAME:-auto}"
NAT="${NAT:-1}"
DNS_REDIRECT="${DNS_REDIRECT:-1}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"
CLIENT_IFACES="${CLIENT_IFACES:-}"
VPN_TABLE="${VPN_TABLE:-5000}"
RET_TABLE="${RET_TABLE:-5001}"

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

log() {
    echo "vpn-gateway: $*"
    [ -x /system/bin/log ] && /system/bin/log -t vpn-gateway "$*" 2>/dev/null
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
}

iface_addr() {
    "$IP" -o -4 addr show dev "$1" 2>/dev/null |
        sed -n 's/.* inet \([0-9.]*\/[0-9]*\).*/\1/p' | head -n 1
}

iface_network() {
    local iface="$1" addr prefix net
    addr=$(iface_addr "$iface")
    [ -n "$addr" ] || return 1

    # Prefer the connected route installed by netd, works for any prefix length.
    net=$(printf '%s\n' "$ALL_ROUTES" |
        sed -n "s/^\([0-9.]*\/[0-9]*\) dev $iface .*/\1/p" | head -n 1)
    if [ -n "$net" ]; then
        echo "$net"
        return 0
    fi

    # Fallback: assume the usual /24 used by Android tethering.
    prefix=${addr#*/}
    addr=${addr%/*}
    if [ "$prefix" = "24" ]; then
        echo "${addr%.*}.0/24"
    else
        echo "$addr/$prefix"
    fi
}

is_uplink() {
    printf '%s\n' "$ALL_ROUTES" | grep -q "default .* dev $1 " 2>/dev/null
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
    while "$cmd" -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
    "$cmd" -t "$table" -F "$chain" 2>/dev/null
    "$cmd" -t "$table" -X "$chain" 2>/dev/null
}

cleanup_legacy() {
    # Remove rules created by vpn-gateway <= 1.1 in the built-in chains.
    local t c
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

ensure_chain() {
    local cmd="$1" table="$2" chain="$3"
    "$cmd" -t "$table" -n -L "$chain" >/dev/null 2>&1 ||
        "$cmd" -t "$table" -N "$chain" 2>/dev/null
    "$cmd" -t "$table" -F "$chain" 2>/dev/null
}

healthy() {
    "$IP" rule show 2>/dev/null | grep -q "lookup $VPN_TABLE" || return 1
    "$IP" route show table "$VPN_TABLE" 2>/dev/null | grep -q '^default' || return 1
    "$IPT" -C FORWARD -j "$FWD_CHAIN" >/dev/null 2>&1 || return 1
    if [ "$NAT" = "1" ]; then
        "$IPT" -t nat -C POSTROUTING -j "$NAT_CHAIN" >/dev/null 2>&1 || return 1
    fi
    return 0
}

apply() {
    local tun="$1" clients="$2" iface cidr pref

    cleanup_all

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

refresh_routes
cleanup_ip_forward_stub
cleanup_legacy
cleanup_all
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

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
    elif [ -n "$tun" ] && ! healthy; then
        need_apply=1
    fi

    if [ "$need_apply" = "1" ]; then
        if [ -n "$tun" ]; then
            if apply "$tun" "$clients"; then
                log "active tun=$tun nat=$NAT clients=[$clients]"
            else
                log "setup failed (tun=$tun), cleaning up"
                cleanup_all
            fi
        else
            cleanup_all
            log "waiting for a VPN tun interface"
        fi
        last_sig=$sig
    fi

    [ -n "$tun" ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    sleep 5
done
