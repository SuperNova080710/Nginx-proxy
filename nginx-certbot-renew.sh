#!/bin/bash

set -e

cd /home/sgp/nginx-proxy

docker compose run --rm certbot renew --quiet

docker compose exec -T nginx nginx -s reload