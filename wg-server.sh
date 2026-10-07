#!/system/bin/sh
# Create a WireGuard server config (phone = 10.8.0.1) plus N client configs. Keys are never printed.
#   su -c "sh /data/adb/modules/hotspot_smb/wg-server.sh <public-endpoint-host-or-ip> [clients=1] [port=51820]"
# Output (root-only): /data/adb/hotspot_smb/wg0.conf and /data/adb/hotspot_smb/wg-clients/client<N>.conf
# Then set ENABLE_WG=1 (config.sh or /sdcard/hotspot_smb.conf), reboot. Clients reach the phone at 10.8.0.1.
MODDIR=$(cd "$(dirname "$0")" && pwd)
TERMUX=/data/data/com.termux/files/usr
export LD_LIBRARY_PATH="$MODDIR/prefix/lib" PATH="$MODDIR/prefix/bin:$PATH"
WG="$MODDIR/prefix/bin/wg"
EP=$1; N=${2:-1}; PORT=${3:-51820}
[ -n "$EP" ] || { echo "usage: $0 <endpoint host/ip> [clients] [port]"; exit 1; }
OUT=/data/adb/hotspot_smb; mkdir -p "$OUT/wg-clients"; umask 077

SK=$("$WG" genkey); SP=$(echo "$SK" | "$WG" pubkey)
{
  echo "[Interface]"; echo "Address = 10.8.0.1/24"; echo "ListenPort = $PORT"; echo "PrivateKey = $SK"
} > "$OUT/wg0.conf"
i=1
while [ "$i" -le "$N" ]; do
  CK=$("$WG" genkey); CP=$(echo "$CK" | "$WG" pubkey); PSK=$("$WG" genpsk)
  { echo; echo "[Peer]"; echo "# client$i"; echo "PublicKey = $CP"; echo "PresharedKey = $PSK"; echo "AllowedIPs = 10.8.0.$((i+1))/32"; } >> "$OUT/wg0.conf"
  {
    echo "[Interface]"; echo "Address = 10.8.0.$((i+1))/32"; echo "PrivateKey = $CK"
    echo; echo "[Peer]"; echo "PublicKey = $SP"; echo "PresharedKey = $PSK"
    echo "Endpoint = $EP:$PORT"; echo "AllowedIPs = 10.8.0.0/24"; echo "PersistentKeepalive = 25"
  } > "$OUT/wg-clients/client$i.conf"
  i=$((i+1))
done
echo "wrote $OUT/wg0.conf and $N client config(s) in $OUT/wg-clients/"
echo "Copy a client config:  adb pull $OUT/wg-clients/client1.conf   (it holds a private key)"
