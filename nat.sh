#!/system/bin/sh
# Share the phone's internet with hotspot clients: NAT + policy routing, follows the upstream
# interface (mobile data <-> Wi-Fi). Started by service.sh:  nat.sh <ap-iface> <subnet/24>
APIF=$1; NET=$2; GW=$3
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

# Force every client DNS query to the phone's resolver (unbound), even when the client hardcodes 1.1.1.1/8.8.8.8
if [ -n "$GW" ]; then
  for proto in udp tcp; do
    iptables -t nat -C PREROUTING -i "$APIF" -p $proto --dport 53 ! -d "$GW" -j DNAT --to-destination "$GW:53" 2>/dev/null \
      || iptables -t nat -I PREROUTING 1 -i "$APIF" -p $proto --dport 53 ! -d "$GW" -j DNAT --to-destination "$GW:53"
  done
fi

last=""
while :; do
  UP=$(find_up)
  if [ "$UP" != "$last" ]; then
    unrules "$last"
    if [ -n "$UP" ]; then
      ipt nat POSTROUTING 1 -s "$NET" -o "$UP" -j MASQUERADE
      ipt filter FORWARD 1 -i "$APIF" -o "$UP" -j ACCEPT
      ipt filter FORWARD 1 -i "$UP" -o "$APIF" -m state --state RELATED,ESTABLISHED -j ACCEPT
      ip rule add iif "$APIF" lookup "$UP" pref 9000 2>/dev/null
      ip rule show | grep -q "to $NET lookup" || ip rule add to "$NET" lookup main pref 8999 2>/dev/null
      echo "$(date +%T) upstream: $UP"
    else
      echo "$(date +%T) no upstream"
    fi
    last=$UP
  fi
  sleep 15
done
