#!/bin/bash
#
# Builds this checkout as a side-by-side "Rectangle Dev" app and installs it
# with a copy of the real Rectangle's settings and keyboard shortcuts.
#
# The dev build deliberately uses its own bundle identifier. Accessibility
# permission is keyed to bundle id plus code signature, so an ad-hoc signed
# build claiming com.knollsoft.Rectangle collides with the record belonging to
# the released, Developer ID signed app: System Settings lists the app but
# refuses to enable it. A distinct identifier gets its own record, and lets the
# dev build run alongside the real one.
#
# The cost of a distinct identifier is a separate preferences domain, which
# would otherwise mean no settings and no shortcuts. Hence the copy.

set -euo pipefail

readonly SOURCE_DOMAIN="com.knollsoft.Rectangle"
readonly DEV_DOMAIN="com.knollsoft.Rectangle.dev"
readonly APP_NAME="Rectangle Dev.app"

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT="$REPO_ROOT/Rectangle.xcodeproj"

INSTALL_DIR="$(dirname "$REPO_ROOT")/rectangle-build"
DERIVED_DATA="${TMPDIR:-/tmp}/rectangle-dev-build"
COPY_SETTINGS=auto
LAUNCH=true

usage() {
    cat <<'USAGE'
Usage: scripts/install-dev-build.sh [options]

Options:
  --install-dir DIR   Where to put the app (default: ../rectangle-build)
  --reset-settings    Re-copy settings and shortcuts from the real Rectangle,
                      discarding any changes made in the dev build
  --no-settings       Never touch the dev build's preferences
  --no-launch         Install without launching
  -h, --help          This text

Settings and shortcuts are copied from the real Rectangle on first install
only, so later runs don't discard what you changed in the dev build.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --reset-settings) COPY_SETTINGS=force; shift ;;
        --no-settings) COPY_SETTINGS=never; shift ;;
        --no-launch) LAUNCH=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

readonly APP_PATH="$INSTALL_DIR/$APP_NAME"

# --- Stop any running dev build -----------------------------------------------
# Matched on the install path so the real Rectangle is never touched.
if pgrep -f "$APP_PATH/Contents/MacOS/" >/dev/null 2>&1; then
    echo "==> Quitting the running dev build"
    pkill -f "$APP_PATH/Contents/MacOS/" || true
    sleep 1
fi

# --- Build --------------------------------------------------------------------
# Signed ad-hoc: a local build has no Developer ID to sign with, and an ad-hoc
# signature is enough for macOS to grant Accessibility. Note that re-signing on
# every build can invalidate the existing grant, in which case macOS asks again.
echo "==> Building Release (bundle id $DEV_DOMAIN)"
xcodebuild \
    -project "$PROJECT" \
    -scheme Rectangle \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    PRODUCT_BUNDLE_IDENTIFIER="$DEV_DOMAIN" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

readonly BUILT_APP="$DERIVED_DATA/Build/Products/Release/Rectangle.app"
[[ -d "$BUILT_APP" ]] || { echo "Build produced no app at $BUILT_APP" >&2; exit 1; }

echo "==> Signing ad-hoc"
codesign --force --deep --sign - "$BUILT_APP" 2>/dev/null

echo "==> Installing to $APP_PATH"
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"

# --- Settings and shortcuts ---------------------------------------------------
dev_domain_populated() {
    defaults read "$DEV_DOMAIN" >/dev/null 2>&1
}

copy_settings() {
    if ! defaults read "$SOURCE_DOMAIN" >/dev/null 2>&1; then
        echo "==> No settings found for $SOURCE_DOMAIN, leaving the dev build at its defaults"
        return
    fi

    echo "==> Copying settings and shortcuts from $SOURCE_DOMAIN"
    # Shortcuts live in the same domain as everything else (MASShortcut keys),
    # so a whole domain copy carries them along.
    defaults export "$SOURCE_DOMAIN" - | defaults import "$DEV_DOMAIN" -

    # Never let a test build add itself to login items.
    defaults write "$DEV_DOMAIN" launchOnLogin -bool false
    # Sparkle would happily replace this ad-hoc build with the official release.
    defaults write "$DEV_DOMAIN" SUEnableAutomaticChecks -bool false
    defaults write "$DEV_DOMAIN" SUAutomaticallyUpdate -bool false
    # The reason this build exists.
    defaults write "$DEV_DOMAIN" reapplyActionOnDisplayChange -int 1
    defaults write "$DEV_DOMAIN" restoreLayoutOnDisplayChange -int 1
}

case "$COPY_SETTINGS" in
    force) copy_settings ;;
    never) echo "==> Leaving the dev build's preferences alone" ;;
    auto)
        if dev_domain_populated; then
            echo "==> Keeping the dev build's existing settings (--reset-settings to re-copy)"
        else
            copy_settings
        fi
        ;;
esac

# --- Launch -------------------------------------------------------------------
if [[ "$LAUNCH" == true ]]; then
    echo "==> Launching"
    open "$APP_PATH"
fi

cat <<EOF

Installed: $APP_PATH
Bundle id: $DEV_DOMAIN

If it asks for Accessibility permission, grant it through the app's own prompt
rather than adding the app by hand in System Settings. A stale, un-enableable
"Rectangle" entry from an earlier attempt can be removed there with the - button.
EOF
