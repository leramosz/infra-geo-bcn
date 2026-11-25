#!/usr/bin/env bash
# Arranca el proxy local (Caddy) que sirve la app en http://localhost:8088 (front + API) sobre la infra de Floci.
set -euo pipefail
cd "$(dirname "$0")/.." && . local/env.sh
CF=$(aws cloudformation describe-stacks --stack-name geobcn-edge --query "Stacks[0].Outputs[?OutputKey=='DistributionDomain'].OutputValue" --output text)
# La X-Api-Key es la que CloudFront tiene configurada como cabecera de origen hacia el ALB (edge.yaml), es decir,
# la misma que añadiría CloudFront si Floci le dejara usar el ALB como origen.
ID=$(aws cloudfront list-distributions --query 'DistributionList.Items[0].Id' --output text)
HV=$(aws cloudfront get-distribution-config --id "$ID" --query "DistributionConfig.Origins.Items[?Id=='api'] | [0].CustomHeaders.Items[?HeaderName=='X-Api-Key'] | [0].HeaderValue" --output text)
[ -n "$HV" ] && [ "$HV" != None ] || { echo "La distribución no tiene X-Api-Key en el origen api" >&2; exit 1; }
docker rm -f geo-app-proxy >/dev/null 2>&1 || true
docker run -d --name geo-app-proxy --network geo-floci-net -p 127.0.0.1:8088:8088 \
  -e GEO_API_KEY="$HV" \
  -e CF_DOMAIN="$CF" -v "$PWD/local/proxy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.8.4-alpine >/dev/null
for i in $(seq 1 20); do curl -sf -o /dev/null http://localhost:8088/ && break; sleep 1; done
echo "App en http://localhost:8088 (CloudFront $CF + ALB)"
