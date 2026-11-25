# Prueba de las plantillas en Floci

> **Actualización (misma fecha):** `data.yaml` tiene ahora el parámetro `DbSecretMode`. La [sección final](#parámetro-dbsecretmode) lo prueba. Con `DbSecretMode=explicit`, las 4 plantillas del repo despliegan en Floci sin variantes. Las secciones de abajo describen la prueba de la versión anterior (`variants/data.yaml.anterior`).

Fecha: 2026-11-25. Floci `floci/floci:2.5.0` (gratuito), contenedor propio `geo-floci` en el puerto 4577, región `eu-west-1`, credenciales `test/test`. Mac ARM (arm64). Independiente del Floci de LRZBank (otra red, otro namespace `geofloci`).

Cómo repetirlo (desde `infra-geo-bcn/`):

```bash
bash local/up.sh          # Floci limpio en :4577 (construye geo-postgis:17 si falta)
bash local/deploy-all.sh  # las 4 pilas, data con DbSecretMode=explicit
bash local/verify.sh      # 22 comprobaciones contra los servicios del emulador
bash local/psql.sh        # psql a la base con la clave del secreto
bash local/down.sh        # borra solo lo de este proyecto
```

## Resumen

| Pila | Estado | Qué pasa |
|---|---|---|
| `geobcn-network` | CREATE_COMPLETE | Todo creado y visible en EC2. La regla del SG del ALB con prefix list se crea **sin** el prefix list (se ignora en silencio). |
| `geobcn-data` (original) | CREATE_COMPLETE, pero **inservible** | `Database.MasterUserSecret.SecretArn` no se resuelve: no hay secreto y el export `DbSecretArn` vale el texto literal. Nadie conoce la contraseña. |
| `geobcn-compute` sobre `geobcn-data` | **ROLLBACK_COMPLETE** | `ExecutionRole`: `Resource Database.MasterUserSecret.SecretArn must be in ARN format or "*".` |
| `geobcn-data-v` (variante, secreto explícito) | CREATE_COMPLETE | Funciona; la contraseña del secreto entra en la base de datos. |
| `geobcn-compute` sobre `geobcn-data-v` | CREATE_COMPLETE | ECS levanta **de verdad** el contenedor, con los secretos inyectados; el ALB hace health checks reales y enruta (200). |
| `geobcn-edge` | CREATE_COMPLETE | S3 + CloudFront sirven el front de verdad. CloudFront → ALB da 502 (Floci bloquea orígenes privados). |

`cfn-lint` 1.61.0: 0 avisos en las 4 plantillas y en la variante.

**Conclusión**: Floci sirve para ensayar network, compute y edge casi enteros, y el flujo ALB → ECS → RDS. Lo que **no** emula es `ManageMasterUserPassword`, que es justo la pieza que une `data` con `compute`. Para probar en Floci hace falta la variante de `data` (o un parámetro alternativo); la plantilla original no se puede validar aquí en ese punto.

## Detalle por pila

### geobcn-network

Parámetros: `CloudFrontPrefixListId=pl-0123456789abcdef0`, `EnableNatGateway=true`. Los 22 recursos quedaron CREATE_COMPLETE y los 6 exports se registraron.

| Recurso | CFN | ¿Existe en el servicio? | Notas |
|---|---|---|---|
| Vpc | creado | sí (`describe-vpcs`, 10.20.0.0/16) | |
| InternetGateway, GatewayAttachment | creado | sí, `attached` a la VPC | |
| PublicSubnetA/B, PrivateSubnetA/B | creado | sí, /24 en eu-west-1a y 1b | `!GetAZs` y `!Cidr` resueltos bien |
| PublicRouteTable, PublicRoute, PublicAssocA/B | creado | sí, 0.0.0.0/0 → igw | |
| NatEip, NatGateway | creado | sí, NAT `available` en PublicSubnetA, EIP 203.0.113.1 | No hay NAT real (todo es red Docker) |
| PrivateRouteTable, PrivateRoute, PrivateAssocA/B | creado | sí, 0.0.0.0/0 → nat | |
| AlbSecurityGroup | creado | sí | **ignorado en parte**: la regla tcp/80 existe con `PrefixListIds: []`. Floci aceptó un `pl-` inventado y lo descartó. Solo conoce los prefix list de S3 y DynamoDB, no el de CloudFront. |
| AppSecurityGroup + AppIngressFromAlb | creado | sí, 8080 desde el SG del ALB | |
| DbSecurityGroup + DbIngressFromApp | creado | sí, 5432 desde el SG de la app | Los SG **no se aplican** al tráfico: los contenedores se ven por la red Docker. |

### geobcn-data (plantilla original)

| Recurso | CFN | ¿Existe en el servicio? | Notas |
|---|---|---|---|
| DbSubnetGroup | creado | sí | |
| Database | creado | sí: `available`, postgres 17.7, `StorageEncrypted: true`, SG y subnet group correctos | Endpoint `172.20.0.2:7001`: un proxy de autenticación dentro de Floci, solo alcanzable desde la red Docker de Floci. |
| Secreto de `ManageMasterUserPassword` | **no creado** | `list-secrets` vacío, `MasterUserSecret: null` | Log de Floci: `Unresolved GetAtt: Database.MasterUserSecret.SecretArn` |
| Output/export `DbSecretArn` | **valor erróneo** | | Se exporta el texto `Database.MasterUserSecret.SecretArn` sin fallar la pila. |
| Contraseña | desconocida | | Floci genera una de 4 caracteres que no sirve en el proxy (`FATAL: password authentication failed for user "geobcn"`). Solo se entra tras `aws rds modify-db-instance --master-user-password ... --apply-immediately`. |
| `DeletionPolicy: Snapshot` | **ignorado** | | Al borrar la pila desaparece la instancia y `describe-db-snapshots` queda vacío. |

Los demás exports (`DbEndpoint`, `DbPort`, `DbName`) sí se resuelven.

### geobcn-compute sobre geobcn-data

ROLLBACK_COMPLETE. El único CREATE_FAILED:

```
ExecutionRole  Resource Database.MasterUserSecret.SecretArn must be in ARN format or "*".
```

Se habían creado Repository, ApiSecrets, ApiKeySecret, LogGroup, Cluster, TaskRole, LoadBalancer y TargetGroup, y se borraron en el rollback. Es decir, `Fn::ImportValue` funciona; lo que llega es el valor basura del export.

### Variante variants/data-secret-explicito.yaml

Cambios frente a `data.yaml` (sin tocar el original): un `AWS::SecretsManager::Secret` con `GenerateSecretString` (`username` y `password`), `MasterUserPassword: {{resolve:secretsmanager:...:SecretString:password}}` en lugar de `ManageMasterUserPassword`, y `DbSecretArn: !Ref DbMasterSecret`.

Primer intento con `SecretStringTemplate: !Sub '{"username": "${DbUsername}"}'`: falla `Database` con

```
secret arn:aws:secretsmanager:...:secret:geobcn-data-v-DbMasterSecret-... does not contain valid JSON
```

porque Floci no resuelve `!Sub` dentro de `SecretStringTemplate` (log: `Failed to parse SecretStringTemplate: ... MissingNode cannot be cast to ... ObjectNode`) y genera un texto plano. Con una pila de prueba aparte comprobé que `SecretStringTemplate` literal (`'{"username": "geobcn"}'`) y `"{}"` sí funcionan, y que sin plantilla sale un texto plano. La variante final usa el usuario literal.

Con eso, CREATE_COMPLETE: el secreto existe, el export `DbSecretArn` es un ARN real y `psql` entra con la contraseña del secreto. Floci deja en el log `a dynamic reference did not resolve ({{resolve:secretsmanager:${DbMasterSecret}:...}})`, pero al final la resuelve: la contraseña literal se rechaza y la del secreto entra.

### geobcn-compute sobre geobcn-data-v

`ImageUri`: primero `nginx:alpine` y luego `nginxinc/nginx-unprivileged:alpine` (escucha en 8080) con `update-stack`. Los 12 recursos quedaron CREATE_COMPLETE.

| Recurso | CFN | ¿Existe en el servicio? | Notas |
|---|---|---|---|
| Repository | creado | sí | `ImageTagMutability: IMMUTABLE` se respeta; **`ScanOnPush` queda `False`** (ignorado). Floci arranca un registro ECR propio. |
| ApiSecrets | creado | sí, JSON `{"jwt_secret": "<48 car>"}` | |
| ApiKeySecret | creado | sí, texto de 40 car | |
| LogGroup | creado | sí, retención 14 días | Los logs del contenedor llegan con streams `back/back/<task>`. |
| Cluster | creado | sí | |
| ExecutionRole, TaskRole | creado | sí, con la política gestionada y la inline | IAM no se evalúa. |
| TaskDefinition | creado | sí | `DB_URL=jdbc:postgresql://172.20.0.2:7002/geobcn`: los 3 `ImportValue` dentro de `!Sub` se resuelven. |
| LoadBalancer | creado | sí, `active`, internet-facing, subredes públicas y SG correctos | DNS `...elb.localhost.floci.io`; el listener escucha en el puerto 80 **del contenedor de Floci**. |
| TargetGroup | creado | sí | Floci registra la IP de la tarea (`172.20.0.x:8080`) y **hace health checks reales** a `HealthCheckPath`. |
| Listener | creado | sí, HTTP:80 | |
| Service | creado | sí: `ACTIVE`, 1/1 en ejecución, FARGATE, awsvpc | **El contenedor arranca de verdad** (no como en la prueba de LRZBank del 19-11). |

Comprobaciones en el contenedor de la tarea:
- Recibe `DB_URL`, `DB_USER=geobcn`, `DB_PASSWORD` (32 car), `GEOBCN_JWT_SECRET` (48 car, la clave `jwt_secret` del JSON) y `GEOBCN_API_KEYS` (40 car). La sintaxis `arn:clave::` de `valueFrom` funciona.
- Llega al proxy de RDS (`nc -z 172.20.0.2 7002` OK).
- Con `nginx:alpine` (puerto 80): target `unhealthy` (`Target.FailedHealthChecks`) y el ALB responde 502. Correcto.
- Con `nginx-unprivileged` en 8080, la ruta `/geo-bcn/v2/openapi.yaml` daba 404 y el target seguía `unhealthy`. **El `update-stack` se queda en UPDATE_IN_PROGRESS esperando a que el target esté sano.** Al crear el fichero en el contenedor, el target pasa a `healthy`, la pila a UPDATE_COMPLETE y `GET /geo-bcn/v2/openapi.yaml` por el ALB devuelve 200.
- En `create-stack`, en cambio, el Service queda CREATE_COMPLETE aunque el target esté `unhealthy`.
- Tras el despliegue nuevo, ECS dice 1 tarea, pero **el contenedor de la tarea antigua sigue corriendo** en Docker (no se para).

### geobcn-edge

Los 4 recursos quedaron CREATE_COMPLETE.

| Recurso | CFN | ¿Existe en el servicio? | Notas |
|---|---|---|---|
| SiteBucket | creado | sí (`s3 ls`), cifrado AES256 y bloqueo de acceso público correctos | |
| OriginAccessControl | creado | sí | |
| Distribution | creado | sí: `Deployed`, 2 orígenes, error 403/404 → `/index.html` 200, `DefaultRootObject`, `http2and3` | **Ignorados en parte**: `CachePolicyId` (null en los dos comportamientos), `OriginRequestPolicyId`, y `AllowedMethods` del comportamiento `/geo-bcn/v2/*` se queda en `GET, HEAD` (había 7). |
| SiteBucketPolicy | creado | sí, con la condición `AWS:SourceArn` de la distribución | |

Plano de datos (petición a `localhost:4577` con `Host: <id>.cloudfront.net`):
- `/` y `/index.html` → 200 con el `index.html` subido al bucket. `/barrios` → 200 con `index.html` (la reescritura SPA funciona).
- `redirect-to-https` no se aplica: responde 200 por HTTP.
- `/geo-bcn/v2/openapi.yaml` → **502**. Log: `CloudFront custom origin host geobcn-compute-loadbala-....elb.localhost.floci.io resolves to a private or reserved address; list it in floci.services.cloudfront.allowed-private-origin-hosts to allow it`.
- `POST /geo-bcn/v2/x` → 403 (por los `AllowedMethods` recortados).
- `FLOCI_SERVICES_CLOUDFRONT_ALLOWED_PRIVATE_ORIGIN_HOSTS` solo admite nombres exactos: con `*.elb.localhost.floci.io` sigue el 502, y con `.elb.localhost.floci.io` Floci no arranca (`Empty label is not a legal name`). Como el DNS del ALB es aleatorio en cada despliegue, no he podido probar CloudFront → ALB. Haría falta arrancar Floci con persistencia (`floci.storage.mode`) y reiniciarlo con el nombre exacto; no lo he intentado.

## PostGIS

| Imagen RDS | Resultado |
|---|---|
| Por defecto (`postgres:17.7-alpine`) | `CREATE EXTENSION postgis` → `ERROR: extension "postgis" is not available` |
| `postgis/postgis:16-3.5` vía `FLOCI_SERVICES_RDS_DEFAULT_POSTGRES_IMAGE` | La instancia falla: `Could not pull image: no matching manifest for linux/arm64/v8 in the manifest list entries` (no hay imagen arm64; la que usa `geo-bcn-postgis` es amd64 emulada) |
| `geo-postgis:17` (`local/postgis/Dockerfile`: `postgres:17` + `postgresql-17-postgis-3`, construida en local) | Funciona con `data.yaml` y con la variante: `CREATE EXTENSION`, PostGIS 3.7.0 y `ST_Transform` a EPSG:25831 correcto |

Nota: con esa imagen el servidor es 17.12 aunque la plantilla pida 17.7. Floci no valida `EngineVersion` contra la imagen.

## Lo que Floci no valida (ni aquí ni con ninguna variante)

IAM (políticas y `AssumeRole`), security groups y rutas (la red real es la red Docker), NAT, prefix lists de CloudFront, `ScanOnPush`, snapshots al borrar, `EngineVersion` real, políticas de caché de CloudFront y HTTPS.

## Qué dejo en el repo

- `local/compose.yaml`, `local/compose.postgis.yaml`, `local/env.sh`, `local/wait.sh`, `local/deploy-all.sh`, `local/postgis/Dockerfile`
- `variants/data-secret-explicito.yaml`
- `.venv/` (cfn-lint; conviene ignorarlo en git)
- La imagen Docker `geo-postgis:17` queda en local.

Floci y sus contenedores hijos (`floci-aws-geofloci-*`) y redes están borrados. No he tocado `geo-bcn-postgis` ni nada de LRZBank.

## Parámetro DbSecretMode

Prueba del nuevo `cloudformation/data.yaml` (la versión anterior está en `variants/data.yaml.anterior`):
- `DbSecretMode`: `managed` (por defecto) usa `ManageMasterUserPassword` y es el modo para AWS real. `explicit` crea un secreto propio `DbSecret` con `{"username":"geobcn","password":...}` y se lo pasa a RDS con `{{resolve:secretsmanager}}`.
- La regla `ExplicitSecretUsername` exige `DbUsername=geobcn` en modo `explicit`.

`compute.yaml`, `network.yaml` y `edge.yaml` no cambian. `cfn-lint` 1.61.0: 0 avisos en las 4.

Entorno: Floci 2.5.0 nuevo (`geo-floci`, puerto 4577) con `local/compose.yaml` + `local/compose.postgis.yaml` (RDS con `geo-postgis:17`). Despliegue con `bash local/deploy-all.sh`, que ya pasa `DbSecretMode=explicit`.

| Caso | Resultado | Detalle |
|---|---|---|
| `geobcn-network` | CREATE_COMPLETE | Como antes. |
| `geobcn-data` con `DbSecretMode=explicit` | CREATE_COMPLETE | Se crean `DbSecret`, `DbSubnetGroup` y `Database`. El secreto contiene `username=geobcn` y `password` (32 caracteres). El export `DbSecretArn` es un ARN real (`arn:aws:secretsmanager:eu-west-1:000000000000:secret:geobcn-data-DbSecret-...`). |
| psql + PostGIS con la contraseña del secreto | OK | `CREATE EXTENSION` y `postgis_lib_version()` = 3.7.0, a través del proxy RDS de Floci. |
| `geobcn-compute` (plantilla del repo, sin variante) | CREATE_COMPLETE | Servicio `ACTIVE` con 1 tarea. La tarea recibe `DB_URL`, `DB_USER=geobcn` (sacado del JSON del secreto con `:username::`), `DB_PASSWORD` (32 car), `GEOBCN_JWT_SECRET` (48 car) y `GEOBCN_API_KEYS` (40 car). |
| ALB → ECS | 200 | Target `healthy` y `GET /geo-bcn/v2/openapi.yaml` por el ALB = 200. |
| `geobcn-edge` | CREATE_COMPLETE | Como antes (CloudFront → ALB sigue sin poder probarse). |
| `data` con `DbSecretMode=managed` (por defecto) | CREATE_COMPLETE, sin secreto | No se crea secreto. `DbSecretArn` exporta el texto `Database.MasterUserSecret.SecretArn`. Log: `Unresolved GetAtt: Database.MasterUserSecret.SecretArn`. Es lo esperado: es el modo de AWS real y aquí no se puede probar. |
| `compute` sobre `data` en `managed` | ROLLBACK_COMPLETE | `ExecutionRole  Resource Database.MasterUserSecret.SecretArn must be in ARN format or "*".` (el mismo error de antes) |
| Regla: `explicit` + `DbUsername=otro` | **CREATE_COMPLETE, la regla no se evalúa** | Floci ignora `Rules`: crea la pila sin error. El resultado es justo lo que la regla quiere evitar: RDS tiene el usuario `otro`, pero el secreto dice `geobcn`, y `psql` con el secreto falla con `FATAL: password authentication failed for user "geobcn"` / `Role "geobcn" does not exist`. En AWS real, `create-stack` debería rechazarlo con el `AssertDescription`. No lo he podido comprobar aquí, y `cfn-lint` no evalúa reglas con valores de parámetros. |

Notas:
- Para el health check en 200 he usado `nginxinc/nginx-unprivileged:alpine` (escucha en 8080), como la vez anterior, en lugar de `nginx:alpine`. Esta última escucha en el 80 y el target nunca estaría sano. Se elige con `IMAGE_URI=... bash local/deploy-all.sh`. El fichero `/geo-bcn/v2/openapi.yaml` lo creé a mano dentro del contenedor de la tarea.
- `variants/data-secret-explicito.yaml` queda **obsoleta** (lo indica su cabecera) y se conserva solo como referencia.
- Floci, sus contenedores `floci-aws-geofloci-*` y sus redes están borrados.

## Despliegue de la app

La app real (back `ms-geo-bcn` y front `front-geo-bcn`) corre sobre la infra de Floci. Todo se queda en marcha.

**Abrir en el navegador del Mac: <http://localhost:8088>**. El mapa carga las 1.760 fuentes, los filtros de distrito y barrio, y la ficha de cada fuente.

### Comandos (desde `infra-geo-bcn/`)

```bash
bash local/up.sh          # Floci limpio (con ECR en modo ruta y RDS PostGIS)
bash local/deploy-all.sh  # infra: 4 pilas, compute con un nginx de relleno
bash local/deploy-app.sh  # datos + back al ECR + update-stack de compute + front a S3
bash local/app-up.sh      # proxy local en http://localhost:8088
bash local/down.sh        # lo borra todo (proxy, Floci, contenedores y redes de este proyecto)
```

`deploy-app.sh` admite `--skip-back` y `--skip-front`. Para desplegar otra versión del back, basta con volver a lanzarlo: cada vez usa un tag nuevo (`0.0.1-AAAAMMDDhhmmss`), porque el repositorio ECR es `IMMUTABLE`.

### Qué hace cada paso

| Paso | Cómo | Resultado |
|---|---|---|
| Imagen del back | `ms-geo-bcn/Dockerfile` nuevo (multi-stage Maven/Temurin 17, usuario 10001, puerto 8080, sin secretos) y `.dockerignore`. No he tocado ningún fichero existente del repo. | arm64 nativa, unos 129 MB |
| Imagen en ECR | Tag fijo por versión. Se empuja a `localhost:5100/<cuenta>/<región>/<repo>` (el registro de Floci) y la pila la usa como `RepositoryUri:tag`. | `describe-images` la lista |
| Orden de dependencias | El repositorio lo crea la misma pila que el servicio: `deploy-all.sh` crea compute con `nginxinc/nginx-unprivileged:alpine` como relleno, se sube la imagen y `update-stack --use-previous-template` cambia solo `ImageUri`. `compute.yaml` no cambia. | UPDATE_COMPLETE |
| Datos | Migración `ms-geo-bcn/db/migration/V1__...sql` (solo si no existe la tabla) y carga `db/load/load_fonts_beure.sql` con el CSV, contra el RDS de `geobcn-data` con la clave de su secreto | 1.760 fuentes, 10 distritos, 73 barrios; PostGIS 3.7.0 |
| Health check | `/geo-bcn/v2/openapi.yaml` responde 200 sin API key (`ApiAuthFilter.shouldNotFilter`). No hace falta otro `HealthCheckPath`. | target `healthy` |
| Front | `npm ci && npm run build` en `front-geo-bcn` (sin tocar `.env` ni código; `dist/` está en `.gitignore`) y `aws s3 sync dist/` al bucket de `geobcn-edge` | CloudFront sirve el front real en `/` |
| Proxy local | `local/proxy/Caddyfile` + `local/app-up.sh`, contenedor `geo-app-proxy` en `127.0.0.1:8088`: `/geo-bcn/v2/*` → ALB con `X-Api-Key`; el resto → CloudFront de Floci → S3 | <http://localhost:8088> |

### Pruebas de extremo a extremo (ALB, desde la red de Floci)

| Petición | Resultado |
|---|---|
| `GET /geo-bcn/v2/openapi.yaml` sin key | 200 |
| `GET /geo-bcn/v2/districts` sin key | 401 |
| `GET /geo-bcn/v2/districts` con `X-Api-Key: dev-api-key` | 401 (en Floci la key es la del secreto, no la de dev) |
| `GET /geo-bcn/v2/districts` con la key de `ApiKeySecret` | 200, 10 distritos con sus barrios |
| `GET /geo-bcn/v2/drinking-water-fountains?lat=41.3851&lon=2.1734&radius=300&limit=2` con key | 200, fuentes reales con paginación `next` |
| `GET /geo-bcn/v2/drinking-water-fountains?limit=2000` con key | 200, unos 547 KB |
| Navegador → `http://localhost:8088` | `GET /districts` 200 y `GET /drinking-water-fountains?limit=2000` 200; mapa con clusters y ficha |

Comando para repetirlo (la key sale del secreto, no se escribe en ningún fichero):

```bash
source local/env.sh
KEY=$(aws secretsmanager get-secret-value --secret-id "$(aws cloudformation describe-stack-resources --stack-name geobcn-compute --logical-resource-id ApiKeySecret --query 'StackResources[0].PhysicalResourceId' --output text)" --query SecretString --output text)
docker run --rm --network geo-floci-net curlimages/curl:8.11.1 -s -H "X-Api-Key: $KEY" http://floci:80/geo-bcn/v2/districts
```

### API key del front

El front **no lleva la API key en el bundle**. En desarrollo, el proxy de Vite añade `X-Api-Key: dev-api-key`. En Floci, la key válida es la que genera CloudFormation en `ApiKeySecret` (40 caracteres), y `dev-api-key` da 401. El proxy local la lee al arrancar (`app-up.sh`) de la cabecera de origen configurada en la distribución de CloudFront, y la añade a cada petición `/geo-bcn/v2/*`.

### Qué no funciona o hay que decidir

- **Hallazgo de arquitectura (afecta a AWS real):** con el front estático en S3 nadie añadía `X-Api-Key`, así que el navegador habría recibido 401 en `/geo-bcn/v2/*`. **Resuelto:** CloudFront añade la key como cabecera de origen (ver la sección «X-Api-Key en CloudFront»).
- **CloudFront → ALB en Floci:** sigue dando 502 (origen con IP privada). Lo sustituye el proxy local. Sin él, `/` funciona por CloudFront pero la API no.
- **ECR en Floci:** con la URI por defecto (`000000000000.dkr.ecr.eu-west-1.localhost:4577`), Docker Desktop no resuelve el host y ECS no puede descargar la imagen. El `update-stack` acabó en `UPDATE_ROLLBACK_FAILED` con `dial tcp: lookup 000000000000.dkr.ecr.eu-west-1.localhost: no such host`. Por eso `local/compose.yaml` arranca Floci con `FLOCI_SERVICES_ECR_URI_STYLE=path` (URI `localhost:4577/000000000000/eu-west-1/<repo>`). Aun así, el push por `:4577` da `denied`, y se hace al registro directamente (`:5100`).
- **Tareas huérfanas:** Floci no para el contenedor de la tarea anterior al hacer un despliegue nuevo. `deploy-app.sh` borra los contenedores de tareas que ECS ya no lista.
- **Imagen de prueba en ECR:** el repositorio tiene además un tag `probe-1`, de una prueba de push; desaparece con `down.sh`.
- `local/verify.sh` está pensado para la infra con el nginx de relleno. Con la app real, las comprobaciones del health check y del contenido de CloudFront ya no aplican igual.

## X-Api-Key en CloudFront

El back exige `X-Api-Key` y el front estático no la lleva, así que la añade CloudFront en cada petición al ALB. El navegador nunca la ve y la clave no está en el repo.

Cambios en las plantillas (`cfn-lint` 1.61.0: 0 avisos en las 4):
- `compute.yaml`, en Outputs: `ApiKeySecretArn: {Value: !Ref ApiKeySecret, Export: {Name: !Sub "${AWS::StackName}-ApiKeySecretArn"}}`.
- `edge.yaml`, en el origen `api`: `OriginCustomHeaders` con `X-Api-Key = {{resolve:secretsmanager:${SecretArn}:SecretString}}`, con `SecretArn` sacado del export anterior.

| Prueba | Resultado |
|---|---|
| `update-stack` de `geobcn-compute` en caliente (plantilla nueva, todos los parámetros con `UsePreviousValue`, incluido el `ImageUri` real) | UPDATE_COMPLETE, export `geobcn-compute-ApiKeySecretArn` creado |
| `update-stack` de `geobcn-edge` en caliente | UPDATE_COMPLETE |
| `get-distribution-config`: origen `api` → `CustomHeaders` | `Quantity: 1`, `X-Api-Key` **coincide** con `ApiKeySecret` (40 car; empieza por los 4 caracteres que muestra `verify.sh`) |
| Referencia dinámica `{{resolve:secretsmanager:<arn>:SecretString}}` en `OriginCustomHeaders` | Se resuelve. Floci deja en el log `a dynamic reference did not resolve ({{resolve:secretsmanager:${SecretArn}:SecretString}}): Secrets Manager can't find the specified secret.` (es un primer intento antes de sustituir `${SecretArn}`, igual que en `data.yaml`), pero el valor final es la clave real |
| App real: ALB `/geo-bcn/v2/districts` con la `X-Api-Key` leída de la distribución | 200 |
| App real: ALB `/geo-bcn/v2/districts` sin cabecera | 401 |
| Desde cero (`down.sh`, `up.sh`, `deploy-all.sh`, `verify.sh`, `deploy-app.sh`, `app-up.sh`) | 4 pilas CREATE_COMPLETE, `verify.sh` 24 OK / 0 fallos, compute UPDATE_COMPLETE con la imagen real, proxy en marcha |
| Navegador → <http://localhost:8088> | Mapa con las 1.760 fuentes |

Cambios en `local/`:
- `verify.sh` añade dos comprobaciones: la cabecera de la distribución coincide con el secreto, y el ALB responde 200 con esa cabecera.
- `app-up.sh` ya no lee la clave de Secrets Manager: el proxy usa la `X-Api-Key` configurada en la distribución, la misma que enviaría CloudFront.
- `deploy-all.sh` y `deploy-app.sh` no cambian: el orden (compute antes que edge) ya era el necesario.

**Qué se prueba de verdad y qué no:**
- Sí: que CloudFormation resuelve el secreto y deja la clave correcta en la configuración de la distribución, y que esa clave abre el back real detrás del ALB.
- No: que CloudFront **envíe** la cabecera en una petición real. En Floci, CloudFront → ALB sigue dando 502 (origen con IP privada), así que ese salto lo hace el proxy local con el mismo valor.
- No: que CloudFront sustituya una `X-Api-Key` enviada por el navegador. En AWS, una cabecera de origen con el mismo nombre que una del viewer la reemplaza, así que nadie puede colar otra clave.

Notas para AWS real:
- El valor de la cabecera queda en texto claro en `GetDistributionConfig` para quien tenga permisos de lectura de CloudFront.
- Una referencia dinámica se resuelve solo al desplegar: si se rota la clave en Secrets Manager, hay que volver a desplegar `geobcn-edge` (y reiniciar las tareas del back para que lean la nueva).
- Con la clave puesta por CloudFront, la clave de la API sirve también para que el back rechace lo que llegue al ALB sin pasar por CloudFront (además del security group con el prefix list).
