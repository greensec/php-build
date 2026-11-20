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
| 8.1-8.6 | build in progress | - | matrix run publishing |

Versions above sury's last bullseye builds (8.2.35 / 8.3.36 / 8.4.27 /
8.5.12, frozen 2026-10-21), so apt upgrades to them.

## security branches (EOL, php-src-security backports)

`conf/branches.map` maps 5.6, 7.0-7.4, 8.0 to the `security`
strategy (remicollet/php-src-security + last sury packaging). Not built
or published yet - build individually via `workflow_dispatch` once
needed. The `all` matrix only covers `phpnet` branches.

## Version scheme

`<upstream>-<sury-revision*1000+1>~<dist><BUILD_ID>` where `BUILD_ID` is
the GitHub run number - rebuilt versions stay monotonic and unique for
the publisher's dedupe.
