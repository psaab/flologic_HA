#!/bin/sh
# Package the split drivers for Composer Pro at one lockstep version
# (flologic_cloud.c4z + flologic_water_valve.c4z). The monolith is legacy
# and is no longer packaged: its last build stays on its old release
# tags under the flologic_valve.c4z filename, which the split family must
# never reuse (installed monoliths would offer the companion as an
# update). A stale flologic_valve.c4z from an older checkout is removed
# so it can never be uploaded by mistake.
# Usage: sh c4/scripts/package.sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/package-cloud.sh
sh scripts/package-valve.sh
rm -f flologic_valve.c4z
