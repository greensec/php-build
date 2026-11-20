#!/usr/bin/env bash
# Build php<BRANCH> packages for Debian <DIST> (designed to run in a
# debian:<DIST> container, but works locally on a matching host too).
#
# Required env:
#   PHP_BRANCH   e.g. 8.2
#   DIST         target suite, e.g. bullseye
# Optional env:
#   SRC_DIST     suite whose sury source package is used as packaging base
#                for "phpnet" branches (default: bookworm - newest suite that
#                still gets sury builds and whose Build-Depends still match
#                bullseye)
#   SURY         sury repo base URL
#   SEC_GIT      php-src-security clone URL
#   OUTDIR       where .debs are placed (default: ./out)
#
# Versioning: phpnet builds reuse sury's upstream+debian revision and append
# "+greensec1~<dist>" so the version sorts above the installed sury build and
# carries the dist marker apt-repo-action's version_by_filename expects.
# security builds get "<upver>-10+greensec~sec<date>~<dist>".

set -euo pipefail

: "${PHP_BRANCH:?missing PHP_BRANCH}" "${DIST:?missing DIST}"
: "${SRC_DIST:=bookworm}"
: "${SURY:=https://packages.sury.org/php}"
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

# --- toolchain + sury repo ----------------------------------------------------
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
cat >/etc/apt/sources.list.d/sury.list <<EOF
deb [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $DIST main
deb-src [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $DIST main
deb-src [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $SRC_DIST main
EOF
apt-get update -qq

cd "$WORKDIR"

# --- fetch + prepare source tree ---------------------------------------------
if [ "$src_type" = phpnet ]; then
    # newest sury source package for SRC_DIST already contains the current
    # upstream tarball - rebuilding it on DIST is the whole job.
    apt-get source --download-only -t "$SRC_DIST" "$PKG"
    dsc=$(ls "${PKG}"_*.dsc | head -n1)
    [ -n "$dsc" ] || { echo "ERROR: no source package for $PKG in $SRC_DIST" >&2; exit 1; }
    dpkg-source -x "$dsc" src
    cd src
    base_ver=$(dpkg-parsechangelog -SVersion)
    up_ver=${base_ver%%-*}
    new_ver="${up_ver}-2+greensec1~${DIST}"
    dch -b -v "$new_ver" "Rebuild of ${SRC_DIST} source ${base_ver} for ${DIST} (greensec php-build)."

else
    # EOL branch: php-src-security checkout + last DIST packaging
    brname=$(git ls-remote --heads "$SEC_GIT" \
        | awk -v b="PHP-${PHP_BRANCH}-" 'tolower($2) ~ "refs/heads/" tolower(b) "security-backports" {sub("refs/heads/", "", $2); print $2; exit}')
    [ -n "${brname:-}" ] || { echo "ERROR: no security-backports branch for $PHP_BRANCH" >&2; exit 1; }
    git clone --depth 50 --single-branch --branch "$brname" "$SEC_GIT" src

    apt-get source --download-only -t "$DIST" "$PKG"
    dsc=$(ls "${PKG}"_*.dsc 2>/dev/null | head -n1)
    if [ -n "$dsc" ]; then
        dpkg-source -x "$dsc" pkgsrc
        cp -a pkgsrc/debian src/debian
        base_ver=$(cd pkgsrc && dpkg-parsechangelog -SVersion)
    else
        echo "ERROR: no DIST source package for $PKG - need packaging base" >&2
        exit 1
    fi
    cd src
    ./buildconf --force
    up_ver=${base_ver%%-*}
    new_ver="${up_ver}-10+greensec~sec$(date +%Y%m%d)~${DIST}"
    dch -b -v "$new_ver" "Rebuild of php-src-security branch ${brname} (base ${base_ver}) for ${DIST} (greensec php-build)."
    # quilt patches were written for the last sury tarball - try to apply;
    # failure is reported verbatim for manual refresh via patches-override/.
    if ! quilt push -a; then
        echo "ERROR: quilt patch(es) failed against $brname - refresh needed (see README)" >&2
        quilt pop -a -f || true
        exit 2
    fi
    if [ -d "$ROOT/patches-override/$PHP_BRANCH" ]; then
        cp "$ROOT/patches-override/$PHP_BRANCH"/* debian/patches/ 2>/dev/null || true
        for p in "$ROOT/patches-override/$PHP_BRANCH"/*.patch; do
            [ -e "$p" ] && grep -qxF "$(basename "$p")" debian/patches/series || true
        done
    fi
fi

# --- build dependencies + build ----------------------------------------------
# resolve deps of the newest stanza (bookworm for phpnet == bullseye's deps).
# NOTE: no -t here - pinning to "bullseye" would prefer base-suite -dev
# packages over the deb11uN security updates apt installs at runtime.
apt-get build-dep -y "$PKG"

cd "$WORKDIR/src"
dpkg-buildpackage -b -us -uc -d "-j$(nproc)"

mkdir -p "$OUTDIR"
mv "$WORKDIR"/*.deb "$OUTDIR/" 2>/dev/null || true
ls -la "$OUTDIR"
echo ">>> done: $PKG $new_ver for $DIST"
