#!/usr/bin/env bash
# Abre psql contra el RDS de Floci con la clave del secreto de geobcn-data. Uso: bash local/psql.sh [-c "SQL"]
set -eu
cd "$(dirname "$0")/.." && . local/env.sh
o() { aws cloudformation describe-stacks --stack-name geobcn-data --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
PW=$(aws secretsmanager get-secret-value --secret-id "$(o DbSecretArn)" --query SecretString --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
T=-i; [ -t 0 ] && T=-it
exec docker run --rm $T --network geo-floci-net -e PGPASSWORD="$PW" geo-postgis:17 psql -h floci -p "$(o DbPort)" -U geobcn -d geobcn "$@"
