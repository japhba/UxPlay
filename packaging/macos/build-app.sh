#!/usr/bin/env bash
#
# Build a self-contained macOS application bundle, dist/UxPlay.app, from this
# source tree, and zip it as dist/UxPlay-<version>-macos-<arch>.zip.
#
# The bundle contains the uxplay binary plus the subset of the official
# GStreamer.framework (libraries, plugins, gst-plugin-scanner) that UxPlay
# needs on macOS, with all install names rewritten so that nothing outside the
# .app is loaded at run time.
#
# Requirements (build host): Xcode command line tools, cmake, Homebrew
# openssl@3 and libplist, and the official GStreamer runtime + devel packages
# in /Library/Frameworks/GStreamer.framework.
#
# Optional environment variables:
#   CODESIGN_IDENTITY        "Developer ID Application: ..." -> real signing
#                            with hardened runtime; otherwise ad-hoc signing.
#   NOTARY_KEYCHAIN_PROFILE  notarytool keychain profile name, or
#   APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD
#                            -> notarize and staple (needs CODESIGN_IDENTITY).
#   SKIP_SMOKE_TEST=1        do not start the packaged server for 5 seconds.
#   BUILD_DIR, DIST_DIR      override build-app/ and dist/.
#   GSTREAMER_FRAMEWORK      override /Library/Frameworks/GStreamer.framework/Versions/1.0
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_DIR="$ROOT/packaging/macos"
BUILD_DIR="${BUILD_DIR:-$ROOT/build-app}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
GST_FW="${GSTREAMER_FRAMEWORK:-/Library/Frameworks/GStreamer.framework/Versions/1.0}"
ARCH="${ARCH:-$(uname -m)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

APP="$DIST_DIR/UxPlay.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
PLUGINS="$CONTENTS/PlugIns"
RESOURCES="$CONTENTS/Resources"

# GStreamer plugins UxPlay uses on macOS (mirror + audio modes; HLS/YouTube
# playback needs many more and is deliberately not bundled).
GST_PLUGINS=(
    app coreelements typefindfunctions playback autodetect   # appsrc, queue, capsfilter, typefind, decodebin, auto*sink
    videoparsersbad applemedia opengl                        # h264parse/h265parse, vtdec_hw/vtdec, glimagesink
    videoconvertscale videofilter osxvideo                   # videoconvert/videoscale, videoflip (-r/-f), osxvideosink fallback
    debug debugutilsbad jpeg                                 # capssetter, fpsdisplaysink (-fps), jpegdec (cover art)
    audioparsers libav audioconvert audioresample volume     # aacparse, avdec_aac/avdec_alac, audio chain
    osxaudio level                                           # osxaudiosink, level (audio pipeline)
    imagefreeze pango                                        # cover art + metadata overlay in audio-only mode
    isomp4                                                   # mp4mux (-mp4 recording)
)

# Elements that must resolve from the bundled plugin path for the app to work.
REQUIRED_ELEMENTS=(appsrc queue typefind decodebin h264parse h265parse vtdec_hw vtdec
                   videoconvert videoscale videoflip autovideosink glimagesink
                   aacparse avdec_aac avdec_alac audioconvert audioresample volume
                   autoaudiosink osxaudiosink capssetter mp4mux
                   level imagefreeze textoverlay jpegdec)

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script only runs on macOS"
[ -d "$GST_FW/lib" ] || die "GStreamer framework not found at $GST_FW (install the official runtime + devel .pkg)"
for tool in cmake otool install_name_tool lipo codesign ditto xcrun iconutil sips; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
xcrun --find swiftc >/dev/null 2>&1 || die "missing tool: swiftc (install the Xcode command line tools)"

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)"
VERSION="${VERSION#v}"
SHORT_VERSION="$(printf '%s' "$VERSION" | sed -nE 's/^([0-9]+(\.[0-9]+)*).*/\1/p')"
[ -n "$SHORT_VERSION" ] || SHORT_VERSION="0.0"
log "Packaging UxPlay $VERSION (CFBundleShortVersionString $SHORT_VERSION, $ARCH)"

# ---------------------------------------------------------------------------
# Build uxplay
# ---------------------------------------------------------------------------
log "Building uxplay in $BUILD_DIR"
cmake -S "$ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j"$JOBS"
[ -x "$BUILD_DIR/uxplay" ] || die "build did not produce $BUILD_DIR/uxplay"

# ---------------------------------------------------------------------------
# Assemble bundle skeleton
# ---------------------------------------------------------------------------
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$FRAMEWORKS" "$PLUGINS" "$RESOURCES"

cp "$BUILD_DIR/uxplay" "$MACOS/uxplay-bin"
cp "$GST_FW/libexec/gstreamer-1.0/gst-plugin-scanner" "$MACOS/gst-plugin-scanner"
cp "$GST_FW/bin/gst-inspect-1.0" "$MACOS/gst-inspect-1.0"
for p in "${GST_PLUGINS[@]}"; do
    src="$GST_FW/lib/gstreamer-1.0/libgst$p.dylib"
    [ -f "$src" ] || die "plugin not found: $src"
    cp "$src" "$PLUGINS/"
done

sed -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" -e "s/@BUNDLE_VERSION@/$VERSION/g" \
    "$PKG_DIR/Info.plist.in" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
# run-uxplay.sh stays in the bundle for CLI/debug use; the CFBundleExecutable
# is now the Swift menu-bar app (compiled below), not the Terminal launcher.
install -m 755 "$PKG_DIR/run-uxplay.sh" "$RESOURCES/run-uxplay.sh"
# fontconfig configuration for the pango textoverlay element (cover art mode)
cp -R "$GST_FW/etc/fonts" "$RESOURCES/fonts"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT/README.md" "$RESOURCES/README.md"
[ -f "$ROOT/uxplay.1" ] && cp "$ROOT/uxplay.1" "$RESOURCES/uxplay.1"

# ---------------------------------------------------------------------------
# App icon + menu-bar template, then the Swift menu-bar app itself
# ---------------------------------------------------------------------------
log "Generating app icon and menu-bar template image"
ICON_TMP="$BUILD_DIR/icons"
rm -rf "$ICON_TMP"
xcrun swift "$PKG_DIR/make-icons.swift" "$ICON_TMP"
cp "$ICON_TMP/AppIcon.icns"          "$RESOURCES/AppIcon.icns"
cp "$ICON_TMP/menubarTemplate.png"    "$RESOURCES/menubarTemplate.png"
cp "$ICON_TMP/menubarTemplate@2x.png" "$RESOURCES/menubarTemplate@2x.png"

log "Compiling the menu-bar app -> $MACOS/UxPlay (arm64)"
# Single-file AppKit app; links AppKit/Foundation automatically, no extra
# frameworks (notifications use the dependency-free NSUserNotification).
xcrun swiftc -O -target "$ARCH-apple-macos13.0" \
    -o "$MACOS/UxPlay" "$PKG_DIR/UxPlayMenuBar.swift"
chmod 755 "$MACOS/UxPlay"

# ---------------------------------------------------------------------------
# Collect transitive dylib dependencies from the framework
# ---------------------------------------------------------------------------
# Print the library names a Mach-O references via @rpath or via an absolute
# path into the GStreamer framework (one basename per line, self excluded).
deps_of() {
    local f="$1" self
    self="$(basename "$f")"
    otool -L "$f" | tail -n +2 | awk '{print $1}' \
        | grep -E "^(@rpath/|$GST_FW/|/Library/Frameworks/GStreamer\.framework/)" \
        | xargs -n1 basename 2>/dev/null | grep -vx "$self" | sort -u || true
}

is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

log "Resolving GStreamer library dependencies"
queue=()
for f in "$MACOS"/uxplay-bin "$MACOS"/gst-plugin-scanner "$MACOS"/gst-inspect-1.0 "$PLUGINS"/*.dylib; do
    queue+=("$f")
done
i=0
while [ $i -lt ${#queue[@]} ]; do
    f="${queue[$i]}"; i=$((i + 1))
    for dep in $(deps_of "$f"); do
        [ -f "$FRAMEWORKS/$dep" ] && continue
        [ -f "$PLUGINS/$dep" ] && continue
        src="$GST_FW/lib/$dep"
        [ -f "$src" ] || die "cannot find dependency $dep (needed by $(basename "$f")) in $GST_FW/lib"
        cp -L "$src" "$FRAMEWORKS/$dep"
        queue+=("$FRAMEWORKS/$dep")
    done
done
printf '   %d libraries, %d plugins\n' "$(ls "$FRAMEWORKS" | wc -l)" "$(ls "$PLUGINS" | wc -l)"

# ---------------------------------------------------------------------------
# Thin universal binaries and rewrite install names / rpaths
# ---------------------------------------------------------------------------
all_machos() {
    find "$MACOS" "$FRAMEWORKS" "$PLUGINS" -type f | while read -r f; do
        is_macho "$f" && printf '%s\n' "$f"
    done
}

log "Thinning universal binaries to $ARCH"
all_machos | while read -r f; do
    chmod u+w "$f"
    if lipo -info "$f" 2>/dev/null | grep -q '^Architectures in the fat file'; then
        lipo -thin "$ARCH" -output "$f.thin" "$f" && mv -f "$f.thin" "$f"
    fi
done

log "Rewriting rpaths"
fix_rpaths() {
    local f="$1" rpath="$2" rp
    # Remove every existing LC_RPATH (the framework ships several).
    while :; do
        rp="$(otool -l "$f" | awk '/LC_RPATH/{r=1} r && /path /{print $2; exit}')"
        [ -n "$rp" ] || break
        install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || break
    done
    install_name_tool -add_rpath "$rpath" "$f"
    # Any absolute reference into the framework becomes @rpath/<name>.
    local abs_refs
    abs_refs="$(otool -L "$f" | tail -n +2 | awk '{print $1}' \
        | grep -E "^($GST_FW/|/Library/Frameworks/GStreamer\.framework/)" | sort -u || true)"
    for abs in $abs_refs; do
        install_name_tool -change "$abs" "@rpath/$(basename "$abs")" "$f"
    done
    case "$f" in
        *.dylib) install_name_tool -id "@rpath/$(basename "$f")" "$f" ;;
    esac
}
for f in "$MACOS"/uxplay-bin "$MACOS"/gst-plugin-scanner "$MACOS"/gst-inspect-1.0; do
    fix_rpaths "$f" "@executable_path/../Frameworks"
done
for f in "$FRAMEWORKS"/*.dylib; do fix_rpaths "$f" "@loader_path"; done
for f in "$PLUGINS"/*.dylib;    do fix_rpaths "$f" "@loader_path/../Frameworks"; done

# Every @rpath reference must now be satisfied inside the bundle, and nothing
# may still point at the framework.
log "Checking link references"
all_machos | while read -r f; do
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r ref; do
        case "$ref" in
            /usr/lib/*|/System/Library/*) ;;
            @rpath/*)
                name="${ref#@rpath/}"
                [ -f "$FRAMEWORKS/$name" ] || [ "$name" = "$(basename "$f")" ] \
                    || die "unresolved @rpath reference $ref in $f"
                ;;
            *) die "unexpected reference $ref in $f" ;;
        esac
    done
done
printf '   all references resolve inside the bundle\n'

# ---------------------------------------------------------------------------
# Code signing
# ---------------------------------------------------------------------------
sign_args=()
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    log "Signing with identity: $CODESIGN_IDENTITY"
    sign_args=(--sign "$CODESIGN_IDENTITY" --options runtime --timestamp)
else
    log "Ad-hoc signing (set CODESIGN_IDENTITY for a Developer ID signature)"
    sign_args=(--sign -)
fi
# Sign inside-out: libraries, plugins, helpers, main binary, then the bundle.
for f in "$FRAMEWORKS"/*.dylib "$PLUGINS"/*.dylib "$MACOS"/gst-plugin-scanner "$MACOS"/gst-inspect-1.0 "$MACOS"/uxplay-bin; do
    codesign --force "${sign_args[@]}" "$f" 2>&1 | grep -v 'replacing existing signature' || true
done
codesign --force "${sign_args[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
printf '   signature verified\n'

# ---------------------------------------------------------------------------
# Verify the menu-bar app and the icons
# ---------------------------------------------------------------------------
log "Verifying: menu-bar app and app icon"
[ -x "$MACOS/UxPlay" ] || die "menu-bar executable $MACOS/UxPlay missing or not executable"
lipo -archs "$MACOS/UxPlay" | grep -qw "$ARCH" || die "$MACOS/UxPlay is not $ARCH (got: $(lipo -archs "$MACOS/UxPlay"))"
# It must link only the OS AppKit/Foundation/Swift runtime, nothing bundled.
if otool -L "$MACOS/UxPlay" | tail -n +2 | awk '{print $1}' | grep -vqE '^(/usr/lib/|/System/)'; then
    die "menu-bar app links non-system libraries:\n$(otool -L "$MACOS/UxPlay")"
fi
otool -L "$MACOS/UxPlay" | grep -q 'AppKit.framework' || die "menu-bar app is not linked against AppKit"
codesign --verify --strict --verbose=1 "$MACOS/UxPlay" || die "menu-bar app failed signature verification"
# AppIcon.icns must be a valid 1024px icns (sips reads it, iconutil round-trips).
icon_w="$(sips -g pixelWidth "$RESOURCES/AppIcon.icns" 2>/dev/null | awk '/pixelWidth/{print $2}')"
[ "${icon_w:-0}" = 1024 ] || die "AppIcon.icns is not a valid 1024px icns (pixelWidth=$icon_w)"
iconutil -c iconset "$RESOURCES/AppIcon.icns" -o "$BUILD_DIR/icons-roundtrip.iconset" \
    || die "AppIcon.icns failed iconutil round-trip (corrupt icns)"
rm -rf "$BUILD_DIR/icons-roundtrip.iconset"
for tpl in menubarTemplate.png menubarTemplate@2x.png; do
    [ -f "$RESOURCES/$tpl" ] || die "menu-bar template $tpl missing from Resources"
done
sips -g pixelWidth "$RESOURCES/menubarTemplate.png" | grep -q 'pixelWidth: 18' || die "menubarTemplate.png is not 18px"
plutil -extract CFBundleIconFile raw "$CONTENTS/Info.plist" | grep -qx AppIcon || die "CFBundleIconFile is not set to AppIcon in Info.plist"
printf '   menu-bar app is %s, links only system frameworks, signature OK; AppIcon.icns is a valid 1024px icns\n' "$ARCH"
# Exercise the app's pure runtime logic (PIN/line parsing, version comparison,
# release-asset matching, argument splitting) headlessly -- no GUI required.
"$MACOS/UxPlay" --self-test || die "menu-bar app --self-test failed"
printf '   menu-bar app --self-test passed\n'
# NOTE: a full launch of the status-bar app needs a GUI (Aqua) session, which
# CI does not have; we verify it compiles, links, is arm64, is signed, and that
# its logic self-test passes.  Interactive menu behavior (status item, PIN
# display, updater dialogs) is exercised manually (see the README / PR notes).

# ---------------------------------------------------------------------------
# Verification: run the bundled binaries with the bundled runtime only
# ---------------------------------------------------------------------------
VERIFY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/uxplay-app-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_TMP"' EXIT
bundled_env() {
    env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
        GST_PLUGIN_SYSTEM_PATH_1_0="$PLUGINS" GST_PLUGIN_PATH_1_0="$PLUGINS" \
        GST_PLUGIN_SCANNER_1_0="$MACOS/gst-plugin-scanner" GST_PLUGIN_SCANNER="$MACOS/gst-plugin-scanner" \
        GST_REGISTRY_1_0="$VERIFY_TMP/registry.bin" \
        FONTCONFIG_PATH="$RESOURCES/fonts" "$@"
}

log "Verifying: uxplay-bin -v with DYLD_PRINT_LIBRARIES"
bundled_env env DYLD_PRINT_LIBRARIES=1 "$MACOS/uxplay-bin" -v > "$VERIFY_TMP/version.log" 2>&1 || die "uxplay-bin -v failed:\n$(cat "$VERIFY_TMP/version.log")"
grep -q 'UxPlay version' "$VERIFY_TMP/version.log" || die "unexpected -v output:\n$(cat "$VERIFY_TMP/version.log")"
loaded_outside="$(grep -E '^dyld\[[0-9]+\]: <' "$VERIFY_TMP/version.log" | awk '{print $NF}' \
    | grep -vE "^(/usr/lib/|/System/)" | grep -v "^$APP/" || true)"
[ -z "$loaded_outside" ] || die "libraries loaded from outside the bundle:\n$loaded_outside"
loaded_inside="$(grep -E '^dyld\[[0-9]+\]: <' "$VERIFY_TMP/version.log" | awk '{print $NF}' | grep -c "^$APP/" || true)"
printf '   %s ; %s libraries loaded from inside the bundle, none from outside\n' \
    "$(grep 'UxPlay version' "$VERIFY_TMP/version.log")" "$loaded_inside"

log "Verifying: required GStreamer elements from the bundled plugins"
missing=()
for e in "${REQUIRED_ELEMENTS[@]}"; do
    if ! out="$(bundled_env "$MACOS/gst-inspect-1.0" "$e" 2>&1)"; then missing+=("$e"); continue; fi
    plugin_file="$(printf '%s\n' "$out" | awk '/^ *Filename/{print $2; exit}')"
    case "$plugin_file" in
        "$PLUGINS"/*) ;;
        *) die "element $e comes from $plugin_file, not from the bundle" ;;
    esac
done
[ ${#missing[@]} -eq 0 ] || die "missing GStreamer elements: ${missing[*]}"
printf '   %d elements OK (%s)\n' "${#REQUIRED_ELEMENTS[@]}" "${REQUIRED_ELEMENTS[*]}"
blacklisted="$(bundled_env "$MACOS/gst-inspect-1.0" -b 2>/dev/null | grep -A100 'Blacklisted files' | grep -vE 'Blacklisted files|Total count|^$' || true)"
[ -z "$blacklisted" ] || die "blacklisted (unloadable) plugins:\n$blacklisted"

if [ -z "${SKIP_SMOKE_TEST:-}" ]; then
    log "Smoke test: starting the packaged server (waiting up to 30 s)"
    # Run under a pty (script -F) so uxplay's stdout is not block-buffered
    # and the log can be polled while the server is running.
    : > "$VERIFY_TMP/smoke.log"
    bundled_env env GST_DEBUG=GST_PLUGIN_LOADING:4 GST_DEBUG_NO_COLOR=1 \
        script -q -F "$VERIFY_TMP/smoke.log" \
        "$MACOS/uxplay-bin" -p2p -pin 3939 -h265 -vsync no \
        -vs "osxvideosink force-aspect-ratio=true" -n pkgtest \
        > /dev/null 2>&1 < /dev/null &
    smoke_pid=$!
    started=
    for _ in $(seq 1 30); do
        sleep 1
        grep -q 'Initialized server socket(s)' "$VERIFY_TMP/smoke.log" && { started=1; break; }
    done
    # Kill only the processes we started (other uxplay instances may be
    # running on this machine): the background job, its script(1) wrapper,
    # and the uxplay-bin child -- deepest first.
    kill_tree() {
        local kid
        for kid in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$kid"; done
        kill -INT "$1" 2>/dev/null || true
    }
    kill_tree "$smoke_pid"
    wait "$smoke_pid" 2>/dev/null || true
    sleep 1
    pkill -9 -f "$MACOS/uxplay-bin .* -n pkgtest" 2>/dev/null || true
    [ -n "$started" ] || die "server did not start:\n$(cat "$VERIFY_TMP/smoke.log")"
    if grep -iE 'dyld|failed to load plugin|no such element|not-linked|Library not loaded' "$VERIFY_TMP/smoke.log"; then
        die "runtime errors in smoke test log:\n$(cat "$VERIFY_TMP/smoke.log")"
    fi
    if grep -q "$GST_FW" "$VERIFY_TMP/smoke.log"; then
        die "plugin loaded from $GST_FW during smoke test:\n$(grep "$GST_FW" "$VERIFY_TMP/smoke.log")"
    fi
    printf '   server started, no plugin/dyld errors, %d plugins loaded from the bundle\n' \
        "$(grep -c 'plugin ".*" loaded' "$VERIFY_TMP/smoke.log" || true)"
fi

# ---------------------------------------------------------------------------
# Notarization (optional)
# ---------------------------------------------------------------------------
ZIP="$DIST_DIR/UxPlay-$VERSION-macos-$ARCH.zip"
make_zip() {
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
}

if [ -n "${CODESIGN_IDENTITY:-}" ] && { [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ] || [ -n "${APPLE_ID:-}" ]; }; then
    log "Notarizing"
    make_zip
    if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    else
        [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] \
            || die "APPLE_ID needs APPLE_TEAM_ID and APPLE_APP_PASSWORD as well"
        xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" --wait
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
elif [ -n "${CODESIGN_IDENTITY:-}" ]; then
    log "Not notarizing (set NOTARY_KEYCHAIN_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD)"
else
    log "Note: ad-hoc signed build. Users must right-click > Open on first launch (see README)."
fi

# ---------------------------------------------------------------------------
# Zip
# ---------------------------------------------------------------------------
log "Creating $ZIP"
make_zip
printf '   app size: %s   zip size: %s\n' "$(du -sh "$APP" | cut -f1)" "$(du -sh "$ZIP" | cut -f1)"
log "Done: $ZIP"
