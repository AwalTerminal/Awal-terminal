#!/bin/bash
# Create a new GitHub Release with the universal app bundle
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

# --- Helpers ---------------------------------------------------------------
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

die() { red "Error: $*" >&2; exit 1; }

step() {
    STEP_START=$(date +%s)
    info "$1"
}
step_done() {
    local elapsed=$(( $(date +%s) - STEP_START ))
    green "  done (${elapsed}s)"
}

# --- Validate inputs -------------------------------------------------------
if [ -z "$VERSION" ]; then
    echo "Usage: scripts/release.sh <version>"
    echo "Example: scripts/release.sh v0.2.0"
    exit 1
fi

# Ensure version starts with 'v'
[[ "$VERSION" == v* ]] || die "Version must start with 'v' (e.g. v0.2.0)"

# Check for uncommitted changes
if ! git -C "$ROOT" diff-index --quiet HEAD --; then
    die "Working tree has uncommitted changes. Commit or stash them first."
fi

# Check tag doesn't already exist
if git -C "$ROOT" rev-parse "$VERSION" >/dev/null 2>&1; then
    die "Tag $VERSION already exists."
fi

# Check required tools
command -v gh >/dev/null 2>&1 || die "'gh' (GitHub CLI) is required but not installed."

TOTAL_START=$(date +%s)

# --- Build -----------------------------------------------------------------
step "Building universal release binary..."
cd "$ROOT/app"
swift build -c release --arch arm64 --arch x86_64
cd "$ROOT"

BINARY="$ROOT/app/.build/apple/Products/Release/AwalTerminal"
[ -f "$BINARY" ] || die "Binary not found at $BINARY"
step_done

# --- Bundle ----------------------------------------------------------------
step "Bundling app..."
"$ROOT/scripts/bundle.sh" universal "$VERSION"

APP_DIR="$ROOT/build/AwalTerminal.app"
[ -d "$APP_DIR" ] || die "App bundle not found at $APP_DIR"
step_done

# --- Zip -------------------------------------------------------------------
step "Zipping app bundle..."
ZIP="$ROOT/docs/AwalTerminal.zip"
rm -f "$ZIP"
cd "$ROOT/build"
zip -rq "$ZIP" AwalTerminal.app
cd "$ROOT"
step_done

# --- Commit the updated zip ------------------------------------------------
step "Committing updated zip..."
git -C "$ROOT" add docs/AwalTerminal.zip
if ! git -C "$ROOT" diff-index --quiet --cached HEAD --; then
    git -C "$ROOT" commit -m "Update AwalTerminal.zip for $VERSION"
fi
step_done

# --- Confirm ---------------------------------------------------------------
echo ""
echo "Ready to release $VERSION"
echo "This will create a git tag, push to origin, and create a GitHub Release."
read -p "Continue? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

# --- Tag & push ------------------------------------------------------------
step "Tagging $VERSION and pushing..."
git -C "$ROOT" tag "$VERSION"
git -C "$ROOT" push origin main
git -C "$ROOT" push origin "$VERSION"
step_done

# --- Generate changelog -----------------------------------------------------
step "Generating changelog..."
PREV_TAG=$(git -C "$ROOT" tag --sort=-v:refname | grep -v "^${VERSION}$" | head -1)
CHANGELOG_FILE=$(mktemp)

if [ -n "$PREV_TAG" ]; then
    # Categorize commits
    features=""
    fixes=""
    improvements=""

    while IFS= read -r line; do
        msg="${line#* }"  # strip hash
        lower=$(echo "$msg" | tr '[:upper:]' '[:lower:]')
        if echo "$lower" | grep -qE '^(add|feat|new|implement|introduce)'; then
            features="${features}- ${msg}\n"
        elif echo "$lower" | grep -qE '^(fix|resolve|correct|patch|repair)'; then
            fixes="${fixes}- ${msg}\n"
        else
            improvements="${improvements}- ${msg}\n"
        fi
    done < <(git -C "$ROOT" log "${PREV_TAG}..${VERSION}" --oneline --no-merges)

    {
        if [ -n "$features" ]; then
            echo "## Features"
            printf "$features"
            echo ""
        fi
        if [ -n "$fixes" ]; then
            echo "## Fixes"
            printf "$fixes"
            echo ""
        fi
        if [ -n "$improvements" ]; then
            echo "## Improvements"
            printf "$improvements"
            echo ""
        fi
    } > "$CHANGELOG_FILE"
else
    echo "Initial release." > "$CHANGELOG_FILE"
fi
step_done

# --- Create GitHub release --------------------------------------------------
step "Creating GitHub Release..."
gh release create "$VERSION" "$ZIP" --title "$VERSION" --notes-file "$CHANGELOG_FILE"
rm -f "$CHANGELOG_FILE"
step_done

# --- Update Homebrew cask --------------------------------------------------
step "Updating Homebrew cask formula..."
ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
CASK_FILE="$ROOT/homebrew-cask/awal-terminal.rb"
VERSION_NUM="${VERSION#v}"  # strip leading 'v'

if [ -f "$CASK_FILE" ]; then
    sed -i '' "s/version \".*\"/version \"${VERSION_NUM}\"/" "$CASK_FILE"
    sed -i '' "s/sha256 \".*\"/sha256 \"${ZIP_SHA}\"/" "$CASK_FILE"
    green "  Updated $CASK_FILE"
    echo ""
    echo "  Next: copy $CASK_FILE to your AwalTerminal/homebrew-tap repo"
    echo "  as Casks/awal-terminal.rb and push to update the tap."
else
    echo "  Cask file not found at $CASK_FILE — skipping."
fi
step_done

# --- Summary ---------------------------------------------------------------
total_elapsed=$(( $(date +%s) - TOTAL_START ))
echo ""
green "Released $VERSION in ${total_elapsed}s"
