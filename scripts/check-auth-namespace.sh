#!/bin/sh
# Core reserves the optional auth package's module names; BEAM names are global.
set -eu
cd "$(dirname "$0")/.."
for module in src/howdy/auth.gleam src/howdy/auth src/howdy/authorization.gleam src/howdy/migration.gleam; do
  if [ -e "$module" ]; then
    echo "Reserved auth namespace collides with core: $module" >&2
    exit 1
  fi
done
