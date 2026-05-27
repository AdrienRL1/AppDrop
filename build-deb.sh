#!/bin/bash
# Build AppDrop as a Cydia .deb that wraps the .ipa and installs it via
# `ipainstaller` from postinst.
#
# Why this approach (v1.0.1+):
# A regular Cydia .deb installs the .app under /Applications/ (system path).
# SpringBoard does not apply its icon treatment to system apps — the home-screen
# icon ends up square with no iOS-6 gloss. By delegating to ipainstaller, the
# bundle lands under /var/mobile/Applications/<UUID>/ (user path), and iOS
# applies the standard rounded-corner mask + glossy reflection at draw time.
#
# Trade-off: dpkg only tracks the helper .ipa file at /usr/share/appdrop/, not
# the actual installed bundle. Uninstall (via Cydia) calls ipainstaller -u in
# prerm to clean up the real bundle too.
#
# Output:
#   docs/debs/ca.adrien.appdrop_<version>_iphoneos-arm.deb
#   docs/Packages, docs/Packages.gz, docs/Release
#
# Cydia source URL: https://AdrienRL1.github.io/adrienrl/

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

# === 3. Build the .ipa (zip of Payload/IPAInstaller.app) ================
IPA_STAGE=/tmp/appdrop-ipa-stage
rm -rf "$IPA_STAGE"
mkdir -p "$IPA_STAGE/Payload"
cp -R "IPAInstaller/$APP_BUNDLE" "$IPA_STAGE/Payload/"
(cd "$IPA_STAGE" && zip -qr AppDrop.ipa Payload)
IPA_FILE="$IPA_STAGE/AppDrop.ipa"
echo "=== ipa built: $(ls -lh "$IPA_FILE" | awk '{print $5}') ==="

# === 4. Stage the Debian package tree ===================================
STAGE=/tmp/appdrop-deb
rm -rf "$STAGE"
mkdir -p "$STAGE/usr/share/appdrop"
cp "$IPA_FILE" "$STAGE/usr/share/appdrop/AppDrop.ipa"

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
Depends: com.autopear.installipa | ai.akemi.appinst | ipainstaller | appinst
EOF

# Postinst — invoke ipainstaller to install the bundled .ipa, then remove
# the helper .ipa file so we don't waste 17 MB of permanent storage. The
# actual app bundle lives under /var/mobile/Applications/<UUID>/ where iOS
# treats it as a user app and applies the home-screen icon treatment.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    IPA=/usr/share/appdrop/AppDrop.ipa
    if ! [ -f "$IPA" ]; then
        echo "AppDrop helper .ipa missing at $IPA — install aborted."
        exit 1
    fi
    INSTALLER=""
    for p in /usr/bin/ipainstaller /usr/bin/appinst /var/jb/usr/bin/ipainstaller /var/jb/usr/bin/appinst; do
        [ -x "$p" ] && INSTALLER="$p" && break
    done
    if [ -z "$INSTALLER" ]; then
        echo "ipainstaller / appinst not found. Install one of them first:"
        echo "  - 'IPA Installer Console' (autopear) on classic Cydia"
        echo "  - 'appinst' (ai.akemi.appinst) on most repos"
        exit 1
    fi
    echo "Installing AppDrop bundle via $INSTALLER..."
    if ! "$INSTALLER" "$IPA"; then
        echo "ipainstaller failed. AppDrop bundle install aborted."
        exit 1
    fi
    # Cleanup: the helper .ipa is no longer needed. We leave the empty
    # /usr/share/appdrop/ dir for dpkg's file-tracking peace of mind.
    rm -f "$IPA"
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# Prerm — when the user uninstalls from Cydia, also remove the real app
# from /var/mobile/Applications/.
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
if [ "$1" = remove ] || [ "$1" = purge ]; then
    INSTALLER=""
    for p in /usr/bin/ipainstaller /usr/bin/appinst /var/jb/usr/bin/ipainstaller /var/jb/usr/bin/appinst; do
        [ -x "$p" ] && INSTALLER="$p" && break
    done
    if [ -n "$INSTALLER" ]; then
        "$INSTALLER" -u ca.adrien.appdrop 2>/dev/null || true
    fi
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/prerm"

# === 5. Build the .deb (POSIX-clean tarballs, no macOS xattrs) ==========
DEB_DIR="$(pwd)/docs/debs"
mkdir -p "$DEB_DIR"
DEB_FILE="$DEB_DIR/${BUNDLE_ID}_${VERSION}_iphoneos-arm.deb"
echo "=== packaging $DEB_FILE ==="

WORK=/tmp/appdrop-deb-build
rm -rf "$WORK"
mkdir -p "$WORK"

echo "2.0" > "$WORK/debian-binary"

# Strip macOS xattrs / AppleDouble / .DS_Store from the staging tree so
# dpkg on iOS doesn't choke with "corrupted filesystem tarfile". See the
# v1.0.0 install report for the long version of why this matters.
xattr -cr "$STAGE" 2>/dev/null || true
find "$STAGE" \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null || true

COPYFILE_DISABLE=1 tar -C "$STAGE/DEBIAN" \
    --format=ustar \
    --uid=0 --gid=0 --numeric-owner \
    --no-xattrs --no-fflags --no-mac-metadata \
    -czf "$WORK/control.tar.gz" .

COPYFILE_DISABLE=1 tar -C "$STAGE" \
    --format=ustar \
    --uid=0 --gid=0 --numeric-owner \
    --no-xattrs --no-fflags --no-mac-metadata \
    --exclude=./DEBIAN \
    -czf "$WORK/data.tar.gz" .

(cd "$WORK" && ar -rc "$DEB_FILE.tmp" debian-binary control.tar.gz data.tar.gz)
mv "$DEB_FILE.tmp" "$DEB_FILE"
ls -lh "$DEB_FILE"

# === 6. Refresh docs/ Cydia repo metadata ===============================
echo "=== regenerating Cydia repo metadata ==="
SIZE=$(stat -f%z "$DEB_FILE")
MD5=$(md5 -q "$DEB_FILE")
SHA1=$(shasum -a 1 "$DEB_FILE" | awk '{print $1}')
SHA256=$(shasum -a 256 "$DEB_FILE" | awk '{print $1}')
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
Depends: com.autopear.installipa | ai.akemi.appinst | ipainstaller | appinst
Filename: debs/$(basename "$DEB_FILE")
Size: $SIZE
MD5sum: $MD5
SHA1: $SHA1
SHA256: $SHA256
Icon: https://adrienrl1.github.io/adrienrl/CydiaIcon.png
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
