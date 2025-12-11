#!/bin/sh
set -eu

# ---------- Config ----------
PGHOST="${PGHOST:-db}"
PGPORT="${PGPORT:-5432}"
PGDB="${PGDB:-postgres}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
DATA_DIR="${DATA_DIR:-/data}"

# Geo / reproyección
SRC_SRS="${SRC_SRS:-EPSG:4326}"        # CRS de entrada (ajusta si tus GeoJSON no están en 4326)
DST_SRS="${DST_SRS:-EPSG:4326}"        # CRS a guardar en PG
OGR_APPEND="${OGR_APPEND:-0}"          # 1 = append, 0 = overwrite
PROMOTE_MULTI="${PROMOTE_MULTI:-1}"    # 1 = tolera Multi*, 0 = tipo exacto

# Tablas destino
TAB_CALLEJERO="${TAB_CALLEJERO:-public.callejero_geolocalizador}"
TAB_INTERS="${TAB_INTERS:-public.intersecciones_geolocalizador}"

# Archivos
CALLEJERO="${DATA_DIR}/callejero_geolocalizador.geojson"
INTESECC="${DATA_DIR}/intersecciones_geolocalizador.geojson"

# Postload opcional
POSTLOAD_SQL="${POSTLOAD_SQL:-/app/postload.sql}"

export PGPASSWORD

# ---------- Helpers ----------
log(){ printf '%s %s\n' "[importer]" "$*" ; }
die(){ printf '%s %s\n' "[importer][ERROR]" "$*" >&2; exit 1; }

ogr_overwrite_flag(){
  [ "$OGR_APPEND" = "1" ] && echo "-append" || echo "-overwrite"
}

ogr_geom_flags(){
  # Promueve a multi si hace falta y define tipo geom general
  if [ "$PROMOTE_MULTI" = "1" ]; then
    # callee: LINESTRING/MULTILINESTRING; inters: POINT/MULTIPOINT
    # dejamos que GDAL detecte y promueva a multi
    echo "-nlt PROMOTE_TO_MULTI"
  else
    echo "$1"  # usar tal cual lo que pase el caller (-nlt LINESTRING/POINT)
  fi
}

hash_file(){
  # sha256sum no está siempre en imágenes mínimas; md5sum suele estar
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    md5sum "$1" | awk '{print $1}'
  fi
}

# ---------- Esperar PG ----------
log "Esperando Postgres en ${PGHOST}:${PGPORT}/${PGDB} ..."
for i in $(seq 1 60); do
  if ogrinfo "PG:host=${PGHOST} port=${PGPORT} dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}" >/dev/null 2>&1; then
    log "Postgres OK"; break
  fi
  sleep 2
  [ "$i" = "60" ] && die "Timeout esperando Postgres"
done

# ---------- Chequeo de archivos ----------
[ -f "$CALLEJERO" ] || die "No existe $CALLEJERO"
[ -f "$INTESECC" ]  || die "No existe $INTESECC"

# ---------- Evitar reimport innecesario ----------
STATE_DIR="/app/.state"
mkdir -p "$STATE_DIR"
H1=$(hash_file "$CALLEJERO")
H2=$(hash_file "$INTESECC")
SFILE="$STATE_DIR/import.hash"

if [ -f "$SFILE" ]; then
  OLD=$(cat "$SFILE" 2>/dev/null || true)
  if [ "$OLD" = "$H1|$H2|$SRC_SRS|$DST_SRS|$OGR_APPEND|$PROMOTE_MULTI" ]; then
    log "Hashes idénticos y misma config; salto importación."
    SKIP_IMPORT=1
  else
    SKIP_IMPORT=0
  fi
else
  SKIP_IMPORT=0
fi

# ---------- Importar (si corresponde) ----------
if [ "${SKIP_IMPORT:-0}" -eq 0 ]; then
  log "=========================================="
  log "INICIANDO IMPORTACIÓN DE DATOS"
  log "=========================================="
  
  log "[1/2] Importando $CALLEJERO → $TAB_CALLEJERO ..."
  log "      Archivo: $(basename "$CALLEJERO")"
  log "      Tamaño: $(du -h "$CALLEJERO" | cut -f1)"
  ogr2ogr -f PostgreSQL "PG:host=${PGHOST} port=${PGPORT} dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}" \
    "$CALLEJERO" \
    -nln "$TAB_CALLEJERO" \
    $(ogr_geom_flags) \
    -lco GEOMETRY_NAME=geom \
    -lco FID=id \
    -t_srs "$DST_SRS" -s_srs "$SRC_SRS" \
    $(ogr_overwrite_flag) -skipfailures -progress
  log "✓ Callejero importado exitosamente"

  log "[2/2] Importando $INTESECC → $TAB_INTERS ..."
  log "      Archivo: $(basename "$INTESECC")"
  log "      Tamaño: $(du -h "$INTESECC" | cut -f1)"
  ogr2ogr -f PostgreSQL "PG:host=${PGHOST} port=${PGPORT} dbname=${PGDB} user=${PGUSER} password=${PGPASSWORD}" \
    "$INTESECC" \
    -nln "$TAB_INTERS" \
    $(ogr_geom_flags) \
    -lco GEOMETRY_NAME=geom \
    -lco FID=id \
    -t_srs "$DST_SRS" -s_srs "$SRC_SRS" \
    $(ogr_overwrite_flag) -skipfailures -progress
  log "✓ Intersecciones importadas exitosamente"

  echo "${H1}|${H2}|${SRC_SRS}|${DST_SRS}|${OGR_APPEND}|${PROMOTE_MULTI}" > "$SFILE"
  log "=========================================="
  log "IMPORTACIÓN COMPLETADA"
  log "=========================================="
else
  log "Usando datos ya importados."
fi

# ---------- Post-proceso ----------
log "=========================================="
log "EJECUTANDO POST-PROCESAMIENTO"
log "=========================================="

# Note: nums_norm column and backfill will be handled by postload.sql
# Just run basic ANALYZE if tables exist
log "[1/2] Ejecutando análisis preliminar de tablas..."
psql "host=${PGHOST} port=${PGPORT} dbname=${PGDB} user=${PGUSER}" >/dev/null 2>&1 <<'SQL' || true
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='callejero_geolocalizador') THEN
    ANALYZE public.callejero_geolocalizador;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='intersecciones_geolocalizador') THEN
    ANALYZE public.intersecciones_geolocalizador;
  END IF;
END$$;
SQL
log "✓ Análisis completado"

# Ejecutar postload.sql si existe (índices, triggers, funciones geocode_*)
if [ -f "$POSTLOAD_SQL" ]; then
  log "[2/2] Ejecutando postload: $POSTLOAD_SQL"
  log "      Creando índices, triggers y funciones..."
  psql "host=${PGHOST} port=${PGPORT} dbname=${PGDB} user=${PGUSER}" -v ON_ERROR_STOP=1 -f "$POSTLOAD_SQL"
  log "✓ Post-procesamiento SQL completado"
else
  log "Sin postload.sql (saltando)."
fi

log "=========================================="
log "IMPORTACIÓN FINALIZADA EXITOSAMENTE ✓"
log "=========================================="
