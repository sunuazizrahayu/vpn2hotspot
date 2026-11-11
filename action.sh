#!/system/bin/sh

# Action button handler for Magisk / KernelSU.
# Toggles the VPN Gateway service without disabling the module or rebooting.

DIR=${0%/*}
case "$DIR" in
    "$0"|"") DIR=$(pwd) ;;
esac
[ -f "$DIR/service.sh" ] || DIR=/data/adb/modules/vpn-gateway

sh "$DIR/service.sh" toggle
