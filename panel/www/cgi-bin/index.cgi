#!/system/bin/sh
# Phone home-server control panel. Runs as root under busybox httpd (basic auth in httpd.conf).
export PATH=/system/bin:/system/xbin:/apex/com.android.runtime/bin
MODDIR=/data/adb/modules/hotspot_smb
BB=/data/adb/magisk/busybox
CONF=/data/local/tmp/httpd.conf
MSG=/data/local/tmp/panel_msg
ALOG=/data/local/tmp/panel_actions.log
SECRET=$(grep '^/:' "$CONF" | cut -d: -f3-)
TOKEN=$(printf '%s%s' "$(cat /proc/sys/kernel/random/boot_id)" "$SECRET" | $BB md5sum | cut -c1-32)

esc() { sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'; }
field() { echo "$BODY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | { read -r v; $BB httpd -d "$v"; }; }
up() { ps -A 2>/dev/null | grep -qE "$1"; }
upargs() { ps -A -o ARGS 2>/dev/null | grep -q "$1"; }
go_back() { printf 'Status: 303 See Other\r\nLocation: /cgi-bin/index.cgi\r\n\r\n'; exit 0; }
detach() { ( "$@" >>"$ALOG" 2>&1 & ) ; }

# ---------- actions (POST only, token-checked) ----------
if [ "$REQUEST_METHOD" = POST ]; then
  BODY=$($BB head -c "${CONTENT_LENGTH:-0}")
  if [ "$(field token)" != "$TOKEN" ]; then
    printf 'Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nBad token, reload the page.\n'; exit 0
  fi
  ACTION=$(field action); SVC=$(field svc)
  case "$ACTION" in
    restart)
      case "$SVC" in
        samba|transmission|ssh|syncthing|unbound|proxy|network|hotspot|wg|panel|watchdog|sms)
          detach sh "$MODDIR/service.sh" "$SVC"; echo "Restarting $SVC..." > "$MSG" ;;
        *) echo "Unknown service" > "$MSG" ;;
      esac ;;
    stop)
      case "$SVC" in
        samba) pkill -x smbd; pkill -x nmbd ;;
        transmission) pkill -f "[t]ransmission-daemon" ;;
        ssh) pkill -f "[s]shd -f /data/local/tmp/ssh/sshd_config" ;;
        syncthing) pkill -f "[s]yncthing serve" ;;
        unbound) pkill -9 -x unbound ;;
        proxy) pkill -f "[n]ginx" ;;
        watchdog) pkill -f "[w]atchdog.s[h]" ;;
        sms) pkill -f "[s]ms.s[h]" ;;
        network) pkill -f "[u]dhcpd"; pkill -f "[n]at.s[h]" ;;
        *) echo "Cannot stop that one" > "$MSG"; go_back ;;
      esac
      echo "Stopped $SVC" > "$MSG" ;;
    band)
      case "$(field val)" in
        2|5) mkdir -p /data/adb/hotspot_smb; field val > /data/adb/hotspot_smb/band
             detach sh -c "sh $MODDIR/service.sh hotspot; sh $MODDIR/service.sh network"
             echo "Switching hotspot to $(field val) GHz. You will be disconnected; reconnect in ~20 s." > "$MSG" ;;
        *) echo "Bad band" > "$MSG" ;;
      esac ;;
    wd)
      case "$(field val)" in
        off) mkdir -p /data/adb/hotspot_smb; touch /data/adb/hotspot_smb/watchdog.off; echo "Watchdog paused (no auto-restart, no SMS)" > "$MSG" ;;
        on) rm -f /data/adb/hotspot_smb/watchdog.off; echo "Watchdog resumed" > "$MSG" ;;
      esac ;;
    smssave)
      NUM=$(field num); PIN=$(field pin); NR=$(field notify)
      case "$NUM" in +[0-9]*) ;; *) echo "Number must start with + and country code, e.g. +37255512345" > "$MSG"; go_back ;; esac
      case "$NUM" in *[!0-9+]*) echo "Number: digits only after +" > "$MSG"; go_back ;; esac
      if [ -z "$PIN" ]; then
        PIN=$(sed -n 's/^SMS_PIN="\(.*\)"/\1/p' /data/adb/hotspot_smb/sms.conf 2>/dev/null)
        [ -n "$PIN" ] || PIN=$(tr -dc '0-9' < /dev/urandom | head -c 6)
      fi
      case "$PIN" in *[!A-Za-z0-9]*) echo "PIN: letters and digits only" > "$MSG"; go_back ;; esac
      [ "${#PIN}" -ge 4 ] || { echo "PIN needs 4+ characters" > "$MSG"; go_back; }
      mkdir -p /data/adb/hotspot_smb
      ( umask 077; printf 'SMS_TO="%s"\nSMS_ALLOWED="%s"\nSMS_PIN="%s"\nSMS_NOTIFY_RECOVERY=%s\n' "$NUM" "$NUM" "$PIN" "$([ "$NR" = 1 ] && echo 1 || echo 0)" > /data/adb/hotspot_smb/sms.conf )
      detach sh -c "sh $MODDIR/service.sh sms; sh $MODDIR/service.sh watchdog"
      echo "SMS settings saved. Number $NUM, PIN $PIN (shown once). Send '$PIN help' from that number." > "$MSG" ;;
    smsoff)
      rm -f /data/adb/hotspot_smb/sms.conf; pkill -f "[s]ms.s[h]"
      detach sh "$MODDIR/service.sh" watchdog
      echo "SMS disabled (alerts and commands off)." > "$MSG" ;;
    smstest)
      if ( . "$MODDIR/lib.sh"; [ -n "$SMS_TO" ] && sms_alert "Test message from the panel." ); then echo "Test SMS sent." > "$MSG"
      else echo "Test SMS FAILED or no number set. See the watchdog log below." > "$MSG"; fi ;;
    keepon)
      case "$(field val)" in
        on) rm -f /data/adb/hotspot_smb/hotspot.off; echo "Hotspot is kept on: it is restarted within ~10 s if Android turns it off." > "$MSG" ;;
        off) mkdir -p /data/adb/hotspot_smb; touch /data/adb/hotspot_smb/hotspot.off; echo "Keep-on disabled: the module will leave the hotspot alone when it is turned off." > "$MSG" ;;
      esac ;;
    restartall) detach sh "$MODDIR/service.sh"; echo "Restarting everything (takes ~1 min)..." > "$MSG" ;;
    reboot) ( sleep 3; reboot ) >/dev/null 2>&1 & echo "Rebooting now. The panel is back after unlock + boot." > "$MSG" ;;
    passwd)
      W=$(field which); NP=$(field newpw)
      case "$W" in
        hotspot|smb|transmission|syncthing|panel) sh "$MODDIR/passwd.sh" "$W" "$NP" > "$MSG" 2>&1 ;;
        *) echo "Unknown account" > "$MSG" ;;
      esac ;;
  esac
  go_back
fi

# ---------- page ----------
QS=$QUERY_STRING
LOGSEL=$(echo "$QS" | sed -n 's/.*log=\([a-z]*\).*/\1/p')
HOST=${HTTP_HOST%%:*}
printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
cat <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Phone server</title><style>
body{font:15px system-ui,sans-serif;background:#111;color:#ddd;margin:0;padding:12px;max-width:900px;margin:auto}
h1{font-size:20px}h2{font-size:15px;color:#9ab;margin:22px 0 6px;border-bottom:1px solid #333}
table{border-collapse:collapse;width:100%}td,th{padding:5px 6px;border-bottom:1px solid #222;text-align:left}
.up{color:#4c8}.down{color:#e66}button,select,input{font:inherit;padding:5px 9px;background:#222;color:#ddd;border:1px solid #444;border-radius:4px}
button{cursor:pointer}button.danger{border-color:#a44;color:#f99}a{color:#8bd}form{display:inline}
pre{background:#000;padding:8px;overflow:auto;max-height:340px;font-size:12px}.msg{background:#243;padding:8px;border-radius:4px;margin:8px 0}
</style></head><body><h1>📱 Phone server</h1>
HTML
if [ -s "$MSG" ]; then echo "<div class=msg><pre style='background:none;margin:0;max-height:none'>$(esc < "$MSG")</pre></div>"; rm -f "$MSG"; fi

# --- links & addresses
cfg() { v=$(sed -n "s/^$1=\"\([^\"]*\)\".*/\1/p" "$MODDIR/config.sh" 2>/dev/null | tail -1); [ -n "$v" ] || v=$(sed -n "s/^$1=\([^ \"#]*\).*/\1/p" "$MODDIR/config.sh" 2>/dev/null | tail -1); echo "${v:-$2}"; }
DOM=$(cfg HOTSPOT_DOMAIN lan); HIP=$(cfg HOTSPOT_IP ""); TRP=$(cfg TR_PORT 9091); STP=$(cfg ST_PORT 8384); SSP=$(cfg SSH_PORT 22)
PNP=$(cfg PANEL_PORT 8080); SMBS=$(cfg SHARE_NAME share)
PUB=/data/local/tmp/panel_pubip
if [ ! -s "$PUB" ] || [ -n "$(find "$PUB" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
  ( curl -s -m 5 https://api.ipify.org > "$PUB.t" 2>/dev/null; [ -s "$PUB.t" ] && mv "$PUB.t" "$PUB"; rm -f "$PUB.t" ) >/dev/null 2>&1 &
fi
PUBIP=$(cat "$PUB" 2>/dev/null); PUBIP=${PUBIP:-checking...}
label() { case "$1" in rmnet*|ccmni*) echo "mobile data" ;; wlan0) echo "Wi-Fi (phone as client)" ;; wlan[12]|ap0|swlan0) echo "hotspot" ;; wg*) echo "WireGuard" ;; eth*|usb*|rndis*) echo "USB / Ethernet" ;; *) echo "$1" ;; esac; }
echo "<h2>Addresses</h2><table>"
ip -o -4 addr show 2>/dev/null | awk '$2!="lo" && $2!~/^(dummy|gretap|ip6)/ {split($4,a,"/"); print $2, a[1]}' | while read -r IFN IPA; do
  echo "<tr><td>$(label "$IFN")</td><td><code>$IPA</code></td><td><small>$IFN</small></td></tr>"
done
echo "<tr><td>Public (internet)</td><td><code>$PUBIP</code></td><td><small>as seen from outside, cached 10 min; behind carrier NAT it is shared</small></td></tr>"
echo "</table>"
H=${HIP:-$HOST}
DNSON=$(cfg ENABLE_UNBOUND 0)
N() { if [ "$DNSON" = 1 ]; then echo "$1"; else echo "<small>(local DNS is off)</small>"; fi; }
echo "<h2>Links</h2><table><tr><th>Service</th><th>By name</th><th>By IP ($H)</th></tr>"
lrow() { printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$1" "$2" "$3"; }
lrow "This panel" "$(N "<a href='http://panel.$DOM/'>panel.$DOM</a>")" "<a href='http://$H/'>$H</a> &nbsp;<small>(also :$PNP)</small>"
lrow "Transmission (torrents)" "$(N "<a href='http://torrent.$DOM/'>torrent.$DOM</a>")" "<a href='http://$H/transmission/web/'>$H/transmission/web/</a> &nbsp;<small>(also :$TRP)</small>"
lrow "Syncthing" "$(N "<a href='http://sync.$DOM/'>sync.$DOM</a>")" "<a href='http://$H:$STP/'>$H:$STP</a>"
lrow "Files (Samba)" "$(N "<code>\\\\phone.$DOM\\$SMBS</code>")" "<code>\\\\$H\\$SMBS</code>"
lrow "Torrent downloads (Samba)" "$(N "<code>\\\\phone.$DOM\\torrents</code>")" "<code>\\\\$H\\torrents</code>"
lrow "SSH" "$(N "<code>ssh -p $SSP root@phone.$DOM</code>")" "<code>ssh -p $SSP root@$H</code>"
[ "$DNSON" = 1 ] && lrow "DNS server" "" "<code>$H</code> (answers <code>*.$DOM</code>)"
ip link show wg0 >/dev/null 2>&1 && lrow "WireGuard" "" "<code>$(ip -o -4 addr show wg0 | awk '{split($4,a,"/"); print a[1]}')</code>"
echo "</table>"

# --- device
BAT=$(dumpsys battery 2>/dev/null)
LVL=$(echo "$BAT" | sed -n 's/^ *level: //p'); TEMP=$(echo "$BAT" | sed -n 's/^ *temperature: //p')
PWR=$(echo "$BAT" | grep -E 'AC powered: true|USB powered: true|Wireless powered: true' | head -1 | sed 's/^ *//;s/ powered: true/ power/')
echo "<h2>Device</h2><table>"
echo "<tr><td>Battery</td><td>${LVL:-?}% · $(( ${TEMP:-0} / 10 )).$(( ${TEMP:-0} % 10 ))°C · ${PWR:-on battery}</td></tr>"
echo "<tr><td>Uptime</td><td>$(uptime | sed 's/^ *//' | esc)</td></tr>"
echo "<tr><td>Storage</td><td>$(df -h /sdcard 2>/dev/null | tail -1 | awk '{print $3" used of "$2", "$4" free"}')</td></tr>"
echo "<tr><td>Addresses</td><td>$(ip -o -4 addr show 2>/dev/null | awk '$2!="lo"{printf "%s %s · ", $2, $4}' | esc)</td></tr>"
echo "</table>"

# --- services
row() { # name label running-flag link
  if [ "$3" = 1 ]; then st='<span class=up>● running</span>'; else st='<span class=down>● stopped</span>'; fi
  lnk=""; [ -n "$4" ] && lnk="<a href='$4' target=_blank>open</a>"
  printf '<tr><td>%s</td><td>%s</td><td>%s</td><td><form method=post><input type=hidden name=token value="%s"><input type=hidden name=svc value="%s"><button name=action value=restart>restart</button> <button name=action value=stop>stop</button></form></td></tr>\n' "$2" "$st" "$lnk" "$TOKEN" "$1"
}
echo "<h2>Services</h2><table>"
f=0; up ' smbd$' && f=1;                    row samba "Samba + NetBIOS" $f ""
f=0; up ' transmission-daemon$' && f=1;      row transmission "Transmission" $f "http://$H:$TRP/"
f=0; up ' syncthing$' && f=1;                row syncthing "Syncthing" $f "http://$H:$STP/"
f=0; up ' sshd$' && f=1;                     row ssh "SSH" $f ""
[ "$DNSON" = 1 ] && { f=0; up ' unbound$' && f=1; row unbound "DNS (unbound)" $f ""; }
f=0; up ' nginx(\.conf)?$' && f=1;                    row proxy "Web proxy (nginx)" $f ""
f=0; upargs '[u]dhcpd' && f=1;               row network "DHCP + internet sharing" $f ""
f=0; ip link show wg0 >/dev/null 2>&1 && f=1; row wg "WireGuard" $f ""
f=0; upargs '[w]atchdog.s[h]' && f=1;        row watchdog "Watchdog" $f ""
f=0; upargs '[s]ms.s[h]' && f=1;             row sms "SMS commands" $f ""
echo "</table>"
if [ -e /data/adb/hotspot_smb/watchdog.off ]; then WDS="<b class=down>PAUSED</b> <button name=val value=on>resume watchdog</button>"; else WDS="<b class=up>active</b> <button name=val value=off>pause watchdog</button>"; fi
echo "<p><form method=post><input type=hidden name=token value=\"$TOKEN\"><input type=hidden name=action value=wd>Watchdog: $WDS</form></p>"
if [ -e /data/adb/hotspot_smb/hotspot.off ]; then KOS="<b class=down>off</b> <button name=val value=on>keep hotspot on</button>"; else KOS="<b class=up>on</b> <button name=val value=off onclick=\"return confirm('Let the hotspot stay off when it is turned off?')\">allow it to stay off</button>"; fi
echo "<p><form method=post><input type=hidden name=token value=\"$TOKEN\"><input type=hidden name=action value=keepon>Keep hotspot on (restart if Android turns it off): $KOS</form></p>"
echo "<p><form method=post><input type=hidden name=token value=\"$TOKEN\"><button name=action value=restartall>Restart everything</button> <button name=action value=reboot class=danger onclick=\"return confirm('Reboot the phone?')\">Reboot phone</button></form></p>"
FREQ=$(dumpsys wifi 2>/dev/null | grep -o 'frequency= *[0-9]*' | grep -v 'frequency= *0$' | head -1 | tr -dc '0-9')
if [ -z "$FREQ" ]; then CUR="off"; elif [ "$FREQ" -lt 3000 ]; then CUR="2.4 GHz (ch. $(( (FREQ - 2407) / 5 )))"; else CUR="5 GHz ($FREQ MHz)"; fi
echo "<p>Hotspot band: <b>$CUR</b> &nbsp; <form method=post><input type=hidden name=token value=\"$TOKEN\"><input type=hidden name=action value=band><button name=val value=2 onclick=\"return confirm('Switch to 2.4 GHz? Clients are disconnected for ~20 s.')\">2.4 GHz</button> <button name=val value=5 onclick=\"return confirm('Switch to 5 GHz? Clients are disconnected for ~20 s. Older devices cannot see 5 GHz.')\">5 GHz</button></form></p>"
echo "<p><form method=post><input type=hidden name=token value=\"$TOKEN\"><input type=hidden name=svc value=hotspot><button name=action value=restart onclick=\"return confirm('Restart the hotspot? You will be disconnected.')\">Restart hotspot</button></form></p>"

# --- clients
echo "<h2>Hotspot clients</h2><pre>$($BB dumpleases -f /data/local/tmp/udhcpd.leases 2>/dev/null | esc)</pre>"

# --- passwords
cat <<HTML
<h2>Change password</h2>
<form method=post><input type=hidden name=token value="$TOKEN"><input type=hidden name=action value=passwd>
<select name=which><option value=hotspot>Hotspot Wi-Fi</option><option value=smb>Samba</option><option value=transmission>Transmission</option><option value=syncthing>Syncthing</option><option value=panel>This panel</option></select>
<input name=newpw placeholder="new password (blank = random)" autocomplete=off size=30>
<button>Change</button></form>
<small>No " \ \$ \` | &amp; ' characters. A random one is shown above after changing.</small>
HTML

# --- sms
SMSNUM=$(sed -n 's/^SMS_TO="\(.*\)"/\1/p' /data/adb/hotspot_smb/sms.conf 2>/dev/null)
SMSREC=$(sed -n 's/^SMS_NOTIFY_RECOVERY=//p' /data/adb/hotspot_smb/sms.conf 2>/dev/null)
if [ -n "$SMSNUM" ]; then SMSST="<b class=up>on</b> for $(echo "$SMSNUM" | sed 's/.*\(....\)$/…\1/')"; else SMSST="<b class=down>not set up</b>"; fi
cat <<HTML
<h2>SMS alerts &amp; commands</h2>
<p>$SMSST. One text when something goes down, one when it is back; commands need the PIN first (e.g. <code>PIN status</code>).</p>
<form method=post><input type=hidden name=token value="$TOKEN"><input type=hidden name=action value=smssave>
<input name=num placeholder="+37255512345" value="$SMSNUM" size=18>
<input name=pin placeholder="PIN (blank = keep / random)" autocomplete=off size=24>
<label><input type=checkbox name=notify value=1 $([ "$SMSREC" != 0 ] && echo checked)> also text when recovered</label>
<button>Save</button></form>
<form method=post><input type=hidden name=token value="$TOKEN"><input type=hidden name=action value=smstest><button>Send test SMS</button></form>
<form method=post><input type=hidden name=token value="$TOKEN"><input type=hidden name=action value=smsoff><button class=danger onclick="return confirm('Turn off SMS alerts and commands?')">Disable SMS</button></form>
HTML

# --- logs
echo "<h2>Logs</h2><p>"
for l in module watchdog sms nat transmission syncthing unbound dhcp actions; do echo "<a href='?log=$l'>$l</a> "; done; echo "</p>"
case "$LOGSEL" in
  module) F=/data/local/tmp/hotspot_smb.log ;; watchdog) F=/data/local/tmp/watchdog.log ;; sms) F=/data/local/tmp/sms_sent.log ;; nat) F=/data/local/tmp/nat.log ;;
  transmission) F=/data/local/tmp/transmission/daemon.log ;; syncthing) F=/data/local/tmp/syncthing/serve.log ;;
  unbound) F=/data/local/tmp/unbound/unbound.log ;; dhcp) F=/data/local/tmp/udhcpd.log ;; actions) F=$ALOG ;; *) F="" ;;
esac
[ -n "$F" ] && echo "<pre>$(tail -n 60 "$F" 2>&1 | esc)</pre>"
echo "<p><a href='/cgi-bin/index.cgi'>refresh</a></p></body></html>"
