# Testing Guide for Docker Compose Fixes

## Prerequisites
- Docker and Docker Compose installed
- Access to the data files (`callejero_geolocalizador.geojson` and `intersecciones_geolocalizador.geojson`)

## Quick Test (Recommended)

### 1. Clean Start Test
This test verifies the fix works with a fresh installation:

```bash
# Stop and remove all containers, networks, and volumes
docker compose down -v

# Start the services
docker compose up
```

**Expected Results:**
- ✅ All services start successfully
- ✅ No "column nums_norm does not exist" error
- ✅ No "cannot change name of input parameter" error
- ✅ `importer-1` container completes with exit code 0 (not 3)
- ✅ The log should show:
  ```
  [importer] Refrescando derivados...
  [importer] Ejecutando análisis preliminar...
  [importer] Ejecutando postload: /app/postload.sql
  [importer] Importación finalizada.
  ```

### 2. Database Verification
After the import completes successfully, verify the database state:

```bash
# Check that the nums_norm column exists
docker compose exec db psql -U postgres -c "\d intersecciones_geolocalizador" | grep nums_norm

# Expected output: 
# nums_norm | text[] | 

# Check that the function exists with correct signature
docker compose exec db psql -U postgres -c "\df sugerencias_calles"

# Expected output should show:
# public | sugerencias_calles | TABLE(numero_cal text, nombre_cal text, score numeric) | q text, lim integer DEFAULT 20
```

### 3. Functional Test
Test that the geocoding functions work:

```bash
# Test sugerencias_calles function
docker compose exec db psql -U postgres -c "SELECT * FROM public.sugerencias_calles('san martin', 5);"

# Test nums_norm column is populated
docker compose exec db psql -U postgres -c "SELECT count(*) FROM intersecciones_geolocalizador WHERE nums_norm IS NOT NULL;"

# Expected: Should return a count > 0 if data was imported
```

## Advanced Tests

### Test 1: Incremental Update (Idempotency Test)
This test verifies that re-running the importer doesn't cause errors:

```bash
# With containers already running, restart just the importer
docker compose restart importer

# Check logs
docker compose logs importer

# Expected: Should either skip import or handle existing data gracefully
```

### Test 2: API Endpoints
Test the API is working correctly:

```bash
# Wait for API to be ready
sleep 5

# Test direccion endpoint
curl "http://localhost:8000/geocode/direccion?calle=San%20Martin&altura=100"

# Expected: Should return JSON with coordinates

# Test sugerencias endpoint
curl "http://localhost:8000/geocode/sugerencias?q=san"

# Expected: Should return JSON array with street suggestions
```

### Test 3: Manual SQL Test
Manually test the problematic SQL from the logs:

```bash
docker compose exec db psql -U postgres <<'EOF'
-- Test that the nums_norm backfill works
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='intersecciones_geolocalizador'
               AND column_name='nums_norm')
     AND EXISTS (SELECT 1 FROM pg_proc WHERE proname='calc_nums_norm' 
                 AND pronamespace = 'public'::regnamespace) THEN
    UPDATE public.intersecciones_geolocalizador
    SET nums_norm = public.calc_nums_norm(num_calle)
    WHERE nums_norm IS NULL;
    RAISE NOTICE 'Backfill completed successfully';
  ELSE
    RAISE NOTICE 'Column or function not found - skipping backfill';
  END IF;
END$$;
EOF

# Expected: Should complete without errors
```

## Troubleshooting

### If you still see errors:

1. **Check Docker Compose version:**
   ```bash
   docker compose version
   ```
   Ensure you're using Docker Compose V2 (not docker-compose V1)

2. **Check if old containers are cached:**
   ```bash
   docker compose down -v --remove-orphans
   docker system prune -f
   ```

3. **Rebuild containers:**
   ```bash
   docker compose build --no-cache
   docker compose up
   ```

4. **Check data files exist:**
   ```bash
   ls -lh data/
   ```
   Should show:
   - `callejero_geolocalizador.geojson`
   - `intersecciones_geolocalizador.geojson`

5. **Check PostgreSQL logs:**
   ```bash
   docker compose logs db | grep ERROR
   ```

## Success Criteria

The fix is successful if:
- ✅ All containers start and run without fatal errors
- ✅ The `importer` container completes and exits with code 0
- ✅ No "column nums_norm does not exist" error appears
- ✅ No "cannot change name of input parameter" error appears
- ✅ Database has all expected tables and functions
- ✅ API responds to geocoding requests
- ✅ The `nums_norm` column is populated in `intersecciones_geolocalizador`

## What Was Fixed

### Issue 1: Missing Column Check
**Before:** The script tried to UPDATE `nums_norm` without checking if it exists
**After:** Added explicit checks for both column and function existence before any operations

### Issue 2: Function Parameter Conflict
**Before:** Used `CREATE OR REPLACE` which couldn't handle parameter name changes
**After:** Implemented proper dynamic SQL dropping of all function variants before creating new one

### Issue 3: Import Script Missing Step
**Before:** Import script had no "Refrescando derivados" step
**After:** Added the step with proper safety checks

## Performance Notes

- Initial import may take several minutes depending on data size
- The "Refrescando derivados" step processes all intersection records
- If you have a large dataset, expect longer processing times

## Monitoring Progress

Watch the logs in real-time:
```bash
docker compose logs -f importer
```

Expected timeline:
1. **0-10s:** Waiting for PostgreSQL
2. **10-30s:** Importing callejero data
3. **30-60s:** Importing intersecciones data
4. **60-90s:** Refrescando derivados (backfilling nums_norm)
5. **90-120s:** Running postload.sql (creating indexes and functions)
6. **120s+:** Import complete

## Need Help?

If errors persist:
1. Save complete logs: `docker compose logs > docker-logs.txt`
2. Check FIX_SUMMARY.md for detailed technical explanation
3. Review the specific error messages in the logs
4. Verify all prerequisites are met
