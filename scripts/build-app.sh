#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$#" -ne 0 ]]; then
    echo "Usage: $0 (builds build/Catch.app)" >&2
    exit 1
fi

DRIVE_OAUTH_JSON="${CATCH_GOOGLE_DRIVE_OAUTH_JSON:-}"
if [[ -n "$DRIVE_OAUTH_JSON" ]]; then
    for field in client_id client_secret; do
        if ! value="$(/usr/bin/plutil -extract "installed.$field" raw -expect string -o - -- "$DRIVE_OAUTH_JSON" 2>/dev/null)" || [[ -z "$value" ]]; then
            echo "CATCH_GOOGLE_DRIVE_OAUTH_JSON must point to a Google Desktop OAuth client JSON file." >&2
            exit 1
        fi
    done
fi

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/Catch"

APP_BUNDLE="$ROOT_DIR/build/Catch.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/Catch"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R "$(dirname "$BIN_PATH")/Catch_CatchCore.bundle" "$APP_BUNDLE/Contents/Resources/"
if [[ -n "$DRIVE_OAUTH_JSON" ]]; then
    cp "$DRIVE_OAUTH_JSON" "$APP_BUNDLE/Contents/Resources/GoogleDriveOAuthClient.json"
fi

codesign --force --deep --sign "${CATCH_CODESIGN_IDENTITY:--}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
