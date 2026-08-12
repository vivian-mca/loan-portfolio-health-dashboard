#!/usr/bin/env bash
# Runs every sql/*.sql script, in filename order, against the running container.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; source .env; set +a
fi

CONTAINER=loan-portfolio-sqlserver
PASSWORD="${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD in .env first (copy .env.example to .env)}"

for f in sql/*.sql; do
  name=$(basename "$f")
  echo "=== Running $name ==="
  docker exec -i "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$PASSWORD" -C \
    -i "/var/opt/mssql/scripts/$name"
done

echo "All scripts completed."
