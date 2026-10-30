#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
bundle="$PWD/.build/Ciaobot.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources"

cp "$binary_dir/CiaobotMac" "$bundle/Contents/MacOS/CiaobotMac"

# Package the artwork with the app. The build fails here if SwiftPM did not
# produce the resource bundle, rather than shipping a title without it.
resource_bundle="CiaobotMac_CiaobotMac.bundle"
rm -rf "$resources/$resource_bundle"
cp -R "$binary_dir/$resource_bundle" "$resources/$resource_bundle"

# Flat copies are also resolved by AppAssets inside a .app.
cp "Sources/CiaobotMac/Resources/face.png" "$resources/face.png"
cp "Sources/CiaobotMac/Resources/face_template.png" "$resources/face_template.png"
cp "Sources/CiaobotMac/Resources/app-icon.png" "$resources/app-icon.png"

# Native Finder/Dock icon. It is generated from the rounded PWA artwork
# snapshot in Sources/CiaobotMac/Resources, never read from the engine
# checkout, so the bundle build needs no running server and no third-party
# tooling. The source has transparent rounded corners (macOS shows a native
# .icns as-is); fail here rather than ship another square Dock tile.
command -v sips >/dev/null || { echo "sips is required to build AppIcon.icns" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil is required to build AppIcon.icns" >&2; exit 1; }
iconset_root=$(mktemp -d "${TMPDIR:-/tmp}/ciaobot-iconset.XXXXXX")
trap 'rm -rf "$iconset_root"' EXIT INT TERM
iconset="$iconset_root/AppIcon.iconset"
mkdir -p "$iconset"
icon_source="Sources/CiaobotMac/Resources/app-icon.png"
if [ "$(sips -g hasAlpha "$icon_source" | awk '/hasAlpha/ { print $2 }')" != "yes" ]; then
    echo "app-icon.png must have transparent rounded corners" >&2
    exit 1
fi
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CiaobotMac</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>local.ciaobot.mac</string>
<key>CFBundleName</key><string>Ciaobot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist"
test -s "$resources/AppIcon.icns"
printf 'Built %s\n' "$bundle"
