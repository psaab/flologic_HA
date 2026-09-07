#!/bin/sh
# Package the driver for Composer Pro: driver.xml + bundled driver.lua
# zipped as flologic_valve.c4z. Usage: sh c4/scripts/package.sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/bundle.sh
OUT="flologic_valve.c4z"
rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -q "$OUT" driver.xml driver.lua ca-bundle.pem CA-LICENSE
else
  python3 -c "import zipfile; z = zipfile.ZipFile('$OUT', 'w', zipfile.ZIP_DEFLATED); z.write('driver.xml'); z.write('driver.lua'); z.write('ca-bundle.pem'); z.write('CA-LICENSE'); z.close()"
fi
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
