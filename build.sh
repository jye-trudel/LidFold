#!/bin/zsh
# Builds a release LidFold.app into ./dist, ad-hoc signed for local use.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/LidFold"
APP=dist/LidFold.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LidFold"
cp Resources/Info.plist "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/LidFold"
# Stable local identity (scripts/make-signing-identity.sh) keeps the Screen Recording grant across
# rebuilds; without it, fall back to ad-hoc signing (grant must be re-given after each build).
KC="$PWD/.signing/lidfold.keychain-db"
if [[ -f "$KC" ]]; then
  security unlock-keychain -p lidfold "$KC"
  ID=$(security find-certificate -c "LidFold Local Signing" -Z "$KC" | awk '/SHA-1/{print $3}')
  OLD=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
  security list-keychains -d user -s "$KC" "${OLD[@]}"       # codesign only searches the list
  trap 'security list-keychains -d user -s "${OLD[@]}"' EXIT  # always restore it
  codesign --force --sign "$ID" --options runtime --timestamp=none "$APP"
  echo "Signed with LidFold Local Signing (stable identity)"
else
  codesign --force --sign - --options runtime --timestamp=none "$APP"
  echo "Ad-hoc signed (run scripts/make-signing-identity.sh for a stable identity)"
fi
codesign --verify --strict "$APP" && echo "Built and signed: $PWD/$APP"
