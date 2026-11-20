#!/bin/sh
# Adds the greensec php-build apt repository.
# Currently ships bullseye (amd64) PHP packages rebuilt from sury sources.

set -eu

if [ "$(id -u)" -ne 0 ]; then
    SUDO=sudo
else
    SUDO=
fi

if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    CODENAME="${VERSION_CODENAME:-}"
else
    DISTRO_ID=
    CODENAME=
fi

case "${DISTRO_ID}:${CODENAME}" in
    debian:bullseye)
        ;;
    *)
        echo "Unsupported distribution: ${DISTRO_ID}:${CODENAME}"
        echo "This repository currently only ships debian:bullseye (amd64)."
        exit 1
        ;;
esac

KEYRING=/usr/share/keyrings/greensec-php-build.key
SOURCE_NAME=greensec-php-build

${SUDO} apt-get update
${SUDO} apt-get -y install ca-certificates wget
${SUDO} wget -O "${KEYRING}" https://greensec.github.io/php-build/public.key

if [ -f "/etc/apt/sources.list.d/${DISTRO_ID}.sources" ]; then
    ${SUDO} rm -f "/etc/apt/sources.list.d/${SOURCE_NAME}.list"
    ${SUDO} tee "/etc/apt/sources.list.d/${SOURCE_NAME}.sources" >/dev/null <<EOF
Types: deb
URIs: https://greensec.github.io/php-build/repo
Suites: ${CODENAME}
Components: main
Signed-By: ${KEYRING}
Architectures: amd64
EOF
else
    ${SUDO} rm -f "/etc/apt/sources.list.d/${SOURCE_NAME}.sources"
    ${SUDO} tee "/etc/apt/sources.list.d/${SOURCE_NAME}.list" >/dev/null <<EOF
deb [signed-by=${KEYRING} arch=amd64] https://greensec.github.io/php-build/repo ${CODENAME} main
EOF
fi

${SUDO} apt-get update
