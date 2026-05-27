#!/bin/bash
# Build + package + push to iPad + install
set -e
cd "$(dirname "$0")/IPAInstaller"
export THEOS=$HOME/theos

echo "=== make ==="
rm -rf .theos/obj/debug
if ! make -j4 2>&1 | tee /tmp/build.log | grep -E "error|Compiling|Linking|Signing" | tail -15; then
    echo "Build failed."; exit 1
fi
if grep -q "error:" /tmp/build.log; then
    echo "BUILD ERROR — abandon."
    grep "error:" /tmp/build.log | head -5
    exit 2
fi
if ! [ -f ".theos/obj/debug/IPAInstaller.app/IPAInstaller" ]; then
    echo "Pas de binaire — abandon."; exit 1
fi

echo ""
echo "=== package .ipa ==="
rm -rf /tmp/ipa-build
mkdir -p /tmp/ipa-build/Payload
cp -R .theos/obj/debug/IPAInstaller.app /tmp/ipa-build/Payload/
cd /tmp/ipa-build
zip -qr IPAInstaller.ipa Payload
ls -la IPAInstaller.ipa

echo ""
echo "=== push iPad + install (direct Mac → iPad, no Unraid intermediary) ==="
IPAD_IP="${IPAD_IP:-192.168.2.29}"
IPAD_PASS="${IPAD_PASS:-alpine}"
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa \
          -o KexAlgorithms=+diffie-hellman-group14-sha1 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
sshpass -p "$IPAD_PASS" scp -q "${SSH_OPTS[@]}" IPAInstaller.ipa "root@$IPAD_IP:/var/mobile/Documents/IPAInstaller.ipa"
sshpass -p "$IPAD_PASS" ssh "${SSH_OPTS[@]}" "root@$IPAD_IP" \
    "ipainstaller /var/mobile/Documents/IPAInstaller.ipa; rm /var/mobile/Documents/IPAInstaller.ipa"

echo ""
echo "=== installed ==="
