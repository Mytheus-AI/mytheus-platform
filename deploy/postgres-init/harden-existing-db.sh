#!/bin/sh
# OPERATOR SCRIPT for an EXISTING database (a new volume is hardened automatically by
# zz-mytheus-harden-roles.sh). Idempotent: running it twice is the same as running it once.
#
# Usage, ON THE DATABASE HOST, as root:
#   ./deploy/postgres-init/harden-existing-db.sh <postgres-container-name>
#
# It copies harden-roles.sql into the container and runs it as supabase_admin (whose password
# the image sets to the container's own POSTGRES_PASSWORD, read inside the container so it never
# reaches this shell or its history), then prints the verification query's result, which must be "(0 rows)".
#
# Before running it in production, check nothing logs in as the three roles it disables:
#   docker exec <c> psql -U supabase_admin -d mytheus -c \
#     "SELECT usename, client_addr, backend_start FROM pg_stat_activity
#      WHERE usename IN ('supabase_read_only_user','authenticator','supabase_storage_admin');"
# Rollback (only if something legitimately needed one of them):
#   ALTER ROLE authenticator LOGIN;   -- and/or supabase_storage_admin
#   (supabase_read_only_user is not restored: it is a read-everything backdoor.)
set -eu
c="${1:?usage: $0 <postgres-container-name>}"
here="$(cd "$(dirname "$0")" && pwd)"
docker cp "$here/harden-roles.sql" "$c:/tmp/mytheus-harden-roles.sql"
docker exec -e DB="${PGDATABASE:-mytheus}" "$c" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 --no-psqlrc -h localhost \
     -U supabase_admin -d "$DB" -f /tmp/mytheus-harden-roles.sql'
docker exec "$c" rm -f /tmp/mytheus-harden-roles.sql
