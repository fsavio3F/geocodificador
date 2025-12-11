# Geocodificador

Sistema de geocodificación para calles argentinas con arquitectura centrada en base de datos.

## 🏗️ Arquitectura

Este sistema sigue el principio de **"procesamiento intensivo en el servidor de base de datos"**. La mayoría del trabajo pesado de geocodificación, búsqueda y procesamiento de datos se realiza mediante funciones PostgreSQL/PostGIS, no en scripts de Python.

### Componentes

```
┌─────────────────┐
│   FastAPI       │  ← API ligera (solo llamadas a DB)
│   (Python)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   PostgreSQL    │  ← Motor principal: geocodificación,
│   + PostGIS     │     búsqueda, normalización
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Elasticsearch   │  ← Búsqueda fuzzy/autocompletado
│                 │
└─────────────────┘
```

### Filosofía de Diseño

✅ **En la Base de Datos** (PostgreSQL):
- Geocodificación de direcciones (`geocode_direccion`)
- Geocodificación de intersecciones (`geocode_interseccion`)
- Búsqueda y sugerencias de calles (`sugerencias_calles`)
- Normalización de texto (`norm_text`, `norm_code`)
- Cálculos geométricos con PostGIS
- Índices optimizados (GiST, GIN, trigram)

✅ **En Elasticsearch**:
- Búsqueda fuzzy avanzada
- Autocompletado con n-grams
- Tolerancia a errores tipográficos

❌ **NO en Python**:
- Procesamiento de coordenadas
- Lógica de búsqueda de calles
- Interpolación de alturas
- Matching de nombres

La API Python es solo un **thin wrapper** que:
1. Recibe requests HTTP
2. Llama a funciones de PostgreSQL
3. Devuelve JSON

## 🚀 Inicio Rápido

### Prerrequisitos

- Docker y Docker Compose v2
- 4GB+ RAM disponible
- Archivos GeoJSON en `./data/`:
  - `callejero_geolocalizador.geojson`
  - `intersecciones_geolocalizador.geojson`

### Configuración

1. Crear archivo `.env`:

```bash
PGDB=postgres
PGUSER=postgres
PGPASSWORD=postgres
ES_INDEX=calles
```

2. Levantar servicios:

```bash
docker compose up -d
```

El sistema iniciará automáticamente:
1. **db**: PostgreSQL + PostGIS
2. **elasticsearch**: Motor de búsqueda
3. **importer**: Importa GeoJSON → PostgreSQL (una vez)
4. **loader**: Carga datos → Elasticsearch (una vez)
5. **api**: API REST en http://localhost:8000

### Verificar Estado

```bash
curl http://localhost:8000/health
```

Respuesta esperada:
```json
{
  "status": "ok",
  "db": true,
  "es": true,
  "version": "1.1"
}
```

### Solución de Problemas

Si encuentras errores durante el inicio, consulta [DOCKER_TROUBLESHOOTING.md](./DOCKER_TROUBLESHOOTING.md) para soluciones comunes.

**Problemas frecuentes**:
- Error "cannot change name of input parameter": Limpia los volúmenes con `docker compose down -v`
- Error "column nums_norm does not exist": Corregido en la última versión, actualiza el código
- Importer falla: Verifica que los archivos GeoJSON existan en `./data/`

**Script de prueba automatizado**:
```bash
./scripts/test-docker-compose.sh
```

## 📡 API Endpoints

Todos los endpoints delegan el procesamiento pesado a funciones PostgreSQL.

### 1. Sugerencias de Calles

**Endpoint**: `GET /sugerencias`

Busca calles usando trigram similarity en PostgreSQL.

```bash
curl "http://localhost:8000/sugerencias?qstr=corrientes&limit=10"
```

**Función DB**: `public.sugerencias_calles(q text, lim int)`
- Normaliza texto con `norm_text()`
- Usa índice GIN trigram
- Calcula similarity score en SQL
- Deduplica por nombre

### 2. Sugerencias con Elasticsearch

**Endpoint**: `GET /sugerencias_es2`

Búsqueda fuzzy avanzada con tolerancia a errores.

```bash
curl "http://localhost:8000/sugerencias_es2?qstr=corientes&limit=10"
```

**Lógica**:
- Búsqueda híbrida: phrase match + prefix + fuzzy
- Deduplicación por nombre en Python (ligero)
- Ideal para autocompletado

### 3. Geocodificar Dirección

**Endpoint**: `GET /geocode_direccion`

Convierte dirección (calle + altura) en coordenadas.

```bash
curl "http://localhost:8000/geocode_direccion?calle=corrientes&altura=1234"
```

**Función DB**: `public.geocode_direccion(calle_q text, altura int, numero_cal_in text, fallback boolean)`

**Procesamiento en PostgreSQL**:
1. Resuelve nombre/código de calle → `resolve_code_or_name()`
2. Busca segmento con rangos de alturas correctos
3. Determina paridad (par/impar)
4. Interpola posición en geometría: `ST_LineInterpolatePoint()`
5. Transforma a WGS84: `ST_Transform(geom, 4326)`

Respuesta:
```json
{
  "success": true,
  "numero_cal": "1234",
  "nombre_cal": "AV CORRIENTES",
  "altura": 1234,
  "paridad": "par",
  "min_par": 1200,
  "max_par": 1400,
  "lat": -34.603722,
  "lon": -58.381592,
  "geojson": {...}
}
```

### 4. Geocodificar Intersección

**Endpoint**: `GET /geocode_interseccion`

Encuentra coordenadas de cruce entre dos calles.

```bash
curl "http://localhost:8000/geocode_interseccion?calle1=corrientes&calle2=callao"
```

**Función DB**: `public.geocode_interseccion(calle1_q text, calle2_q text)`

**Procesamiento en PostgreSQL**:
1. Resuelve códigos de ambas calles
2. Busca en tabla `intersecciones_geolocalizador` con índice GIN
3. Extrae punto de geometría
4. Transforma a WGS84

## 🗄️ Base de Datos

### Tablas Principales

#### `callejero_geolocalizador`
```sql
- id: bigint (PK)
- numero_cal: text (código único de calle)
- nombre_cal: text (nombre de calle)
- alt_ini_pa, alt_fin_pa: integer (rango par)
- alt_ini_im, alt_fin_im: integer (rango impar)
- geom: geometry(MULTILINESTRING, 4326)
```

#### `intersecciones_geolocalizador`
```sql
- id: bigint (PK)
- num_calle: text (códigos separados por ;)
- nums_norm: text[] (códigos normalizados)
- geom: geometry
```

### Funciones Clave

Definidas en `db/postload.sql`:

| Función | Propósito |
|---------|-----------|
| `norm_text(text)` | Normaliza texto: lowercase, sin acentos, espacios |
| `norm_code(text)` | Normaliza código: uppercase, sin espacios |
| `resolve_calle(q, lim)` | Busca calles por similaridad |
| `resolve_code_or_name(q)` | Resuelve código desde nombre o código |
| `geocode_direccion(...)` | **Función principal de geocodificación** |
| `geocode_interseccion(...)` | Geocodifica intersecciones |
| `sugerencias_calles(q, lim)` | Wrapper para sugerencias |

### Índices

```sql
-- Búsqueda fuzzy por nombre
CREATE INDEX callejero_nombre_trgm_idx 
  ON callejero_geolocalizador 
  USING gin ((norm_text(nombre_cal)) gin_trgm_ops);

-- Búsqueda exacta por código
CREATE INDEX callejero_numcode_idx 
  ON callejero_geolocalizador (norm_code(numero_cal));

-- Índices espaciales
CREATE INDEX callejero_geom_gist 
  ON callejero_geolocalizador USING gist (geom);

CREATE INDEX inter_geom_gist 
  ON intersecciones_geolocalizador USING gist (geom);

-- Búsqueda de intersecciones
CREATE INDEX inter_nums_norm_gin 
  ON intersecciones_geolocalizador USING gin (nums_norm);
```

## 📥 Pipeline de Importación

### 1. Inicialización DB (`db/init/00_core.sql`)

Ejecutado automáticamente al crear el contenedor:
- Instala extensiones: PostGIS, unaccent, pg_trgm
- Crea funciones de utilidad
- **NO crea tablas** (las crea ogr2ogr)

### 2. Importación GeoJSON (`importer/import.sh`)

```bash
# Ejecuta ogr2ogr para importar GeoJSON → PostgreSQL
ogr2ogr -f PostgreSQL "PG:..." \
  callejero_geolocalizador.geojson \
  -nln public.callejero_geolocalizador \
  -t_srs EPSG:4326
```

**Ventajas de ogr2ogr**:
- Maneja proyecciones automáticamente
- Crea índices espaciales
- Optimizado para GeoJSON grandes
- Evita código Python custom

### 3. Post-Procesamiento (`db/postload.sql`)

Ejecutado después de importar:
- Crea índices adicionales
- Define funciones de geocodificación
- Materializar columnas derivadas (`nums_norm`)
- Ejecuta `ANALYZE` para estadísticas

### 4. Carga a Elasticsearch (`loader/load_calles.py`)

```python
# Lee desde PostgreSQL con cursor
SELECT id, numero_cal, nombre_cal,
       ST_Y(ST_Centroid(ST_Transform(geom,4326))) AS lat,
       ST_X(ST_Centroid(ST_Transform(geom,4326))) AS lon
FROM public.callejero_geolocalizador

# Inserta en ES con bulk API
```

**Nota**: Este es el único script Python que procesa datos, pero:
- Solo lee y transforma formato
- No hace cálculos complejos
- ES hace el trabajo pesado de indexación

## 🔧 Mantenimiento

### Actualizar Datos

```bash
# 1. Reemplazar archivos en ./data/
cp nuevos_datos.geojson ./data/callejero_geolocalizador.geojson

# 2. Forzar reimportación
docker compose down
docker volume rm geocodificador_pgdata geocodificador_esdata
docker compose up -d
```

### Validar Paridad de Alturas

Los datos originales pueden tener alturas pares/impares intercambiadas.

```bash
# Validar
python3 scripts/validate_heights.py data/callejero_geolocalizador.geojson

# Corregir (crea backup automático)
python3 scripts/fix_height_parity.py data/callejero_geolocalizador.geojson

# Ver detalles en:
scripts/README.md
```

### Monitoreo

```bash
# Ver logs
docker compose logs -f api
docker compose logs -f db

# Verificar salud
curl http://localhost:8000/health

# Estadísticas de PostgreSQL
docker compose exec db psql -U postgres -d postgres -c "
  SELECT 
    schemaname, tablename, n_live_tup 
  FROM pg_stat_user_tables 
  WHERE schemaname = 'public';
"
```

## 🎯 Ventajas de la Arquitectura DB-Céntrica

### 1. **Performance**
- Procesamiento cerca de los datos (sin red)
- Índices especializados (GiST, GIN, trigram)
- Query optimizer de PostgreSQL
- Sin overhead de serialización Python ↔ DB

### 2. **Mantenibilidad**
- Lógica de negocio en SQL (declarativo)
- Fácil depuración con `EXPLAIN ANALYZE`
- Versionable con migrations
- Reutilizable desde cualquier lenguaje

### 3. **Escalabilidad**
- PostgreSQL puede escalar verticalmente
- Conexión pool en la API
- DB puede compartirse entre múltiples APIs
- Read replicas posibles

### 4. **Consistencia**
- Funciones DB garantizan misma lógica
- Transacciones ACID
- Sin duplicación de lógica

### 5. **Simplicidad de la API**
```python
# API solo hace esto:
rows = db_query("SELECT public.geocode_direccion(%s,%s,%s,%s)::text;", 
                (calle, altura, numero_cal, fallback))
return json.loads(rows[0][0])
```

No hay:
- ❌ Loops en Python sobre filas
- ❌ Cálculos de coordenadas en Python
- ❌ String matching en Python
- ❌ Lógica de interpolación en Python

## 📚 Recursos Adicionales

- [PostGIS Documentation](https://postgis.net/docs/)
- [PostgreSQL Full Text Search](https://www.postgresql.org/docs/current/textsearch.html)
- [pg_trgm Extension](https://www.postgresql.org/docs/current/pgtrgm.html)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [Elasticsearch Guide](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html)

## 📝 Licencia

[Especificar licencia]

## 👥 Contribuir

Al contribuir, mantener la filosofía de arquitectura:
- **Agregar lógica en PostgreSQL**, no en Python
- Python solo para: API HTTP, carga inicial de datos, utilidades
- Documentar funciones SQL con comentarios
- Incluir índices necesarios para nuevas queries

### Ejemplo de Contribución Correcta

❌ **Incorrecto** (lógica en Python):
```python
@app.get("/calles_cercanas")
def calles_cercanas(lat: float, lon: float):
    rows = db_query("SELECT * FROM callejero_geolocalizador")
    # Loop en Python calculando distancias...
    results = []
    for row in rows:
        dist = calculate_distance(lat, lon, row['lat'], row['lon'])
        if dist < 1000:
            results.append(row)
    return results
```

✅ **Correcto** (lógica en DB):
```python
@app.get("/calles_cercanas")
def calles_cercanas(lat: float, lon: float):
    rows = db_query(
        "SELECT * FROM public.calles_cercanas(%s, %s, %s);",
        (lat, lon, 1000)
    )
    return {"items": [dict(r) for r in rows]}
```

```sql
-- En db/postload.sql
CREATE OR REPLACE FUNCTION public.calles_cercanas(
  lat float, lon float, radio_m float
)
RETURNS TABLE(
  id bigint,
  numero_cal text,
  nombre_cal text,
  distancia float
) AS $$
  SELECT 
    id,
    numero_cal::text,
    nombre_cal,
    ST_Distance(
      geom,
      ST_Transform(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 3857)
    ) AS distancia
  FROM public.callejero_geolocalizador
  WHERE ST_DWithin(
    geom,
    ST_Transform(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 3857),
    radio_m
  )
  ORDER BY distancia ASC;
$$ LANGUAGE sql STABLE;
```

---

**¿Preguntas?** Abrir un issue en GitHub.
