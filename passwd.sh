#!/system/bin/sh
# Change a password, persist it in config.sh and apply it live. Run as root:
#   su -c "sh /data/adb/modules/hotspot_smb/passwd.sh <hotspot|smb|transmission|syncthing|panel> [newpass]"
# With no newpass a random one is generated and printed.
MODDIR=$(cd "$(dirname "$0")" && pwd)
CONF="$MODDIR/config.sh"
TERMUX=/data/data/com.termux/files/usr

what=$1; new=$2
case "$what" in
  hotspot) var=HOTSPOT_PASS ;;
  smb) var=SMB_PASS ;;
  transmission) var=TR_PASS ;;
  syncthing) var=ST_PASS ;;
  panel) var=PANEL_PASS ;;
  *) echo "usage: $0 <hotspot|smb|transmission|syncthing|panel> [newpass]"; exit 1 ;;
esac
[ -n "$new" ] || new=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14)
case "$new" in *[\"\\\$\`\|\&\']*) echo "password may not contain \" \\ \$ \` | & '"; exit 1 ;; esac
[ "$what" = hotspot ] && [ ${#new} -lt 8 ] && { echo "hotspot password needs 8+ characters"; exit 1; }

if [ "$what" = panel ]; then
  mkdir -p /data/adb/hotspot_smb; echo "$new" > /data/adb/hotspot_smb/panel_pass; chmod 600 /data/adb/hotspot_smb/panel_pass
  # If config.sh sets PANEL_PASS it takes priority at start, so keep it in sync
  grep -q '^PANEL_PASS=' "$CONF" && sed -i "s|^PANEL_PASS=.*|PANEL_PASS=\"$new\"|" "$CONF"
  . "$CONF"
else
  sed -i "s|^$var=.*|$var=\"$new\"|" "$CONF" || exit 1
  . "$CONF"
fi
[ -f /sdcard/hotspot_smb.conf ] && grep -q "^$var=" /sdcard/hotspot_smb.conf \
  && echo "WARN: /sdcard/hotspot_smb.conf also sets $var and overrides config.sh at boot"

case "$what" in
  smb)
    export LD_LIBRARY_PATH="$TERMUX/lib"
    ( echo "$new"; echo "$new" ) | "$TERMUX/bin/smbpasswd" -c /data/local/tmp/smb/smb.conf -s -a "$SMB_USER" ;;
  transmission)
    PREFIX="$MODDIR/prefix"; TR=/data/local/tmp/transmission
    pkill -f "transmission-[d]aemon"; sleep 2
    LD_LIBRARY_PATH="$PREFIX/lib" TRANSMISSION_WEB_HOME="$PREFIX/share/transmission/public_html" \
      "$PREFIX/bin/transmission-daemon" -g "$TR" -w "$TR_DOWNLOAD_DIR" -p "$TR_PORT" \
      -t -u "$TR_USER" -v "$TR_PASS" -a "*.*.*.*" -e "$TR/daemon.log" ;;
  panel)
    ( sh "$MODDIR/service.sh" panel >/dev/null 2>&1 & ) ;;
  syncthing)
    STH=/data/local/tmp/syncthing; PREFIX="$MODDIR/prefix"
    pkill -f "[s]yncthing serve"; sleep 2
    export LD_LIBRARY_PATH="$PREFIX/lib" HOME="$STH" STNOUPGRADE=1
    "$PREFIX/bin/syncthing" generate --home "$STH" --gui-user "$ST_USER" --gui-password "$new"
    nohup "$PREFIX/bin/syncthing" serve --home "$STH" --no-browser --gui-address "0.0.0.0:$ST_PORT" >"$STH/serve.log" 2>&1 & ;;
  hotspot)
    [ -s /data/adb/hotspot_smb/band ] && HOTSPOT_BAND=$(cat /data/adb/hotspot_smb/band)
    case "$HOTSPOT_BAND" in 2|5|6|any) band="-b $HOTSPOT_BAND" ;; *) band="" ;; esac
    cmd wifi stop-softap; sleep 3
    cmd wifi start-softap "$HOTSPOT_SSID" wpa2 "$HOTSPOT_PASS" $band
    echo "note: connected clients must reconnect with the new password" ;;
esac
echo "$what password set to: $new"
