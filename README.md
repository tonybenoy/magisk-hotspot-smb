# Hotspot + file server + torrents on boot (Magisk module)

At boot, as root, this module:

1. turns on the Wi-Fi hotspot on a fixed subnet (own DHCP) and shares the phone's internet over it
2. starts **Samba** (SMB shares of `/sdcard` and the torrent folder)
3. starts **Transmission** (torrent client with web UI)
4. optionally starts **SSH**, **Syncthing** and **WireGuard**

Everything is bundled (Termux's aarch64 packages). The Termux app is not needed and is not used.

## Install
Needs: a rooted phone with Magisk, adb on the PC (WSL: the Windows `adb.exe` is used automatically), python3.

    git clone <this repo> && cd magisk-hotspot-smb
    ./make-bundle.sh              # once: downloads Termux packages into prefix.tar.gz (~77 MB, not in git)
    cp config.example.sh config.sh   # optional: edit SSID/passwords; install.sh does this for you if missing
    ./install.sh                  # builds ../hotspot_smb.zip, flashes it via Magisk, adds your SSH key, reboots

`install.sh` options: `--ssid NAME`, `--key ~/.ssh/xyz.pub`, `--no-reboot`. Any `change-me*` password in `config.sh`
is replaced by a random one (printed at the end and saved to `.passwords`). The first boot unpacks the bundle
(~200 MB on disk) into the module folder, so it takes longer. Manual route: zip the files listed under "Repo layout"
as a flat zip and install it from the Magisk app.

Optional overrides without touching the module: put `KEY="value"` lines in `/sdcard/hotspot_smb.conf`.
They win over `config.sh` at boot.

## Repo layout
| Path | Purpose |
|---|---|
| `module.prop`, `service.sh` | Magisk module entry; `service.sh [part]` starts everything or one part |
| `nat.sh`, `lib.sh`, `watchdog.sh`, `sms.sh`, `sms-setup.sh` | internet sharing, shared helpers, watchdog, SMS |
| `passwd.sh`, `wg-server.sh` | password changer, WireGuard server config generator |
| `panel/` | web panel (busybox httpd + one CGI script) |
| `config.example.sh` | template; **`config.sh`, `.passwords`, `sms.conf` hold real secrets and are git-ignored** |
| `install.sh`, `make-bundle.sh`, `fetch-samba.py` | PC-side tooling (flash, build the bundle) |
| `prefix.tar.gz`, `termux-prefix/` | generated bundle, git-ignored |

## Services

| Service | Default | Address | Login |
|---|---|---|---|
| Hotspot | on | SSID `HOTSPOT_SSID` | `HOTSPOT_PASS` (WPA2) |
| Samba | on | `\\<ip>\share` (/sdcard), `\\<ip>\torrents` | `SMB_USER` / `SMB_PASS` |
| Transmission | on | `http://<ip>:9091` | `TR_USER` / `TR_PASS` |
| SSH | on (`ENABLE_SSH`) | `ssh -p 8022 root@<ip>` | key only |
| Syncthing | on (`ENABLE_SYNCTHING`) | `http://<ip>:8384` | `ST_USER` / `ST_PASS` |
| WireGuard | off (`ENABLE_WG`) | tunnel from `WG_CONF` | n/a |
| Web panel | on (`ENABLE_PANEL`) | `http://<ip>:8080` | `admin` / see below |

`<ip>` is `HOTSPOT_IP` (default `192.168.43.1`) or the address Android assigned.

### SMB discovery
`nmbd` (NetBIOS) is started next to `smbd`, so the phone answers to the name `PHONE` (change with
`SMB_NETBIOS_NAME`, default `PHONE`, set it in `config.sh` or `/sdcard/hotspot_smb.conf`).
`\\PHONE\share` works from Windows, and Linux/Android SMB clients that use NetBIOS find it.
Not covered: Windows 10/11's "Network" list (WS-Discovery) and macOS/Linux mDNS (Bonjour/Avahi),
because Termux's repo ships no responder for them. Connect by name or by IP.

### Unbound (local DNS) and friendly names
Hotspot clients get the phone as DNS (`HOTSPOT_IP`), plus the search domain `lan`. `unbound` makes **every**
`<anything>.lan` resolve to the phone and forwards the rest over DNS-over-TLS (Cloudflare, Quad9) with caching.
Android's own tether `dnsmasq` is killed at start because it holds port 53.
DHCP hands out only the phone as DNS, and `nat.sh` additionally redirects any client DNS traffic aimed at another
server (a hardcoded `1.1.1.1`/`8.8.8.8`) to unbound, so local names work regardless of client settings. The
Firefox DoH canary (`use-application-dns.net`) answers NXDOMAIN so Firefox keeps using this DNS. Browsers with
"secure DNS"/DoH explicitly switched on, and phones with Private DNS set, still bypass it: turn that off for `.lan`. `ENABLE_UNBOUND=0` turns it off.
The domain is `HOTSPOT_DOMAIN` (default `lan`). Avoid `local`: it is reserved for mDNS, and Windows, macOS and
systemd-resolved send `.local` lookups to multicast first, so they often never ask unbound.

### Reverse proxy (nginx, port 80)
Names alone don't hide ports, so `nginx` routes by host name on port 80:

| URL | Goes to |
|---|---|
| `http://torrent.lan` (also `transmission.lan`, `qbit.lan`) | Transmission `:9091` |
| `http://sync.lan` (`syncthing.lan`) | Syncthing `:8384` |
| `http://panel.lan` (`phone.lan`) | Web panel `:8080` |
| any other `*.lan` | redirects to `panel.lan` |

Samba works by name too: `\\phone.lan\share` (or `\\PHONE\share` via NetBIOS). `ENABLE_PROXY=0` turns the proxy off.
Plain HTTP, hotspot/WireGuard only.

### WireGuard server
    su -c "sh /data/adb/modules/hotspot_smb/wg-server.sh <public host/ip> [clients=1] [port=51820]"
Writes `/data/adb/hotspot_smb/wg0.conf` (phone = `10.8.0.1`) and client configs in `/data/adb/hotspot_smb/wg-clients/`
(they hold private keys; pull them with adb, then delete). Set `ENABLE_WG=1` and reboot. Clients reach the
phone's services at `10.8.0.1`. The phone must be reachable on UDP `port`: mobile carriers usually NAT inbound
traffic (CGNAT), so for a phone on mobile data use WireGuard as a client to a VPS, or a Cloudflare tunnel.
Tested: `wg-quick up/down` works on the Moto G34; no remote client connection tested.

### Web panel
`http://<ip>:8080` (`PANEL_PORT`), login `admin` (`PANEL_USER`). Built on busybox `httpd` + one CGI script,
nothing extra bundled. It opens with **Addresses** (every interface's current IP: mobile data, Wi-Fi, hotspot, WireGuard, plus the public IP, looked up via api.ipify.org and cached 10 min) and **Links** (every service by name and by IP, built from `config.sh` ports/domain). It shows battery/temperature/charging, uptime, storage, addresses, service status and
hotspot clients; it can restart or stop each service, restart everything, restart the hotspot, reboot the phone,
change passwords (hotspot, Samba, Transmission, Syncthing, the panel itself) and show logs.
- **Login:** user `PANEL_USER` (default `admin`), password `PANEL_PASS`, both in `config.sh`. `install.sh` replaces a
  `change-me` password with a random one and prints it. If `PANEL_PASS` is empty or missing, a random password is
  generated on first start into `/data/adb/hotspot_smb/panel_pass` (read it with
  `adb shell su -c "cat /data/adb/hotspot_smb/panel_pass"`). Change it any time with
  `su -c "sh /data/adb/modules/hotspot_smb/passwd.sh panel <newpass>"` or the panel's password form; that updates
  `config.sh` too when it sets `PANEL_PASS`.
- **Safety:** it runs as root. Every action is POST-only with a per-boot token (so another website cannot trigger
  actions in your logged-in browser), service names are whitelisted, and passwords are checked for shell
  metacharacters. It is plain HTTP, so use it only on the hotspot or through WireGuard, never forward the port to the internet.
- `ENABLE_PANEL=0` turns it off. Restart it from the shell with `su -c "sh /data/adb/modules/hotspot_smb/service.sh panel"`.
- `service.sh <part>` (`hotspot network samba transmission ssh syncthing unbound wg panel`) runs just that part;
  the panel uses this for its restart buttons.

### Watchdog and SMS
`watchdog.sh` checks every 30 s: hotspot, fixed subnet/DHCP/NAT, Samba, Transmission, Syncthing, SSH, unbound,
proxy, panel (and WireGuard if enabled). A service must be down for 2 checks (~60 s) before anything happens; it is
then restarted (max 3 times per 15 min). Per outage you get **one SMS when it goes down and one when it is back**
(`SMS_NOTIFY_RECOVERY=0` in `sms.conf` drops the second), plus one-time alerts for battery >= 45 C, battery <= 15% not
charging, and internet down for ~90 s. A hard cap of 6 SMS/hour (`SMS_MAX_PER_HOUR`) stops a flapping service
from running up a bill. Log: `/data/local/tmp/watchdog.log`. Pause: panel button, `wd off` SMS, or
`touch /data/adb/hotspot_smb/watchdog.off`. Switching the hotspot via panel/SMS pauses it automatically.
`ENABLE_WATCHDOG=0` turns it off.

**SMS settings** can be set three ways: the panel's *SMS alerts & commands* form (number, PIN, recovery texts, test
button, disable), `sms-setup.sh` (below), or the commented `SMS_*` block in `config.sh`. The panel form and
`sms-setup.sh` write `/data/adb/hotspot_smb/sms.conf`, which wins over `config.sh`; the panel only shows what
`sms.conf` holds, and the PIN is shown once after saving and never displayed again.

**One-time SMS setup** (your number, international format):

    su -c "sh /data/adb/modules/hotspot_smb/sms-setup.sh +37255512345 [PIN]"

This saves `/data/adb/hotspot_smb/sms.conf`, sends a test SMS, starts the listener and prints the PIN (random 6 digits
if you give none). Commands are accepted only from that number and must start with the PIN, e.g. `482913 status`:
`help`, `status`, `ip`, `restart <hotspot|network|samba|transmission|syncthing|ssh|unbound|proxy|panel|all>`,
`band 2|5`, `wd on|off`, `reboot`. Wrong-PIN or unknown-number texts are ignored and only logged.
Sending uses the root-only `ISms.sendTextForSubscriber` call (transaction 5 on this Android 16, read from
`framework.jar`), so no SMS app is needed. It is not guaranteed on other Android versions. Caller ID can be spoofed,
so keep the PIN secret; only commands from the whitelist run, and none of them can read files or change passwords.

### SSH keys
Password login is disabled. Add your public key, one per line:

    su -c "echo 'ssh-ed25519 AAAA... me' >> /data/adb/hotspot_smb/authorized_keys"

This file lives outside the module, so it survives module updates. Root's shell is the bundled bash;
`sftp` works too.

### WireGuard
Needs kernel support (the Moto G34's kernel has `CONFIG_WIREGUARD=y`). Put a standard `wg-quick`
config at `/data/adb/hotspot_smb/wg0.conf`, set `ENABLE_WG=1`, reboot. Untested on a real tunnel.

## Changing passwords

    su -c "sh /data/adb/modules/hotspot_smb/passwd.sh <hotspot|smb|transmission|syncthing> [newpass]"

No `newpass` generates a random one and prints it. The value is saved in `config.sh` and applied
immediately (hotspot clients must reconnect). The characters `" \ $ ` | & '` are not allowed.
SSH uses keys, so it has no password. If `/sdcard/hotspot_smb.conf` also sets the variable, that
file still wins at the next boot, and the script warns about it.

## Hotspot subnet
Android's tethering picks a random subnet and runs its own DHCP server. The module replaces that:
it sets the AP interface to `HOTSPOT_IP` (default `192.168.43.1/24`) only, drops Android's DHCP
replies with an iptables rule (uid `network_stack`), and serves DHCP itself with busybox `udhcpd`
(`192.168.43.100-200`, 24h leases). The phone is therefore always at `HOTSPOT_IP`.

Optional settings (not in `config.sh` by default; add them there or to `/sdcard/hotspot_smb.conf`):
`HOTSPOT_DHCP=0` turns this off (the address is then only added next to Android's),
`HOTSPOT_DHCP_START` / `HOTSPOT_DHCP_END` change the pool. Works for /24 only.
To pin a client to one address, add `static_lease <mac> <ip>` to `/data/local/tmp/udhcpd.conf`'s
template in `service.sh`.

### Internet sharing
`cmd wifi start-softap` does not enable Android's internet tethering, so `nat.sh` does it: IP forwarding,
NAT (masquerade) and a policy-routing rule to whichever interface currently has the default route
(mobile data or Wi-Fi), re-checked every 15 s so it follows upstream changes. Clients get `1.1.1.1` as DNS.
`HOTSPOT_SHARE_INTERNET=0` turns it off. Log: `/data/local/tmp/nat.log`.
Some carriers block or throttle tethered traffic (TTL 64 detection); if mobile data works on the phone
but not on clients, that is the likely cause.

## Files and logs
- Module log: `/data/local/tmp/hotspot_smb.log` · DHCP leases: `busybox dumpleases -f /data/local/tmp/udhcpd.leases`
- Samba: `/data/local/tmp/smb/` · Transmission: `/data/local/tmp/transmission/daemon.log`
- Syncthing: `/data/local/tmp/syncthing/serve.log` · SSH host key: `/data/local/tmp/ssh/`
- Downloads: `TR_DOWNLOAD_DIR` (default `/sdcard/Download/torrents`)

## Rebuilding the bundle
`./make-bundle.sh [pkg ...]` runs `fetch-samba.py` (downloads the packages and their dependencies from Termux's repo,
checks SHA256 sums, extracts to `termux-prefix/`) and repacks `prefix.tar.gz`. Default packages: samba, transmission,
zstd, openssh, syncthing, wireguard-tools, bash, unbound, nginx. arm64 only by default (`ARCH=arm ./make-bundle.sh`
for others, untested). Heavy dependencies bloat it (minidlna drags in ffmpeg, ~400 MB).

## Notes and limits
- Hotspot uses `cmd wifi start-softap` (Android 11+). Older versions fall back to a tether command that may not work.
- Many phones cannot run the hotspot while also connected to Wi-Fi as a client.
- Passwords are plain text in `config.sh`. The web UIs listen on all interfaces, protected only by their login.
- Samba runs as root with `force user = root`, so anyone with the SMB login has full access to `/sdcard`.
- If real Termux is installed with `smbd` and `sshd`, its tree is used for those two; Transmission and Syncthing always run from the bundle.
- Tested on: Moto G34 5G, Android 16, Magisk 30.7, run by hand from `/data/local/tmp` (not as an installed module, no reboot test).

## Known issues (not yet fixed)
- `lib.sh` `sms_send` checks the `service call isms` result with `grep 'Parcel(00000000'`, but the real output has a
  tab (`Parcel(<TAB>00000000`), so a text that was actually accepted is logged as "failed" and not counted in the
  hourly cap. Fix: match `Parcel(.*00000000`.
- The watchdog gives up after 3 restarts in 15 min. If Android restarts its tether `dnsmasq` (it grabs port 53) while
  unbound is restarting, unbound cannot bind and DNS stays down until `service.sh unbound` is run again.
- Real-number SMS sending and WireGuard tunnels have not been tested end to end.
