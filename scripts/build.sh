#!/usr/bin/env bash
# Build php<BRANCH> packages for Debian <DIST> (runs in a debian:<DIST>
# container in CI; works locally on a matching host too).
#
# Required env:
#   PHP_BRANCH   e.g. 8.2
#   DIST         target suite, e.g. bullseye
# Optional env:
#   SRC_DIST     suite whose sury source package provides packaging+upstream
#                tarball for "phpnet" branches (default: bookworm - the
#                newest suite still getting sury builds; its Build-Depends
#                still match bullseye)
#   SURY         live sury repo base (source packages)
#   SURY_BIN     repo used for binary build-deps (default: greensec mirror -
#                upstream deleted the whole bullseye pool, index 404s)
#   SEC_GIT      php-src-security clone URL
#   OUTDIR       .deb output dir (default: ./out)
#
# Versioning: <upstream>-<rev*1000+1>~<dist>1 - deterministic, sorts above
# the sury builds the hosts have installed, and carries the dist marker
# apt-repo-action's version_by_filename expects in the .deb filename.

set -euo pipefail

: "${PHP_BRANCH:?missing PHP_BRANCH}" "${DIST:?missing DIST}"
: "${SRC_DIST:=bookworm}"
: "${PPA_SUITE:=jammy}"
: "${PPA:=https://ppa.launchpadcontent.net/ondrej/php/ubuntu}"
: "${SURY:=https://packages.sury.org/php}"
: "${SURY_BIN:=https://mirror.greensec.de/packages.sury.org/php}"
: "${SEC_GIT:=https://github.com/remicollet/php-src-security.git}"
: "${OUTDIR:=$PWD/out}"

PKG="php${PHP_BRANCH}"
export DEBEMAIL="packages@greensec.de"
export DEBFULLNAME="greensec php-build"
export DEBIAN_FRONTEND=noninteractive

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPTDIR")
WORKDIR=$(mktemp -d /tmp/phpbuild.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

src_type=$(awk -v b="$PHP_BRANCH" '$1 !~ /^#/ && $1 == b {print $2}' "$ROOT/conf/branches.map")
if [ -z "${src_type:-}" ]; then
    echo "ERROR: no branch mapping for $PHP_BRANCH in conf/branches.map" >&2
    exit 1
fi
echo ">>> building $PKG for $DIST (source type: $src_type, packaging base: $SRC_DIST)"

# --- toolchain + repos --------------------------------------------------------
# bullseye is EOL - the main mirrors dropped it, move to archive.debian.org
# and drop the emptied -updates/-backports suites.
if [ "$DIST" = bullseye ]; then
    sed -i -e '/bullseye-updates/d' -e '/bullseye-backports/d' \
        -e 's|deb\.debian\.org/debian-security|archive.debian.org/debian-security|g' \
        -e 's|deb\.debian\.org/debian|archive.debian.org/debian|g' \
        -e 's|security\.debian\.org/debian-security|archive.debian.org/debian-security|g' \
        /etc/apt/sources.list
fi
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential devscripts quilt dpkg-dev equivs ca-certificates \
    curl xz-utils git gnupg rsync locales-all tzdata

install -m0755 -d /etc/apt/keyrings
curl -fsSL "$SURY/apt.gpg" -o /etc/apt/keyrings/sury.asc
gpg --dearmor --yes </etc/apt/keyrings/sury.asc >/etc/apt/keyrings/sury.gpg
# the Ubuntu PPA has its own key (classic ondrej key) - fetched over HTTPS
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4F4EA0AAE5267A6C" \
    -o /etc/apt/keyrings/ppa.asc
gpg --dearmor --yes </etc/apt/keyrings/ppa.asc >/etc/apt/keyrings/ppa.gpg
cat >/etc/apt/sources.list.d/sury.list <<EOF
# binaries for build-deps: upstream pruned the whole bullseye pool
# (index intact, every .deb 404s) - the greensec mirror kept the files
deb [signed-by=/etc/apt/keyrings/sury.gpg] $SURY_BIN/ $DIST main
deb-src [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $SRC_DIST main
# the Ubuntu PPA pool keeps the last EOL-branch packaging (php5.6-8.1)
# even where debian dists dropped it
deb-src [signed-by=/etc/apt/keyrings/ppa.gpg] $PPA/ $PPA_SUITE main
# last packaging for EOL branches lives here; pool files are gone upstream,
# so this only works again if sury ever restores them
deb-src [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $DIST main
EOF
apt-get update -qq

cd "$WORKDIR"

# --- fetch + prepare source tree ---------------------------------------------
fetch_src() { # suite -> extracted ./src
    local suite=$1
    rm -rf src pkgsrc "${PKG}"_*.dsc "${PKG}"_*.tar.* 2>/dev/null || true
    # pkg/suite syntax, not -t: -t validates against binary lists and we only
    # carry deb-src for these suites.
    apt-get source --download-only "${PKG}/${suite}"
    local dsc
    dsc=$(ls "${PKG}"_*.dsc 2>/dev/null | head -n1 || true)
    [ -n "$dsc" ] || { echo "ERROR: no source package for $PKG in $suite" >&2; exit 1; }
    dpkg-source -x "$dsc" src
}

if [ "$src_type" = phpnet ]; then
    # newest sury source for SRC_DIST already contains the current upstream
    # tarball - rebuilding it on DIST is the whole job.
    fetch_src "$SRC_DIST"
    cd src

else
    # EOL branch: php-src-security checkout + last available packaging
    brname=$(git ls-remote --heads "$SEC_GIT" \
        | awk -v b="PHP-${PHP_BRANCH}-" 'tolower($2) ~ "refs/heads/" tolower(b) "security-backports" {sub("refs/heads/", "", $2); print $2; exit}')
    [ -n "${brname:-}" ] || { echo "ERROR: no security-backports branch for $PHP_BRANCH" >&2; exit 1; }
    git clone --depth 50 --single-branch --branch "$brname" "$SEC_GIT" sec-src

    # packaging base: newest-first - SRC_DIST, then the Ubuntu PPA (keeps
    # EOL packaging forever), then the frozen $DIST suite
    got_src=""
    for suite in "$SRC_DIST" "$PPA_SUITE" "$DIST"; do
        rm -f "${PKG}"_*.dsc "${PKG}"_*.tar.* 2>/dev/null || true
        if apt-get source --download-only "${PKG}/${suite}" 2>/dev/null \
            && compgen -G "${PKG}_*.dsc" >/dev/null; then
            got_src=$suite
            break
        fi
    done
    [ -n "$got_src" ] || { echo "ERROR: no source packaging for $PKG in $SRC_DIST, $PPA_SUITE or $DIST" >&2; exit 1; }
    echo ">>> using $PKG packaging from $got_src"
    dsc=$(ls "${PKG}"_*.dsc 2>/dev/null | head -n1 || true)
    dpkg-source -x "$dsc" pkgsrc
    cp -a pkgsrc/debian sec-src/debian
    cd sec-src
    ./buildconf --force
    # quilt patches were written for the last sury tarball - apply; failure is
    # reported verbatim for manual refresh via patches/$PKG/
    if ! quilt push -a; then
        echo "ERROR: quilt patch(es) failed against $brname - refresh needed (see README)" >&2
        quilt pop -a -f || true
        exit 2
    fi
    # dpkg-source -b needs an orig tarball; build one from the checked-out tree
    up_ver=$(dpkg-parsechangelog -SVersion | sed 's/-.*//')
    tar -cJf "../${PKG}_${up_ver}.orig.tar.xz" --exclude=debian --exclude=.pc --exclude-vcs .
fi

# optional dedicated packaging overlay for this distro (debian.<dist>/)
if [ -d "$ROOT/debian.$DIST" ]; then
    echo ">>> using packaging overlay debian.$DIST"
    mv debian debian.upstream
    cp -a "$ROOT/debian.$DIST" debian
    mkdir -p debian/patches
    cp -a debian.upstream/patches/. debian/patches/ 2>/dev/null || true
    rm -rf debian.upstream
fi

# --- build dependencies from our own control file -----------------------------
# (no apt-get build-dep - it resolves against the newest index stanza and its
# pinning quirks; dpkg-checkbuilddeps reads THIS debian/control)
# dpkg-checkbuilddeps exits 1 whenever something is unmet - that is the
# expected case here, so keep it out of pipefail's reach.
missing=$(dpkg-checkbuilddeps 2>&1 || true)
missing=$(printf '%s\n' "$missing" | sed -n 's/.*[Uu]nmet build dependencies: //p' \
    | sed -e 's/([^)]*)//g; s/\[[^]]*\]//g; s/<[^>]*>//g; s/ *| *[^ ]*//g' \
        -e 's/\bdebhelper-compat\b/debhelper/g' \
    | tr ' ,' '\n' | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e '/^$/d' | sort -u)
if [ -n "${missing}" ]; then
    echo ">>> installing build-deps: $(echo "$missing" | wc -l) packages"
    apt-get -y install --no-install-recommends $missing
    dpkg-checkbuilddeps   # fail loudly if anything is still unmet
fi

# repo-local patches appended to the quilt series
if [ -d "$ROOT/patches/$PKG" ]; then
    for x in "$ROOT/patches/$PKG"/*; do
        [ -e "$x" ] || continue
        case "$(basename "$x")" in
            legacy_*) [ -d "$ROOT/debian.$DIST" ] || continue ;;
        esac
        echo ">>> adding patch $(basename "$x")"
        mkdir -p debian/patches
        cp "$x" debian/patches/
        basename "$x" >> debian/patches/series
    done
fi

# --- changelog + build ---------------------------------------------------------
base_ver=$(dpkg-parsechangelog -SVersion)
up_ver=${base_ver%%-*}
rev=${base_ver#*-}
rev_num=${rev%%[^0-9]*}
new_ver="${up_ver}-$((10#${rev_num:-0}*1000+1))~${DIST}1"
dch -b -v "$new_ver" "Rebuild of ${base_ver} for ${DIST} (greensec php-build)."

DEB_BUILD_OPTIONS="noautodbgsym nocheck nodocs" \
    dpkg-buildpackage -j"$(nproc)" -d -us -uc -b

mkdir -p "$OUTDIR"
mv "$WORKDIR"/*.deb "$OUTDIR/" 2>/dev/null || true
ls -la "$OUTDIR"
echo ">>> done: $PKG $new_ver for $DIST"
