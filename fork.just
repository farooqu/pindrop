# Fork-only recipes for farooqu/pindrop (imported by justfile; never send upstream).
# See FORK.md → "Releasing fork builds".

fork_repo := "farooqu/pindrop"
upstream_ed_key := "TCU0MwULuIK6y0ubIossVr+61PGh/wHZfFrRFc9F2Is="

# Generate a self-signed code-signing certificate and import it into your login Keychain (run once, on the Mac that releases)
fork-signing-cert name="Pindrop Fork":
    #!/usr/bin/env bash
    set -euo pipefail
    NAME="{{name}}"
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    if security find-identity -p codesigning | grep -Fq "\"${NAME}\""; then
        echo "✅ Code signing identity already exists: ${NAME}"
        exit 0
    fi
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    printf '%s\n' \
        '[req]' 'distinguished_name = dn' 'prompt = no' 'x509_extensions = codesign' \
        '[dn]' "CN = ${NAME}" \
        '[codesign]' 'basicConstraints = critical, CA:false' 'keyUsage = critical, digitalSignature' \
        'extendedKeyUsage = critical, codeSigning' 'subjectKeyIdentifier = hash' > "$TMP/cfg"
    # macOS's /usr/bin/openssl (LibreSSL); legacy PKCS#12 algorithms so Keychain can import it.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    PASS=$(/usr/bin/openssl rand -hex 16)
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout "pass:${PASS}" -out "$TMP/id.p12"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
    echo "🔐 Trusting the certificate for code signing (macOS asks for your password)..."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
    security find-identity -p codesigning | grep -F "\"${NAME}\""
    echo "✅ Imported '${NAME}'. Back it up from Keychain Access (export as .p12) if you may build on another Mac."

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

# Usage (on the Mac): just fork-build "Pindrop Fork"
# Test, build, sign, and package a fork release into dist/ (no gh needed; publish with fork-publish)
fork-build identity:
    #!/usr/bin/env bash
    set -euo pipefail

    IDENTITY="{{identity}}"
    REPO="{{fork_repo}}"
    APP="{{app_bundle}}"
    DMG="{{dmg_dir}}/{{app_name}}.dmg"

    fail() { echo "❌ $*" >&2; exit 1; }

    # Preflight: build only what main consumers get, with fork update settings.
    command -v create-dmg >/dev/null 2>&1 || fail "Required tool not found: create-dmg"
    [ "$(git branch --show-current)" = "main" ] || fail "Build releases from main."
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
    COMMIT=$(git rev-parse HEAD)
    TAG="v${VERSION}-fork.${BUILD}"
    echo "🔨 Building ${TAG} (Pindrop ${VERSION}, build ${BUILD}, ${COMMIT})"

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
    cp "$UPDATES/appcast.xml" {{dmg_dir}}/appcast.xml
    rm -rf "$UPDATES"

    printf '%s\n' "TAG=${TAG}" "VERSION=${VERSION}" "BUILD=${BUILD}" "COMMIT=${COMMIT}" \
        "DMG_SHA256=$(shasum -a 256 "$DMG" | cut -d' ' -f1)" > {{dmg_dir}}/fork-release.env
    echo "✅ Built ${TAG}. Artifacts:"
    echo "   ${DMG}"
    echo "   {{dmg_dir}}/appcast.xml"
    echo "   {{dmg_dir}}/fork-release.env"
    echo "   Publish them from a machine with gh: just fork-publish"

# Publish the artifacts from fork-build (dist/Pindrop.dmg, dist/appcast.xml, dist/fork-release.env) as the latest fork release
fork-publish:
    #!/usr/bin/env bash
    set -euo pipefail

    REPO="{{fork_repo}}"
    DIST="{{dmg_dir}}"
    DMG="${DIST}/{{app_name}}.dmg"
    APPCAST="${DIST}/appcast.xml"
    ENV_FILE="${DIST}/fork-release.env"

    fail() { echo "❌ $*" >&2; exit 1; }

    for f in "$DMG" "$APPCAST" "$ENV_FILE"; do [ -f "$f" ] || fail "Missing artifact: $f (run fork-build on the Mac and copy dist/ here)"; done
    TAG=$(sed -n 's/^TAG=//p' "$ENV_FILE")
    VERSION=$(sed -n 's/^VERSION=//p' "$ENV_FILE")
    BUILD=$(sed -n 's/^BUILD=//p' "$ENV_FILE")
    COMMIT=$(sed -n 's/^COMMIT=//p' "$ENV_FILE")
    DMG_SHA256=$(sed -n 's/^DMG_SHA256=//p' "$ENV_FILE")
    [ -n "$TAG" ] && [ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$COMMIT" ] && [ -n "$DMG_SHA256" ] \
        || fail "Incomplete ${ENV_FILE}"

    command -v gh >/dev/null 2>&1 || fail "Required tool not found: gh"
    gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI is not authenticated (gh auth login)."

    # The artifacts must be intact and match what fork-build signed.
    if command -v sha256sum >/dev/null 2>&1; then ACTUAL=$(sha256sum "$DMG" | cut -d' ' -f1); else ACTUAL=$(shasum -a 256 "$DMG" | cut -d' ' -f1); fi
    [ "$ACTUAL" = "$DMG_SHA256" ] || fail "DMG checksum mismatch (copied file is corrupt or from another build)."
    grep -Fq "https://github.com/${REPO}/releases/download/${TAG}/{{app_name}}.dmg" "$APPCAST" \
        || fail "appcast.xml does not point at ${TAG}'s DMG."
    grep -Fq "<sparkle:version>${BUILD}</sparkle:version>" "$APPCAST" \
        || fail "appcast.xml is not for build ${BUILD}."

    # Release only commits that are on the fork's main, and never twice.
    git fetch --quiet origin main --tags
    git merge-base --is-ancestor "$COMMIT" origin/main || fail "${COMMIT} is not on origin/main."
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then fail "Release ${TAG} already exists."; fi

    PREV_TAG=$(git describe --tags --abbrev=0 --match 'v*-fork.*' "$COMMIT" 2>/dev/null || true)
    NOTES=$(mktemp)
    {
        echo "Fork build of Pindrop ${VERSION} from \`main\` (${COMMIT:0:7})."
        echo "Fork changes vs. upstream: see the divergence ledger in FORK.md."
        if [ -n "$PREV_TAG" ]; then
            echo
            echo "## Changes since ${PREV_TAG}"
            git log --first-parent --pretty='- %s' "${PREV_TAG}..${COMMIT}"
        fi
    } > "$NOTES"

    echo "🚀 Publishing ${TAG} to ${REPO}..."
    gh release create "$TAG" "$DMG" "$APPCAST" \
        --repo "$REPO" \
        --target "$COMMIT" \
        --title "Pindrop ${VERSION} (fork build ${BUILD})" \
        --notes-file "$NOTES" \
        --latest
    rm -f "$NOTES"
    echo "✅ Published https://github.com/${REPO}/releases/tag/${TAG}"
