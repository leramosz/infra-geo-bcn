#!/usr/bin/env bash
# Despliega la app real sobre la infra de Floci (requiere up.sh + deploy-all.sh antes).
#  1. Construye el back (../ms-geo-bcn/Dockerfile) y lo sube al ECR de la pila geobcn-compute con un tag nuevo
#     (el repositorio es IMMUTABLE). Con FLOCI_SERVICES_ECR_URI_STYLE=path el RepositoryUri es
#     localhost:4577/000000000000/eu-west-1/<repo>: el pull por :4577 funciona, pero el push no ("denied"), así que
#     se empuja directo al registro de Floci (127.0.0.1:5100) con la misma ruta.
#  2. Esquema V1 + 1.760 fuentes de ../ms-geo-bcn/db en el RDS de geobcn-data (idempotente: V1 solo si no existe).
#  3. update-stack de geobcn-compute con ImageUri = RepositoryUri:tag (plantilla sin cambios).
#  4. Front: npm ci + npm run build en ../front-geo-bcn y sync de dist/ al bucket de geobcn-edge.
# Uso: bash local/deploy-app.sh [--skip-back] [--skip-front]
set -euo pipefail
cd "$(dirname "$0")/.." && . local/env.sh
CODES=$(cd .. && pwd)
SKIP_BACK=0; SKIP_FRONT=0
for a in "$@"; do case $a in --skip-back) SKIP_BACK=1;; --skip-front) SKIP_FRONT=1;; esac; done
out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

# 2. Datos
PW=$(aws secretsmanager get-secret-value --secret-id "$(out geobcn-data DbSecretArn)" --query SecretString --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
PORT=$(out geobcn-data DbPort)
PSQL="psql -v ON_ERROR_STOP=1 -h floci -p $PORT -U geobcn -d geobcn -q"
docker run --rm -i --network geo-floci-net -e PGPASSWORD="$PW" -v "$CODES/ms-geo-bcn/db:/db:ro" geo-postgis:17 sh -c "
  [ \"\$($PSQL -Atc \"select to_regclass('drinking_water_fountain') is not null\")\" = t ] || $PSQL -f /db/migration/V1__create_drinking_water_fountains.sql
  $PSQL -f /db/load/load_fonts_beure.sql < /db/data/fonts_beure_2026.csv"
echo "datos: $(docker run --rm --network geo-floci-net -e PGPASSWORD="$PW" geo-postgis:17 $PSQL -Atc 'select count(*) from drinking_water_fountain') fuentes"

# 1 y 3. Back
if [ $SKIP_BACK = 0 ]; then
  URI=$(out geobcn-compute RepositoryUri); RPATH=${URI#*/}; REPO=${URI##*/}; TAG=0.0.1-$(date +%Y%m%d%H%M%S)
  docker build -q -t geo-bcn-back:local "$CODES/ms-geo-bcn" >/dev/null
  aws ecr get-login-password | docker login --username AWS --password-stdin localhost:5100 >/dev/null
  docker tag geo-bcn-back:local "localhost:5100/$RPATH:$TAG"
  docker push -q "localhost:5100/$RPATH:$TAG" >/dev/null && docker rmi "localhost:5100/$RPATH:$TAG" >/dev/null
  echo "ECR: $(aws ecr describe-images --repository-name "$REPO" --query 'imageDetails[].imageTags[]' --output text)"
  aws cloudformation update-stack --stack-name geobcn-compute --use-previous-template --capabilities CAPABILITY_IAM \
    --parameters ParameterKey=ImageUri,ParameterValue="$URI:$TAG" ParameterKey=DataStackName,UsePreviousValue=true \
      ParameterKey=NetworkStackName,UsePreviousValue=true ParameterKey=DesiredCount,UsePreviousValue=true \
      ParameterKey=HealthCheckPath,UsePreviousValue=true >/dev/null
  echo "geobcn-compute: $(bash local/wait.sh geobcn-compute 200) con $URI:$TAG"
  # Floci 2.5.0 no para el contenedor de la tarea anterior al desplegar otra: se quitan los que ECS ya no lista.
  CL=$(aws ecs list-clusters --query 'clusterArns[0]' --output text)
  LIVE=$(aws ecs list-tasks --cluster "$CL" --query 'taskArns[]' --output text | tr '\t' '\n' | sed 's|.*/||')
  for c in $(docker ps --format '{{.Names}}' | grep '^floci-aws-geofloci-ecs-'); do
    id=${c#floci-aws-geofloci-ecs-}; id=${id%-back}; echo "$LIVE" | grep -qx "$id" || docker rm -f "$c" >/dev/null
  done
fi

# 4. Front
if [ $SKIP_FRONT = 0 ]; then
  (cd "$CODES/front-geo-bcn" && npm ci --no-audit --no-fund --silent && npm run -s build >/dev/null)
  aws s3 sync --delete --only-show-errors "$CODES/front-geo-bcn/dist/" "s3://$(out geobcn-edge BucketName)/"
  echo "front subido a s3://$(out geobcn-edge BucketName)"
fi
