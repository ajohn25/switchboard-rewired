# CD into ./migrations/data and to run ./production-seed.sh
psql "$DATABASE_URL" -f geo-seed.sql -1
