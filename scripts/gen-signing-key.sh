#!/usr/bin/env bash
# Generate the apt repo signing keypair for this repo.
# Writes .secret/apt-signing.key (private - NEVER commit) and public.key.
# Uploads them to GitHub as secret APT_SIGNING_KEY + variable APT_PUBLIC_KEY.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .secret

if [ -f .secret/apt-signing.key ]; then
    echo "key already exists at .secret/apt-signing.key - refusing to overwrite" >&2
    exit 1
fi

cat >.secret/gen-key.batch <<'EOF'
Key-Type: RSA
Key-Length: 4096
Name-Real: greensec php-build repository
Name-Email: php-build@greensec.de
Expire-Date: 0
%no-protection
%commit
EOF

gpg --batch --gen-key .secret/gen-key.batch
rm -f .secret/gen-key.batch

fp=$(gpg --batch --with-colons --list-keys php-build@greensec.de | awk -F: '/^fpr/{print $10; exit}')
[ -n "$fp" ] || { echo "key generation failed" >&2; exit 1; }

gpg --armor --export "$fp" > public.key
gpg --armor --export-secret-keys "$fp" > .secret/apt-signing.key
chmod 600 .secret/apt-signing.key

echo "generated signing key: $fp"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "greensec/php-build")
    gh secret set APT_SIGNING_KEY --repo "$repo" < .secret/apt-signing.key
    gh variable set APT_PUBLIC_KEY --repo "$repo" < public.key
    echo "uploaded APT_SIGNING_KEY secret + APT_PUBLIC_KEY variable to $repo"
else
    echo "gh not available - set these manually on the repo:"
    echo "  secret  APT_SIGNING_KEY  <- .secret/apt-signing.key"
    echo "  variable APT_PUBLIC_KEY  <- public.key"
fi
