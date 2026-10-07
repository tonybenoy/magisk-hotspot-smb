#!/system/bin/sh
# Magisk late_start service: hotspot on, then smbd.
MODDIR=$(cd "$(dirname "$0")" && pwd)
LOG=/data/local/tmp/hotspot_smb.log
exec >>"$LOG" 2>&1
echo "=== $(date) boot ==="

. "$MODDIR/config.sh"
[ -f /sdcard/hotspot_smb.conf ] && . /sdcard/hotspot_smb.conf

# Optional argument: run only one part (used by the web panel), e.g. `service.sh samba`
ONLY=${1:-}
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
DOM=${HOTSPOT_DOMAIN:-lan}   # local DNS domain: every <name>.$DOM resolves to the phone
if [ -z "$ONLY" ]; then
  while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
  sleep "$BOOT_DELAY"
fi

# Keep the CPU awake so hotspot/smbd survive screen-off
echo hotspot_smb > /sys/power/wake_lock 2>/dev/null

if want hotspot; then
# ---- Hotspot ----
start_hotspot() {
  # Android 11+: softap via the wifi service
  case "$HOTSPOT_BAND" in 2|5|6|any) band="-b $HOTSPOT_BAND" ;; *) band="" ;; esac
  if cmd wifi start-softap "$HOTSPOT_SSID" wpa2 "$HOTSPOT_PASS" $band 2>&1; then
    return 0
  fi
  # Fallback: generic tethering start
  cmd connectivity tether start wifi 2>&1 || cmd connectivity start-tethering wifi 2>&1
}

# Band chosen in the panel (2 or 5) overrides config.sh
[ -s /data/adb/hotspot_smb/band ] && HOTSPOT_BAND=$(cat /data/adb/hotspot_smb/band)
# Re-running just the hotspot part: stop the running AP first so the new band takes effect
[ -n "$ONLY" ] && { mkdir -p /data/local/tmp/wd; touch /data/local/tmp/wd/pause; cmd wifi stop-softap >/dev/null 2>&1; sleep 4; }
# Start once, then wait up to ~40 s for the AP interface (5 GHz is slow). Only retry if it never came up:
# sending a second start while the first is still pending corrupts Android's softap state.
for i in 1 2 3; do
  start_hotspot
  up=0
  for w in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    sleep 3
    if ip -o -4 addr show | grep -qE ' (ap0|swlan0|wlan[12]) '; then up=1; break; fi
  done
  [ "$up" = 1 ] && break
  echo "hotspot did not come up (attempt $i), stopping and retrying"
  cmd wifi stop-softap >/dev/null 2>&1; sleep 5
done
ip -o -4 addr show
fi

if want network; then
# Fixed subnet: replace Android's random hotspot subnet with HOTSPOT_IP and serve DHCP ourselves.
# Android's own DHCP replies on the AP interface are dropped (uid network_stack = 1073).
HOTSPOT_DHCP=${HOTSPOT_DHCP:-1}; HOTSPOT_PREFIX=${HOTSPOT_PREFIX:-24}
HOTSPOT_DHCP_START=${HOTSPOT_DHCP_START:-100}; HOTSPOT_DHCP_END=${HOTSPOT_DHCP_END:-200}
if [ -n "$HOTSPOT_IP" ]; then
  APIF=$(ip -o -4 addr show | awk '$2 ~ /^(ap0|swlan0|wlan[12])$/ {print $2; exit}')
  if [ -z "$APIF" ]; then
    echo "WARN: no AP interface found, fixed subnet not set"
  elif [ "$HOTSPOT_DHCP" = 1 ] && [ "$HOTSPOT_PREFIX" = 24 ]; then
    BB=/data/adb/magisk/busybox; BASE=${HOTSPOT_IP%.*}
    ip -4 addr flush dev "$APIF"
    ip addr add "$HOTSPOT_IP/24" dev "$APIF" && echo "$APIF now $HOTSPOT_IP/24 only"
    iptables -C OUTPUT -o "$APIF" -p udp --sport 67 -m owner --uid-owner 1073 -j DROP 2>/dev/null \
      || iptables -I OUTPUT -o "$APIF" -p udp --sport 67 -m owner --uid-owner 1073 -j DROP
    touch /data/local/tmp/udhcpd.leases
    cat > /data/local/tmp/udhcpd.conf <<EOF2
start $BASE.$HOTSPOT_DHCP_START
end $BASE.$HOTSPOT_DHCP_END
interface $APIF
max_leases $((HOTSPOT_DHCP_END - HOTSPOT_DHCP_START + 1))
lease_file /data/local/tmp/udhcpd.leases
pidfile /data/local/tmp/udhcpd.pid
opt subnet 255.255.255.0
opt router $HOTSPOT_IP
opt dns $HOTSPOT_IP
opt domain $DOM
opt search $DOM
opt lease 86400
EOF2
    pkill -f "[u]dhcpd" 2>/dev/null
    nohup "$BB" udhcpd -f /data/local/tmp/udhcpd.conf >/data/local/tmp/udhcpd.log 2>&1 &
    echo "udhcpd serving $BASE.$HOTSPOT_DHCP_START-$HOTSPOT_DHCP_END on $APIF"
    if [ "${HOTSPOT_SHARE_INTERNET:-1}" = 1 ]; then
      pkill -f "[n]at.sh" 2>/dev/null
      nohup sh "$MODDIR/nat.sh" "$APIF" "$BASE.0/24" "$HOTSPOT_IP" >/data/local/tmp/nat.log 2>&1 &
      echo "internet sharing started (log: /data/local/tmp/nat.log)"
    fi
  else
    # DHCP off or non-/24: just add the address next to Android's
    ip addr show dev "$APIF" | grep -q "inet $HOTSPOT_IP/" || ip addr add "$HOTSPOT_IP/$HOTSPOT_PREFIX" dev "$APIF"
  fi
fi
fi

# ---- Samba ----
TERMUX=/data/data/com.termux/files/usr
# /data/data and /sdcard stay encrypted until the first unlock after boot: wait for that.
until mkdir -p "$TERMUX" 2>/dev/null && [ -d /sdcard/Download ]; do sleep 5; done
echo "storage unlocked"

# Bundled Termux tree (Samba, Transmission + libs), unpacked once into the module.
# Samba wants it at the Termux prefix: bind-mount it there unless real Termux already has smbd.
# Transmission always runs from the unpacked copy (works alongside a real Termux install).
PREFIX="$MODDIR/prefix"
if [ ! -x "$PREFIX/bin/smbd" ] || [ ! -x "$PREFIX/bin/transmission-daemon" ] || [ ! -x "$PREFIX/bin/syncthing" ] || [ ! -x "$PREFIX/bin/unbound" ] || [ ! -x "$PREFIX/bin/nginx" ]; then
  mkdir -p "$PREFIX" && tar -xzf "$MODDIR/prefix.tar.gz" -C "$PREFIX" || { echo "ERROR: unpack failed"; exit 1; }
  chmod -R 755 "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/libexec" 2>/dev/null
fi
if [ ! -x "$TERMUX/bin/smbd" ] || [ ! -x "$TERMUX/bin/sshd" ]; then
  for try in 1 2 3 4 5; do
    mkdir -p "$TERMUX"
    grep -q " $TERMUX " /proc/mounts && break
    mount --bind "$PREFIX" "$TERMUX" 2>&1 && break
    echo "mount attempt $try failed, retrying"; sleep 3
  done
  grep -q " $TERMUX " /proc/mounts || { echo "ERROR: bind mount failed"; exit 1; }
fi
export LD_LIBRARY_PATH="$TERMUX/lib"
export PATH="$TERMUX/bin:$PATH"
SMBD="$TERMUX/bin/smbd"; SMBPASSWD="$TERMUX/bin/smbpasswd"

if want samba; then
RUN=/data/local/tmp/smb
mkdir -p "$RUN/private" "$RUN/lock" "$RUN/cache" "$RUN/state"
cat > "$RUN/smb.conf" <<EOF
[global]
  workgroup = WORKGROUP
  server string = Phone
  security = user
  map to guest = never
  server min protocol = SMB2
  netbios name = ${SMB_NETBIOS_NAME:-PHONE}
  disable netbios = no
  wins support = no
  local master = no
  smb ports = 445
  interfaces = lo ap0 swlan0 wlan0 wlan1 wlan2
  bind interfaces only = no
  load printers = no
  printcap name = /dev/null
  disable spoolss = yes
  log file = $RUN/log.%m
  max log size = 1000
  private dir = $RUN/private
  lock directory = $RUN/lock
  state directory = $RUN/state
  cache directory = $RUN/cache
  pid directory = $RUN
  passdb backend = tdbsam:$RUN/private/passdb.tdb
  force user = root
  force group = root

[$SHARE_NAME]
  path = $SHARE_PATH
  read only = no
  valid users = $SMB_USER
  create mask = 0666
  directory mask = 0777

[torrents]
  path = $TR_DOWNLOAD_DIR
  read only = no
  valid users = $SMB_USER
  create mask = 0666
  directory mask = 0777
EOF
mkdir -p "$TR_DOWNLOAD_DIR"

( echo "$SMB_PASS"; echo "$SMB_PASS" ) | "$SMBPASSWD" -c "$RUN/smb.conf" -s -a "$SMB_USER"

pkill -x smbd 2>/dev/null; pkill -x nmbd 2>/dev/null
"$SMBD" -D -s "$RUN/smb.conf" && echo "smbd started" || echo "smbd failed"
"$TERMUX/bin/nmbd" -D -s "$RUN/smb.conf" && echo "nmbd started (NetBIOS name ${SMB_NETBIOS_NAME:-PHONE})" || echo "nmbd failed"

fi

# ---- Transmission ----
if want transmission; then
TR=/data/local/tmp/transmission
mkdir -p "$TR"
pkill -f transmission-daemon 2>/dev/null
LD_LIBRARY_PATH="$PREFIX/lib" TRANSMISSION_WEB_HOME="$PREFIX/share/transmission/public_html" \
  "$PREFIX/bin/transmission-daemon" -g "$TR" -w "$TR_DOWNLOAD_DIR" -p "$TR_PORT" \
  -t -u "$TR_USER" -v "$TR_PASS" -a "*.*.*.*" -e "$TR/daemon.log" \
  && echo "transmission started on :$TR_PORT" || echo "transmission failed"

fi

# ---- SSH (key auth only) ----
PERSIST=/data/adb/hotspot_smb
mkdir -p "$PERSIST"
if want ssh && [ "$ENABLE_SSH" = 1 ]; then
  SSH=/data/local/tmp/ssh; mkdir -p "$SSH"; chmod 700 "$SSH"
  [ -f "$SSH/host_ed25519" ] || "$TERMUX/bin/ssh-keygen" -q -t ed25519 -N "" -f "$SSH/host_ed25519"
  touch "$PERSIST/authorized_keys"; chmod 600 "$PERSIST/authorized_keys"
  cat > "$SSH/sshd_config" <<EOF2
Port $SSH_PORT
HostKey $SSH/host_ed25519
PidFile $SSH/sshd.pid
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile $PERSIST/authorized_keys
StrictModes no
SetEnv PATH=$TERMUX/bin:/system/bin:/system/xbin:/data/adb/magisk
Subsystem sftp $TERMUX/libexec/sftp-server
EOF2
  mkdir -p "$PREFIX/var/empty"; chmod 755 "$PREFIX/var/empty"
  pkill -x sshd 2>/dev/null
  "$TERMUX/bin/sshd" -f "$SSH/sshd_config" && echo "sshd started on :$SSH_PORT" || echo "sshd failed"
  [ -s "$PERSIST/authorized_keys" ] || echo "WARN: $PERSIST/authorized_keys is empty, SSH login impossible until you add a key"
fi

# ---- Syncthing ----
if want syncthing && [ "$ENABLE_SYNCTHING" = 1 ]; then
  STH=/data/local/tmp/syncthing; mkdir -p "$STH"
  export LD_LIBRARY_PATH="$PREFIX/lib" SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" HOME="$STH" STNOUPGRADE=1
  [ -f "$STH/config.xml" ] || "$PREFIX/bin/syncthing" generate --home "$STH" --gui-user "$ST_USER" --gui-password "$ST_PASS"
  pkill -f "[s]yncthing serve" 2>/dev/null
  nohup "$PREFIX/bin/syncthing" serve --home "$STH" --no-browser --gui-address "0.0.0.0:$ST_PORT" >"$STH/serve.log" 2>&1 &
  echo "syncthing started on :$ST_PORT"
fi

# ---- WireGuard ----
if want wg && [ "$ENABLE_WG" = 1 ]; then
  if [ -f "$WG_CONF" ]; then
    PATH="$TERMUX/bin:$PATH" "$TERMUX/bin/wg-quick" up "$WG_CONF" 2>&1 && echo "wireguard up" || echo "wireguard failed"
  else
    echo "WARN: $WG_CONF not found, skipping WireGuard"
  fi
fi

# ---- Unbound (local DNS for hotspot clients) ----
if want unbound && [ "${ENABLE_UNBOUND:-1}" = 1 ] && [ -n "$HOTSPOT_IP" ]; then
  UB=/data/local/tmp/unbound; mkdir -p "$UB"
  cat > "$UB/unbound.conf" <<EOF2
server:
  interface: $HOTSPOT_IP
  port: 53
  access-control: ${HOTSPOT_IP%.*}.0/24 allow
  do-ip6: no
  username: ""
  chroot: ""
  directory: "$UB"
  pidfile: "$UB/unbound.pid"
  logfile: "$UB/unbound.log"
  use-syslog: no
  hide-identity: yes
  hide-version: yes
  cache-min-ttl: 300
  prefetch: yes
  tls-cert-bundle: "$PREFIX/etc/tls/cert.pem"
  local-zone: "$DOM." redirect
  local-data: "$DOM. A $HOTSPOT_IP"
  local-data: "phone. A $HOTSPOT_IP"
  local-zone: "use-application-dns.net." always_nxdomain
forward-zone:
  name: "."
  forward-tls-upstream: yes
  forward-addr: 1.1.1.1@853#cloudflare-dns.com
  forward-addr: 9.9.9.9@853#dns.quad9.net
EOF2
  pkill -9 -x dnsmasq 2>/dev/null; pkill -9 -x unbound 2>/dev/null; sleep 2   # Android's tether dnsmasq holds :53
  LD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/bin/unbound" -c "$UB/unbound.conf" \
    && echo "unbound started (*.$DOM -> $HOTSPOT_IP)" || echo "unbound failed (see $UB/unbound.log)"
fi

# ---- Reverse proxy: http://torrent.lan, sync.lan, panel.lan on port 80 ----
if want proxy && [ "${ENABLE_PROXY:-1}" = 1 ]; then
  NG=/data/local/tmp/nginx; mkdir -p "$NG"
  PANEL_PORT=${PANEL_PORT:-8080}
  cat > "$NG/nginx.conf" <<EOF2
worker_processes 1;
pid $NG/nginx.pid;
error_log $NG/error.log warn;
events { worker_connections 256; }
http {
  access_log off;
  client_body_temp_path $NG/tmp_body; proxy_temp_path $NG/tmp_proxy;
  fastcgi_temp_path $NG/tmp_fcgi; uwsgi_temp_path $NG/tmp_uwsgi; scgi_temp_path $NG/tmp_scgi;
  client_max_body_size 0; proxy_read_timeout 300s;
  server { listen 80 default_server; return 302 http://panel.$DOM/; }
  server { listen 80; server_name torrent.$DOM transmission.$DOM qbit.$DOM;
    location / { proxy_pass http://127.0.0.1:${TR_PORT:-9091}; proxy_set_header Host 127.0.0.1; } }
  server { listen 80; server_name sync.$DOM syncthing.$DOM;
    location / { proxy_pass http://127.0.0.1:${ST_PORT:-8384}; proxy_set_header Host 127.0.0.1:${ST_PORT:-8384}; } }
  server { listen 80; server_name panel.$DOM phone.$DOM;
    location / { proxy_pass http://127.0.0.1:$PANEL_PORT; proxy_set_header Host \$host; proxy_set_header Authorization \$http_authorization; } }
}
EOF2
  pkill -f "[n]ginx" 2>/dev/null; sleep 1
  LD_LIBRARY_PATH="$PREFIX/lib" "$PREFIX/bin/nginx" -p "$NG/" -c "$NG/nginx.conf" \
    && echo "proxy started on :80 (torrent/sync/panel .$DOM)" || echo "proxy failed (see $NG/error.log)"
fi

# ---- Web panel (busybox httpd + CGI) ----
if want panel && [ "${ENABLE_PANEL:-1}" = 1 ]; then
  BB=/data/adb/magisk/busybox
  PANEL_PORT=${PANEL_PORT:-8080}; PANEL_USER=${PANEL_USER:-admin}
  WWW="$MODDIR/panel/www"
  chmod 755 "$WWW" "$WWW/cgi-bin" "$WWW"/cgi-bin/* 2>/dev/null
  if [ -z "$PANEL_PASS" ]; then
    [ -s "$PERSIST/panel_pass" ] || tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14 > "$PERSIST/panel_pass"
    chmod 600 "$PERSIST/panel_pass"; PANEL_PASS=$(cat "$PERSIST/panel_pass")
  fi
  ( umask 077; echo "/:$PANEL_USER:$PANEL_PASS" > /data/local/tmp/httpd.conf )
  pkill -f "[b]usybox httpd" 2>/dev/null; sleep 1
  "$BB" httpd -p "$PANEL_PORT" -h "$WWW" -c /data/local/tmp/httpd.conf \
    && echo "panel started on :$PANEL_PORT" || echo "panel failed"
fi

# ---- Watchdog (restarts dead services, one SMS per outage) + SMS command listener ----
if want watchdog && [ "${ENABLE_WATCHDOG:-1}" = 1 ]; then
  pkill -f "[w]atchdog.s[h]" 2>/dev/null; sleep 1
  nohup sh "$MODDIR/watchdog.sh" >/dev/null 2>&1 &
  echo "watchdog started"
fi
[ -s "$PERSIST/sms.conf" ] && . "$PERSIST/sms.conf"
if want sms && [ -n "$SMS_PIN" ] && [ -n "${SMS_ALLOWED:-$SMS_TO}" ]; then
  pkill -f "[s]ms.s[h]" 2>/dev/null; sleep 1
  nohup sh "$MODDIR/sms.sh" >/dev/null 2>&1 &
  echo "sms listener started"
fi
