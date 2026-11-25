# Parámetros por entorno

Mismas plantillas, distintos valores.

| Parámetro | Local (Floci) | AWS real |
|---|---|---|
| network `CloudFrontPrefixListId` | `pl-0123456789abcdef0` (relleno; Floci lo descarta) | el de la región (`aws ec2 describe-managed-prefix-lists`) |
| data `DbSecretMode` | `explicit` | `managed` |
| data `EngineVersion` | cualquiera (Floci no lo valida) | una versión existente |
| compute `ImageUri` | `nginxinc/nginx-unprivileged:alpine` (relleno, escucha en el 8080) y luego `localhost:4577/000000000000/eu-west-1/<repo>:<tag>` (`deploy-app.sh`) | `<cuenta>.dkr.ecr.<región>.amazonaws.com/...:tag` |
