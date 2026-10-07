#!/system/bin/sh
# Watchdog: checks services every 30 s, restarts what died (max 3 times / 15 min each) and sends ONE sms per
# outage (plus one when it recovers). Pause: touch /data/adb/hotspot_smb/watchdog.off  (or panel / "wd off" sms).
MODDIR=$(cd "$(dirname "$0")" && pwd)
. "$MODDIR/lib.sh"
LOG=/data/local/tmp/watchdog.log
exec >>"$LOG" 2>&1
log() { echo "$(date '+%F %T') $*"; }
log "watchdog started (sms to: ${SMS_TO:-nobody})"
sleep "${WD_GRACE:-90}"

restart_allowed() { # 3 per 15 minutes
  f=$WD/tries_$1; touch "$f"; now=$(date +%s)
  awk -v n="$now" 'n - $1 < 900' "$f" > "$f.t"; mv "$f.t" "$f"
  [ "$(wc -l < "$f")" -lt 3 ]
}
flag_once() { # <name> <alert-text> <condition-true?>  : alert once while condition holds, clear when it ends
  if [ "$3" = 1 ]; then [ -e "$WD/flag_$1" ] || { touch "$WD/flag_$1"; log "$2"; sms_alert "$2"; }
  else [ -e "$WD/flag_$1" ] && { rm -f "$WD/flag_$1"; [ "$4" = recover ] && sms_alert "OK again: $1"; }; fi
}

inet_fail=0
while :; do
  sleep "${WD_INTERVAL:-30}"
  [ -e "$PERSIST/watchdog.off" ] && continue
  if [ -e "$WD/pause" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$WD/pause") )); [ "$age" -lt 150 ] && continue; rm -f "$WD/pause"
  fi
  [ -d /sdcard/Download ] || continue          # storage still locked

  for s in $SERVICES; do
    svc_enabled "$s" || continue
    if svc_up "$s"; then
      if [ -e "$WD/alert_$s" ]; then
        rm -f "$WD/alert_$s" "$WD/gaveup_$s"; log "$s recovered"
        [ "${SMS_NOTIFY_RECOVERY:-1}" = 1 ] && sms_alert "UP again: $s"
      fi
      echo 0 > "$WD/fail_$s"
    else
      n=$(( $(cat "$WD/fail_$s" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WD/fail_$s"
      [ "$n" -ge 2 ] || continue                 # must be down for 2 checks in a row (~60 s)
      if [ ! -e "$WD/alert_$s" ]; then touch "$WD/alert_$s"; log "$s DOWN"; sms_alert "DOWN: $s. Restarting."; fi
      if restart_allowed "$s"; then
        date +%s >> "$WD/tries_$s"; log "restarting $s"; svc_restart "$s"; echo 0 > "$WD/fail_$s"
      elif [ ! -e "$WD/gaveup_$s" ]; then
        touch "$WD/gaveup_$s"; log "$s: gave up"; sms_alert "GAVE UP: $s still down after 3 restarts."
      fi
    fi
  done

  # battery heat / charge / internet (each alerts once per episode)
  b=$(dumpsys battery 2>/dev/null)
  t=$(( $(echo "$b" | sed -n 's/^ *temperature: //p' | head -1 | tr -dc '0-9' | sed 's/^$/0/') / 10 ))
  lvl=$(echo "$b" | sed -n 's/^ *level: //p' | head -1 | tr -dc '0-9')
  chg=$(echo "$b" | grep -cE '(AC|USB|Wireless) powered: true')
  if [ "$t" -ge 45 ]; then flag_once hot "HOT: battery ${t}C" 1; elif [ "$t" -le 41 ]; then flag_once hot "" 0; fi
  if [ -n "$lvl" ] && [ "$lvl" -le 15 ] && [ "$chg" = 0 ]; then flag_once lowbat "LOW battery ${lvl}% and not charging" 1
  elif [ "${lvl:-0}" -ge 25 ] || [ "$chg" -gt 0 ]; then flag_once lowbat "" 0; fi
  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then inet_fail=0; flag_once internet "" 0 recover
  else inet_fail=$((inet_fail + 1)); [ "$inet_fail" -ge 3 ] && flag_once internet "Internet is down on the phone" 1; fi
done
