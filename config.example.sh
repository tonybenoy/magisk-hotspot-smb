# Template. install.sh copies this to config.sh (git-ignored) when config.sh is missing, and replaces every
# "change-me*" password below with a random one. On the phone the live copy is
# /data/adb/modules/hotspot_smb/config.sh. Overrides without touching the module: /sdcard/hotspot_smb.conf

# ---- Hotspot ----
HOTSPOT_SSID="PhoneNAS"
HOTSPOT_PASS="change-me-1234"     # WPA2, min 8 chars
HOTSPOT_BAND="2"                  # 2 = 2.4GHz, 5 = 5GHz (the panel / SMS "band" choice overrides this)
HOTSPOT_IP="192.168.43.1"         # fixed address of the phone on the hotspot (/24); also the DNS server
HOTSPOT_PREFIX="24"
# HOTSPOT_DOMAIN="lan"            # every <name>.lan resolves to the phone (avoid "local": mDNS clashes)
# HOTSPOT_DHCP=1                  # 0 = keep Android's random subnet, only add HOTSPOT_IP
# HOTSPOT_DHCP_START=100          # DHCP pool .100-.200
# HOTSPOT_DHCP_END=200
# HOTSPOT_SHARE_INTERNET=1        # 0 = no NAT for clients

# Seconds to wait after boot before touching Wi-Fi
BOOT_DELAY=20

# ---- Samba ----
SHARE_NAME="share"
SHARE_PATH="/sdcard"              # folder to share
SMB_USER="root"                   # must be a unix user Android resolves (root, shell, ...)
SMB_PASS="change-me"
# SMB_NETBIOS_NAME="PHONE"

# ---- Transmission: web UI http://<ip>:9091 or http://torrent.lan ----
TR_PORT="9091"
TR_USER="admin"
TR_PASS="change-me"
TR_DOWNLOAD_DIR="/sdcard/Download/torrents"

# ---- Optional services (1 = start at boot) ----
# SSH: key login only, as root. Public keys go in /data/adb/hotspot_smb/authorized_keys
ENABLE_SSH=1
SSH_PORT="22"

# Syncthing web UI: http://<ip>:8384 or http://sync.lan
ENABLE_SYNCTHING=1
ST_PORT="8384"
ST_USER="admin"
ST_PASS="change-me"

# WireGuard: tunnel from a wg-quick file (create one with wg-server.sh)
ENABLE_WG=0
WG_CONF="/data/adb/hotspot_smb/wg0.conf"

# ENABLE_UNBOUND=0               # 1 = local DNS so torrent.lan / sync.lan / panel.lan resolve (off by default: Android's
#                                 # tether dnsmasq fights it for port 53). Off: clients get 1.1.1.1/8.8.8.8, use IPs.
# ENABLE_PROXY=1                  # nginx on :80 -> torrent.lan, sync.lan, panel.lan

# ---- Web panel: http://panel.lan or http://<ip>:8080 ----
PANEL_USER="admin"
PANEL_PASS="change-me"            # empty = random, kept in /data/adb/hotspot_smb/panel_pass
PANEL_PORT="8080"
# ENABLE_PANEL=1

# ---- Watchdog + SMS (optional). The panel's SMS form / sms-setup.sh write sms.conf, which wins over these ----
# ENABLE_WATCHDOG=1
# SMS_TO="+37255512345"           # alerts go here (space-separated list allowed)
# SMS_ALLOWED="+37255512345"      # numbers allowed to send commands (defaults to SMS_TO)
# SMS_PIN="123456"                # commands must start with this: "123456 status"
# SMS_NOTIFY_RECOVERY=1           # also text when a service is back
# SMS_MAX_PER_HOUR=6              # hard cap on outgoing texts
