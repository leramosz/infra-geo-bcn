#!/usr/bin/env bash
# Levanta un Floci limpio (geo-floci:4577) con RDS PostGIS. Construye geo-postgis:17 si falta.
set -eu
cd "$(dirname "$0")/.."
docker image inspect geo-postgis:17 >/dev/null 2>&1 || docker build -t geo-postgis:17 local/postgis
bash local/down.sh
docker compose -f local/compose.yaml -f local/compose.postgis.yaml up -d
. local/env.sh
until aws cloudformation list-stacks >/dev/null 2>&1; do sleep 1; done
echo "Floci listo en $AWS_ENDPOINT_URL"
