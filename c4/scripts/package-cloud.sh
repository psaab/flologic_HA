#!/bin/sh
# Package the FloLogic Cloud driver for Composer Pro: driver.xml + bundled
# driver.lua plus the TLS trust store, zipped as flologic_cloud.c4z.
# The trust store ships because the cloud driver opens raw-TLS SignalR
# sessions with CACERTFILE="./ca-bundle.pem".
# Usage: sh c4/scripts/package-cloud.sh
set -eu
cd "$(dirname "$0")/.."
sh cloud/bundle.sh
OUT="flologic_cloud.c4z"
rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -q -j "$OUT" cloud/driver.xml cloud/driver.lua ca-bundle.pem CA-LICENSE
else
  python3 -c "import zipfile; files = [('cloud/driver.xml', 'driver.xml'), ('cloud/driver.lua', 'driver.lua'), ('ca-bundle.pem', 'ca-bundle.pem'), ('CA-LICENSE', 'CA-LICENSE')]; z = zipfile.ZipFile('$OUT', 'w', zipfile.ZIP_DEFLATED); [z.write(src, arc) for src, arc in files]; z.close()"
fi
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
