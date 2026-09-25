#!/usr/bin/env bash
# Release every Howdy package together as one Howdy version. See RELEASING.md.
#
#   scripts/release.sh 2.1.0            check, record, commit and tag
#   scripts/release.sh 2.1.0 --no-tag   check and record only, to review first
#
# It never pushes. Push the branch and the tag yourself when you are happy.
set -euo pipefail

cd "$(dirname "$0")/.."

version="${1:-}"
tag_it=true
if [[ "${2:-}" == "--no-tag" ]]; then tag_it=false; fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh VERSION [--no-tag]   (VERSION like 2.1.0)" >&2
  exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "Tag v$version already exists." >&2
  exit 1
fi

echo "== Checking versions"
gleam run -m howdy_release -- check "$version"

echo "== Exporting each package's public API"
interfaces="$(mktemp -d)"
trap 'rm -rf "$interfaces"' EXIT
packages=(
  "howdy:."
  "howdy_dev:howdy_dev"
  "howdy_ui:ui"
  "howdy_database:database"
  "howdy_auth:auth"
  "howdy_mail:mail"
  "howdy_admin:admin"
  "howdy_remote:remote"
)
for entry in "${packages[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"
  echo "   $name"
  (cd "$path" && gleam export package-interface --out "$interfaces/$name.json" >/dev/null)
done

echo "== Recording the release"
gleam run -m howdy_release -- record "$version" "$(date +%F)" "$interfaces"

echo "== Pointing the docs' install instructions at v$version"
find docs -name '*.djot' -print0 | xargs -0 sed -i -E \
  "s#(github\.com/mikeyjones/howdy\.git\", ref = \")v[^\"]*\"#\1v$version\"#g"

if [[ "$tag_it" == false ]]; then
  echo
  echo "Recorded Howdy $version without committing. Review with: git diff"
  exit 0
fi

git add releases docs
git commit -q -m "Release Howdy $version"
git tag -a "v$version" -m "Howdy $version"

echo
echo "Released Howdy $version as tag v$version. To publish it:"
echo "  git push origin HEAD v$version"
