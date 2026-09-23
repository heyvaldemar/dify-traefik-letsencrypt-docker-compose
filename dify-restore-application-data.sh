#!/bin/bash

# Restore Dify's application data from one of the archives the `backups`
# container has taken: the uploaded documents and tool files under the api's
# storage directory, and the installed plugin packages.
#
#     chmod +x dify-restore-application-data.sh
#     ./dify-restore-application-data.sh
#
# Restore the DATABASE FIRST, with dify-restore-database.sh, and then this
# archive from the same timestamp. The database is the index: a storage
# directory newer than its database holds files no dataset row points at, and a
# database newer than its storage holds rows pointing at files that are gone.
#
# The knowledge-base embeddings live in Weaviate and are NOT in this archive.
# After a restore, re-index the affected knowledge bases from the Dify console;
# see the README for why that is the honest answer here rather than a tar of a
# live vector store.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-dify-traefik-letsencrypt-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-dify}"

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

BACKUPS_CONTAINER="$(dc ps -aq backups | head -n 1)"
[ -n "$BACKUPS_CONTAINER" ] || { echo "the backups container was not found — is the stack up?" >&2; exit 1; }

# Every value from the backups container: the environment its loop reads, so
# a path or name set in .env is the one used here too. This used to read the
# shell that ran it, which has none of them unless someone exported them.
env_of() { docker exec "$BACKUPS_CONTAINER" printenv "$1"; }
BACKUP_PATH="$(env_of DATA_BACKUPS_PATH)"; DATA="$(env_of DATA_PATH)"; PLUGIN_DATA="$(env_of PLUGIN_DATA_PATH)"
for d in "$DATA" "$PLUGIN_DATA"; do case "$d" in ""|/) echo "a data path is '$d'; refusing to clear it" >&2; exit 1 ;; esac; done

SELECTED="${1:-}"
if [ -z "$SELECTED" ]; then
  echo "--> All available application data backups:"
  docker exec "$BACKUPS_CONTAINER" sh -c "ls -1 $BACKUP_PATH" || true

  echo "--> Copy and paste the backup name from the list above and press [ENTER]
  --> Example: dify-application-data-backup-YYYY-MM-DD_hh-mm.tar.gz"
  echo -n "--> "
  read -r SELECTED
fi
[ -n "$SELECTED" ] || { echo "nothing selected, nothing restored" >&2; exit 1; }

if ! docker exec "$BACKUPS_CONTAINER" sh -c "tar -tzf '${BACKUP_PATH}/${SELECTED}' > /dev/null"; then
  echo "that file is not a readable tar archive — nothing has been stopped or deleted" >&2
  exit 1
fi
echo "--> $SELECTED was selected and reads as a valid archive"

STOPPED=""
for svc in api api_websocket worker plugin_daemon; do
  cid="$(dc ps -aq "$svc" | head -n 1)"
  [ -n "$cid" ] || continue
  STOPPED="$STOPPED $svc"
  docker stop "$cid" > /dev/null
done
echo "--> Stopped:$STOPPED"
restart() {  # started again whatever happens
  for svc in $STOPPED; do c="$(dc ps -aq "$svc" | head -n 1)"; [ -n "$c" ] && docker start "$c" > /dev/null; done
}
trap restart EXIT

echo "--> Restoring application data..."
# The archive stores paths relative to /, so it extracts there. Both trees are
# replaced wholesale: a file the archive does not carry is a file the database
# it belongs with does not know about either.
docker exec "$BACKUPS_CONTAINER" bash -c "set -o pipefail
  find '$DATA' '$PLUGIN_DATA' -mindepth 1 -delete
  tar -zxpf '${BACKUP_PATH}/${SELECTED}' -C /"
echo "--> Application data recovery completed."

echo "--> Starting the services again..."
for svc in $STOPPED; do
  cid="$(dc ps -aq "$svc" | head -n 1)"
  [ -n "$cid" ] && docker start "$cid" > /dev/null
done
echo "--> Re-index any knowledge base whose documents were restored: the embeddings are in Weaviate, not in this archive."
