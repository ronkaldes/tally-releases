#!/usr/bin/env bash
# Install (or update) Tally for Mac from the public Tally releases.
#
#   bash install-mac.sh                      # latest stable release
#   bash install-mac.sh --version 2.3.2      # a specific release (betas too: 2.3.2-beta.1)
#   bash install-mac.sh --tag v2.3.2         # same, written as a tag
#   bash install-mac.sh --dmg ~/Downloads/Tally-2.3.2.dmg --sums ~/Downloads/SHA256SUMS
#   bash install-mac.sh --dmg "~/Downloads/Tally-2.3.2 (1).dmg" --name Tally-2.3.2.dmg
#                                            # a renamed download: --name is the file's name in SHA256SUMS
#   bash install-mac.sh --dry-run            # download and check, install nothing
#   bash install-mac.sh --reset              # also start again from the first-run setup
#
# What it does, in order:
#   1. Downloads Tally-<version>.dmg and SHA256SUMS with plain curl from the public
#      release repository (no GitHub CLI, no sign-in), or uses the files given with
#      --dmg / --sums.
#   2. Refuses to continue unless the DMG matches its SHA-256 line in SHA256SUMS.
#   3. Quits Tally if it is running and copies Tally.app into /Applications.
#   4. Trusts the app: removes the com.apple.quarantine flag that makes macOS block
#      an app that is not notarised. Only do this for a DMG whose checksum passed.
#   5. With --reset: moves your Tally data (~/.tally) to ~/tally-backup-<date-time>
#      instead of deleting it, so the next launch is a first run. Nothing is deleted.
#   6. Opens Tally.
#
# The latest release is the newest stable one; a beta is only installed when you ask
# for it with --version. WARNING: TALLY_RELEASES_BASE_URL overrides the download
# location and drops the HTTPS/TLS restrictions; it is for tests only.
set -euo pipefail

REPO="ronkaldes/tally-releases"
BASE_URL="${TALLY_RELEASES_BASE_URL:-https://github.com/$REPO}"
APP_NAME="Tally.app"
DEST="/Applications"
VERSION=""
DMG=""
NAME=""
SUMS=""
RESET=false
OPEN_APP=true
DRY_RUN=false

# usage prints the header comment: from line 2 up to the line before "set -euo".
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# Same rule as scripts/release-asset-names.cjs (SemVer, no leading "v"). The
# fixture table test/fixtures/release-asset-names.json pins both to one answer.
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
check_version() { [[ "$1" =~ $VERSION_RE ]] || die "not a release version: '$1' (expected something like 2.3.2 or 2.3.2-beta.1)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version|--tag)
      VERSION="${2:?$1 needs a value}"; VERSION="${VERSION#v}"
      [ -n "$VERSION" ] || die "$1 needs a version such as 2.3.2, got '$2'"
      shift 2 ;;
    --dmg) DMG="${2:?--dmg needs a path}"; shift 2 ;;
    --name) NAME="${2:?--name needs the file name listed in SHA256SUMS}"; shift 2 ;;
    --sums) SUMS="${2:?--sums needs a path}"; shift 2 ;;
    --reset) RESET=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-open) OPEN_APP=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -z "$VERSION" ] || check_version "$VERSION"
[ -z "$NAME" ] || [ -n "$DMG" ] || die "--name only works with --dmg"
if [ -n "$NAME" ] && ! [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then die "--name must be a plain file name, got '$NAME'"; fi
if [ "$DRY_RUN" = false ]; then
  [ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS."
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tally-install.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Plain curl, no credentials. The default location is HTTPS-only; an override
# (tests, mirrors) may use any scheme curl supports.
CURL_OPTS=(--retry 3 --silent --show-error)
if [ -z "${TALLY_RELEASES_BASE_URL:-}" ]; then CURL_OPTS+=(--proto '=https' --tlsv1.2); fi
# fetch <file> <url>: succeeds only on HTTP 200 with a non-empty file. curl 8.14
# with --retry exits 0 after a --fail 404, so its exit status alone is not trusted.
fetch() {
  local out="$1" url="$2" code
  code="$(curl -fL "${CURL_OPTS[@]}" -o "$out" -w '%{http_code}' "$url")" || return 1
  [ "$code" = "200" ] && [ -s "$out" ]
}

# The version of the newest stable release: the tag the "latest" page redirects to.
latest_version() {
  local target tag
  # No -L: the redirect target is the answer, so read it instead of following it.
  target="$(curl -f "${CURL_OPTS[@]}" -o /dev/null -w '%{redirect_url}' "$BASE_URL/releases/latest" 2>/dev/null || true)"
  tag="${target##*/releases/tag/}"
  [ -n "$target" ] && [ "$tag" != "$target" ] || return 1
  tag="${tag#v}"
  [[ "$tag" =~ $VERSION_RE ]] || return 1
  printf '%s' "$tag"
}

# 1. Get the DMG and its checksums. DMG_NAME is the name SHA256SUMS lists.
if [ -n "$DMG" ]; then
  [ -f "$DMG" ] || die "no DMG at $DMG"
  [ -n "$SUMS" ] || SUMS="$(dirname "$DMG")/SHA256SUMS"
  [ -f "$SUMS" ] || die "no SHA256SUMS next to the DMG; download it from the same release and pass --sums"
  DMG_NAME="${NAME:-$(basename "$DMG")}"
  cp "$DMG" "$WORK/$DMG_NAME"
  cp "$SUMS" "$WORK/SHA256SUMS"
else
  if [ -z "$VERSION" ]; then
    step "Finding the latest release"
    VERSION="$(latest_version)" || die "could not find the latest release at $BASE_URL/releases/latest. Check your connection, or ask for a version with --version."
  fi
  check_version "$VERSION"
  TAG="v$VERSION"
  DMG_NAME="Tally-$VERSION.dmg"
  step "Downloading $DMG_NAME and SHA256SUMS ($TAG)"
  fetch "$WORK/$DMG_NAME" "$BASE_URL/releases/download/$TAG/$DMG_NAME" \
    || die "could not download $DMG_NAME from $BASE_URL/releases/download/$TAG/"
  fetch "$WORK/SHA256SUMS" "$BASE_URL/releases/download/$TAG/SHA256SUMS" \
    || die "could not download SHA256SUMS for $TAG"
fi

# 2. Verify before anything touches /Applications.
step "Checking the SHA-256 checksum"
# The name goes in through ENVIRON, not awk -v, which would process backslash escapes.
expected="$(ASSET_NAME="$DMG_NAME" awk '{ f = $2; sub(/^\*/, "", f) } f == ENVIRON["ASSET_NAME"] { print $1 }' "$WORK/SHA256SUMS")"
[ -n "$expected" ] || die "SHA256SUMS has no line for $DMG_NAME. If the download was renamed, pass its name in SHA256SUMS with --name."
# Read from stdin so shasum does not print (and escape) the file name.
actual="$(shasum -a 256 < "$WORK/$DMG_NAME" | awk '{ print $1 }')"
[ "$expected" = "$actual" ] || die "checksum mismatch: expected $expected, got $actual. Do not install this file."
echo "OK  $actual"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "Dry run: $DMG_NAME is genuine. Nothing was installed."
  exit 0
fi

# 3. Quit Tally and copy the new app in.
if pgrep -x Tally >/dev/null 2>&1; then
  step "Quitting Tally"
  osascript -e 'tell application "Tally" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Tally >/dev/null 2>&1 || break; sleep 1; done
  pkill -x Tally >/dev/null 2>&1 || true
fi

step "Installing $APP_NAME into $DEST"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/tally-dmg.XXXXXX")"
hdiutil attach "$WORK/$DMG_NAME" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
[ -d "$MOUNT/$APP_NAME" ] || die "the DMG does not contain $APP_NAME"
SUDO=""
[ -w "$DEST" ] || SUDO="sudo"
if [ -d "$DEST/$APP_NAME" ]; then $SUDO rm -rf "$DEST/$APP_NAME"; fi
$SUDO ditto "$MOUNT/$APP_NAME" "$DEST/$APP_NAME"
hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
MOUNT=""

# 4. Trust the app (it is ad-hoc signed, not notarised).
step "Trusting Tally (removing the macOS quarantine flag)"
$SUDO xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true
echo "Tally will open without the \"cannot be opened\" warning."

# 5. Optional: start again from the first-run setup, keeping a backup.
if [ "$RESET" = true ]; then
  step "Resetting Tally data (a backup is kept)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [ -e "$HOME/.tally" ] && [ ! -L "$HOME/.tally" ]; then
    mv "$HOME/.tally" "$HOME/tally-backup-$stamp"
    echo "Your data is now in ~/tally-backup-$stamp"
  fi
  # The legacy ~/.tokentracker name is normally a link to ~/.tally.
  if [ -L "$HOME/.tokentracker" ]; then
    rm "$HOME/.tokentracker"
  elif [ -e "$HOME/.tokentracker" ]; then
    mv "$HOME/.tokentracker" "$HOME/tokentracker-backup-$stamp"
    echo "Legacy data is now in ~/tokentracker-backup-$stamp"
  fi
  echo "The next launch runs the first-run setup and sets up your AI tool hooks again."
  echo "To undo: quit Tally, then: rm -rf ~/.tally && mv ~/tally-backup-$stamp ~/.tally"
fi

# 6. Open it.
if [ "$OPEN_APP" = true ]; then
  step "Opening Tally"
  open "$DEST/$APP_NAME"
fi
echo
echo "Done."
