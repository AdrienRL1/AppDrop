#!/bin/bash
# Cross-compile mbedTLS as static library for armv7-ios with iOS 5+ deployment target.
# Output : ~/Documents/ipa-installer-app/deps/build/libmbedcrypto.a + libmbedtls.a + libmbedx509.a
set -e
cd "$(dirname "$0")/mbedtls"

SDK="$HOME/theos/sdks/iPhoneOS7.0.sdk"
OUT="../build"
mkdir -p "$OUT"

CFLAGS="-target armv7-apple-ios5.0 -arch armv7 -isysroot $SDK -miphoneos-version-min=5.0 -Os -fno-modules -Wno-deprecated-module-dot-map -Wno-everything -I include -I library -I 3rdparty/everest/include -I 3rdparty/p256-m -DMBEDTLS_HAVE_TIME -DMBEDTLS_HAVE_TIME_DATE"

build_one() {
    local lib_name="$1"
    shift
    local srcs="$@"
    local objs=""
    for s in $srcs; do
        local o=$(echo "$s" | sed 's|.*/||;s|\.c$||')
        echo "  cc $s"
        clang $CFLAGS -c "$s" -o "$OUT/${lib_name}_${o}.o" 2>/dev/null || {
            echo "  WARN: failed $s"
        }
        if [ -f "$OUT/${lib_name}_${o}.o" ]; then
            objs="$objs $OUT/${lib_name}_${o}.o"
        fi
    done
    if [ -n "$objs" ]; then
        ar rcs "$OUT/lib${lib_name}.a" $objs
        ranlib "$OUT/lib${lib_name}.a"
        echo "  --> lib${lib_name}.a built ($(du -h "$OUT/lib${lib_name}.a" | cut -f1))"
    fi
    # Clean temp objs
    rm -f "$OUT"/${lib_name}_*.o
}

echo "=== mbedcrypto ===" && \
build_one mbedcrypto \
    library/aes.c library/aesni.c library/aesce.c library/aria.c \
    library/asn1parse.c library/asn1write.c library/base64.c \
    library/bignum.c library/bignum_core.c library/bignum_mod.c library/bignum_mod_raw.c \
    library/camellia.c library/ccm.c library/chacha20.c library/chachapoly.c \
    library/cipher.c library/cipher_wrap.c library/cmac.c \
    library/constant_time.c library/ctr_drbg.c library/des.c \
    library/dhm.c library/ecdh.c library/ecdsa.c library/ecjpake.c \
    library/ecp.c library/ecp_curves.c library/ecp_curves_new.c \
    library/entropy.c library/entropy_poll.c \
    library/error.c library/gcm.c library/hash_info.c library/hkdf.c library/hmac_drbg.c \
    library/md.c library/md5.c library/memory_buffer_alloc.c \
    library/mps_reader.c library/mps_trace.c library/nist_kw.c \
    library/oid.c library/padlock.c library/pem.c library/pk.c library/pk_wrap.c \
    library/pkcs12.c library/pkcs5.c library/pkparse.c library/pkwrite.c \
    library/platform.c library/platform_util.c library/poly1305.c \
    library/psa_crypto.c library/psa_crypto_aead.c library/psa_crypto_cipher.c \
    library/psa_crypto_client.c library/psa_crypto_ecp.c library/psa_crypto_ffdh.c \
    library/psa_crypto_hash.c library/psa_crypto_mac.c library/psa_crypto_pake.c \
    library/psa_crypto_rsa.c library/psa_crypto_se.c library/psa_crypto_slot_management.c \
    library/psa_crypto_storage.c library/psa_its_file.c library/psa_util.c \
    library/ripemd160.c library/rsa.c library/rsa_alt_helpers.c \
    library/sha1.c library/sha256.c library/sha512.c library/sha3.c \
    library/threading.c library/timing.c library/version.c library/version_features.c \
    library/lmots.c library/lms.c library/block_cipher.c \
    library/pk_ecc.c library/pk_internal.c library/ssl_debug_helpers_generated.c \
    library/psa_crypto_driver_wrappers_no_static.c

echo "" && \
echo "=== mbedx509 ===" && \
build_one mbedx509 \
    library/x509.c library/x509_create.c library/x509_crl.c library/x509_crt.c \
    library/x509_csr.c library/x509write.c library/x509write_crt.c library/x509write_csr.c \
    library/pkcs7.c

echo "" && \
echo "=== mbedtls (SSL/TLS) ===" && \
build_one mbedtls \
    library/debug.c library/mps_reader.c library/mps_trace.c \
    library/net_sockets.c library/ssl_cache.c library/ssl_ciphersuites.c \
    library/ssl_client.c library/ssl_cookie.c \
    library/ssl_msg.c library/ssl_ticket.c library/ssl_tls.c library/ssl_tls12_client.c \
    library/ssl_tls12_server.c \
    library/ssl_tls13_client.c library/ssl_tls13_generic.c library/ssl_tls13_keys.c \
    library/ssl_tls13_server.c

echo ""
echo "=== Final ==="
ls -la "$OUT"/*.a 2>/dev/null
file "$OUT"/libmbedtls.a 2>/dev/null | head -1
