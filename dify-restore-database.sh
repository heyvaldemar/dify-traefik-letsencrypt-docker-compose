#!/bin/bash

# Restore a Dify database from one of the backups the `backups` container has
# taken. Two databases exist and this script handles either: the main one,
# which holds apps, workflows, accounts and encrypted provider credentials, and
# the plugin daemon's own, which holds installed plugin records.
#
#     chmod +x dify-restore-database.sh
#     ./dify-restore-database.sh              # the main database
#     ./dify-restore-database.sh --plugin     # the plugin daemon's database
#
# The encrypted provider credentials in the main database are only readable
# with the DIFY_SECRET_KEY that was set when they were written. Restoring a
# database into a deployment with a different key gives you rows nobody can
# decrypt, so keep .env with the backup.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-dify-traefik-letsencrypt-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-dify}"
DB_USER="${DIFY_DB_USER:-postgres}"
BACKUP_PATH="${POSTGRES_BACKUPS_PATH:-/srv/dify-postgres/backups}"

WHICH=main
for arg in "$@"; do
  case "$arg" in
    --plugin) WHICH=plugin ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done
if [ "$WHICH" = "plugin" ]; then
  DB_NAME="${DIFY_DB_PLUGIN_DATABASE:-dify_plugin}"
  PREFIX="${PLUGIN_BACKUP_NAME:-dify-plugin-postgres-backup}"
else
  DB_NAME="${DIFY_DB_NAME:-dify}"
  PREFIX="${POSTGRES_BACKUP_NAME:-dify-postgres-backup}"
fi

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

BACKUPS_CONTAINER="$(dc ps -aq backups | head -n 1)"
[ -n "$BACKUPS_CONTAINER" ] || { echo "the backups container was not found — is the stack up?" >&2; exit 1; }

echo "--> Restoring the $WHICH database ($DB_NAME)"
echo "--> All available backups:"
docker exec "$BACKUPS_CONTAINER" sh -c "ls -1 $BACKUP_PATH | grep '^$PREFIX'" || true

echo "--> Copy and paste the backup name from the list above and press [ENTER]
--> Example: ${PREFIX}-YYYY-MM-DD_hh-mm.gz"
echo -n "--> "
read -r SELECTED
[ -n "$SELECTED" ] || { echo "nothing selected, nothing restored" >&2; exit 1; }

if ! docker exec "$BACKUPS_CONTAINER" sh -c "gzip -t '${BACKUP_PATH}/${SELECTED}'"; then
  echo "that file is not a readable gzip archive — nothing has been stopped or dropped" >&2
  exit 1
fi
echo "--> $SELECTED was selected and reads as a valid archive"

# Everything that holds a connection to this database has to let go of it, and
# the api and the worker both reconnect to a schema they cache at start.
STOPPED=""
for svc in api api_websocket worker worker_beat plugin_daemon; do
  cid="$(dc ps -aq "$svc" | head -n 1)"
  [ -n "$cid" ] || continue
  STOPPED="$STOPPED $svc"
  docker stop "$cid" > /dev/null
done
echo "--> Stopped:$STOPPED"

echo "--> Restoring..."
docker exec "$BACKUPS_CONTAINER" bash -c "set -o pipefail
  dropdb --force -h db_postgres -p 5432 -U '$DB_USER' '$DB_NAME' \
  && createdb -h db_postgres -p 5432 -U '$DB_USER' '$DB_NAME' \
  && gzip -dc '${BACKUP_PATH}/${SELECTED}' \
     | psql -q -o /dev/null -v ON_ERROR_STOP=1 -h db_postgres -p 5432 -U '$DB_USER' -d '$DB_NAME'"
echo "--> Database recovery completed."

echo "--> Starting the services again..."
for svc in $STOPPED; do
  cid="$(dc ps -aq "$svc" | head -n 1)"
  [ -n "$cid" ] && docker start "$cid" > /dev/null
done
echo "--> Dify runs its migrations at start; the console answers once they finish."
