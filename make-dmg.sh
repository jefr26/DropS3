#!/bin/bash
# Builds DropS3.app and packs it into dist/DropS3-<version>.dmg (app + Applications shortcut).
#   VERSION=1.2.0 UNIVERSAL=1 ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

export VERSION="${VERSION:-1.0}"
./build.sh

NAME="DropS3-$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R dist/DropS3.app "$STAGE/DropS3.app"
ln -s /Applications "$STAGE/Applications"

rm -f "dist/$NAME.dmg"
hdiutil create -volname "DropS3" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "dist/$NAME.dmg" >/dev/null
echo "OK → dist/$NAME.dmg"
