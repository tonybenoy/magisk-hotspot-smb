#!/system/bin/sh
# One-time SMS setup. Run as root:
#   su -c "sh /data/adb/modules/hotspot_smb/sms-setup.sh <your number, e.g. +37255512345> [PIN]"
# Alerts go to this number; commands are accepted only from it, prefixed with the PIN ("1234 status").
MODDIR=$(cd "$(dirname "$0")" && pwd)
NUM=$1; PIN=${2:-$(tr -dc '0-9' < /dev/urandom | head -c 6)}
case "$NUM" in +[0-9]*) ;; *) echo "usage: $0 <+countrycode number> [PIN]"; exit 1 ;; esac
case "$PIN" in *[!A-Za-z0-9]*|'') echo "PIN: letters/digits only"; exit 1 ;; esac
mkdir -p /data/adb/hotspot_smb; umask 077
cat > /data/adb/hotspot_smb/sms.conf <<EOC
SMS_TO="$NUM"
SMS_ALLOWED="$NUM"
SMS_PIN="$PIN"
SMS_NOTIFY_RECOVERY=1
EOC
. "$MODDIR/lib.sh"
if sms_send "$NUM" "SMS alerts enabled. Send 'PIN help' for commands."; then echo "Test SMS sent to $NUM."; else echo "Test SMS FAILED, see /data/local/tmp/watchdog.log"; fi
sh "$MODDIR/service.sh" sms >/dev/null 2>&1; sh "$MODDIR/service.sh" watchdog >/dev/null 2>&1
echo "Your PIN: $PIN   (send e.g. \"$PIN status\" from $NUM)"
