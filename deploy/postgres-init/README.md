# postgres-init

`prod-bootstrap.sql` is generated at deploy time and is NOT committed: it contains the
`POSTGRES_PASSWORD`. Generate it before the first `docker compose up`:

    PG=$(grep '^POSTGRES_PASSWORD=' ../env/prod.env | cut -d= -f2-)
    cat > postgres-init/prod-bootstrap.sql <<SQL
    ALTER USER postgres WITH PASSWORD '$PG';
    ALTER SCHEMA public OWNER TO postgres;
    GRANT ALL ON SCHEMA public TO postgres;
    SQL
    chmod 600 postgres-init/prod-bootstrap.sql

## Why this exists

`supabase/postgres` ships the `postgres` role pre-created, so the image never applies
`POSTGRES_PASSWORD` to it, and the `mytheus` database is created owned by `supabase_admin`. Under
PostgreSQL 15 schema `public` is owned by `pg_database_owner` and `postgres` holds only USAGE, so
`alembic upgrade head` fails on a fresh database with "permission denied for schema public".

The local `docker-compose.yml` has always mounted an equivalent hook; `compose.prod.yml` did not.
That gap went unnoticed because the VPS deploy had never actually been run.
