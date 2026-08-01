#!/bin/bash
# Assemble the Apple Help Book inside an app bundle from docs/help — the same
# files GitHub Pages serves, so the help is written exactly once. Called by
# both the Makefile bundle step and scripts/release.sh, BEFORE codesign.
#
#   scripts/assemble-help.sh dist/Parrot.app
set -euo pipefail

APP="${1:?usage: scripts/assemble-help.sh <path/to/Parrot.app>}"
SRC="docs/help"
BOOK="$APP/Contents/Resources/Parrot.help"
LPROJ="$BOOK/Contents/Resources/en.lproj"

rm -rf "$BOOK"
mkdir -p "$LPROJ"
cp "$SRC"/*.html "$SRC"/help.css "$LPROJ/"
cp -R "$SRC/img" "$LPROJ/img"

# The book's own identity. HPDBookAccessPath is the landing page; the index
# file is what gives the Help menu's search field results from our pages.
cat > "$BOOK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>com.uygar.parrot.help</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Parrot Help</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>HPDBookAccessPath</key>
	<string>index.html</string>
	<key>HPDBookIndexPath</key>
	<string>Parrot.helpindex</string>
	<key>HPDBookTitle</key>
	<string>Parrot Help</string>
	<key>HPDBookType</key>
	<string>3</string>
</dict>
</plist>
PLIST

# Build the search index Help Viewer queries.
hiutil -Caf "$LPROJ/Parrot.helpindex" "$LPROJ"

echo "==> help book assembled ($(ls "$LPROJ"/*.html | wc -l | tr -d ' ') pages, indexed)"
