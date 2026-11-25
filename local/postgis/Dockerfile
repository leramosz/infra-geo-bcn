# PostgreSQL 17 con PostGIS para el RDS de Floci en Mac ARM (postgis/postgis no publica imagen arm64).
FROM postgres:17
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-postgis-3 \
 && rm -rf /var/lib/apt/lists/*
