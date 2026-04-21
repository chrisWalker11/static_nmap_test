# Portable Static Nmap Builder

Builds a **fully static** `nmap` (plus `ncat` and `nping`) that runs on
locked-down RHEL 8 / CentOS 7+ / Rocky / Alma boxes with **no runtime
dependencies** — no glibc version mismatch, no missing `libssl`, no
`ldd` output at all.

Drop the resulting tarball on a target, untar, run. That's it.

---

## What you get

```
nmap-portable-7.98-static-x86_64.tgz   (~17 MB)
└── nmap-portable/
    ├── nmap              ← statically linked, stripped
    ├── ncat              ← statically linked, stripped
    ├── nping             ← statically linked, stripped
    ├── scripts/*.nse     ← NSE scripts
    ├── nselib/*          ← NSE libraries
    └── nmap-services, nmap-os-db, nmap-service-probes, ...
```

```
$ file nmap
ELF 64-bit LSB executable, x86-64, statically linked, stripped
$ ldd nmap
        not a dynamic executable
```

---

## Why this exists

Pre-built nmap binaries break the moment the target's glibc is older
than your builder's. RHEL 8 ships glibc 2.28; Fedora 40+ ships 2.39+.
A binary built on modern Fedora **will not run** on RHEL 8.

Solution: build on **Rocky 8** (same glibc ABI as RHEL 8), link
everything statically, and you get a single binary that runs on
essentially any Linux from the last decade.

---

## Components

| File                   | Purpose                                          |
| ---------------------- | ------------------------------------------------ |
| `test.sh`              | The build script — fetches sources, compiles     |
|                        | OpenSSL + PCRE2 + nmap, bundles the tarball.     |
| `Dockerfile.rocky8`    | Rocky Linux 8 build environment with all the     |
|                        | `*-static` packages needed for static linking.   |

---

## Pinned versions

| Component | Version | Why                                        |
| --------- | ------- | ------------------------------------------ |
| OpenSSL   | 3.5.4   | Current LTS, required by nmap 7.98         |
| PCRE2     | 10.44   | Matches nmap's regex expectations          |
| Nmap      | 7.98    | Latest stable at time of writing           |

Override any of these with env vars:

```bash
OPENSSL_VER=3.5.4 PCRE2_VER=10.44 NMAP_VER=7.98 bash test.sh
```

---

## How it works

### 1. Build the container

```bash
docker build -f Dockerfile.rocky8 -t nmap-builder:rocky8 .
```

This gives you Rocky 8 with:
- `glibc-static`, `libstdc++-static`, `zlib-static` — the actual static libs
- `gcc`, `gcc-c++`, `make`, `perl-core`, `python3` — the toolchain
- `powertools` repo enabled (that's where the `*-static` packages live)

### 2. Run the build

```bash
docker run --name nmap-extract nmap-builder:rocky8
```

Inside the container, `test.sh` does three compile stages:

1. **OpenSSL 3.5.4** — `no-shared no-dso no-engine no-tests`, installs to `/build/opt/ossl`
2. **PCRE2 10.44** — `--disable-shared --enable-static --with-pic --enable-jit`, installs to `/build/opt/pcre2`
3. **Nmap 7.98** — configured with `-static -static-libstdc++ -static-libgcc` and pointed at the two dep trees above

A `sed` fixes Nmap's linker order so OpenSSL 3.x resolves (`libcrypto`
must follow `libssl`). Binaries are stripped, then everything is
tarred up under `/build/out/`.

### 3. Extract the tarball to your host

```bash
docker ps -a
docker start <nmap container>
docker cp nmap-extract:/build/out/. ./
docker rm nmap-extract
```

You now have `nmap-portable-7.98-static-x86_64.tgz` in the current
directory on the host.

---

## Deploying to a target

```bash
scp nmap-portable-7.98-static-x86_64.tgz target:/tmp/
ssh target
cd /tmp && tar xzf nmap-portable-7.98-static-x86_64.tgz
./nmap-portable/nmap -sS -Pn -n 10.0.0.0/24
```

### If you get `Permission denied` even as root

You're probably hitting one of the usual execution blockers:

**noexec on `/tmp`** — find a mount that allows exec:

```bash
findmnt -lo TARGET,SOURCE,FSTYPE,OPTIONS | awk 'NR==1 || /noexec/'
```

Typical writable + exec locations: `/dev/shm`, `/var/tmp`, `$HOME`.

**SELinux** — relabel the binary:

```bash
chcon -t bin_t ./nmap-portable/nmap
```

**fapolicyd** — check with `systemctl status fapolicyd`. If it's
enforcing, you'll need an allowlist entry or a path it trusts.

---

## Runtime caveats

- **NSS warnings** — static glibc prints a warning about `getaddrinfo`
  / `getnetbyname_r` needing shared NSS modules at runtime. Harmless
  for IP-based scans. Use `-n` to skip DNS and silence it:

  ```bash
  ./nmap -sS -Pn -n 10.0.0.0/24
  ```

- **Raw sockets still need root** (or `CAP_NET_RAW`) for `-sS`, OS
  detection, etc. Static linking doesn't change Linux capability
  requirements.

- **No zenmap, no ndiff, no nmap-update** — intentionally excluded;
  they pull in Python/GTK and defeat the point of a portable binary.

---

## Rebuilding from scratch

```bash
rm -rf opt/ src/ out/
docker run --name nmap-extract nmap-builder:rocky8
docker cp nmap-extract:/build/out/. ./
docker rm nmap-extract
```

The script caches OpenSSL and PCRE2 builds (checks for
`libssl.a` / `libpcre2-8.a`), so re-runs only rebuild nmap unless you
wipe `opt/`.
