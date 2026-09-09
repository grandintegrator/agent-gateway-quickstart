#!/usr/bin/env bash
# External data source: tar.gz one directory (relative to a root) and return it
# base64-encoded, plus a short digest so code changes show up in a plan.
# Usage (from Terraform): tar_b64.sh <root> <dir>
set -euo pipefail
root="$1"; dir="$2"
tmp="$(mktemp)"
tar -C "$root" --exclude='__pycache__' --exclude='*.pyc' --sort=name --mtime='2000-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$tmp" "$dir"
sha="$(sha256sum "$tmp" | cut -c1-16)"
printf '{"b64":"%s","sha":"%s"}' "$(base64 -w0 "$tmp")" "$sha"
rm -f "$tmp"
