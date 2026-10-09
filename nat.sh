#!/system/bin/sh
# Share the phone's internet with hotspot clients: NAT + policy routing, follows the upstream
# interface (mobile data <-> Wi-Fi). Started by service.sh:  nat.sh <ap-iface> <subnet/24>
APIF=$1; NET=$2; GW=$3; DNS=${4:-0}
MODDIR=$(cd "$(dirname "$0")" && pwd)
WD=/data/local/tmp/wd; mkdir -p "$WD"
PERSIST=/data/adb/hotspot_smb
log() { echo "$(date +%T) $*"; }
echo 1 > /proc/sys/net/ipv4/ip_forward

find_up() {
  ip -4 route show table all 2>/dev/null \
    | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | sort -u \
    | grep -vE "^(lo|dummy0|$APIF)$" | head -1
}

ipt() { # add rule once: ipt <table> <chain> <pos> <rule...>
  t=$1; c=$2; pos=$3; shift 3
  iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -I "$c" "$pos" "$@"
}
unrules() {
  [ -n "$1" ] || return
  iptables -t nat -D POSTROUTING -s "$NET" -o "$1" -j MASQUERADE 2>/dev/null
  iptables -D FORWARD -i "$APIF" -o "$1" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -i "$1" -o "$APIF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  ip rule del iif "$APIF" lookup "$1" pref 9000 2>/dev/null
}

# With local DNS (unbound) on: force every client DNS query to the phone's resolver, even a hardcoded 1.1.1.1/8.8.8.8.
# With it off: make sure no stale redirect is left behind.
if [ -n "$GW" ]; then
  for proto in udp tcp; do
    if [ "$DNS" = 1 ]; then
      iptables -t nat -C PREROUTING -i "$APIF" -p $proto --dport 53 ! -d "$GW" -j DNAT --to-destination "$GW:53" 2>/dev/null \
        || iptables -t nat -I PREROUTING 1 -i "$APIF" -p $proto --dport 53 ! -d "$GW" -j DNAT --to-destination "$GW:53"
    else
      while iptables -t nat -D PREROUTING -i "$APIF" -p $proto --dport 53 ! -d "$GW" -j DNAT --to-destination "$GW:53" 2>/dev/null; do :; done
    fi
  done
fi

# Android's own DHCP replies on the AP interface are dropped only while OUR dhcp + address are healthy
# (uid network_stack = 1073). If Android re-takes the interface (hotspot toggled in Settings), the rule is lifted so
# clients still get an address, then the fixed subnet is re-applied after it has been stable for ~10 s.
drop_rule() { # add|del
  if [ "$1" = add ]; then
    iptables -C OUTPUT -o "$APIF" -p udp --sport 67 -m owner --uid-owner 1073 -j DROP 2>/dev/null \
      || iptables -I OUTPUT -o "$APIF" -p udp --sport 67 -m owner --uid-owner 1073 -j DROP
  else
    while iptables -D OUTPUT -o "$APIF" -p udp --sport 67 -m owner --uid-owner 1073 -j DROP 2>/dev/null; do :; done
  fi
}
heal() { # at most once per 60 s
  now=$(date +%s); lh=$(cat "$WD/last_heal" 2>/dev/null || echo 0)
  [ $((now - lh)) -ge 60 ] || { log "heal skipped (ran <60 s ago)"; return 1; }
  echo "$now" > "$WD/last_heal"; touch "$WD/pause"
  log "Android re-took $APIF: re-applying fixed subnet + DNS"
  ( nohup sh -c "sh '$MODDIR/service.sh' network; sh '$MODDIR/service.sh' unbound" >/dev/null 2>&1 & )
}

# Android turns a hotspot started with `cmd wifi start-softap` off after 10 min with no clients (that command ignores the
# "turn off automatically" setting of the UI). Nobody is connected at that moment, so bring it straight back,
# unless hotspot.off exists (panel "keep hotspot on" switch) or another script is restarting it (pause file).
keep_on() { # at most once per 60 s
  now=$(date +%s); lk=$(cat "$WD/last_keepon" 2>/dev/null || echo 0)
  [ $((now - lk)) -ge 60 ] || return 1
  echo "$now" > "$WD/last_keepon"; touch "$WD/pause"
  log "hotspot was turned off (Android idle timeout?): turning it back on"
  ( nohup sh -c "sh '$MODDIR/service.sh' hotspot; sh '$MODDIR/service.sh' network; sh '$MODDIR/service.sh' unbound" >/dev/null 2>&1 & )
}
paused() { [ -e "$WD/pause" ] && [ $(( $(date +%s) - $(stat -c %Y "$WD/pause") )) -lt 150 ]; }

last=""; wrong=0; tick=0; gone=0
while :; do
  # --- upstream interface (every 15 s) ---
  if [ $((tick % 3)) = 0 ]; then
    UP=$(find_up)
    if [ "$UP" != "$last" ]; then
      unrules "$last"
      if [ -n "$UP" ]; then
        ipt nat POSTROUTING 1 -s "$NET" -o "$UP" -j MASQUERADE
        ipt filter FORWARD 1 -i "$APIF" -o "$UP" -j ACCEPT
        ipt filter FORWARD 1 -i "$UP" -o "$APIF" -m state --state RELATED,ESTABLISHED -j ACCEPT
        ip rule add iif "$APIF" lookup "$UP" pref 9000 2>/dev/null
        ip rule show | grep -q "to $NET lookup" || ip rule add to "$NET" lookup main pref 8999 2>/dev/null
        log "upstream: $UP"
      else
        log "no upstream"
      fi
      last=$UP
    fi
  fi
  # --- is the hotspot interface still ours? (every 5 s) ---
  if [ -n "$GW" ]; then
    cur=$(ip -4 addr show dev "$APIF" 2>/dev/null)
    if echo "$cur" | grep -q "inet $GW/"; then
      wrong=0; gone=0; drop_rule add
    elif echo "$cur" | grep -q 'inet '; then
      wrong=$((wrong + 1))
      gone=0
      [ "$wrong" = 1 ] && { drop_rule del; log "$APIF has Android's address, DHCP block lifted"; }
      if [ "$wrong" -ge 2 ] && heal; then exit 0; fi
    elif ip link show "$APIF" >/dev/null 2>&1; then
      gone=0; wrong=$((wrong + 1)); [ "$wrong" = 1 ] && drop_rule del
      if [ "$wrong" -ge 2 ] && heal; then exit 0; fi
    else
      [ "$wrong" != 0 ] && log "$APIF is gone (hotspot off?), waiting"
      drop_rule del; wrong=0; gone=$((gone + 1))
      if [ "$gone" -ge 2 ] && [ ! -e "$PERSIST/hotspot.off" ] && ! paused && keep_on; then exit 0; fi
    fi
  fi
  tick=$((tick + 1)); sleep 5
done
