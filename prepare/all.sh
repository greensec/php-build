#!/usr/bin/env bash
# Prepare hook - runs inside the extracted source tree before the build.
#
# sury's debian/rules builds all SAPI variants (ext apache2 phpdbg embed
# fpm litespeed cgi cli) one after another inside single make recipes:
#
#   for target in $(TARGETS); do \
#       dh_auto_build --builddirectory $${target}-build $(PARALLEL); \
#   done
#
# The variants are independent build dirs, so they can run concurrently -
# same produced .debs, just scheduled together (~4-6x faster compile).
# The rewrite below is a no-op when upstream restructures the recipe.

set -euo pipefail

rules=debian/rules
[ -f "$rules" ] || exit 0

perl -0pi -e '
my $rep = sub {
  my ($indent, $line) = @_;
  $line =~ s/;\s*$//;
  return "pids=\x27\x27; for target in \$(TARGETS); do \\\n$indent$line \& pids=\"\$\$pids \$\$!\"; \\\n${indent}done; rc=0; for p in \$\$pids; do wait \$\$p || rc=\$\$?; done; exit \$\$rc";
};
s/for target in \$\(TARGETS\); do \\\n([\t ]+)dh_auto_build --builddirectory \$\$\{target\}-build \$\(PARALLEL\); \\\n[\t ]+done/$rep->($1, "dh_auto_build --builddirectory \$\$\{target\}-build -- -j\$\$(( \$\$(nproc) \/ \$\(words \$(TARGETS)\) ))")/ge;
s/for target in \$\(TARGETS\); do \\\n([\t ]+)dh_auto_configure --builddirectory \$\$\{target\}-build \$\(PARALLEL\)([^\n]*) \\\n[\t ]+done/$rep->($1, "dh_auto_configure --builddirectory \$\$\{target\}-build \$\(PARALLEL\)$2")/ge;
' "$rules"

grep -q 'pids=' "$rules" && echo "parallelized per-variant build loops in debian/rules"
