#!/usr/bin/env bash
# Despliega las 4 pilas contra el Floci de local/compose.yaml. Uso: bash local/deploy-all.sh
# data va con DbSecretMode=explicit: Floci 2.5.0 no implementa ManageMasterUserPassword (MasterUserSecret).
set -u
cd "$(dirname "$0")/.." && . local/env.sh
cfn() { aws cloudformation create-stack --stack-name "$1" --template-body "file://$2" "${@:3}" >/dev/null && echo "$1: $(bash local/wait.sh "$1" 150)"; }
cfn geobcn-network cloudformation/network.yaml --parameters ParameterKey=CloudFrontPrefixListId,ParameterValue=pl-0123456789abcdef0 ParameterKey=EnableNatGateway,ParameterValue=true
cfn geobcn-data cloudformation/data.yaml --parameters ParameterKey=DbSecretMode,ParameterValue=explicit
cfn geobcn-compute cloudformation/compute.yaml --capabilities CAPABILITY_IAM --parameters ParameterKey=ImageUri,ParameterValue=${IMAGE_URI:-nginxinc/nginx-unprivileged:alpine}
cfn geobcn-edge cloudformation/edge.yaml
