# Docker Compose Troubleshooting

## Clearing Persistent Volumes

If you encounter errors related to old database schema or function definitions, you may need to clear the persistent volumes:

```bash
# Stop all containers
docker compose down

# Remove volumes (WARNING: This will delete all data)
docker volume rm geocodificador_pgdata geocodificador_esdata

# Or use the prune command to remove all unused volumes
docker volume prune

# Then start fresh
docker compose up
```

## Common Errors

### Error: "cannot change name of input parameter"

**Symptom**: 
```
ERROR:  cannot change name of input parameter "q"
HINT:  Use DROP FUNCTION sugerencias_calles(text,integer) first.
```

**Cause**: The PostgreSQL volume contains an old version of functions with different parameter names.

**Solution**: Clear the pgdata volume as shown above, or connect to the database and manually drop the functions:

```bash
docker compose exec db psql -U postgres -d postgres -c "DROP FUNCTION IF EXISTS public.sugerencias_calles CASCADE;"
```

### Error: "column nums_norm does not exist"

**Symptom**:
```
ERROR:  column "nums_norm" does not exist
LINE 3:       WHERE nums_norm IS NULL
```

**Cause**: The import script was trying to update the nums_norm column before it was created by postload.sql.

**Solution**: This has been fixed in the latest version. If you still see this error, clear volumes and rebuild:

```bash
docker compose down
docker volume rm geocodificador_pgdata
docker compose build --no-cache importer
docker compose up
```

## Fresh Start

To completely start from scratch:

```bash
# Stop and remove everything
docker compose down -v

# Remove any built images
docker compose rm -f
docker rmi geocodificador-importer geocodificador-loader geocodificador-api

# Rebuild and start
docker compose build --no-cache
docker compose up
```

## Checking Status

To verify all services are running correctly:

```bash
# Check service status
docker compose ps

# Check logs for specific service
docker compose logs importer
docker compose logs api
docker compose logs db

# Follow logs in real-time
docker compose logs -f
```

## API Health Check

Once running, verify the API is working:

```bash
curl http://localhost:8000/health
```

Expected response: `{"status":"ok"}`
