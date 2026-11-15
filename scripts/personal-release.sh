#!/bin/bash
set -euo pipefail

# Personal build: a universal DMG signed with my Developer ID (not notarized),
# installed into /Applications here and uploaded as a GitHub release on the fork.
# A Developer ID signature gives macOS a stable identity (bundle ID + team), so
# the Accessibility grant the brightness keys need survives later builds,
# unlike ad-hoc signing, whose identity changes every build.
#
# Run it from your own Terminal: the keychain may ask for your password.
#   ./scripts/personal-release.sh v1.7.1-personal.2

TAG="${1:?Usage: ./scripts/personal-release.sh vX.Y.Z-personal.N}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# By hash: the keychain holds two copies of the same certificate, so the name is ambiguous.
CRISP_SIGN_ID=$(security find-identity -v -p codesigning \
    | awk '/Developer ID Application/ { print $2; exit }')
[ -n "$CRISP_SIGN_ID" ] || { echo "ERROR: no Developer ID Application identity"; exit 1; }
export CRISP_SIGN_ID

./scripts/release.sh "$TAG"   # dry run: builds and signs Crisp.dmg, publishes nothing

echo "==> Installing into /Applications…"
osascript -e 'quit app "Crisp"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Crisp.app
ditto build/Crisp.app /Applications/Crisp.app
open /Applications/Crisp.app

echo "==> Uploading the release to the fork…"
gh release create "$TAG" Crisp.dmg --repo jainnitin/Crisp \
    --title "Crisp $TAG (personal)" \
    --notes "Personal build. Signed with a Developer ID but not notarized. After copying Crisp to Applications, run: xattr -dr com.apple.quarantine /Applications/Crisp.app"

echo "==> Done. Re-add Crisp under Privacy & Security > Accessibility once on each Mac."
