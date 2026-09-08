#!/bin/sh
# Package the split drivers for Composer Pro at one lockstep version
# (flologic_cloud.c4z + flologic_valve.c4z). The monolith is legacy and is
# no longer packaged: its last build stays on its old release tags, and the
# flologic_valve.c4z filename now belongs to the split valve driver.
# Usage: sh c4/scripts/package.sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/package-cloud.sh
sh scripts/package-valve.sh
