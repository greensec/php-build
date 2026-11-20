# php-build

PHP packages for suites [sury](https://packages.sury.org/php/) stopped
building (currently: **Debian bullseye, amd64**), published as an apt
repository via GitHub Pages:

```
deb [signed-by=/usr/share/keyrings/greensec-php-build.key arch=amd64] \
    https://greensec.github.io/php-build/repo bullseye main
```

`./add-repository.sh` on a host wires it up (or let the ansible
`repositories` role manage it).

## How it works

Two source strategies per branch (`conf/branches.map`):

| type | branches | source |
|---|---|---|
| `phpnet` | 8.2-8.6 | sury's newest `SRC_DIST` (bookworm) **source** package - it already contains the current php.net tarball plus packaging; rebuilt unmodified for `$DIST` with a `+greensec1~<dist>` changelog suffix |
| `security` | 5.6-8.1 | [remicollet/php-src-security](https://github.com/remicollet/php-src-security) `PHP-<b>-security-backports` checkout (`buildconf` bootstrap) + last sury `$DIST` packaging |

Versioning sorts above the last sury bullseye builds, so hosts pick the
packages up as plain upgrades once the repo is added.

## Building

GitHub Actions → `build php packages` → pick branch + dist, tick
`release` to publish to gh-pages. Artifact-only runs leave the .debs as
a workflow artifact.

Locally:

```sh
docker build -f docker/Dockerfile.bullseye -t php-build-bullseye .
docker run --rm -v "$PWD:/php-build" -e PHP_BRANCH=8.2 -e DIST=bullseye php-build-bullseye
# or directly on a bullseye host:
PHP_BRANCH=8.2 DIST=bullseye ./scripts/build.sh
```

`check-upstream.sh` (daily cron workflow) fails when php.net ships a
newer release than the repo carries for any `phpnet` branch.

## Repo signing

`scripts/gen-signing-key.sh` creates a dedicated keypair, stores the
private half in gitignored `.secret/`, exports `public.key` and (with
`gh` auth) uploads `secrets.APT_SIGNING_KEY` + `vars.APT_PUBLIC_KEY`.
The action publishes `public.key` + `repo/` onto the `gh-pages` branch -
enable Pages (source: `gh-pages`, `/`) once after the first publish.

## EOL branches and patch refreshes

`security` builds apply sury's last `$DIST` `debian/` onto the backport
tree. If `debian/patches` stop applying, `build.sh` aborts and prints the
failing patch - refresh it and drop overrides into
`patches-override/<branch>/`.
