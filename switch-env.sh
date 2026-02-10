#!/bin/bash
# Switch between test and production Informix environments
# Preserves Kafka + Debezium volumes per environment to avoid re-doing snapshots.
#
# Usage: ./switch-env.sh [test|production]

set -e

ENV="${1:-}"

if [[ "$ENV" != "test" && "$ENV" != "production" ]]; then
  echo "Usage: ./switch-env.sh [test|production]"
  echo ""
  echo "  test        -> Informix local (host.docker.internal:9088, testdb)"
  echo "  production  -> Informix produccion (192.168.96.117:9800, fedefarm)"
  exit 1
fi

SOURCE=".env.${ENV}"

if [[ ! -f "$SOURCE" ]]; then
  echo "ERROR: File $SOURCE not found."
  echo "Create it from .env.example and fill in the credentials."
  exit 1
fi

# Volume names used by docker-compose
KAFKA_VOL="informix-debezium_kafka-data"
DEBEZIUM_VOL="informix-debezium_debezium-data"

# Detect current environment from .env
CURRENT_ENV=""
if [[ -f .env ]]; then
  CURRENT_DB=$(grep -E '^DB_NAME=' .env | cut -d= -f2)
  if [[ "$CURRENT_DB" == "testdb" ]]; then
    CURRENT_ENV="test"
  elif [[ "$CURRENT_DB" == "fedefarm" ]]; then
    CURRENT_ENV="production"
  fi
fi

if [[ "$CURRENT_ENV" == "$ENV" ]]; then
  echo "Already on '$ENV' environment. Nothing to do."
  exit 0
fi

# --- Helper: copy volume data using a temporary alpine container ---
copy_volume() {
  local src="$1" dst="$2"
  docker volume create "$dst" >/dev/null 2>&1 || true
  docker run --rm -v "$src":/from -v "$dst":/to alpine sh -c "rm -rf /to/* && cp -a /from/. /to/"
}

echo "==> Stopping current stack..."
docker compose down

# --- Save current volumes (if we know the current env) ---
if [[ -n "$CURRENT_ENV" ]]; then
  echo "==> Saving current volumes as '$CURRENT_ENV'..."

  if docker volume inspect "$KAFKA_VOL" >/dev/null 2>&1; then
    copy_volume "$KAFKA_VOL" "${KAFKA_VOL}-${CURRENT_ENV}"
    echo "    Saved $KAFKA_VOL -> ${KAFKA_VOL}-${CURRENT_ENV}"
  fi

  if docker volume inspect "$DEBEZIUM_VOL" >/dev/null 2>&1; then
    copy_volume "$DEBEZIUM_VOL" "${DEBEZIUM_VOL}-${CURRENT_ENV}"
    echo "    Saved $DEBEZIUM_VOL -> ${DEBEZIUM_VOL}-${CURRENT_ENV}"
  fi
fi

# --- Restore target volumes (if they exist) or start fresh ---
TARGET_KAFKA="${KAFKA_VOL}-${ENV}"
TARGET_DEBEZIUM="${DEBEZIUM_VOL}-${ENV}"

if docker volume inspect "$TARGET_KAFKA" >/dev/null 2>&1 && \
   docker volume inspect "$TARGET_DEBEZIUM" >/dev/null 2>&1; then
  echo "==> Restoring saved '$ENV' volumes (no snapshot needed)..."

  # Remove current volumes and replace with saved ones
  docker volume rm "$KAFKA_VOL" 2>/dev/null || true
  docker volume rm "$DEBEZIUM_VOL" 2>/dev/null || true

  copy_volume "$TARGET_KAFKA" "$KAFKA_VOL"
  echo "    Restored ${TARGET_KAFKA} -> $KAFKA_VOL"

  copy_volume "$TARGET_DEBEZIUM" "$DEBEZIUM_VOL"
  echo "    Restored ${TARGET_DEBEZIUM} -> $DEBEZIUM_VOL"

  FRESH=false
else
  echo "==> No saved volumes for '$ENV'. Will perform fresh snapshot."
  docker volume rm "$KAFKA_VOL" 2>/dev/null || true
  docker volume rm "$DEBEZIUM_VOL" 2>/dev/null || true
  FRESH=true
fi

echo "==> Switching to $ENV environment..."
cp "$SOURCE" .env
echo "    Copied $SOURCE -> .env"

echo "==> Starting stack..."
docker compose up -d

echo ""
if [[ "$FRESH" == "true" ]]; then
  echo "Done! Debezium will perform a fresh snapshot against the $ENV server."
else
  echo "Done! Restored existing data for $ENV (Debezium will resume, no snapshot)."
fi
echo "Monitor with: docker logs -f debezium-server"
