#!/bin/sh
# Core reserves the optional packages' module names; BEAM names are global.
set -eu
cd "$(dirname "$0")/.."
for module in src/howdy/auth.gleam src/howdy/auth src/howdy/authorization.gleam src/howdy/database.gleam src/howdy/migration.gleam src/howdy/remote.gleam src/howdy/remote; do
  if [ -e "$module" ]; then
    echo "Reserved optional-package namespace collides with core: $module" >&2
    exit 1
  fi
done
