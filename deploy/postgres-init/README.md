# postgres-init

`prod-bootstrap.sql` is generated at deploy time and is NOT committed: it contains the
`POSTGRES_PASSWORD`. It lives on the host at `/etc/dokploy/mytheus-secrets/prod-bootstrap.sql`
(see the header of `../compose.prod.yml` for why that specific directory). Generate it before
the first `docker compose up`:

    S=/etc/dokploy/mytheus-secrets
    install -d -m 700 "$S"
    PG=$(grep '^POSTGRES_PASSWORD=' "$S/env/prod.env" | cut -d= -f2-)
    cat > "$S/prod-bootstrap.sql" <<SQL
    ALTER USER postgres WITH PASSWORD '$PG';
    ALTER SCHEMA public OWNER TO postgres;
    GRANT ALL ON SCHEMA public TO postgres;
    SQL
    chmod 644 "$S/prod-bootstrap.sql"   # NOT 600 - see below

## The file must be 0644, not 0600

This README previously said `chmod 600`, and that instruction silently broke every fresh
install. `psql` reads this file as the **non-root `postgres` user inside the container**, not as
root, so a root-only file produces:

    /docker-entrypoint-initdb.d/migrate.sh: running /etc/postgresql.schema.sql
    psql: error: /etc/postgresql.schema.sql: Permission denied

The entrypoint does not treat that as fatal. Bootstrap continues, `public` stays owned by
`pg_database_owner`, and the failure only surfaces much later and somewhere else, as
`alembic upgrade head` dying on "permission denied for schema public". Nothing in between
points at a file mode.

Confidentiality comes from the **directory**, which is `0700 root`, so the file is unreachable
to non-root users on the host. A bind mount resolves the inode directly and does not traverse
the directory, so the container reads it regardless. Verify both properties after generating it:

    sudo -u nobody cat "$S/prod-bootstrap.sql"   # must fail: Permission denied
    docker exec <pg-container> cat /etc/postgresql.schema.sql | tail -2   # must succeed

The `env/*.env` files stay `0600`: those are read by the compose CLI, which runs as root.

## Why this exists

`supabase/postgres` ships the `postgres` role pre-created, so the image never applies
`POSTGRES_PASSWORD` to it, and the `mytheus` database is created owned by `supabase_admin`. Under
PostgreSQL 15 schema `public` is owned by `pg_database_owner` and `postgres` holds only USAGE, so
`alembic upgrade head` fails on a fresh database with "permission denied for schema public".

The local `docker-compose.yml` has always mounted an equivalent hook; `compose.prod.yml` did not.
That gap went unnoticed because the VPS deploy had never actually been run. Production was
subsequently repaired by hand, which hid the fact that the hook still did not work - every
rebuild and any disaster recovery would have failed the same way until the mode was corrected.

## Verifying a rebuild actually works

The only proof is a from-empty install, since the hook runs solely against an uninitialised
data directory. Against a THROWAWAY compose project, never production:

    docker compose -p scratch -f ./deploy/compose.prod.yml down -v
    docker compose -p scratch -f ./deploy/compose.prod.yml up -d
    # then, as the postgres role:
    #   SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public';  -> postgres
    #   SELECT count(*) FROM information_schema.tables WHERE table_schema='public'; -> 31
    docker compose -p scratch -f ./deploy/compose.prod.yml down -v
