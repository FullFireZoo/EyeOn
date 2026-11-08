#!/bin/bash
# Construit dist/EyeOn.app (universelle arm64 + x86_64, macOS 14+) et dist/EyeOn-<version>.dmg, sans Xcode.
# Prérequis : outils en ligne de commande d'Apple (xcode-select --install).
#   ./build.sh             construit l'app et l'image disque
#   ./build.sh --installer construit puis copie dans /Applications et enregistre le widget (pour le développement)
set -euo pipefail

VERSION="1.0.0"
BUILD="1"
MIN="14.0"
ARCHS=(arm64 x86_64)

D="$(cd "$(dirname "$0")" && pwd)"
OUT="$D/dist"; TMP="$D/build"
APP="$OUT/EyeOn.app"; X="$APP/Contents/PlugIns/EyeOnWidget.appex"
DMG="$OUT/EyeOn-$VERSION.dmg"
S="$D/Sources"

rm -rf "$TMP" "$APP" "$DMG"; mkdir -p "$TMP" "$OUT"

# compile <nom> <options...> -- <sources...> : un binaire par architecture, puis lipo
compile() {
  local nom="$1"; shift
  local opts=() srcs=()
  while [ "$1" != "--" ]; do opts+=("$1"); shift; done; shift
  srcs=("$@")
  local parts=()
  for a in "${ARCHS[@]}"; do
    echo "  · $nom ($a)"
    swiftc -O -target "$a-apple-macos$MIN" ${opts[@]+"${opts[@]}"} "${srcs[@]}" -o "$TMP/$nom-$a"
    parts+=("$TMP/$nom-$a")
  done
  lipo -create "${parts[@]}" -output "$TMP/$nom"
}

echo "▸ Compilation"
compile EyeOn -framework Cocoa -framework WebKit -framework WidgetKit -framework SwiftUI -framework ServiceManagement -- \
  "$S/App/main.swift" "$S/App/Lecteur.swift" "$S/App/Assistant.swift" "$S/Commun/Commun.swift"
compile eyeon-hook -- "$S/Hook/main.swift" "$S/Commun/Commun.swift"
compile eyeon-progres -- "$S/Progres/main.swift" "$S/Commun/Commun.swift"
compile EyeOnWidget -parse-as-library -application-extension -framework WidgetKit -framework SwiftUI \
  -Xlinker -e -Xlinker _NSExtensionMain -- "$S/Widget/EyeOnWidget.swift"

echo "▸ Assemblage de EyeOn.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$X/Contents/MacOS"
cp "$TMP/EyeOn" "$TMP/eyeon-hook" "$TMP/eyeon-progres" "$APP/Contents/MacOS/"
cp "$D/Resources/panneau.html" "$D/Resources/EyeOn.icns" "$APP/Contents/Resources/"
cp "$TMP/EyeOnWidget" "$X/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>EyeOn</string><key>CFBundleDisplayName</key><string>EyeOn</string>
<key>CFBundleIdentifier</key><string>fr.fullfirezoo.eyeon</string>
<key>CFBundleExecutable</key><string>EyeOn</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleDevelopmentRegion</key><string>fr</string>
<key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>$MIN</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>CFBundleIconFile</key><string>EyeOn</string>
<key>NSHumanReadableCopyright</key><string>Licence MIT</string>
<key>NSAppleEventsUsageDescription</key><string>EyeOn utilise Messages pour t'envoyer une alerte sur iPhone quand tu n'es pas devant ton Mac (option facultative).</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>fr.fullfirezoo.eyeon</string><key>CFBundleURLSchemes</key><array><string>eyeon</string></array></dict></array>
</dict></plist>
P
cat > "$X/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>EyeOnWidget</string><key>CFBundleDisplayName</key><string>EyeOn</string>
<key>CFBundleIdentifier</key><string>fr.fullfirezoo.eyeon.widget</string>
<key>CFBundleExecutable</key><string>EyeOnWidget</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>LSMinimumSystemVersion</key><string>$MIN</string>
<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
P
# Widget sandboxé : lecture seule du dossier de données de EyeOn (chemin relatif au dossier personnel)
cat > "$TMP/widget.entitlements" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key><array><string>/Library/Application Support/EyeOn/</string></array>
</dict></plist>
P

echo "▸ Signature ad hoc"
codesign --force -s - --entitlements "$TMP/widget.entitlements" "$X"
codesign --force -s - "$APP/Contents/MacOS/eyeon-hook"
codesign --force -s - "$APP/Contents/MacOS/eyeon-progres"
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Image disque"
STAGE="$TMP/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "EyeOn $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$TMP"

echo "✓ $APP"
echo "✓ $DMG"

if [ "${1:-}" = "--installer" ]; then
  echo "▸ Installation dans /Applications"
  pkill -f "EyeOn.app/Contents/MacOS/EyeOn" || true
  rm -rf "/Applications/EyeOn.app"; cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/EyeOn.app"
  pluginkit -a "/Applications/EyeOn.app/Contents/PlugIns/EyeOnWidget.appex" 2>/dev/null || true
  killall chronod 2>/dev/null || true   # sinon macOS garde l'ancienne version du widget (« Bundle version did not match »)
  open "/Applications/EyeOn.app"
fi
