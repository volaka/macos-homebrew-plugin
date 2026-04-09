# BrewNotifier justfile
# Usage: just <recipe>

# Show available recipes
default:
    @just --list

# ── Development ────────────────────────────────────────────────────────────────

# Build debug and run the app
dev:
    swift build 2>&1 | tail -5
    @pkill -x BrewNotifier 2>/dev/null || true
    @sleep 0.3
    open .build/debug/BrewNotifier

# Build debug only (no run)
build:
    swift build

# Run tests
test:
    swift test

# Run SwiftLint
lint:
    swiftlint lint --strict

# Build, lint, and test
check: build lint test

# Kill the running app
kill:
    @pkill -x BrewNotifier 2>/dev/null && echo "Stopped BrewNotifier" || echo "Not running"

# ── Release ────────────────────────────────────────────────────────────────────

# Build release binary
build-release:
    swift build -c release

# Package a .app bundle (ad-hoc signed, ditto zipped) for a given version
# Usage: just package v1.2.3
package version: build-release
    #!/usr/bin/env bash
    set -euo pipefail
    APP_DIR="BrewNotifier.app/Contents"
    rm -rf BrewNotifier.app
    mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
    cp .build/release/BrewNotifier "$APP_DIR/MacOS/BrewNotifier"
    cp Sources/BrewNotifier/Info.plist "$APP_DIR/Info.plist"
    if [ -d "Sources/BrewNotifier/Resources" ]; then
        cp -r Sources/BrewNotifier/Resources/. "$APP_DIR/Resources/"
    fi
    codesign --force --deep --sign - "BrewNotifier.app"
    ditto -c -k --sequesterRsrc --keepParent "BrewNotifier.app" "BrewNotifier-{{version}}.zip"
    echo "Packaged: BrewNotifier-{{version}}.zip ($(du -sh BrewNotifier-{{version}}.zip | cut -f1))"

# Build release, install to /Applications, register as login item (runs at every login/reboot)
serve-release: build-release
    #!/usr/bin/env bash
    set -euo pipefail
    PLIST="$HOME/Library/LaunchAgents/com.volaka.BrewNotifier.plist"

    # 1. Build .app bundle
    APP_DIR="BrewNotifier.app/Contents"
    rm -rf BrewNotifier.app
    mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
    cp .build/release/BrewNotifier "$APP_DIR/MacOS/BrewNotifier"
    cp Sources/BrewNotifier/Info.plist "$APP_DIR/Info.plist"
    if [ -d "Sources/BrewNotifier/Resources" ]; then
        cp -r Sources/BrewNotifier/Resources/. "$APP_DIR/Resources/"
    fi
    codesign --force --deep --sign - "BrewNotifier.app"

    # 2. Install to /Applications (replace existing)
    rm -rf /Applications/BrewNotifier.app
    cp -r BrewNotifier.app /Applications/BrewNotifier.app
    echo "Installed: /Applications/BrewNotifier.app"

    # 3. Stop any running instance
    pkill -x BrewNotifier 2>/dev/null || true
    sleep 0.5

    # 4. Write LaunchAgent plist from template (substitute __HOME__ with actual home path)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/BrewNotifier"
    sed "s|__HOME__|$HOME|g" scripts/com.volaka.BrewNotifier.plist.template > "$PLIST"
    echo "LaunchAgent: $PLIST"

    # 5. Load (or reload) the LaunchAgent and start it now
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    launchctl start com.volaka.BrewNotifier
    echo "BrewNotifier registered as login item and started."

# Unregister the login item and stop the app
unserve:
    #!/usr/bin/env bash
    PLIST="$HOME/Library/LaunchAgents/com.volaka.BrewNotifier.plist"
    launchctl unload "$PLIST" 2>/dev/null && echo "LaunchAgent unloaded" || echo "LaunchAgent not loaded"
    pkill -x BrewNotifier 2>/dev/null && echo "Stopped BrewNotifier" || echo "Not running"

# Tag and push a release (triggers CI release workflow)
# Usage: just release v1.2.3
release version: check
    @echo "Tagging {{version}} and pushing to origin…"
    git tag {{version}}
    git push origin {{version}}
    @echo "Release workflow triggered — watch: gh run list"

# Open logs folder in Finder
logs:
    open ~/Library/Logs/BrewNotifier/

# Print today's log
log-today:
    @cat ~/Library/Logs/BrewNotifier/runtime-$(date +%Y-%m-%d).log 2>/dev/null || echo "No log for today yet."
