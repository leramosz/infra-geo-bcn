# Parámetros por entorno

Mismas plantillas, distintos valores.

| Parámetro | Local (Floci) | AWS real |
|---|---|---|
| network `CloudFrontPrefixListId` | `pl-0123456789abcdef0` (relleno; Floci lo descarta) | el de la región (`aws ec2 describe-managed-prefix-lists`) |
| data `DbSecretMode` | `explicit` | `managed` |
| data `EngineVersion` | cualquiera (Floci no lo valida) | una versión existente |
| compute `ImageUri` | `nginx:alpine` o la imagen local | `<cuenta>.dkr.ecr.<región>.amazonaws.com/...:tag` |
