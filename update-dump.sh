#!/bin/bash

PG_HOST_PORT=${1:-"6432"}

echo "Spinning up Postgres Docker container..."

# Start the container in the background
CONTAINER_ID=$(docker container run -d  \
  --cap-add SYS_RESOURCE \
  --platform linux/amd64 \
  -p $PG_HOST_PORT:5432  \
  -e ALLOW_NOSSL=true \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=zalando \
  registry.opensource.zalan.do/acid/spilo-14:2.1-p6)


retVal=$?
if [ $retVal -ne 0 ]; then
  echo "Failed to start container"
  exit $retVal
fi

# Crude wait for container to be ready
export PROD_POSTGRES_URL=postgres://postgres:zalando@127.0.0.1:$PG_HOST_PORT/postgres
echo "Waiting for container to be ready..."
until psql --no-psqlrc $PROD_POSTGRES_URL -c 'select 1' 2>/dev/null 1>/dev/null; do
  sleep 0.2
done
echo -e "Container is ready. Running migrations...\n"

psql --no-psqlrc $PROD_POSTGRES_URL -c "create database switchboard;";
export PROD_POSTGRES_URL=postgres://postgres:zalando@127.0.0.1:$PG_HOST_PORT/switchboard

# Run the migrations against the temporary Docker container
NODE_ENV=production yarn migrate:worker && NODE_ENV=production yarn migrate up

# Dump the schema using the pegged pg_dump version in the container
docker exec -e PGPASSWORD=zalando $CONTAINER_ID pg_dump -U postgres -d switchboard --schema-only  \
  --schema public \
  --schema billing  \
  --schema lookup  \
  --schema geo  \
  --schema sms  \
  --schema worker  \
  > ./schema-dump.sql

docker kill $CONTAINER_ID 1>/dev/null
