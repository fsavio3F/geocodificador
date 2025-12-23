# Columna nums_norm en Intersecciones

## ¿Qué es nums_norm?

`nums_norm` es una **columna derivada/calculada** en la tabla `intersecciones_geolocalizador` que NO viene en el archivo GeoJSON original. Se crea y mantiene automáticamente por PostgreSQL.

## Flujo de Datos

### 1. Archivo GeoJSON Original
```json
{
  "type": "Feature",
  "properties": {
    "calles": "Gaceta de Buenos Aires; Doctor Alfredo Lorenzo Palacios",
    "id_calle": "7; 8; 9; 26",
    "num_calle": "205; 248",    ← Campo original en el GeoJSON
    "ID_inter_nuevo": 10
  },
  "geometry": { "type": "Point", "coordinates": [...] }
}
```

### 2. Importación con ogr2ogr
```bash
ogr2ogr -f PostgreSQL "PG:..." intersecciones_geolocalizador.geojson
```

Crea tabla con columnas del GeoJSON:
- `calles` (text)
- `id_calle` (text)
- `num_calle` (text) - ejemplo: "205; 248"
- `ID_inter_nuevo` (integer)
- `geom` (geometry)

### 3. Post-procesamiento (postload.sql)

#### a) Se crea la función de normalización:
```sql
CREATE OR REPLACE FUNCTION public.calc_nums_norm(src text)
RETURNS text[] AS $$
  -- Convierte "205; 248" en ARRAY['205', '248']
  -- Normaliza cada código (quita espacios, uppercase)
$$;
```

#### b) Se agrega la columna derivada:
```sql
ALTER TABLE intersecciones_geolocalizador
  ADD COLUMN IF NOT EXISTS nums_norm text[];
```

#### c) Se crea un trigger para mantenerla actualizada:
```sql
CREATE TRIGGER biu_set_nums_norm
BEFORE INSERT OR UPDATE OF num_calle
ON intersecciones_geolocalizador
FOR EACH ROW 
EXECUTE FUNCTION trg_set_nums_norm();
```

#### d) Se hace backfill de registros existentes:
```sql
UPDATE intersecciones_geolocalizador
SET nums_norm = calc_nums_norm(num_calle)
WHERE nums_norm IS NULL;
```

### 4. Resultado Final en PostgreSQL

```
 num_calle  |   nums_norm    
------------+----------------
 205; 248   | {205,248}
 248; 551   | {248,551}
 254; 551   | {254,551}
```

## ¿Por qué se hace así?

### Ventajas de una Columna Derivada

1. **Eficiencia en Búsquedas**
   ```sql
   -- Sin nums_norm (lento):
   WHERE num_calle LIKE '%205%' AND num_calle LIKE '%248%'
   
   -- Con nums_norm + índice GIN (rápido):
   WHERE ARRAY['205', '248'] <@ nums_norm
   ```

2. **Índice GIN**
   ```sql
   CREATE INDEX inter_nums_norm_gin 
   ON intersecciones_geolocalizador 
   USING gin (nums_norm);
   ```
   Permite búsquedas extremadamente rápidas de intersecciones.

3. **Normalización Consistente**
   - "205; 248" → ['205', '248']
   - "205 ; 248" → ['205', '248'] (espacios inconsistentes)
   - "  205;248  " → ['205', '248'] (espacios extra)

4. **Mantenimiento Automático**
   El trigger actualiza `nums_norm` automáticamente si cambia `num_calle`.

## Uso en Geocodificación de Intersecciones

```sql
-- Función: geocode_interseccion(calle1, calle2)
WITH codes AS (
  SELECT resolve_code_or_name('corrientes') AS c1,
         resolve_code_or_name('callao') AS c2
),
norm AS (
  SELECT norm_code(c1) AS n1, norm_code(c2) AS n2 FROM codes
)
SELECT geom
FROM intersecciones_geolocalizador i, norm
WHERE ARRAY[n1, n2] <@ i.nums_norm  ← Búsqueda rápida con índice GIN
   OR ARRAY[n2, n1] <@ i.nums_norm
LIMIT 1;
```

## Resumen

✅ **CORRECTO**: 
- El GeoJSON NO tiene la columna `nums_norm`
- PostgreSQL la crea y mantiene automáticamente
- Es una optimización de performance

❌ **INCORRECTO**:
- Agregar `nums_norm` al GeoJSON fuente
- Calcular manualmente los valores
- Mantenerla sincronizada fuera de PostgreSQL

## Solución de Problemas

### Error: "column nums_norm does not exist"

**Causa**: postload.sql no se ejecutó o falló.

**Solución**:
1. Verificar que postload.sql se ejecuta después de importar
2. Revisar logs del importer para errores
3. Ver DOCKER_TROUBLESHOOTING.md

### Valores NULL en nums_norm

**Causa**: El backfill no se ejecutó o `num_calle` está vacío.

**Solución**:
```sql
-- Ejecutar manualmente el backfill
UPDATE public.intersecciones_geolocalizador
SET nums_norm = public.calc_nums_norm(num_calle)
WHERE nums_norm IS NULL;
```

### Índice GIN no funciona

**Verificar que existe**:
```sql
SELECT indexname 
FROM pg_indexes 
WHERE tablename = 'intersecciones_geolocalizador' 
  AND indexname = 'inter_nums_norm_gin';
```

**Recrear si es necesario**:
```sql
DROP INDEX IF EXISTS inter_nums_norm_gin;
CREATE INDEX inter_nums_norm_gin 
ON public.intersecciones_geolocalizador 
USING gin (nums_norm);
```
