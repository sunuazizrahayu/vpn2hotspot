# VPN2Hotspot

A root module for Magisk, KernelSU, and APatch. It sends traffic from
Wi-Fi hotspot, USB/Bluetooth tethering, and LAN clients through the VpnService
tunnel that is already running on your phone, without creating a VPN of its
own.

## Install

1. Install `vpn2hotspot.zip` in your root manager.
2. Start the service from **Action** or the **WebUI**.

The service starts at boot unless you stopped it. A WebUI needs a manager that
supports module web pages (for example KernelSU).

Updates are published as GitHub releases and show up in your root manager.

## Usage

The module card shows the state: `✔️` running, `❌` stopped, `▶️` not started.
Action and WebUI toggle the service; their button locks while starting or
stopping.

```sh
su -c 'sh /data/adb/modules/vpn2hotspot/service.sh start'
su -c 'sh /data/adb/modules/vpn2hotspot/service.sh stop'
su -c 'sh /data/adb/modules/vpn2hotspot/service.sh status'
```

Other commands: `run`, `restart`, `toggle`, `state`.

## Configuration

Optional. Create `/data/adb/vpn2hotspot.conf`; common keys:

| Key | Default | Description |
|---|---|---|
| `TUN_NAME` | `auto` | VPN interface; `auto` detects `tun*`, `wg*`, `ppp*`. |
| `NAT` | `1` | `1` applies MASQUERADE to client traffic. |
| `DNS_REDIRECT` | `1` | Redirect client UDP/53 to `DNS_SERVER`. |
| `DNS_SERVER` | `1.1.1.1` | DNS server when redirect is enabled. |
| `CLIENT_IFACES` | empty | Force interfaces, e.g. `ap0 rndis0`. |

## Uninstall

Stop the service, remove the module, then optionally:

```sh
su -c 'rm -f /data/adb/vpn2hotspot.*'
```

## Build

```sh
make build   # creates vpn2hotspot.zip
```

## Credits

Based on the [`vpn-gateway`](https://github.com/Kr328/vpn-gateway) module by
**Kr328**. Maintained by **sunuazizrahayu**.
