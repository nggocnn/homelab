#!/bin/sh
# Generate Forgejo's signing secrets once and keep them.
#
# Forgejo would create these itself on first start and write them back into
# app.ini, which fails because the config is deliberately not writable by the
# service account. Regenerating them later would invalidate every session and
# stored credential, so anything already present is left alone.
set -e
OUT=/var/lib/forgejo/.secrets
umask 077
touch "$OUT"
for key in SECRET_KEY INTERNAL_TOKEN JWT_SECRET LFS_JWT_SECRET; do
    if ! grep -q "^${key}=" "$OUT" 2>/dev/null; then
        printf '%s=%s\n' "$key" "$(/usr/local/bin/forgejo generate secret "$key")" >> "$OUT"
    fi
done
chown git:git "$OUT"
