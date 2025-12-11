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

### WSL2 Clock Synchronization Warnings

**Symptom**: 
```json
{
  "@timestamp":"2025-12-11T18:01:57.366Z",
  "log.level": "WARN",
  "message":"absolute clock went backwards by [459ms/459ms] while timer thread was sleeping",
  ...
}
```

**Cause**: WSL2 virtual machine clock drift issues.

**Solution**: See the dedicated [WSL2_TROUBLESHOOTING.md](./WSL2_TROUBLESHOOTING.md) guide for comprehensive solutions.

**Quick Fix**: These warnings are generally harmless and won't affect functionality. The system includes configuration to suppress them.

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

### Elasticsearch startup INFO logs

**Symptom** (example):
```json
{"@timestamp":"2025-12-11T18:37:32.454Z", "log.level": "INFO", "message":"loaded module [x-pack-eql]", "ecs.version": "1.2.0","service.name":"ES_ECS","event.dataset":"elasticsearch.server","process.thread.name":"main","log.logger":"org.elasticsearch.plugins.PluginsService","elasticsearch.node.name":"f926ec486065","elasticsearch.cluster.name":"docker-cluster"}
{"@timestamp":"2025-12-11T18:37:33.533Z", "log.level": "INFO", "message":"using [1] data paths, mounts [[/usr/share/elasticsearch/data (/dev/sde)]], net usable_space [818.1gb], net total_space [1006.8gb], types [ext4]", "ecs.version": "1.2.0","service.name":"ES_ECS","event.dataset":"elasticsearch.server","process.thread.name":"main","log.logger":"org.elasticsearch.env.NodeEnvironment","elasticsearch.node.name":"f926ec486065","elasticsearch.cluster.name":"docker-cluster"}
{"@timestamp":"2025-12-11T18:37:33.599Z", "log.level": "INFO", "message":"node name [f926ec486065], node ID [LHXD3xpTTgKMKZqkoOeDSg], cluster name [docker-cluster], roles [data_hot, ml, data_frozen, ingest, data_cold, data, remote_cluster_client, master, data_warm, data_content, transform]", "ecs.version": "1.2.0","service.name":"ES_ECS","event.dataset":"elasticsearch.server","process.thread.name":"main","log.logger":"org.elasticsearch.node.Node","elasticsearch.node.name":"f926ec486065","elasticsearch.cluster.name":"docker-cluster"}
```

**What it means**: These are normal Elasticsearch startup messages (module loading, data paths, node info/roles). They do not indicate failures.

**Action**: None. Investigate only if `WARN`/`ERROR` lines appear or if the healthcheck shows issues.
- Healthcheck commands: `docker compose ps` and `curl http://localhost:9200/_cluster/health`
- Expected responses: `"status":"green"`; `"status":"yellow"` can be acceptable on single-node dev setups.

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
