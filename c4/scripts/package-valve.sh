#!/bin/sh
# Package the FloLogic Water Valve driver for Composer Pro: driver.xml +
# bundled driver.lua zipped as flologic_valve.c4z (the valve reuses the
# legacy monolith asset filename). No trust store: the
# valve driver uses only platform HTTPS (C4:url) and plain-TCP Composer SOAP,
# with no raw-TLS CACERTFILE reference.
# Usage: sh c4/scripts/package-valve.sh
set -eu
cd "$(dirname "$0")/.."
sh valve/bundle.sh
OUT="flologic_valve.c4z"
rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -q -j "$OUT" valve/driver.xml valve/driver.lua
else
  python3 -c "import zipfile; files = [('valve/driver.xml', 'driver.xml'), ('valve/driver.lua', 'driver.lua')]; z = zipfile.ZipFile('$OUT', 'w', zipfile.ZIP_DEFLATED); [z.write(src, arc) for src, arc in files]; z.close()"
fi
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
