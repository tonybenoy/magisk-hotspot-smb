#!/usr/bin/env bash
# Compare the module installed on the phone with this repo (adb + root). config.sh is NEVER pulled or read.
#   ./diff-device.sh           # per-file status by md5
#   ./diff-device.sh --diff    # also show unified diffs of differing text files
cd "$(dirname "$0")"
has_dev() { "$1" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"' | grep -q .; }
ADB=adb; has_dev adb || { has_dev adb.exe && ADB=adb.exe; }
has_dev "$ADB" || { echo "No adb device found"; exit 1; }
M=/data/adb/modules/hotspot_smb
FILES="module.prop service.sh nat.sh lib.sh watchdog.sh sms.sh sms-setup.sh passwd.sh wg-server.sh panel/www/index.html panel/www/cgi-bin/index.cgi prefix.tar.gz"
rsum() { "$ADB" shell "su -c 'md5sum $M/$1 2>/dev/null'" | tr -d '\r' | cut -d' ' -f1; }
diffs=()
for f in $FILES; do
  l=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1); r=$(rsum "$f")
  if [ -z "$r" ]; then echo "MISSING on phone  $f"
  elif [ "$l" = "$r" ]; then echo "same              $f"
  else echo "DIFFERENT         $f"; diffs+=("$f"); fi
done
echo "config.sh         (skipped on purpose)"
echo "--- on the phone but not in the repo (outside prefix/):"
"$ADB" shell "su -c 'cd $M && find . -type f ! -path ./prefix/\\*'" | tr -d '\r' | sed 's|^\./||' | sort > /tmp/.dd_remote.$$
for f in $FILES config.sh; do echo "$f"; done | sort > /tmp/.dd_local.$$
comm -23 /tmp/.dd_remote.$$ /tmp/.dd_local.$$ | grep -vE '^(\.replace|\.remove|update|disable|skip_mount)$' || echo "(none)"
rm -f /tmp/.dd_remote.$$ /tmp/.dd_local.$$
if [ "$1" = "--diff" ]; then
  for f in "${diffs[@]}"; do
    [ "$f" = prefix.tar.gz ] && continue
    echo; echo "=== $f (phone -> repo)"
    diff -u <("$ADB" exec-out "su -c 'cat $M/$f'" | tr -d '\r') "$f"
  done
fi
