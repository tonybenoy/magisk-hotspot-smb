#!/usr/bin/env bash
# One-shot installer, run on the PC with the phone connected over USB (adb + Magisk root).
#   ./install.sh [--ssid NAME] [--key ~/.ssh/tony.pub] [--no-reboot]
# Uses the passwords in config.sh (random ones replace any "change-me*" placeholders; saved to .passwords, mode 600), builds hotspot_smb.zip,
# flashes it with `magisk --install-module`, adds your SSH public key, reboots.
set -euo pipefail
cd "$(dirname "$0")"

SSID=""; REBOOT=1; KEYFILE=""
while [ $# -gt 0 ]; do
  case $1 in
    --ssid) SSID=$2; shift ;;
    --no-reboot) REBOOT=0 ;;
    --key) KEYFILE=$2; shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac; shift
done

# adb: prefer the Linux one, fall back to Windows adb.exe (WSL)
ADB=adb; WIN=0
has_dev() { "$1" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"' | grep -q .; }
if ! has_dev adb; then
  command -v adb.exe >/dev/null && ADB=adb.exe && WIN=1
fi
adb_() { "$ADB" "$@" | tr -d '\r'; }
has_dev "$ADB" || { echo "No adb device found (phone connected, unlocked, USB debugging authorised?)"; exit 1; }
pth() { [ $WIN = 1 ] && wslpath -w "$1" || echo "$1"; }
su_() { "$ADB" shell "su -c '$1'" | tr -d '\r'; }

su_ id | grep -q uid=0 || { echo "Root (su) not granted to adb shell: approve the Magisk prompt on the phone"; exit 1; }
su_ 'magisk -v' >/dev/null || { echo "Magisk not found"; exit 1; }
[ -f prefix.tar.gz ] || { echo "prefix.tar.gz missing: run ./make-bundle.sh first (see README)"; exit 1; }
[ -f config.sh ] || { cp config.example.sh config.sh; echo "created config.sh from config.example.sh (git-ignored, your real settings)"; }

# Passwords: keep any you already set in config.sh, generate random ones only for "change-me*" placeholders
gen() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14; }
BUILD=$(mktemp -d); trap 'rm -rf "$BUILD"' EXIT
cp module.prop service.sh nat.sh passwd.sh wg-server.sh lib.sh watchdog.sh sms.sh sms-setup.sh prefix.tar.gz config.sh "$BUILD"/
cp -r panel "$BUILD"/panel
umask 077
for v in HOTSPOT_PASS SMB_PASS TR_PASS ST_PASS PANEL_PASS; do
  if grep -q "^$v=\"change-me" config.sh; then
    sed -i "s|^$v=\"change-me[^\"]*\"|$v=\"$(gen)\"|" "$BUILD/config.sh"
  fi
done
[ -n "$SSID" ] && sed -i "s|^HOTSPOT_SSID=\"[^\"]*\"|HOTSPOT_SSID=\"$SSID\"|" "$BUILD/config.sh"
grep -E '^(HOTSPOT_SSID|HOTSPOT_PASS|SMB_USER|SMB_PASS|TR_USER|TR_PASS|ST_USER|ST_PASS|PANEL_USER|PANEL_PASS)=' "$BUILD/config.sh" \
  | sed 's/ *#.*//' > .passwords
ZIP=$PWD/../hotspot_smb.zip
python3 -I - "$BUILD" "$ZIP" <<'EOF'
import sys, zipfile
b, out = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    for f in ["module.prop", "service.sh", "config.sh", "nat.sh", "passwd.sh", "wg-server.sh", "lib.sh", "watchdog.sh", "sms.sh", "sms-setup.sh", "prefix.tar.gz"]:
        z.write(f"{b}/{f}", f)
    import os
    for root, _, files in os.walk(f"{b}/panel"):
        for f in files:
            full = os.path.join(root, f); z.write(full, os.path.relpath(full, b))
EOF
echo "built $ZIP"

# Push + flash
adb_ push "$(pth "$ZIP")" /sdcard/Download/hotspot_smb.zip | tail -1
su_ 'magisk --install-module /sdcard/Download/hotspot_smb.zip' | tail -3
su_ 'rm -f /sdcard/Download/hotspot_smb.zip'

# SSH key
KEY=""
for k in ${KEYFILE:+"$KEYFILE"} ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do [ -f "$k" ] && KEY=$k && break; done
if [ -n "$KEY" ]; then
  adb_ push "$(pth "$KEY")" /data/local/tmp/_key.pub | tail -1
  su_ 'mkdir -p /data/adb/hotspot_smb; touch /data/adb/hotspot_smb/authorized_keys; grep -qxFf /data/local/tmp/_key.pub /data/adb/hotspot_smb/authorized_keys || cat /data/local/tmp/_key.pub >> /data/adb/hotspot_smb/authorized_keys; chmod 600 /data/adb/hotspot_smb/authorized_keys; rm /data/local/tmp/_key.pub'
  echo "added SSH key $KEY"
else
  echo "WARN: no ~/.ssh/*.pub found, SSH login won't work until you add a key (see README)"
fi

echo; echo "Installed. Logins (also saved in $PWD/.passwords):"; cat .passwords; echo
if [ $REBOOT = 1 ]; then
  echo "Rebooting. First boot is slow (unpacks ~170MB). Log: adb shell 'su -c \"cat /data/local/tmp/hotspot_smb.log\"'"
  "$ADB" reboot
else
  echo "Not rebooting. Reboot the phone to start everything."
fi
