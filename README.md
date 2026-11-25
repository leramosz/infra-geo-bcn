# infra-geo-bcn

IaC en CloudFormation de **BCN Geo** (API de fuentes de agua potable de Barcelona): front estático en S3 + CloudFront,
back Spring Boot ([ms-geo-bcn](https://github.com/leramosz/ms-geo-bcn)) en ECS Fargate detrás de un ALB, y RDS
PostgreSQL con PostGIS. CloudFront añade la `X-Api-Key` hacia el back, así que el navegador nunca la ve.

| Plantilla | Pila | Contenido |
|---|---|---|
| `cloudformation/network.yaml` | `geobcn-network` | VPC, subredes públicas y privadas, NAT, security groups |
| `cloudformation/data.yaml` | `geobcn-data` | RDS PostgreSQL; `DbSecretMode=managed` (AWS) o `explicit` (emulador) |
| `cloudformation/compute.yaml` | `geobcn-compute` | ECR, ALB, ECS Fargate, secretos de API key y JWT |
| `cloudformation/edge.yaml` | `geobcn-edge` | S3 privado + CloudFront (origen S3 y `/geo-bcn/v2/*` al ALB) |

Detalle y decisiones: [ARQUITECTURA.md](ARQUITECTURA.md).

## Probar en local (Floci, gratuito)

Requisitos: Docker, AWS CLI v2 y, para el despliegue de la app, los repos `ms-geo-bcn` y `front-geo-bcn` clonados
junto a este. Todo corre contra Floci (imagen `floci/floci:2.5.0`) en `localhost:4577` con credenciales de prueba.

```bash
bash local/up.sh          # Floci limpio
bash local/deploy-all.sh  # las 4 pilas (compute arranca con un nginx de relleno)
bash local/deploy-app.sh  # datos, back al ECR + update-stack, front a S3
bash local/app-up.sh      # app en http://localhost:8088
bash local/down.sh        # lo borra todo
```

`bash local/verify.sh` comprueba la infra contra los servicios del emulador. Qué funciona y qué no en Floci:
[RESULTADOS-FLOCI.md](RESULTADOS-FLOCI.md).

> **Aviso:** estas plantillas solo se han probado en un emulador (Floci). No se han desplegado en AWS real. IAM,
> cuotas, versiones de motor, prefix lists y el tramo CloudFront → ALB no se validan en el emulador.
