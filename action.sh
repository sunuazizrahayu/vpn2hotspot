#!/system/bin/sh

# Action button handler for Magisk / KernelSU / APatch.
# Toggles the VPN Gateway service without disabling the module or rebooting.
#
# The manager streams stdout line by line, so print the direction first: that
# way the Action screen never sits blank while the service starts or stops.

DIR=${0%/*}
case "$DIR" in
    "$0"|"") DIR=$(pwd) ;;
esac
[ -f "$DIR/service.sh" ] || DIR=/data/adb/modules/vpn-gateway

SERVICE="$DIR/service.sh"

echo "VPN Gateway"
echo "Allow all LAN traffic routing to VPN."
echo

# Decide the direction before the slow work so something is on screen at once.
state=$(sh "$SERVICE" state 2>/dev/null)
if [ "$state" = "running" ]; then
    action=stop
    echo "Stopping the service, please wait..."
else
    action=start
    echo "Starting the service, please wait..."
fi

output=$(sh "$SERVICE" "$action" 2>&1)
rc=$?

echo "$output"
echo

if [ "$rc" -ne 0 ]; then
    echo "Failed to $action the service."
    echo "Log: /data/adb/vpn-gateway.log"
    exit "$rc"
fi

# Short summary so the result is readable at a glance.
is_on=0
sh "$SERVICE" status 2>/dev/null | while IFS='=' read -r key value; do
    case "$key" in
        state)
            if [ "$value" = "running" ]; then
                is_on=1
                echo "Status:  ON (running)"
            else
                is_on=0
                echo "Status:  OFF (stopped)"
            fi
            ;;
        pid)
            [ -n "$value" ] && echo "PID:     $value"
            ;;
        tun)
            [ "$is_on" = "1" ] && [ -n "$value" ] && echo "Tunnel:  $value"
            ;;
        client_count)
            [ "$is_on" = "1" ] && echo "Clients: $value"
            ;;
        applied)
            if [ "$value" = "yes" ]; then
                echo "Rules:   applied"
            else
                echo "Rules:   inactive"
            fi
            ;;
        nat)
            if [ "$value" = "1" ]; then
                echo "NAT:     on"
            else
                echo "NAT:     off"
            fi
            ;;
    esac
done

echo
echo "Done. You can close this page."
