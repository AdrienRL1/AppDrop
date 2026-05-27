#!/bin/bash
# Build AppDrop as a Cydia .deb package + refresh the GitHub-Pages-hosted repo files.
#
# Output:
#   docs/debs/ca.adrien.appdrop_<version>_iphoneos-arm.deb   — the package
#   docs/Packages, docs/Packages.gz, docs/Release            — repo metadata
#
# The .deb installs to /Applications/IPAInstaller.app/ (system app path on
# rootful jailbreaks — iOS 6.x evasi0n is rootful). On install via Cydia or
# `dpkg -i`, SpringBoard is automatically respringed by Cydia's postinst hook.
#
# Cydia source URL after `git push`: https://AdrienRL1.github.io/adrienrl/

set -e
cd "$(dirname "$0")"
export THEOS=$HOME/theos

# === 1. Build the .app via Theos =========================================
cd IPAInstaller
echo "=== make ==="
rm -rf .theos/obj/debug
if ! make -j4 2>&1 | tee /tmp/build.log | grep -E "Compiling|Linking|Signing|error:" | tail -10; then
    echo "Build failed."; exit 1
fi
if grep -q "error:" /tmp/build.log; then
    echo "BUILD ERROR — abandon."; exit 2
fi
APP_BUNDLE=".theos/obj/debug/IPAInstaller.app"
if ! [ -d "$APP_BUNDLE" ]; then echo "No .app bundle — abandon."; exit 1; fi
cd ..

# === 2. Extract version from Info.plist =================================
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    IPAInstaller/Resources/Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    IPAInstaller/Resources/Info.plist)
echo "=== version: $VERSION  bundle: $BUNDLE_ID ==="

# === 3. Stage the Debian package tree ===================================
STAGE=/tmp/appdrop-deb
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications"
cp -R "IPAInstaller/$APP_BUNDLE" "$STAGE/Applications/IPAInstaller.app"

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $BUNDLE_ID
Name: AppDrop
Version: $VERSION
Architecture: iphoneos-arm
Maintainer: AdrienRL <adrienrl@users.noreply.github.com>
Author: AdrienRL
Description: Vintage IPA installer for jailbroken iOS 6+. Browse a 157k app catalog (2008-2014) hosted on archive.org and install with one tap. Built-in multilingual AI search.
Section: Utilities
Priority: optional
Homepage: https://github.com/AdrienRL1/adrienrl
Depends: ipainstaller | appinst
Conflicts: ca.adrien.ipainstaller
Replaces: ca.adrien.ipainstaller
EOF

# Postinst — respring SpringBoard after install so the icon appears.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
if [ "$1" = configure ]; then
    /usr/bin/uicache 2>/dev/null || su mobile -c /usr/bin/uicache 2>/dev/null || true
    killall -9 SpringBoard 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# Postrm — refresh icon cache on uninstall.
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
/usr/bin/uicache 2>/dev/null || su mobile -c /usr/bin/uicache 2>/dev/null || true
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postrm"

# === 4. Build the .deb (without depending on dpkg-deb) =================
# Format = `ar` archive containing 3 files:
#   debian-binary  (literal "2.0\n")
#   control.tar.gz (DEBIAN/* files)
#   data.tar.gz    (everything else, paths prefixed with ./)
DEB_DIR="$(pwd)/docs/debs"
mkdir -p "$DEB_DIR"
DEB_FILE="$DEB_DIR/${BUNDLE_ID}_${VERSION}_iphoneos-arm.deb"
echo "=== packaging $DEB_FILE ==="

WORK=/tmp/appdrop-deb-build
rm -rf "$WORK"
mkdir -p "$WORK"

echo "2.0" > "$WORK/debian-binary"

(cd "$STAGE/DEBIAN" && tar --no-mac-metadata -czf "$WORK/control.tar.gz" \
    --owner=0 --group=0 --numeric-owner ./*) 2>/dev/null || \
(cd "$STAGE/DEBIAN" && tar -czf "$WORK/control.tar.gz" ./*)

(cd "$STAGE" && tar --no-mac-metadata -czf "$WORK/data.tar.gz" \
    --owner=0 --group=0 --numeric-owner --exclude=./DEBIAN ./*) 2>/dev/null || \
(cd "$STAGE" && tar -czf "$WORK/data.tar.gz" --exclude=./DEBIAN ./*)

(cd "$WORK" && ar -rc "$DEB_FILE.tmp" debian-binary control.tar.gz data.tar.gz)
mv "$DEB_FILE.tmp" "$DEB_FILE"
ls -lh "$DEB_FILE"

# === 5. Refresh docs/ Cydia repo metadata ===============================
echo "=== regenerating Cydia repo metadata ==="
SIZE=$(stat -f%z "$DEB_FILE")
MD5=$(md5 -q "$DEB_FILE")
SHA1=$(shasum -a 1 "$DEB_FILE" | awk '{print $1}')
SHA256=$(shasum -a 256 "$DEB_FILE" | awk '{print $1}')

# Description must use leading-space continuation in Packages format.
DESC_TEXT=$(grep ^Description: "$STAGE/DEBIAN/control" | sed 's/^Description: //')

cat > docs/Packages <<EOF
Package: $BUNDLE_ID
Name: AppDrop
Version: $VERSION
Architecture: iphoneos-arm
Maintainer: AdrienRL <adrienrl@users.noreply.github.com>
Author: AdrienRL
Description: $DESC_TEXT
Section: Utilities
Priority: optional
Homepage: https://github.com/AdrienRL1/adrienrl
Depends: ipainstaller | appinst
Filename: debs/$(basename "$DEB_FILE")
Size: $SIZE
MD5sum: $MD5
SHA1: $SHA1
SHA256: $SHA256
Icon: file://./CydiaIcon.png
EOF

gzip -9c docs/Packages > docs/Packages.gz

cat > docs/Release <<EOF
Origin: AdrienRL
Label: AppDrop Repo
Suite: stable
Version: 1.0
Codename: appdrop
Architectures: iphoneos-arm
Components: main
Description: AppDrop — vintage IPA installer for jailbroken iOS 6+
EOF

echo
echo "=== Cydia repo ready ==="
echo "  Source URL : https://AdrienRL1.github.io/adrienrl/"
echo "  Package    : $DEB_FILE  (size $(($SIZE / 1024)) KB)"
ls -la docs/Packages docs/Packages.gz docs/Release
