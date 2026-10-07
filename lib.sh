#!/system/bin/sh
# Shared helpers for watchdog.sh / sms.sh (sourced). Service checks, restarts, SMS sending.
export PATH=/system/bin:/system/xbin:/apex/com.android.runtime/bin
MODDIR=${MODDIR:-/data/adb/modules/hotspot_smb}
PERSIST=/data/adb/hotspot_smb
SMSCONF=$PERSIST/sms.conf
WD=/data/local/tmp/wd; mkdir -p "$WD"
[ -f "$MODDIR/config.sh" ] && . "$MODDIR/config.sh"
[ -f /sdcard/hotspot_smb.conf ] && . /sdcard/hotspot_smb.conf
[ -f "$SMSCONF" ] && . "$SMSCONF"     # SMS_TO, SMS_ALLOWED, SMS_PIN, SMS_NOTIFY_RECOVERY
[ -s "$PERSIST/band" ] && HOTSPOT_BAND=$(cat "$PERSIST/band")

SERVICES="hotspot network samba transmission syncthing ssh unbound proxy panel wg"
up() { ps -A 2>/dev/null | grep -qE "$1"; }
upargs() { ps -A -o ARGS 2>/dev/null | grep -q "$1"; }
ap_if() { ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^(ap0|swlan0|wlan[12])$/ {print $2; exit}'; }

svc_enabled() {
  case "$1" in
    samba|transmission|hotspot) return 0 ;;
    network) [ -n "$HOTSPOT_IP" ] ;;
    syncthing) [ "${ENABLE_SYNCTHING:-1}" = 1 ] ;;
    ssh) [ "${ENABLE_SSH:-1}" = 1 ] ;;
    unbound) [ "${ENABLE_UNBOUND:-1}" = 1 ] && [ -n "$HOTSPOT_IP" ] ;;
    proxy) [ "${ENABLE_PROXY:-1}" = 1 ] ;;
    panel) [ "${ENABLE_PANEL:-1}" = 1 ] ;;
    wg) [ "${ENABLE_WG:-0}" = 1 ] ;;
    *) return 1 ;;
  esac
}
svc_up() {
  case "$1" in
    samba) up ' smbd$' ;;
    transmission) up ' transmission-daemon$' ;;
    syncthing) up ' syncthing$' ;;
    ssh) up ' sshd$' ;;
    unbound) up ' unbound$' ;;
    proxy) up ' nginx(\.conf)?$' ;;
    panel) upargs '[b]usybox httpd' ;;
    hotspot) [ -n "$(ap_if)" ] ;;
    network) a=$(ap_if); [ -n "$a" ] && ip -4 addr show dev "$a" | grep -q "inet $HOTSPOT_IP/" && upargs '[u]dhcpd' && upargs '[n]at.s[h]' ;;
    wg) ip link show wg0 >/dev/null 2>&1 ;;
  esac
}
# Serialised restart (one at a time; a stale lock older than 5 min is dropped)
svc_restart() {
  [ -n "$(find "$WD/lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] && rmdir "$WD/lock" 2>/dev/null
  mkdir "$WD/lock" 2>/dev/null || return 1
  case "$1" in
    hotspot) touch "$WD/pause"; sh "$MODDIR/service.sh" hotspot; sh "$MODDIR/service.sh" network
             sh "$MODDIR/service.sh" unbound; sh "$MODDIR/service.sh" proxy ;;
    *) sh "$MODDIR/service.sh" "$1" ;;
  esac
  rmdir "$WD/lock" 2>/dev/null
}

# ---- SMS sending: ISms.sendTextForSubscriber = transaction 5 on this Android 16 build (read from framework.jar) ----
# Hard cap: 6 messages per hour, so a flapping service can never run up a bill.
sms_budget_ok() {
  now=$(date +%s); f=$WD/sms_sent; touch "$f"
  awk -v n="$now" 'n - $1 < 3600' "$f" > "$f.t" 2>/dev/null; mv "$f.t" "$f"
  [ "$(wc -l < "$f")" -lt "${SMS_MAX_PER_HOUR:-6}" ]
}
sms_send() { # <number> <text>
  [ -n "$1" ] || return 1
  sms_budget_ok || { echo "$(date '+%T') sms budget exhausted, dropped: $2" >> /data/local/tmp/watchdog.log; return 1; }
  txt=$(printf '[Phone] %s' "$2" | tr '\n' ' ' | tr -cd '[:print:]' | cut -c1-155)
  sub=$(settings get global multi_sim_sms 2>/dev/null)
  case "$sub" in ''|null) sub=-1 ;; esac
  out=$(service call isms 5 i32 "$sub" s16 com.android.shell i32 -1 s16 "$1" i32 -1 s16 "$txt" i32 0 i32 0 i32 0 i64 0 2>&1)
  if echo "$out" | grep -q 'Parcel(00000000'; then date +%s >> "$WD/sms_sent"; return 0; fi
  echo "$(date '+%T') sms send failed: $(echo "$out" | head -2 | tr '\n' ' ')" >> /data/local/tmp/watchdog.log; return 1
}
sms_alert() { for n in $SMS_TO; do sms_send "$n" "$1"; done; }

status_text() {
  b=$(dumpsys battery 2>/dev/null); lvl=$(echo "$b" | sed -n 's/^ *level: //p'); t=$(echo "$b" | sed -n 's/^ *temperature: //p')
  down=""; for s in $SERVICES; do svc_enabled "$s" && ! svc_up "$s" && down="$down $s"; done
  cl=$(( $(/data/adb/magisk/busybox dumpleases -f /data/local/tmp/udhcpd.leases 2>/dev/null | wc -l) - 1 )); [ "$cl" -lt 0 ] && cl=0
  f=$(dumpsys wifi 2>/dev/null | grep -o 'frequency= *[0-9]*' | grep -v ' 0$' | head -1 | tr -dc '0-9')
  if [ -z "$f" ]; then bd="off"; elif [ "$f" -lt 3000 ]; then bd="2.4G"; else bd="5G"; fi
  echo "Bat ${lvl:-?}% $(( ${t:-0} / 10 ))C, hotspot $bd, $cl clients, $( [ -z "$down" ] && echo 'all services up' || echo "DOWN:$down")"
}
