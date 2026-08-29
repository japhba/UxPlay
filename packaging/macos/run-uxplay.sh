#!/bin/bash
# Runs the bundled uxplay binary with the GStreamer runtime that ships inside
# UxPlay.app.  Extra options come from (in order of precedence, last wins):
#   1. ~/.uxplayrc (or $UXPLAYRC / ~/.config/uxplayrc), read by uxplay itself
#   2. the UXPLAY_ARGS environment variable (space separated)
#   3. arguments passed to this script
set -u

RES="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$(cd "$RES/.." && pwd)"

# Use only the GStreamer plugins shipped in the bundle, never a system
# GStreamer.framework, and keep our plugin registry separate from the
# system one so the two do not keep invalidating each other.
export GST_PLUGIN_SYSTEM_PATH_1_0="$CONTENTS/PlugIns"
export GST_PLUGIN_PATH_1_0="$GST_PLUGIN_SYSTEM_PATH_1_0"
export GST_PLUGIN_SCANNER_1_0="$CONTENTS/MacOS/gst-plugin-scanner"
export GST_PLUGIN_SCANNER="$GST_PLUGIN_SCANNER_1_0"
export GST_REGISTRY_1_0="${UXPLAY_GST_REGISTRY:-$HOME/Library/Caches/com.japhba.uxplay/registry.bin}"
mkdir -p "$(dirname "$GST_REGISTRY_1_0")" 2>/dev/null || true
# fontconfig config for the pango textoverlay element (cover-art metadata)
export FONTCONFIG_PATH="$RES/fonts"

# Relative output files (e.g. -mp4) land in the home directory, not in "/".
cd "$HOME" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS/Info.plist" 2>/dev/null || echo unknown)"
printf '\n=== UxPlay.app %s ===\n' "$VERSION"
printf 'Running: uxplay -p2p -h265 -vsync no -vs "osxvideosink force-aspect-ratio=true" %s %s\n' "${UXPLAY_ARGS:-}" "$*"
printf 'Add default options to ~/.uxplayrc (one per line, without the leading "-").\n'
printf 'Press Ctrl-C in this window to stop the server.\n\n'

# shellcheck disable=SC2086
exec "$CONTENTS/MacOS/uxplay-bin" -p2p -h265 -vsync no \
    -vs "osxvideosink force-aspect-ratio=true" ${UXPLAY_ARGS:-} "$@"
