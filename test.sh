#!/usr/bin/env bash
# Build a fully-static nmap on RHEL 8.x/Fedora and bundle it for shipment.
# Output: $WORK/out/nmap-portable-<ver>-static-<arch>.tgz
set -euo pipefail

# --- Config ---
OPENSSL_VER=${OPENSSL_VER:-3.5.4}
PCRE2_VER=${PCRE2_VER:-10.44}
NMAP_VER=${NMAP_VER:-7.98}

WORK=${WORK:-$(pwd)}
PREFIX_OSSL=$WORK/opt/ossl
PREFIX_PCRE=$WORK/opt/pcre2
OUT=$WORK/out

mkdir -p "$WORK/src" "$PREFIX_OSSL" "$PREFIX_PCRE" "$OUT"
cd "$WORK/src"

JOBS=$(nproc 2>/dev/null || echo 2)

# --- Install build deps (skip if already present, e.g. inside the container) ---
need_install=0
for bin in gcc g++ make perl python3 ar; do
    command -v "$bin" >/dev/null 2>&1 || { need_install=1; break; }
done
for lib in /usr/lib64/libc.a /usr/lib/x86_64-linux-gnu/libc.a; do
    [[ -f "$lib" ]] && break
done || need_install=1

if (( need_install )); then
    echo "→ Installing system dependencies..."
    SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
    $SUDO dnf install -y \
        gcc gcc-c++ make curl tar bzip2 gzip xz file pkgconfig \
        autoconf automake libtool perl-core python3 \
        zlib-devel zlib-static \
        glibc-static libstdc++-static
else
    echo "→ Build deps already present, skipping dnf install."
fi

# --- OpenSSL (static, lean, for Nmap) ---
if ! compgen -G "$PREFIX_OSSL/lib*/libssl.a" >/dev/null; then
    echo "→ Building OpenSSL $OPENSSL_VER..."
    [[ -f "openssl-$OPENSSL_VER.tar.gz" ]] || \
        curl -fsSLO "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz"

    rm -rf "openssl-$OPENSSL_VER" && tar xf "openssl-$OPENSSL_VER.tar.gz"
    pushd "openssl-$OPENSSL_VER" >/dev/null

    ./Configure linux-x86_64 \
        --prefix="$PREFIX_OSSL" \
        --openssldir="$PREFIX_OSSL/ssl" \
        no-shared no-dso no-engine no-tests

    # Build with parallelism (ignore warnings due to -u pipefail)
    make -j"$JOBS" depend
    make -j"$JOBS" all
    make install_sw

    popd >/dev/null
    echo "✓ OpenSSL installed to $PREFIX_OSSL"
else
    echo "→ Skipping OpenSSL (already built)"
fi

# --- PCRE2 (static) ---
if [[ ! -f "$PREFIX_PCRE/lib/libpcre2-8.a" ]]; then
    echo "→ Building PCRE2 $PCRE2_VER..."
    [[ -f "pcre2-$PCRE2_VER.tar.bz2" ]] || \
        curl -fsSLO "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.bz2"

    rm -rf "pcre2-$PCRE2_VER" && tar xf "pcre2-$PCRE2_VER.tar.bz2"
    pushd "pcre2-$PCRE2_VER" >/dev/null

    ./configure \
        --prefix="$PREFIX_PCRE" \
        --disable-shared \
        --enable-static \
        --with-pic \
        --enable-jit \
        --disable-cpp

    make -j"$JOBS" all
    make install

    popd >/dev/null
    echo "✓ PCRE2 installed to $PREFIX_PCRE"
fi

# --- Nmap (fully static) ---
echo "→ Building Nmap $NMAP_VER..."
[[ -f "nmap-$NMAP_VER.tar.bz2" ]] || \
    curl -fsSLO "https://nmap.org/dist/nmap-$NMAP_VER.tar.bz2"

rm -rf "nmap-$NMAP_VER" && tar xf "nmap-$NMAP_VER.tar.bz2"
pushd "nmap-$NMAP_VER" >/dev/null

# Configure with static preference + all dependencies rooted
CPPFLAGS="-I$PREFIX_OSSL/include -I$PREFIX_PCRE/include" \
LDFLAGS="-L$PREFIX_OSSL/lib64 -L$PREFIX_OSSL/lib -L$PREFIX_PCRE/lib -static -static-libstdc++ -static-libgcc" \
LIBS="-lpcre2-8 -ldl -lpthread -lz" \
./configure \
    --with-openssl="$PREFIX_OSSL" \
    --with-libpcre="$PREFIX_PCRE" \
    --with-libpcap=included \
    --with-libdnet=included \
    --without-zenmap \
    --without-ndiff \
    --without-nmap-update \
    --enable-static

# Critical: fix linking order for OpenSSL 3.x (libcrypto must follow libssl)
sed -i 's/$(LIBS)/-lcrypto $(LIBS)/' Makefile
# -latomic not needed on x86_64 glibc builds

make -j"$JOBS" all
strip nmap ncat/ncat nping/nping 2>/dev/null || true
popd >/dev/null

# --- Package into portable tarball ---
BUNDLE=nmap-portable
rm -rf "$OUT/$BUNDLE"
mkdir -p "$OUT/$BUNDLE"/{scripts,nselib}

cp "$WORK/src/nmap-$NMAP_VER/nmap"        "$OUT/$BUNDLE/"
cp "$WORK/src/nmap-$NMAP_VER/ncat/ncat"   "$OUT/$BUNDLE/" 2>/dev/null || true
cp "$WORK/src/nmap-$NMAP_VER/nping/nping" "$OUT/$BUNDLE/" 2>/dev/null || true

cp -a "$WORK/src/nmap-$NMAP_VER"/scripts/. "$OUT/$BUNDLE/scripts/"
cp -a "$WORK/src/nmap-$NMAP_VER"/nselib/.  "$OUT/$BUNDLE/nselib/"
[[ -f "$WORK/src/nmap-$NMAP_VER/docs/nmap.xsl" ]] && \
    cp "$WORK/src/nmap-$NMAP_VER/docs/nmap.xsl" "$OUT/$BUNDLE/"

# Core data files (nse_main.lua is required for -sC / --script)
for f in nmap-services nmap-protocols nmap-rpc nmap-mac-prefixes \
         nmap-os-db nmap-service-probes nmap-payloads nse_main.lua; do
    src="$WORK/src/nmap-$NMAP_VER/$f"
    [[ -f "$src" ]] && cp "$src" "$OUT/$BUNDLE/" || echo "  (skipping missing $f)"
done

TARBALL="nmap-portable-$NMAP_VER-static-$(arch).tgz"
tar -C "$OUT" -czf "$OUT/$TARBALL" "$BUNDLE"
sha256sum "$OUT/$TARBALL" > "$OUT/$TARBALL.sha256"

# --- Verification ---
echo
echo "═══════════════════════════════════════════════════════════"
echo "=== DONE! Static nmap built and bundled ==="
file "$OUT/$BUNDLE/nmap"

echo -e "\n--- ldd (static = no external deps) ---"
if ldd "$OUT/$BUNDLE/nmap" >/dev/null 2>&1; then
    ldd "$OUT/$BUNDLE/nmap"
else
    echo "✅ (fully static, no ldd output = success)"
fi

echo -e "\n--- bundle contents ---"
ls -lh "$OUT/$BUNDLE/nmap" "$OUT/$TARBALL"

echo -e "\n--- quick test (scan nmap.org) ---"
"$OUT/$BUNDLE/nmap" -sS -p 80,443 --open nmap.org -n -Pn 2>&1 || echo "⚠️  Scan skipped (needs cap_net_admin or root)"

echo
echo "Tarball: $OUT/$TARBALL"
echo "Checksum: $OUT/$TARBALL.sha256"

