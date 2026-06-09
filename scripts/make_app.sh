#!/bin/bash
# Build a release .app bundle for the menu-bar app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product AgentPulse

APP="$ROOT/AgentPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AgentPulse" "$APP/Contents/MacOS/AgentPulse"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign so macOS assigns a stable identity (needed for the login-item API).
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
