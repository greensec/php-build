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
# EOL dists move to archive.debian.org; the emptied -updates/-backports suites
# must go (404 would break apt-get update). buster still has a useful
# -backports suite (debhelper 13.3.3~bpo10+1 - sury packaging needs compat 13),
# so it gets an explicit archive line instead.
case "$DIST" in
    buster)
        sed -i -e '/buster-updates/d' \
            -e 's|deb\.debian\.org/debian-security|archive.debian.org/debian-security|g' \
            -e 's|deb\.debian\.org/debian|archive.debian.org/debian|g' \
            -e 's|security\.debian\.org/debian-security|archive.debian.org/debian-security|g' \
            /etc/apt/sources.list
        echo "deb http://archive.debian.org/debian buster-backports main" \
            >>/etc/apt/sources.list
        ;;
    bullseye)
        sed -i -e '/bullseye-updates/d' -e '/bullseye-backports/d' \
            -e 's|deb\.debian\.org/debian-security|archive.debian.org/debian-security|g' \
            -e 's|deb\.debian\.org/debian|archive.debian.org/debian|g' \
            -e 's|security\.debian\.org/debian-security|archive.debian.org/debian-security|g' \
            /etc/apt/sources.list
        ;;
esac
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential devscripts quilt dpkg-dev equivs ca-certificates \
    curl xz-utils git gnupg rsync locales-all tzdata ccache
# buster's debhelper 12 cannot satisfy sury's debhelper-compat (= 13);
# buster-backports still ships 13.3.3
if [ "$DIST" = buster ]; then
    apt-get install -y --no-install-recommends -t buster-backports debhelper
fi

# ccache lives inside the checkout so actions/cache can persist it
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-$ROOT/cache/ccache}"
# the build dir is a fresh mktemp every run - keep cache keys independent
# of paths and mtimes
export CCACHE_NOHASHDIR=1 CCACHE_COMPILERCHECK=content
mkdir -p "$CCACHE_DIR"

install -m0755 -d /etc/apt/keyrings
curl -fsSL "$SURY/apt.gpg" -o /etc/apt/keyrings/sury.asc
gpg --dearmor --yes </etc/apt/keyrings/sury.asc >/etc/apt/keyrings/sury.gpg
# the Ubuntu PPA has its own key (classic ondrej key) - fetched over HTTPS
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4F4EA0AAE5267A6C" \
    -o /etc/apt/keyrings/ppa.asc
gpg --dearmor --yes </etc/apt/keyrings/ppa.asc >/etc/apt/keyrings/ppa.gpg
cat >/etc/apt/sources.list.d/sury.list <<EOF
deb-src [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $SRC_DIST main
# the Ubuntu PPA pool keeps the last EOL-branch packaging (php5.6-8.1)
# even where debian dists dropped it
deb-src [signed-by=/etc/apt/keyrings/ppa.gpg] $PPA/ $PPA_SUITE main
EOF
case "$DIST" in
    bullseye)
        # binaries for build-deps: upstream pruned the whole bullseye pool
        # (index intact, every .deb 404s) - the greensec mirror kept the files.
        # buster is skipped: the mirror's buster metadata is empty (NOSPLIT)
        # and upstream never had a buster Release for this repo at all.
        cat >>/etc/apt/sources.list.d/sury.list <<EOF
deb [signed-by=/etc/apt/keyrings/sury.gpg] $SURY_BIN/ $DIST main
# last packaging for EOL branches lives here; pool files are gone upstream,
# so this only works again if sury ever restores them
deb-src [signed-by=/etc/apt/keyrings/sury.gpg] $SURY/ $DIST main
EOF
        ;;
esac

# Freexian Extended LTS carries the only remaining security updates for these
# EOL dists. Build against its patched library variants so runtime deps can
# resolve against the securer packages. The ${DIST}-lts suites are partial
# (security updates only) - the archive lines above still provide the base.
case "$DIST" in
    buster|bullseye)
        curl -fsSL https://deb.freexian.com/extended-lts/archive-key.gpg \
            -o /etc/apt/keyrings/freexian-elts.gpg
        cat >/etc/apt/sources.list.d/freexian-elts.list <<EOF
deb [signed-by=/etc/apt/keyrings/freexian-elts.gpg] https://deb.freexian.com/extended-lts ${DIST}-lts main contrib non-free
EOF
        ;;
esac

# sury backports a few libraries for DIST (pcre2, gd, xml2 - only ones in the
# mirror pool that outrank the distro). Building against them would leak
# Depends: entries (e.g. libpcre2-8-0 >= 10.38) that plain DIST cannot
# satisfy, so pin them to the distro version. Priority 1001 also permits the
# downgrade if they get installed by a build-dep first.
cat >/etc/apt/preferences.d/php-build-distro-libs.pref <<'EOF'
Package: libpcre2-8-0 libpcre2-16-0 libpcre2-32-0 libpcre2-posix2 libpcre2-dev libpcre3 libpcre3-dev libpcre16-3 libpcre32-3 libpcrecpp0v5 libgd3 libgd-dev libxml2 libxml2-dev libxml2-utils
Pin: release o=Debian
Pin-Priority: 1001

# Freexian continues the distro version lineage with security fixes; same
# priority so the higher (patched) version wins over the frozen archive.
Package: libpcre2-8-0 libpcre2-16-0 libpcre2-32-0 libpcre2-posix2 libpcre2-dev libpcre3 libpcre3-dev libpcre16-3 libpcre32-3 libpcrecpp0v5 libgd3 libgd-dev libxml2 libxml2-dev libxml2-utils
Pin: release o=Freexian
Pin-Priority: 1001
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

    # the security branch is a git checkout - generated files (bison parsers,
    # ...) only exist in release tarballs and sury's patches target them.
    # Overlay the checkout onto the matching release tarball: tracked files
    # come from git, generated files from the tarball.
    base_ver=$(dpkg-parsechangelog -lpkgsrc/debian/changelog -SVersion | sed 's/.*://; s/-.*//')
    upball=$(ls "${PKG}"_"${base_ver}".orig.tar.* 2>/dev/null | head -n1 || true)
    if [ -z "$upball" ]; then
        upball="php-${base_ver}.tar.xz"
        curl -fsSL -o "$upball" "https://www.php.net/distributions/$upball" \
            || curl -fsSL -o "$upball" "https://museum.php.net/php${PHP_BRANCH%%.*}/$upball"
    fi
    tar -xaf "$upball"
    rsync -a --exclude=.git "sec-src/" "php-${base_ver}/"
    mv "php-${base_ver}" sec-src.new && rm -rf sec-src && mv sec-src.new sec-src

    cp -a pkgsrc/debian sec-src/debian
    cd sec-src
    ./buildconf --force
    # quilt defaults to ./patches - debian keeps them in debian/patches
    export QUILT_PATCHES=debian/patches
    # patches/<pkg>/pre.d/*.patch are applied with fuzz tolerance before the
    # quilt loop - for big patches whose context drifted (openssl 1.1 compat
    # on 5.6). The series twin is then dropped by the already-in-tree check.
    if [ -d "$ROOT/patches/$PKG/pre.d" ]; then
        for pp in "$ROOT/patches/$PKG/pre.d"/*.patch; do
            [ -e "$pp" ] || continue
            echo ">>> pre-applying $(basename "$pp")"
            patch -p1 --fuzz=3 -f < "$pp"
            find . -name '*.rej' -delete 2>/dev/null || true
            find . -name '*.orig' -delete 2>/dev/null || true
        done
    fi
    # patches/<pkg>/series.drops lists series entries to remove before
    # pushing - for patches that still apply but duplicate code already in
    # the backports tree (e.g. 0197-backport-zend_string_efree on 7.1)
    if [ -f "$ROOT/patches/$PKG/series.drops" ]; then
        while read -r dp; do
            [ -n "$dp" ] || continue
            sed -i "/^${dp//\//\\/}\([[:space:]]\|\$\)/d" debian/patches/series
            echo ">>> series.drops: removed $dp"
        done < "$ROOT/patches/$PKG/series.drops"
    fi
    # quilt patches were written for the last sury tarball; the security
    # branch already carries most upstream fixes as commits, so entries that
    # fail are duplicates applied with different context. Skip them (with a
    # printed list for audit) instead of dying - a dropped debian-specific
    # patch would show up later as a build/packaging failure anyway.
    dropped=""
    while :; do
        nxt=$(quilt next 2>/dev/null) || break
        [ -n "$nxt" ] || break
        bn=$(basename "$nxt")
        # already-in-tree check first: reverse-appliable means the content is
        # present and pushing would silently duplicate code (e.g. redefining
        # zend_string_efree on 7.1)
        if patch -R -p1 --dry-run -f -s < "debian/patches/$bn" >/dev/null 2>&1; then
            sed -i "/^${bn//\//\\/}\([[:space:]]\|\$\)/d" debian/patches/series
            dropped="$dropped $bn"
            continue
        fi
        quilt push >/dev/null 2>&1 && continue
        # a failed push may leave the patch half-applied as top - force-pop it
        if [ "$(basename "$(quilt top 2>/dev/null)")" = "$bn" ]; then
            quilt pop -f >/dev/null 2>&1 || true
        fi
        find . -name '*.rej' -delete 2>/dev/null || true
        sed -i "/^${bn//\//\\/}\([[:space:]]\|\$\)/d" debian/patches/series
        dropped="$dropped $bn"
    done
    if [ -n "$dropped" ]; then
        echo ">>> quilt entries skipped (already in $brname or inapplicable):"
        printf '    %s\n' $dropped
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
# the unmet list is space-separated; "a | b" is one dep with alternatives.
# Rebuild dep groups across whitespace tokens, then pick the first
# alternative that has an install candidate on THIS dist (e.g.
# libenchant-2-dev exists on bullseye+ but not buster).
missing=$(printf '%s\n' "$missing" | sed -n 's/.*[Uu]nmet build dependencies: //p' \
    | sed -e 's/([^)]*)//g; s/\[[^]]*\]//g; s/<[^>]*>//g; s/:[a-z0-9-]*//g' \
        -e 's/\bdebhelper-compat\b/debhelper/g' \
    | tr ' ,' '\n' | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e '/^$/d' \
    | awk 'NR==1 { g=$0; next }
           $0=="|" { g=g" | "; getline; g=g $0; next }
           { print g; g=$0 }
           END { print g }' \
    | while IFS= read -r grp; do
        for cand in $(printf '%s' "$grp" | tr '|' '\n' | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' -e '/^$/d'); do
            if apt-cache policy "$cand" 2>/dev/null | awk '/Candidate:/{e=($2!="(none)")} END{exit !e}'; then
                printf '%s\n' "$cand"
                break
            fi
            # pure virtual (no candidate of its own): resolve a provider
            prov=$(apt-cache showpkg "$cand" 2>/dev/null \
                | awk '/^Reverse Provides:/{p=1;next} p&&NF{print $1}' \
                | while read -r pr; do
                    apt-cache policy "$pr" 2>/dev/null | awk '/Candidate:/{e=($2!="(none)")} END{exit !e}' \
                        && { echo "$pr"; break; }
                  done)
            if [ -n "$prov" ]; then
                printf '%s\n' "$prov"
                break
            fi
        done
      done | sort -u)
if [ -n "${missing}" ]; then
    echo ">>> installing build-deps: $(echo "$missing" | wc -l) packages"
    apt-get -y install --no-install-recommends $missing
    dpkg-checkbuilddeps   # fail loudly if anything is still unmet
fi

# per-package or generic prepare hook (runs inside the source tree)
for hook in "$ROOT/prepare/$PKG.sh" "$ROOT/prepare/all.sh"; do
    if [ -e "$hook" ]; then
        echo ">>> running prepare hook $(basename "$hook")"
        cp "$hook" debian/prepare.sh
        bash ./debian/prepare.sh
        break
    fi
done

# repo-local patches appended to the quilt series (only *.patch files -
# pre.d/ and series.drops are consumed earlier)
if [ -d "$ROOT/patches/$PKG" ]; then
    appended=""
    for x in "$ROOT/patches/$PKG"/*.patch; do
        [ -e "$x" ] || continue
        case "$(basename "$x")" in
            legacy_*) [ -d "$ROOT/debian.$DIST" ] || continue ;;
        esac
        echo ">>> adding patch $(basename "$x")"
        mkdir -p debian/patches
        cp "$x" debian/patches/
        basename "$x" >> debian/patches/series
        appended=1
    done
    # apply the appended entries - appending to the series alone leaves
    # them unapplied, so they would ship in the .dsc but not compile.
    # quilt push -a exits 2 when nothing is left to push, hence the guard.
    if [ -n "$appended" ]; then
        export QUILT_PATCHES=debian/patches
        quilt push -a
    fi
fi

# --- changelog + build ---------------------------------------------------------
base_ver=$(dpkg-parsechangelog -SVersion)
up_ver=${base_ver%%-*}
rev=${base_ver#*-}
rev_num=${rev%%[^0-9]*}
# BUILD_ID keeps rebuilt versions unique - the publisher dedupes by
# version+filename, so rebuilding the same upstream needs a bump anyway
new_ver="${up_ver}-$((10#${rev_num:-0}*1000+1))~${DIST}${BUILD_ID:-1}"
dch -b -v "$new_ver" "Rebuild of ${base_ver} for ${DIST} (greensec php-build)."

# -g would only be stripped again by dh_strip (noautodbgsym) - compiling
# without it is ~10-15% faster and produces identical .debs
export DEB_CFLAGS_STRIP="-g -g3 -ggdb" DEB_CXXFLAGS_STRIP="-g -g3 -ggdb"
DEB_BUILD_OPTIONS="noautodbgsym nocheck nodocs" \
    dpkg-buildpackage -j"$(nproc)" -d -us -uc -b

# --- php-defaults metapackage -------------------------------------------------
# the packaging Depends on php-common (>= 2:95~) which no target dist ships
# (buster has 2:69, bullseye 2:76) - rebuild sury's php-defaults per DIST so
# the repo is self-contained. It produces php-common + the php-* metas, all
# arch=all, in seconds. Static ~DIST version: identical across branch builds,
# so the publisher's skip_duplicates keeps the first copy.
echo ">>> building php-defaults for $DIST"
mkdir -p "$WORKDIR/defaults"
cd "$WORKDIR/defaults"
apt-get source "php-defaults/${SRC_DIST}"
cd php-defaults-*/
dch -b -l "~${DIST}" "Rebuild for ${DIST} (greensec php-build)."
dpkg-buildpackage -b -d -us -uc
cd "$WORKDIR"

mkdir -p "$OUTDIR"
mv "$WORKDIR"/*.deb "$WORKDIR/defaults/"*.deb "$OUTDIR/" 2>/dev/null || true
ls -la "$OUTDIR"
echo ">>> done: $PKG $new_ver for $DIST"
