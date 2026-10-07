#!/system/bin/sh
# SMS command listener. Accepts "<PIN> <command>" from numbers in SMS_ALLOWED only. Needs sms-setup.sh first.
MODDIR=$(cd "$(dirname "$0")" && pwd)
. "$MODDIR/lib.sh"
LOG=/data/local/tmp/watchdog.log
exec >>"$LOG" 2>&1
log() { echo "$(date '+%F %T') sms: $*"; }
[ -n "$SMS_PIN" ] && [ -n "${SMS_ALLOWED:-$SMS_TO}" ] || { log "not configured (run sms-setup.sh), listener not started"; exit 0; }
ALLOWED=${SMS_ALLOWED:-$SMS_TO}
LASTF=/data/local/tmp/sms_last
q() { content query --uri content://sms/inbox --projection _id:address:body "$@" 2>/dev/null | grep '^Row:'; }
# Start from the newest existing message so old texts are never executed
[ -s "$LASTF" ] || { m=$(content query --uri content://sms/inbox --projection _id --sort "_id DESC" 2>/dev/null | grep '^Row:' | head -1 | sed 's/.*_id=//; s/[^0-9].*//'); echo "${m:-0}" > "$LASTF"; }
last9() { echo "$1" | tr -dc '0-9' | sed 's/.*\(.........\)$/\1/'; }
log "listener started"

allowed() { a=$(last9 "$1"); for n in $ALLOWED; do [ "$(last9 "$n")" = "$a" ] && return 0; done; return 1; }

run_cmd() { # <reply-to> <command words...>
  to=$1; shift; cmd=$1; shift
  case "$cmd" in
    help) sms_send "$to" "status | ip | restart <svc|all> | band 2|5 | wd on|off | reboot. svc: hotspot network samba transmission syncthing ssh unbound proxy panel" ;;
    status) sms_send "$to" "$(status_text)" ;;
    ip) sms_send "$to" "$(ip -o -4 addr show | awk '$2!="lo"{printf "%s %s; ", $2, $4}')" ;;
    restart)
      case "$1" in
        all) sms_send "$to" "Restarting everything (~1 min)"; ( sh "$MODDIR/service.sh" >/dev/null 2>&1 & ) ;;
        hotspot|network|samba|transmission|syncthing|ssh|unbound|proxy|panel|wg)
          sms_send "$to" "Restarting $1"; ( . "$MODDIR/lib.sh"; svc_restart "$1" >/dev/null 2>&1 & ) ;;
        *) sms_send "$to" "Unknown service" ;;
      esac ;;
    band)
      case "$1" in 2|5) echo "$1" > "$PERSIST/band"; sms_send "$to" "Switching hotspot to $1 GHz, reconnect in ~30 s"
                  ( . "$MODDIR/lib.sh"; svc_restart hotspot >/dev/null 2>&1 & ) ;;
        *) sms_send "$to" "band 2 or band 5" ;; esac ;;
    wd) case "$1" in off) touch "$PERSIST/watchdog.off"; sms_send "$to" "Watchdog paused" ;;
                     on) rm -f "$PERSIST/watchdog.off"; sms_send "$to" "Watchdog on" ;; *) sms_send "$to" "wd on|off" ;; esac ;;
    reboot) sms_send "$to" "Rebooting now"; ( sleep 3; reboot ) >/dev/null 2>&1 & ;;
    *) sms_send "$to" "Unknown command. Send: PIN help" ;;
  esac
}

while :; do
  sleep "${SMS_POLL:-8}"
  [ -d /sdcard/Download ] || continue
  LAST=$(cat "$LASTF" 2>/dev/null || echo 0)
  q --where "_id>$LAST" --sort "_id ASC" | while IFS= read -r row; do
    id=$(echo "$row" | sed 's/^Row: [0-9]* _id=//; s/,.*//')
    addr=$(echo "$row" | sed 's/.*, address=//; s/, body=.*//')
    body=$(echo "$row" | sed 's/.*, body=//')
    echo "$id" > "$LASTF"
    if ! allowed "$addr"; then log "ignored sms from unlisted number (id $id)"; continue; fi
    set -- $(echo "$body" | tr 'A-Z' 'a-z')
    [ "$1" = "$(echo "$SMS_PIN" | tr 'A-Z' 'a-z')" ] || { log "wrong pin from allowed number (id $id)"; continue; }
    shift; log "command from allowed number: ${1:-<none>}"
    run_cmd "$addr" "$@"
  done
done
