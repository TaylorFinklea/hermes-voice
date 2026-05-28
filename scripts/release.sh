#!/usr/bin/env bash
#
# release.sh — bump build, archive, and upload Hermes Voice to TestFlight.
#
# Usage:
#   ./scripts/release.sh                # default: bump build only
#   ./scripts/release.sh --patch        # also bump patch (1.0 → 1.0.1)
#   ./scripts/release.sh --minor        # also bump minor (1.0 → 1.1.0)
#   ./scripts/release.sh --build        # explicit alias for default
#   ./scripts/release.sh --no-commit    # skip the version-bump commit
#
# Build-only bumps stay under the same App Store record and are right for
# routine TestFlight iteration. --patch / --minor change the marketing version
# and trigger a fresh App Store review when the next build ships to the App
# Store (not just TestFlight). Use those only when you intend a release review.
#
# This is a MONOREPO: the iOS project lives under ios/HermesVoice. The script
# handles the path juggling; run it from anywhere in the repo.
#
# App Store Connect API auth (override defaults via env):
#   ASC_API_KEY_PATH   — path to the .p8 key (default: ~/.appstoreconnect/AuthKey_J79935N6P6.p8)
#   ASC_API_KEY_ID     — key ID matching the .p8 filename     (default: J79935N6P6)
#   ASC_API_ISSUER_ID  — App Store Connect issuer UUID         (default: fe27785a-1413-46ff-bd82-111de0da024f)
#
# This is the ASC *upload* key, NOT the APNs push key — different keys from
# different parts of the developer portal. The ASC key is account-wide and
# shared with the user's other apps (open-feelings, simmersmith).
#
# Source of truth for build/version numbers is ios/HermesVoice/project.yml.
# The script bumps CURRENT_PROJECT_VERSION (and optionally MARKETING_VERSION),
# regenerates the Xcode project, archives Release for generic iOS, exports +
# uploads via the API key, and commits the bump on success.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios/HermesVoice"
cd "$IOS_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
step() { echo -e "\n${GREEN}▸ $1${NC}"; }
fail() { echo -e "${RED}✘ $1${NC}"; exit 1; }

# ---------- flags ----------
BUMP_TYPE="build"
DO_COMMIT=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUMP_TYPE="build"; shift ;;
        --patch) BUMP_TYPE="patch"; shift ;;
        --minor) BUMP_TYPE="minor"; shift ;;
        --no-commit) DO_COMMIT=0; shift ;;
        *) fail "Unknown flag: $1. Use --build, --patch, --minor, or --no-commit." ;;
    esac
done

# ---------- preflight ----------
command -v xcodegen >/dev/null || fail "xcodegen not found (brew install xcodegen)"

ASC_KEY_PATH="${ASC_API_KEY_PATH:-$HOME/.appstoreconnect/AuthKey_J79935N6P6.p8}"
ASC_KEY_ID="${ASC_API_KEY_ID:-J79935N6P6}"
ASC_ISSUER="${ASC_API_ISSUER_ID:-fe27785a-1413-46ff-bd82-111de0da024f}"

[[ -f "$ASC_KEY_PATH" ]] || fail "ASC API key not found at $ASC_KEY_PATH. Set ASC_API_KEY_PATH or place the .p8 there."

PROJECT_YML="$IOS_DIR/project.yml"
PROJECT="$IOS_DIR/HermesVoice.xcodeproj"
SCHEME="HermesVoice"
EXPORT_OPTIONS="$IOS_DIR/ExportOptions.plist"
[[ -f "$EXPORT_OPTIONS" ]] || fail "Missing $EXPORT_OPTIONS"

# ---------- bump version in project.yml ----------
OLD_BUILD=$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")
[[ -n "$OLD_BUILD" ]] || fail "Could not read CURRENT_PROJECT_VERSION from project.yml"

OLD_VERSION=$(awk '/^[[:space:]]*MARKETING_VERSION:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")
[[ -n "$OLD_VERSION" ]] || fail "Could not read MARKETING_VERSION from project.yml"

NEW_BUILD=$((OLD_BUILD + 1))
NEW_VERSION="$OLD_VERSION"

if [[ "$BUMP_TYPE" != "build" ]]; then
    IFS='.' read -ra PARTS <<< "$OLD_VERSION"
    MAJOR="${PARTS[0]:-0}"; MINOR="${PARTS[1]:-0}"; PATCH="${PARTS[2]:-0}"
    case "$BUMP_TYPE" in
        patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
        minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    esac
fi

step "Bumping version ($BUMP_TYPE)"
echo "  $OLD_VERSION ($OLD_BUILD) → $NEW_VERSION ($NEW_BUILD)"

# In-place sed. BSD sed needs the empty '' arg after -i. The project.yml
# values are quoted ("2"), so match the quoted form and rewrite in place.
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]+\")${OLD_BUILD}(\")\$/\\1${NEW_BUILD}\\2/" "$PROJECT_YML"
if [[ "$NEW_VERSION" != "$OLD_VERSION" ]]; then
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]+\")${OLD_VERSION}(\")\$/\\1${NEW_VERSION}\\2/" "$PROJECT_YML"
fi

# Verify the bump actually took (guards against quote-style drift).
CHECK_BUILD=$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {gsub(/"/,"",$2); print $2; exit}' "$PROJECT_YML")
[[ "$CHECK_BUILD" == "$NEW_BUILD" ]] || fail "Version bump didn't apply — check the sed pattern against project.yml quoting"

# ---------- regenerate Xcode project ----------
step "Regenerating Xcode project"
xcodegen generate --spec "$PROJECT_YML" >/dev/null

# ---------- archive ----------
ARCHIVE_PATH="/tmp/HermesVoice-build${NEW_BUILD}.xcarchive"
EXPORT_PATH="/tmp/HermesVoice-build${NEW_BUILD}-export"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

step "Archiving Release for generic iOS"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    archive 2>&1 | grep -E "Archive Succeeded|error:|\*\*" | head -8

[[ -d "$ARCHIVE_PATH" ]] || fail "Archive failed — $ARCHIVE_PATH not created"

# ---------- export + upload ----------
step "Exporting and uploading to TestFlight"
LOG=/tmp/hermesvoice-export.log
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER" 2>&1 | tee "$LOG" | grep -E "Export Succeeded|EXPORT SUCCEEDED|error:|\*\*" | head -10

if ! grep -q "EXPORT SUCCEEDED" "$LOG"; then
    fail "Export/upload failed — see $LOG"
fi

# ---------- commit version bump ----------
if [[ "$DO_COMMIT" -eq 1 ]]; then
    step "Committing version bump"
    git -C "$REPO_ROOT" add ios/HermesVoice/project.yml ios/HermesVoice/HermesVoice.xcodeproj/project.pbxproj
    git -C "$REPO_ROOT" commit -m "Release $NEW_VERSION (build $NEW_BUILD) to TestFlight" >/dev/null
    echo "  committed"
else
    echo "  (--no-commit: leaving the bump uncommitted)"
fi

echo -e "\n${GREEN}✔ Hermes Voice $NEW_VERSION (build $NEW_BUILD) uploaded to TestFlight${NC}"
echo "  Check App Store Connect for processing status (usually 5-15 min)."
