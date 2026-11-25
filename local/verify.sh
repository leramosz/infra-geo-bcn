#!/usr/bin/env bash
# Verifica contra los servicios de Floci que lo que declaran las pilas existe y funciona.
set -u
cd "$(dirname "$0")/.." && . local/env.sh
ok=0; ko=0
check() { if eval "$2" >/dev/null 2>&1; then echo "OK   $1"; ok=$((ok+1)); else echo "FALLO $1"; ko=$((ko+1)); fi; }
out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

for s in geobcn-network geobcn-data geobcn-compute geobcn-edge; do
  st=$(aws cloudformation describe-stacks --stack-name $s --query 'Stacks[0].StackStatus' --output text 2>&1)
  check "$s en CREATE_COMPLETE ($st)" "[ '$st' = CREATE_COMPLETE ]"
  bad=$(aws cloudformation describe-stack-resources --stack-name $s --query "length(StackResources[?ResourceStatus!='CREATE_COMPLETE'])" --output text 2>/dev/null)
  n=$(aws cloudformation describe-stack-resources --stack-name $s --query 'length(StackResources)' --output text 2>/dev/null)
  check "$s: $n recursos, todos CREATE_COMPLETE" "[ '$bad' = 0 ]"
done

VPC=$(out geobcn-network VpcId)
check "VPC $VPC existe" "aws ec2 describe-vpcs --vpc-ids $VPC"
check "4 subredes en la VPC" "[ \$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'length(Subnets)' --output text) = 4 ]"
check "NAT Gateway available" "[ \$(aws ec2 describe-nat-gateways --query 'NatGateways[0].State' --output text) = available ]"

ARN=$(out geobcn-data DbSecretArn); PORT=$(out geobcn-data DbPort)
check "DbSecretArn es un ARN ($ARN)" "[[ '$ARN' == arn:aws:secretsmanager:* ]]"
SEC=$(aws secretsmanager get-secret-value --secret-id "$ARN" --query SecretString --output text 2>/dev/null)
check "secreto con username y password" "echo '$SEC' | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d[\"username\"] and len(d[\"password\"])==32'"
PW=$(echo "$SEC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])' 2>/dev/null)
check "RDS available" "[ \$(aws rds describe-db-instances --query 'DBInstances[0].DBInstanceStatus' --output text) = available ]"
check "psql + CREATE EXTENSION postgis con la clave del secreto" "docker run --rm --network geo-floci-net -e PGPASSWORD='$PW' geo-postgis:17 psql -v ON_ERROR_STOP=1 -h floci -p $PORT -U geobcn -d geobcn -Atc 'create extension if not exists postgis' -c 'select postgis_lib_version()'"

CL=$(aws ecs list-clusters --query 'clusterArns[0]' --output text)
SVC=$(aws ecs list-services --cluster "$CL" --query 'serviceArns[0]' --output text)
check "servicio ECS con 1 tarea en ejecución" "[ \$(aws ecs describe-services --cluster $CL --services $SVC --query 'services[0].runningCount' --output text) = 1 ]"
E=$(docker ps --format '{{.Names}}' | grep geofloci-ecs | head -1)
check "la tarea recibe DB_URL, DB_USER, DB_PASSWORD, JWT y API keys" "docker exec $E sh -c '[ -n \"\$DB_URL\" ] && [ \"\$DB_USER\" = geobcn ] && [ \${#DB_PASSWORD} = 32 ] && [ \${#GEOBCN_JWT_SECRET} = 48 ] && [ \${#GEOBCN_API_KEYS} = 40 ]'"
check "la tarea llega al RDS" "docker exec $E nc -z -w 3 floci $PORT"
# La imagen de relleno no sirve la ruta del health check: se crea a mano para ver el ALB en verde.
docker exec -u 0 "$E" sh -c 'mkdir -p /usr/share/nginx/html/geo-bcn/v2 && echo "openapi: 3.1.0" > /usr/share/nginx/html/geo-bcn/v2/openapi.yaml' >/dev/null 2>&1
TG=$(aws elbv2 describe-target-groups --query 'TargetGroups[0].TargetGroupArn' --output text)
for i in $(seq 1 30); do [ "$(aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)" = healthy ] && break; sleep 3; done
check "target del ALB healthy" "[ \$(aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text) = healthy ]"
check "ALB /geo-bcn/v2/openapi.yaml -> 200" "[ \$(docker run --rm --network geo-floci-net curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' http://floci:80/geo-bcn/v2/openapi.yaml) = 200 ]"

B=$(out geobcn-edge BucketName); D=$(out geobcn-edge DistributionDomain)
echo '<h1>BCN Geo</h1>' | aws s3 cp - "s3://$B/index.html" >/dev/null
check "CloudFront / sirve index.html desde S3" "curl -sf -H 'Host: $D' $AWS_ENDPOINT_URL/ | grep -q 'BCN Geo'"
check "CloudFront ruta SPA /barrios -> index.html" "curl -sf -H 'Host: $D' $AWS_ENDPOINT_URL/barrios | grep -q 'BCN Geo'"
ID=$(aws cloudfront list-distributions --query 'DistributionList.Items[0].Id' --output text)
HV=$(aws cloudfront get-distribution-config --id "$ID" --query "DistributionConfig.Origins.Items[?Id=='api'] | [0].CustomHeaders.Items[?HeaderName=='X-Api-Key'] | [0].HeaderValue" --output text)
KEY=$(aws secretsmanager get-secret-value --secret-id "$(aws cloudformation list-exports --query "Exports[?Name=='geobcn-compute-ApiKeySecretArn'].Value" --output text)" --query SecretString --output text)
check "CloudFront origen api lleva X-Api-Key = ApiKeySecret (${HV:0:4}…)" "[ -n '$HV' ] && [ '$HV' = '$KEY' ]"
check "ALB con la X-Api-Key de CloudFront: /geo-bcn/v2/openapi.yaml -> 200" "[ \$(docker run --rm --network geo-floci-net curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' -H 'X-Api-Key: $HV' http://floci:80/geo-bcn/v2/openapi.yaml) = 200 ]"
echo "CONOCIDO: CloudFront -> ALB (/geo-bcn/v2/*) da 502 en Floci (bloquea orígenes con IP privada); no se comprueba."
echo; echo "Resultado: $ok OK, $ko fallos"; [ $ko = 0 ]
