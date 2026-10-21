#!/bin/bash
# Build Insomnia and assemble an ad-hoc signed Insomnia.app. install.sh runs this for
# source installs, and .github/workflows/release.yml runs it for the
# downloadable package, so both produce the same bundle.
#
# Usage: scripts/build-app.sh --output DIR [--sign IDENTITY]
#   Writes DIR/Insomnia.app, replacing a bundle already at that path. DIR is
#   created if needed. Prints the bundle path last.
#
# The signature is ad-hoc (`codesign --sign -`) unless --sign names a
# codesign identity: releases are ad-hoc signed and not notarized
# (docs/releasing.md) and the release workflow passes no --sign. Ad-hoc
# identifies only this build (its cdhash), and macOS blocks the first launch
# of a downloaded copy until the user allows it. --sign exists for a source
# build on one's own Mac (scripts/make-local-signing-identity.sh): a fixed
# self-signed identity keeps the designated requirement the same across
# rebuilds, so the keychain item ACL still accepts a new build. Nothing is
# read from the environment. The bundle has no nested code, so there is no
# --deep; backstop.sh under Contents/Resources is sealed as a resource.
set -euo pipefail

# Fixed tool paths: never taken from PATH. Tests patch these lines in a
# private copy of the script.
SWIFT=/usr/bin/swift
CODESIGN=/usr/bin/codesign
PLUTIL=/usr/bin/plutil
RM=/bin/rm
MKDIR=/bin/mkdir
CP=/bin/cp
CHMOD=/bin/chmod

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "usage: $0 --output DIR [--sign IDENTITY]" >&2; }
OUTPUT=""
SIGN_IDENTITY="-"
while (( $# )); do
  case "$1" in
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --sign) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; SIGN_IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OUTPUT" ]] || { usage; exit 2; }
# Resolved now, before the build changes into the checkout: a relative
# --output means relative to the caller's directory, not to the checkout.
"$MKDIR" -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
# INSOMNIA_LID_SIMULATION=1 compiles the scripts/simulate-lid.sh file trigger
# (LidSimulation.swift) into this release build, for release validation on
# a machine whose lid stays open (install.sh passes it through from its own
# environment). A normal build has no watcher: nothing reads the trigger
# file. Such a build says so in the log at launch, in the status menu and in
# Settings. The release workflow never sets it.
BUILD_FLAGS=()
if [[ "${INSOMNIA_LID_SIMULATION:-}" == 1 ]]; then
  BUILD_FLAGS+=(-Xswiftc -DINSOMNIA_LID_SIMULATION)
  echo "lid simulation compiled in (INSOMNIA_LID_SIMULATION=1): scripts/simulate-lid.sh will drive the lid actions during sessions"
fi
# ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under set -u on
# the bash 3.2 that ships with macOS.
"$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN="$("$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. Bundle ------------------------------------------------------------------
APP="$OUTPUT/Insomnia.app"
step "Assembling $APP"
"$RM" -rf "$APP"
"$MKDIR" -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CP" "$BIN" "$APP/Contents/MacOS/Insomnia"
"$CP" "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$CP" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent install.sh writes verifies the
# bundle and only then runs this copy; an edited script fails that check.
"$CP" "$ROOT/scripts/backstop.sh" "$APP/Contents/Resources/backstop.sh"
"$CHMOD" 755 "$APP/Contents/Resources/backstop.sh"
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Sign --------------------------------------------------------------------
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  step "Signing ad-hoc (this build is identified only by its cdhash)"
else
  step "Signing with identity \"$SIGN_IDENTITY\""
fi
"$CODESIGN" --force --sign "$SIGN_IDENTITY" "$APP"
"$CODESIGN" --verify --strict "$APP"
"$CODESIGN" -dvv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CDHash)=' || true
echo "$APP"
