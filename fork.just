# Fork-only recipes for farooqu/pindrop (imported by justfile; never send upstream).
# See FORK.md → "Releasing fork builds".

fork_repo := "farooqu/pindrop"
upstream_ed_key := "TCU0MwULuIK6y0ubIossVr+61PGh/wHZfFrRFc9F2Is="

# Create (first run) or print the Sparkle EdDSA public key for SUPublicEDKey; the private key stays in your Keychain
fork-sparkle-key: _fork-sparkle-tools
    ./bin/generate_keys

[private]
_fork-sparkle-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -x bin/generate_appcast ] && [ -x bin/generate_keys ]; then exit 0; fi
    TMP=$(mktemp -d)
    curl -fsSL -o "$TMP/Sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/{{sparkle_tools_version}}/Sparkle-{{sparkle_tools_version}}.tar.xz"
    tar -xf "$TMP/Sparkle.tar.xz" -C "$TMP"
    mkdir -p bin
    for tool in generate_appcast generate_keys sign_update; do
        [ -x "bin/$tool" ] || cp "$TMP/bin/$tool" bin/   # don't replace the tracked binaries
    done
    rm -rf "$TMP"

# Usage: just fork-release "Pindrop Fork"
# Build, sign with your own certificate, and publish a fork release that Sparkle updates from
fork-release identity:
    #!/usr/bin/env bash
    set -euo pipefail

    IDENTITY="{{identity}}"
    REPO="{{fork_repo}}"
    APP="{{app_bundle}}"
    DMG="{{dmg_dir}}/{{app_name}}.dmg"

    fail() { echo "❌ $*" >&2; exit 1; }

    # Preflight: release only what main consumers get, with fork update settings.
    for tool in gh create-dmg; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
    done
    gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI is not authenticated (gh auth login)."
    [ "$(git branch --show-current)" = "main" ] || fail "Release from main."
    if ! git diff --quiet || ! git diff --cached --quiet; then fail "Working tree has uncommitted changes."; fi
    git fetch --quiet origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "Local main must match origin/main."
    FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Pindrop/Info.plist)
    ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Pindrop/Info.plist)
    [[ "$FEED" == "https://github.com/${REPO}/"* ]] || fail "SUFeedURL does not point at ${REPO}: ${FEED}"
    [ "$ED_KEY" != "{{upstream_ed_key}}" ] || fail "SUPublicEDKey is still upstream's key; add your Sparkle public key."
    security find-identity -p codesigning | grep -Fq "\"${IDENTITY}\"" \
        || fail "Code signing identity not found in Keychain: ${IDENTITY}"

    # Version: keep upstream's marketing version; use main's commit count as a
    # monotonically increasing build number (main is never rewritten), so
    # nothing in the Xcode project changes and upstream merges stay clean.
    VERSION=$(grep 'MARKETING_VERSION = ' {{xcode_project}}/project.pbxproj | head -1 | sed 's/.*= \(.*\);/\1/')
    BUILD=$(git rev-list --count HEAD)
    TAG="v${VERSION}-fork.${BUILD}"
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        fail "Release ${TAG} already exists; merge a new commit to main first."
    fi
    echo "🚀 Releasing ${TAG} (Pindrop ${VERSION}, build ${BUILD}) to ${REPO}"

    echo "🧪 Running unit tests..."
    just test-unsigned

    echo "🔨 Building Release..."
    rm -rf {{build_dir}} {{dmg_dir}}
    xcodebuild \
        -project {{xcode_project}} \
        -scheme {{scheme}} \
        -configuration Release \
        -derivedDataPath DerivedData \
        {{signing_disabled}} \
        CURRENT_PROJECT_VERSION="${BUILD}" \
        build

    ./scripts/sign-app-bundle.sh "$APP" "$IDENTITY"
    [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")" = "$BUILD" ] \
        || fail "Built app does not have CFBundleVersion ${BUILD}."

    echo "📦 Creating DMG..."
    ./scripts/create-dmg-self-signed.sh

    echo "📡 Generating appcast.xml (EdDSA-signed with the Sparkle key in your Keychain)..."
    just _fork-sparkle-tools
    UPDATES=$(mktemp -d)
    cp "$DMG" "$UPDATES/"
    ./bin/generate_appcast --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" "$UPDATES"
    cp "$UPDATES/appcast.xml" appcast.xml
    rm -rf "$UPDATES"

    echo "🏷️  Tagging and publishing..."
    PREV_TAG=$(git describe --tags --abbrev=0 --match 'v*-fork.*' 2>/dev/null || true)
    NOTES=$(mktemp)
    {
        echo "Fork build of Pindrop ${VERSION} from \`main\` ($(git rev-parse --short HEAD))."
        echo "Fork changes vs. upstream: see the divergence ledger in FORK.md."
        if [ -n "$PREV_TAG" ]; then
            echo
            echo "## Changes since ${PREV_TAG}"
            git log --first-parent --pretty='- %s' "${PREV_TAG}..HEAD"
        fi
    } > "$NOTES"
    git tag -a "$TAG" -m "Fork release ${TAG}"
    git push origin "$TAG"
    gh release create "$TAG" "$DMG" appcast.xml \
        --repo "$REPO" \
        --title "Pindrop ${VERSION} (fork build ${BUILD})" \
        --notes-file "$NOTES" \
        --latest
    rm -f "$NOTES"

    echo "✅ Published https://github.com/${REPO}/releases/tag/${TAG}"
