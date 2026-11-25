#!/usr/bin/env bash
# Borra el proxy de la app (geo-app-proxy), el Floci de este proyecto y lo que crea (contenedores floci-aws-geofloci-*, sus redes y geo-floci-net).
docker rm -f geo-app-proxy geo-floci >/dev/null 2>&1
ids=$(docker ps -aq --filter name=floci-aws-geofloci-); [ -n "$ids" ] && docker rm -f $ids >/dev/null
for n in $(docker network ls --format '{{.Name}}' | grep -E '^(floci-aws-geofloci-|geo-floci-net$)'); do docker network rm "$n" >/dev/null; done
true
