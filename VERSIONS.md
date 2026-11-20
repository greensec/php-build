# Published versions

Repo: `https://greensec.github.io/php-build/repo` - suites `bullseye` +
`buster`, arch `amd64`, component `main`. Both dists are EOL: hosts must
also have the Freexian Extended LTS repo configured (`<dist>-lts` on
`deb.freexian.com/extended-lts`) - it is the only remaining source of
base-system security fixes and our builds link against its libraries.

## phpnet branches (rebuilt sury security releases)

### bullseye

| branch | version | built | fixes |
|---|---|---|---|
| 8.5 | 8.5.13-2001~bullseye1 | 2026-11-20 | 16 CVEs: RCE, PHP-FPM privilege escalation, request smuggling, signature bypass, information disclosure, DoS |
| 8.4 | 8.4.28-2001~bullseye1 | 2026-11-20 | same synchronized security batch |
| 8.3 | 8.3.37-2001~bullseye1 | 2026-11-20 | same synchronized security batch |
| 8.2 | 8.2.36-2001~bullseye20 | 2026-11-20 | same synchronized security batch |
| 8.1 | 8.1.34-14001~bullseye37 | 2026-11-20 | sury bookworm source already carries Remi's 8.1.34 security backports |

### buster

| branch | version | built | fixes |
|---|---|---|---|
| 8.6 | 8.6.0-2001~buster39 | 2026-11-20 | current upstream |
| 8.5 | 8.5.13-2001~buster39 | 2026-11-20 | 16 CVEs: RCE, PHP-FPM privilege escalation, request smuggling, signature bypass, information disclosure, DoS |
| 8.4 | 8.4.28-2001~buster39 | 2026-11-20 | same synchronized security batch |
| 8.3 | 8.3.37-2001~buster39 | 2026-11-20 | same synchronized security batch |
| 8.2 | 8.2.36-2001~buster39 | 2026-11-20 | same synchronized security batch |
| 8.1 | 8.1.34-14001~buster39 | 2026-11-20 | sury bookworm source already carries Remi's 8.1.34 security backports |

Both suites also publish `php-common` + the `php-*` metapackages from a
per-dist rebuild of sury's `php-defaults` (needed for `php-common >= 2:95~`
which no EOL dist ships).

Versions above sury's last bullseye builds (8.2.35 / 8.3.36 / 8.4.27 /
8.5.12, frozen 2026-10-21), so apt upgrades to them.

## security branches (EOL, php-src-security backports)

`conf/branches.map` maps 5.6, 7.0-7.4, 8.0 to the `security`
strategy (remicollet/php-src-security + last sury packaging). The `all`
matrix only covers `phpnet` branches; security builds run individually
via `workflow_dispatch`.

### security builds

| branch | suite | version | built | notes |
|---|---|---|---|---|
| 8.0 | bullseye | 1:8.0.30-31001~bullseye45 | 2026-11-20 | 8.0.30 + all Remi backports through GHSA-jm4m (FPM stdio fd); sury quilt series reduced to the ~89 packaging patches - upstream-fix entries already in the backports tree are skipped at build time |
| 7.4 | bullseye | 1:7.4.33-37001~bullseye46 | 2026-11-20 | 7.4.33 + Remi backports; ~100 duplicate quilt entries skipped |
| 7.3 | bullseye | 7.3.33-41001~bullseye47 | 2026-11-20 | 7.3.33 + Remi backports |
| 7.2 | bullseye | 7.2.34-71001~bullseye56 | 2026-11-20 | 7.2.34 + Remi backports |
| 7.1 | bullseye | 7.1.33-86001~bullseye53 | 2026-11-20 | 7.1.33 + Remi backports |
| 7.0 | bullseye | 7.0.33-98001~bullseye64 | 2026-11-20 | 7.0.33 + Remi backports; rebuilt against distro libpcre3 8.39 |
| 5.6 | bullseye | 5.6.40-110001~bullseye63 | 2026-11-20 | 5.6.40 + Remi backports; pre.d fuzz-patches for OpenSSL 1.1 compat + php2shell backport; rebuilt against distro libpcre3 8.39 |

## Version scheme

`<upstream>-<sury-revision*1000+1>~<dist><BUILD_ID>` where `BUILD_ID` is
the GitHub run number - rebuilt versions stay monotonic and unique for
the publisher's dedupe.
