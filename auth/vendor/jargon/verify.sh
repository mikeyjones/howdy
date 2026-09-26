#!/bin/sh
# Prove the vendored Jargon sources equal the published Hex package plus
# PATCH.diff and nothing else. Run from anywhere; needs curl, tar, patch, diff.
set -eu

version="1.1.0"
tarball_sha256="963fcd2e851f5fcf3821638c088ea1ef07365187319b9145a1d12dd3980162ca"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -sSfL -o "$work/jargon.tar" "https://repo.hex.pm/tarballs/jargon-$version.tar"
echo "$tarball_sha256  $work/jargon.tar" | sha256sum -c - >/dev/null

mkdir "$work/outer" "$work/upstream"
tar xf "$work/jargon.tar" -C "$work/outer"
tar xzf "$work/outer/contents.tar.gz" -C "$work/upstream"
patch -s -p1 -d "$work/upstream" <"$here/PATCH.diff"

# Only the runtime sources are compared. Upstream rebar packaging is unused;
# local packaging, notices and build outputs are not part of the upstream copy.
for path in LICENSE c_src/jargon.c c_src/Makefile src/jargon.erl argon2/include argon2/src; do
  diff -r -x '*.o' "$work/upstream/$path" "$here/$path"
done

echo "vendor/jargon matches jargon $version + PATCH.diff"
