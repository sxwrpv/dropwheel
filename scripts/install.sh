#!/bin/bash
# Installs or updates Dropwheel on this Mac. The repository is private, so
# this needs the GitHub CLI signed in to an account that can see it:
#
#   gh release download -R sxwrpv/dropwheel -p install.sh -O - | bash
#
# From a public repository, curl does it alone:
#
#   curl -fsSL https://github.com/OWNER/REPO/releases/latest/download/install.sh | bash
#
# Options go after "bash -s --", as in "| bash -s -- --with-libreoffice":
#   --with-libreoffice  also install LibreOffice, for slides, sheets and some documents
#   --skip-tools        leave ffmpeg, webp and pandoc alone
#   --no-launch         don't open Dropwheel afterwards
#
# DROPWHEEL_REPO installs from another GitHub repository. For a private one
# the GitHub CLI must be signed in. DROPWHEEL_BASE_URL and
# DROPWHEEL_INSTALL_DIR are for testing.
#
# Everything is in main, which runs last: piped into bash, the whole script
# is read before anything runs, so nothing below can swallow the rest of it.

main() {
  set -euo pipefail

  local repo="${DROPWHEEL_REPO:-sxwrpv/dropwheel}"
  local base_url="${DROPWHEEL_BASE_URL:-https://github.com/$repo/releases/latest/download}"
  local install_dir="${DROPWHEEL_INSTALL_DIR:-}"
  local with_libreoffice=0 skip_tools=0 launch=1

  local argument
  for argument in "$@"; do
    case "$argument" in
      --with-libreoffice) with_libreoffice=1 ;;
      --skip-tools) skip_tools=1 ;;
      --no-launch) launch=0 ;;
      *) fail "unknown option $argument" ;;
    esac
  done

  [ "$(uname -s)" = "Darwin" ] || fail "Dropwheel runs on macOS only."
  local version
  version="$(sw_vers -productVersion)"
  [ "${version%%.*}" -ge 13 ] || fail "Dropwheel needs macOS 13 or later, and this Mac has $version."

  # What cleanup tidies away, however the script ends.
  WORK="" STAGED="" TARGET="" OLD=""
  trap cleanup EXIT
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/dropwheel-install.XXXXXX")"

  say "Downloading Dropwheel"
  download Dropwheel.zip "$repo" "$base_url" || fail "$(download_problem "$repo" "$base_url")"
  download Dropwheel.zip.sha256 "$repo" "$base_url" || fail "couldn't download the checksum for Dropwheel.zip."
  (cd "$WORK" && shasum -a 256 -c Dropwheel.zip.sha256 >/dev/null 2>&1) || fail "the download is damaged: it doesn't match its checksum."

  ditto -x -k "$WORK/Dropwheel.zip" "$WORK/unpacked"
  local app="$WORK/unpacked/Dropwheel.app"
  [ -d "$app" ] || fail "the download doesn't contain Dropwheel.app."
  codesign --verify --strict "$app" >/dev/null 2>&1 || fail "the app's signature doesn't check out."

  [ -n "$install_dir" ] || install_dir="$(default_install_dir)"
  mkdir -p "$install_dir" 2>/dev/null || true
  if [ ! -d "$install_dir" ] || [ ! -w "$install_dir" ]; then
    fail "this account can't change $install_dir. Run this again from an administrator account."
  fi
  replace_app "$app" "$install_dir"

  [ "$skip_tools" -eq 1 ] || install_tools "$with_libreoffice"

  local target="$install_dir/Dropwheel.app" installed
  installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")"
  warn_about_other_copies "$install_dir"
  [ "$launch" -eq 0 ] || open "$target"
  say "Dropwheel $installed is installed in $install_dir."
  say "It lives in the menu bar: drag a file, then tap a modifier key to open a wheel."
}

say() {
  printf '==> %s\n' "$1"
}

fail() {
  printf "Dropwheel wasn't installed: %s\n" "$1" >&2
  exit 1
}

# True for a file, a folder or a link, even a link to nothing.
exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

# Runs however main ends. If the new copy didn't make it into place, the old
# one goes back. Then the staged copy and the downloads are deleted.
cleanup() {
  if [ -n "$TARGET" ] && ! exists "$TARGET" && exists "$OLD"; then
    if mv "$OLD" "$TARGET" 2>/dev/null; then say "The old Dropwheel is back in place."; fi
  fi
  if [ -n "$STAGED" ]; then rm -rf "$STAGED" 2>/dev/null || true; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK" 2>/dev/null || true; fi
}

# Downloads a release file into $WORK. A private repository's files need the
# GitHub CLI, signed in to an account that can see them.
download() {
  local name="$1" repo="$2" base_url="$3"
  curl -fsSL --retry 3 -o "$WORK/$name" "$base_url/$name" 2>/dev/null && return 0
  [ -z "${DROPWHEEL_BASE_URL:-}" ] && command -v gh >/dev/null 2>&1 || return 1
  gh release download --repo "$repo" --pattern "$name" --dir "$WORK" --clobber </dev/null >/dev/null 2>&1
}

# Why Dropwheel.zip couldn't be downloaded, as far as can be told.
download_problem() {
  local repo="$1" base_url="$2"
  if [ -n "${DROPWHEEL_BASE_URL:-}" ]; then
    echo "couldn't download Dropwheel.zip from $base_url."
  elif ! command -v gh >/dev/null 2>&1; then
    echo "couldn't download Dropwheel.zip from $repo. If the repository is private, install the GitHub CLI with brew install gh, sign in with gh auth login, then run this again."
  elif ! gh auth status </dev/null >/dev/null 2>&1; then
    echo "couldn't download Dropwheel.zip from $repo. Sign in to GitHub with gh auth login, then run this again."
  else
    echo "couldn't download Dropwheel.zip from $repo. Check the connection, and that this GitHub account can see the repository and its releases."
  fi
}

# An update goes where Dropwheel already is; a first install goes in
# /Applications, or in the user's own folder without the rights for it.
default_install_dir() {
  if [ -d /Applications/Dropwheel.app ]; then
    echo /Applications
  elif [ -d "$HOME/Applications/Dropwheel.app" ] || [ ! -w /Applications ]; then
    echo "$HOME/Applications"
  else
    echo /Applications
  fi
}

# Copies the new app next to the old one, quits a running copy, then swaps
# the two with renames. The old copy is deleted only once the new one is in
# place; until then cleanup puts it back if anything fails.
replace_app() {
  local app="$1" install_dir="$2"
  local target="$install_dir/Dropwheel.app"
  local staged="$install_dir/.Dropwheel.app.installing" old="$install_dir/.Dropwheel.app.old"

  # A run killed between its two renames left the only copy as $old.
  if ! exists "$target" && exists "$old"; then
    mv "$old" "$target" || fail "couldn't put back the copy an earlier install left at $old."
  fi
  rm -rf "$staged" "$old" 2>/dev/null || fail "couldn't delete what an earlier install left in $install_dir. Run sudo rm -rf '$staged' '$old', then run this again."
  STAGED="$staged"
  ditto "$app" "$staged" || fail "couldn't copy Dropwheel into $install_dir."
  # Neither curl nor gh marks downloads as quarantined, but a copied zip might be.
  xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true

  quit_running_copy
  say "Installing in $install_dir"
  TARGET="$target" OLD="$old"
  if exists "$target"; then
    mv "$target" "$old" || fail "couldn't move the old Dropwheel aside in $install_dir."
  fi
  mv "$staged" "$target" || fail "couldn't put the new Dropwheel in $install_dir."
  STAGED="" TARGET=""
  rm -rf "$old" 2>/dev/null || say "Couldn't delete the old copy at $old. To delete it, run: sudo rm -rf '$old'"
}

# A running copy would keep the old version in memory. It may be busy with a
# conversion, in which case it asks first; nothing is forced closed.
quit_running_copy() {
  pgrep -xu "$(id -u)" Dropwheel >/dev/null 2>&1 || return 0
  say "Quitting the running Dropwheel"
  osascript -e 'quit app id "dev.dropwheel.Dropwheel"' </dev/null >/dev/null 2>&1 || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xu "$(id -u)" Dropwheel >/dev/null 2>&1 || return 0
    sleep 1
  done
  fail "Dropwheel is still running, perhaps busy. Quit it from its menu bar icon, then run this again."
}

# Two copies would leave one out of date, and either one might open.
warn_about_other_copies() {
  local folder
  for folder in /Applications "$HOME/Applications"; do
    if [ "$folder" != "$1" ] && [ -d "$folder/Dropwheel.app" ]; then
      say "Another copy in $folder wasn't updated. Delete it so the old version doesn't open by mistake."
    fi
  done
}

# The tools Dropwheel uses for audio, video, WebP and documents, from
# Homebrew. Ones already on this Mac are left alone.
install_tools() {
  local with_libreoffice="$1" brew=""
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then brew="$candidate"; break; fi
  done
  if [ -z "$brew" ]; then
    say "Homebrew isn't installed, so audio, video and WebP tools are missing. Install it from https://brew.sh, then run: brew install ffmpeg webp pandoc"
    return 0
  fi

  local missing="" pair formula program
  for pair in ffmpeg:ffmpeg webp:cwebp pandoc:pandoc; do
    formula="${pair%%:*}"
    program="${pair##*:}"
    has_program "$program" || missing="$missing $formula"
  done
  if [ -n "$missing" ]; then
    say "Installing$missing with Homebrew. This can take a few minutes."
    # $missing is a list of words, so it is left unquoted.
    # shellcheck disable=SC2086
    "$brew" install $missing </dev/null || say "Homebrew couldn't install$missing. Dropwheel works without them, minus their conversions."
  fi

  if [ "$with_libreoffice" -eq 1 ] && [ ! -d /Applications/LibreOffice.app ] && [ ! -d "$HOME/Applications/LibreOffice.app" ]; then
    say "Installing LibreOffice with Homebrew"
    "$brew" install --cask libreoffice </dev/null || say "Homebrew couldn't install LibreOffice."
  fi
}

# Where Dropwheel itself looks for its tools.
has_program() {
  local directory
  for directory in /opt/homebrew/bin /usr/local/bin /usr/bin; do
    [ -x "$directory/$1" ] && return 0
  done
  return 1
}

main "$@"
