#!/bin/bash
# Build a drag-to-install DMG containing AgentPulse.app.
#
# NOTE: the app is ad-hoc signed, not notarized. On the machine that built it
# there is no warning. On another Mac, the first launch shows a Gatekeeper
# prompt — right-click the app → Open (once), or run:
#   xattr -dr com.apple.quarantine /Applications/AgentPulse.app
# A fully warning-free install requires an Apple Developer ID + notarization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) Fresh release .app
"$ROOT/scripts/make_app.sh"

APP="$ROOT/AgentPulse.app"
DMG="$ROOT/AgentPulse.dmg"
VOL="AgentPulse"

# 2) Stage app + /Applications symlink for drag-install
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3) Build a compressed DMG
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "Built $DMG"
