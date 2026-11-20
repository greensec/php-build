# php-build

PHP packages for suites [sury](https://packages.sury.org/php/) stopped
building (currently: **Debian buster + bullseye, amd64**), published as
an apt repository via GitHub Pages:

```
deb [signed-by=/usr/share/keyrings/greensec-php-build.key arch=amd64] \
    https://greensec.github.io/php-build/repo bullseye main
```

`./add-repository.sh` on a host wires it up (or let the ansible
`repositories` role manage it).

## Freexian Extended LTS required

Both dists are EOL - Debian publishes no more security updates for them.
Our builds link against the libraries from
[Freexian Extended LTS](https://www.freexian.com/lts/extended/) (`o=Freexian`
variants take precedence over the frozen archive ones), so hosts **must
have the ELTS repo configured** to satisfy runtime dependencies and keep
receiving base-system fixes:

```
wget -O /usr/share/keyrings/freexian-elts.gpg \
    https://deb.freexian.com/extended-lts/archive-key.gpg
echo "deb [signed-by=/usr/share/keyrings/freexian-elts.gpg] \
    https://deb.freexian.com/extended-lts $(. /etc/os-release; echo "$VERSION_CODENAME")-lts \
    main contrib non-free" >/etc/apt/sources.list.d/freexian-elts.list
```

`./add-repository.sh` sets this up automatically alongside our repo.

## How it works

Two source strategies per branch (`conf/branches.map`):

| type | branches | source |
|---|---|---|
| `phpnet` | 8.2-8.6 | sury's newest `SRC_DIST` (bookworm) **source** package - it already contains the current php.net tarball plus packaging; rebuilt unmodified for `$DIST` |
| `security` | 5.6-8.1 | [remicollet/php-src-security](https://github.com/remicollet/php-src-security) `PHP-<b>-security-backports` checkout (`buildconf` bootstrap) + newest available packaging (`SRC_DIST` → ondrej Ubuntu PPA `PPA_SUITE` → frozen `$DIST`) |

Packages are versioned `<upstream>-<rev*1000+1>~<dist>1` - above any sury
build hosts have installed - and carry the dist marker the publisher
(`version_by_filename`) needs.

Build-deps come from `dpkg-checkbuilddeps` on the extracted source's own
`debian/control` (not `apt-get build-dep`). Bullseye binaries can't come
from sury upstream - the whole bullseye pool was deleted (index intact,
every `.deb` 404s) - so `SURY_BIN` defaults to the greensec mirror,
which still serves the last builds.

## Building

GitHub Actions → `build php packages` → pick branch + dist, tick
`release` to publish to gh-pages. Choosing `all` fans out to one matrix
job per `phpnet` branch from `conf/branches.map` (serialized on the
runner). Artifact-only runs leave the .debs as a workflow artifact.

Locally:

```sh
docker build -f docker/Dockerfile.bullseye -t php-build-bullseye .
docker run --rm -v "$PWD:/php-build" -e PHP_BRANCH=8.2 -e DIST=bullseye php-build-bullseye
# (docker/Dockerfile.buster + DIST=buster for buster)
# or directly on a matching host:
PHP_BRANCH=8.2 DIST=bullseye ./scripts/build.sh
```

`check-upstream.sh` (daily cron workflow) fails when php.net ships a
newer release than the repo carries for any `phpnet` branch.

## Patches and packaging overlays

- `patches/<pkg>/*.patch` - appended to `debian/patches/series` of the
  fetched source before building (`legacy_*` files only apply when a
  distro overlay is in use).
- `debian.<dist>/` - when present, replaces the source's `debian/`
  wholesale; upstream quilt patches are carried over.

`security` builds apply sury's last `debian/` onto the backport tree. If
`debian/patches` stop applying, `build.sh` aborts (exit 2) with the
failing patch - refresh it and add a fixed copy under `patches/<pkg>/`.

`patches/php<ver>/pr<N>-*.patch` files are upstream PRs from
remicollet/php-src-security carried locally until they merge
(currently: php5.6 PR31 PHP2Shell backport, php7.2 PR44 and php7.3 PR43
backport fixes). Remove each once the corresponding PR lands upstream.

## Repo signing

`scripts/gen-signing-key.sh` creates a dedicated keypair, stores the
private half in gitignored `.secret/`, exports `public.key` and (with
`gh` auth) uploads `secrets.APT_SIGNING_KEY` + `vars.APT_PUBLIC_KEY`.
The action publishes `public.key` + `repo/` onto the `gh-pages` branch -
enable Pages (source: `gh-pages`, `/`) once after the first publish.
