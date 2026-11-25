# BCN Geo en AWS: arquitectura e IaC (borrador)

Estado: esqueleto probado en emulador. Las plantillas pasan `cfn-lint` 1.61 (0 avisos) y se despliegan enteras en Floci 2.5.0 con `DbSecretMode=explicit` (detalle en `RESULTADOS-FLOCI.md`). **No se han desplegado en AWS.**

## Decisiones tomadas
- Back en **ECS Fargate** y base de datos en **RDS PostgreSQL** (PostGIS con `CREATE EXTENSION` en la migración V1).

## Arquitectura
```
Navegador -> CloudFront -+-> S3 privado (OAC)        front estático (Vite)
                         +-> /geo-bcn/v2/* -> ALB -> ECS Fargate (Spring Boot :8080) -> RDS PostgreSQL
```
Un solo dominio para front y API: no hace falta CORS. El back valida él mismo X-Api-Key y JWT, así que no hay API Gateway. El front estático no lleva clave: **CloudFront añade `X-Api-Key`** como cabecera de origen hacia el ALB, leída de Secrets Manager (`ApiKeySecret`) al desplegar; el navegador no la ve y no está en el repo.

| Plantilla | Contenido |
|---|---|
| `network.yaml` | VPC, 2 subredes públicas (ALB) y 2 privadas (ECS, RDS), 1 NAT, security groups |
| `data.yaml` | RDS PostgreSQL; `DbSecretMode=managed` (clave gestionada por RDS, AWS real) o `explicit` (secreto propio, Floci) |
| `compute.yaml` | ECR, ALB, cluster/servicio/tarea Fargate, secretos de API key y JWT generados por CloudFormation (exporta el ARN de la API key) |
| `edge.yaml` | Bucket S3, CloudFront con origen S3 y origen ALB para `/geo-bcn/v2/*` (con cabecera de origen `X-Api-Key`) |

Orden: network, data, compute (necesita la imagen ya en ECR), edge. Sin credenciales en el repo.

## Emulación: qué se sabe y qué no
- **Floci** (según la prueba de LRZBank, 2026-11-19): CloudFormation y RDS PostgreSQL funcionan; ECS crea la tarea pero no levanta el contenedor. CloudFront figura en su README como "in-process"; no lo he probado.
- **AWS Emulator oficial**: solo he leído la documentación general. La lista de servicios y su fidelidad están en las releases de GitHub y no las he revisado. No sé si cubre ECS ni RDS.
- Ningún emulador valida lo que más suele fallar en real: IAM, quotas, versiones de motor, certificados. IAM no se evalúa en ninguno.
- Propuesta: **local** = Postgres con PostGIS + back + Caddy (como LRZBank), y el emulador solo para ensayar `network`, `data` y `edge` si los cubre. **Real**: `aws cloudformation validate-template` y change sets antes de aplicar.

## Pendiente de decidir
1. HTTPS en el ALB: hoy CloudFront habla HTTP con el ALB (tráfico dentro de AWS). Para cifrarlo hace falta dominio y certificado ACM.
2. NAT Gateway (~32 EUR/mes) o VPC endpoints para ECR, logs y Secrets Manager.
3. Dominio propio o `*.cloudfront.net`.
4. Regla de barrios que cruzan distritos (ya pendiente en el proyecto): no afecta a la infra.

## Valores a verificar antes de desplegar
- `EngineVersion` por defecto 17.7: comprobar con `aws rds describe-db-engine-versions`.
- `HealthCheckPath` `/geo-bcn/v2/openapi.yaml`: confirmar que responde 200 sin API key.
- `CloudFrontPrefixListId` (network): `aws ec2 describe-managed-prefix-lists` (`com.amazonaws.global.cloudfront.origin-facing`).
- Variables que lee el back: DB_URL, DB_USER, DB_PASSWORD, GEOBCN_API_KEYS, GEOBCN_JWT_SECRET (de `application.yml`).
