# Espera a que una pila salga de *_IN_PROGRESS. Uso: bash local/wait.sh <stack> [intentos]
n=${2:-90}; for i in $(seq 1 $n); do s=$(aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>&1); case $s in *PROGRESS) sleep 3;; *) break;; esac; done; echo "$s"
