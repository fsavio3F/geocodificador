-- postload.sql: corre DESPUÉS de importar GeoJSON

-- Columna materializada e infra para intersecciones



CREATE OR REPLACE FUNCTION public.calc_nums_norm(src text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY(
    SELECT v FROM (
      SELECT public.norm_code(x) AS v
      FROM regexp_split_to_table(regexp_replace(coalesce(src,''), '\s+','', 'g'), ';') AS x
    ) s WHERE v <> ''
  );
$$;

CREATE OR REPLACE FUNCTION public.trg_set_nums_norm()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.nums_norm := public.calc_nums_norm(NEW.num_calle);
  RETURN NEW;
END;
$$;

-- Añadir columna si no existe (ahora la tabla YA existe)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='intersecciones_geolocalizador') THEN
    -- Add column if it doesn't exist
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' 
        AND table_name='intersecciones_geolocalizador'
        AND column_name='nums_norm'
    ) THEN
      ALTER TABLE public.intersecciones_geolocalizador
        ADD COLUMN nums_norm text[];
    END IF;

    -- Trigger
    DROP TRIGGER IF EXISTS biu_set_nums_norm ON public.intersecciones_geolocalizador;
    CREATE TRIGGER biu_set_nums_norm
    BEFORE INSERT OR UPDATE OF num_calle ON public.intersecciones_geolocalizador
    FOR EACH ROW EXECUTE FUNCTION public.trg_set_nums_norm();
  END IF;
END$$;

-- Índices (ya existen las tablas)
CREATE INDEX IF NOT EXISTS callejero_nombre_trgm_idx
  ON public.callejero_geolocalizador
  USING gin ((public.norm_text(nombre_cal)) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS callejero_numcode_idx
  ON public.callejero_geolocalizador (public.norm_code(numero_cal));

CREATE INDEX IF NOT EXISTS callejero_geom_gist
  ON public.callejero_geolocalizador USING gist (geom);

CREATE INDEX IF NOT EXISTS inter_geom_gist
  ON public.intersecciones_geolocalizador USING gist (geom);

CREATE INDEX IF NOT EXISTS inter_nums_norm_gin
  ON public.intersecciones_geolocalizador USING gin (nums_norm);

-- Funciones que consultan tablas (ahora sí)

CREATE OR REPLACE FUNCTION public.resolve_code_or_name(q text)
RETURNS text LANGUAGE sql STABLE AS $$
WITH qn AS (SELECT public.norm_code(q) AS qcode),
exact AS (
  SELECT numero_cal::text
  FROM public.callejero_geolocalizador, qn
  WHERE public.norm_code(numero_cal) = (SELECT qcode FROM qn)
  LIMIT 1
),
name AS (
  SELECT numero_cal FROM public.resolve_calle(q,1) LIMIT 1
)
SELECT COALESCE( (SELECT numero_cal FROM exact), (SELECT numero_cal FROM name) );
$$;

CREATE OR REPLACE FUNCTION public.geocode_direccion(
  calle_q text, altura int, numero_cal_in text DEFAULT NULL, fallback boolean DEFAULT FALSE
)
RETURNS jsonb LANGUAGE sql STABLE AS $$
WITH elegida AS (
  SELECT COALESCE(numero_cal_in, public.resolve_code_or_name(calle_q)) AS numero_cal_txt
),
cand AS (
  SELECT
    g.id, g.geom,
    g.numero_cal::text AS numero_cal_txt,
    g.nombre_cal,
    g.alt_ini_pa, g.alt_ini_im, g.alt_fin_pa, g.alt_fin_im,
    GREATEST(LEAST(g.alt_ini_pa, g.alt_fin_pa), 0) AS min_par,
    LEAST(GREATEST(g.alt_ini_pa, g.alt_fin_pa), 999999) AS max_par,
    GREATEST(LEAST(g.alt_ini_im, g.alt_fin_im), 0) AS min_impar,
    LEAST(GREATEST(g.alt_ini_im, g.alt_fin_im), 999999) AS max_impar
  FROM public.callejero_geolocalizador g
  JOIN elegida e
    ON public.norm_code(g.numero_cal) = public.norm_code(e.numero_cal_txt)
),
rango AS (
  SELECT *,
    CASE WHEN altura % 2 = 0 THEN
      CASE WHEN max_par = min_par THEN 0.5
           ELSE (LEAST(GREATEST(altura, min_par), max_par) - min_par)::float
                / NULLIF((max_par - min_par)::float, 0)
      END
    ELSE
      CASE WHEN max_impar = min_impar THEN 0.5
           ELSE (LEAST(GREATEST(altura, min_impar), max_impar) - min_impar)::float
                / NULLIF((max_impar - min_impar)::float, 0)
      END
    END AS t_clamped,
    CASE WHEN altura % 2 = 0 THEN (altura BETWEEN LEAST(min_par,max_par) AND GREATEST(min_par,max_par))
         ELSE (altura BETWEEN LEAST(min_impar,max_impar) AND GREATEST(min_impar,max_impar)) END AS in_range,
    CASE WHEN altura % 2 = 0 THEN (max_par - min_par) ELSE (max_impar - min_impar) END AS ancho
  FROM cand
),
mejor AS (
  SELECT * FROM rango
  WHERE in_range OR fallback
  ORDER BY (CASE WHEN in_range THEN 0 ELSE 1 END), ancho ASC
  LIMIT 1
),
pt AS (
  SELECT id, numero_cal_txt AS numero_cal, nombre_cal,
         ST_LineInterpolatePoint(
           ST_LineMerge(ST_CollectionExtract(geom, 2)),
           GREATEST(0.0, LEAST(1.0, t_clamped))
         ) AS geom_pt
  FROM mejor
)
SELECT jsonb_build_object(
  'success', (SELECT TRUE WHERE EXISTS (SELECT 1 FROM pt)),
  'numero_cal', (SELECT numero_cal FROM pt),
  'nombre_cal', (SELECT nombre_cal FROM pt),
  'altura', altura,
  'paridad', CASE WHEN altura % 2 = 0 THEN 'par' ELSE 'impar' END,
  'min_par',   (SELECT min_par   FROM mejor),
  'max_par',   (SELECT max_par   FROM mejor),
  'min_impar', (SELECT min_impar FROM mejor),
  'max_impar', (SELECT max_impar FROM mejor),
  'min_rango', CASE
                 WHEN altura % 2 = 0 THEN (SELECT min_par   FROM mejor)
                 ELSE                      (SELECT min_impar FROM mejor)
               END,
  'max_rango', CASE
                 WHEN altura % 2 = 0 THEN (SELECT max_par   FROM mejor)
                 ELSE                      (SELECT max_impar FROM mejor)
               END,

  'lat', (SELECT ST_Y(ST_Transform(geom_pt,4326)) FROM pt),
  'lon', (SELECT ST_X(ST_Transform(geom_pt,4326)) FROM pt),
  'geojson', (SELECT ST_AsGeoJSON(ST_Transform(geom_pt,4326))::jsonb FROM pt),

  'message', CASE WHEN EXISTS (SELECT 1 FROM pt) THEN NULL
                  ELSE 'Sin coincidencias en el rango/paridad.' END
);
$$;

CREATE OR REPLACE FUNCTION public.geocode_interseccion(calle1_q text, calle2_q text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
/*
  Devuelve un JSON con:
    success: boolean
    lat, lon: coordenadas en EPSG:4326
    geojson: Point en EPSG:4326
    message: texto en caso de no encontrar
  Notas:
    - Extrae POINT de collections/multipoints si fuera necesario.
    - Si el SRID es 0/unknown, asume 3857 y transforma a 4326 para la salida.
*/
WITH codes AS (
  SELECT public.resolve_code_or_name(calle1_q) AS c1,
         public.resolve_code_or_name(calle2_q) AS c2
),
norm AS (
  SELECT public.norm_code(c1) AS n1, public.norm_code(c2) AS n2 FROM codes
),
pick AS (
  SELECT
    i.geom AS geom_any
  FROM public.intersecciones_geolocalizador i, norm
  WHERE (ARRAY[n1, n2] <@ i.nums_norm) OR (ARRAY[n2, n1] <@ i.nums_norm)
  LIMIT 1
),
pt AS (
  SELECT
    -- 1) si hay puntos dentro de una collection/multi, tomo el primero
    COALESCE(
      NULLIF(ST_GeometryN(ST_CollectionExtract(geom_any, 1), 1), NULL),
      -- 2) si no hay puntos, uso un punto representativo sobre la geometría
      ST_PointOnSurface(geom_any)
    ) AS geom_pt
  FROM pick
),
wgs AS (
  SELECT
    ST_Transform(
      CASE
        WHEN ST_SRID(geom_pt) = 0 THEN ST_SetSRID(geom_pt, 3857)  -- fallback si viniera sin SRID
        ELSE geom_pt
      END,
      4326
    ) AS g4326
  FROM pt
)
SELECT jsonb_build_object(
  'success', (SELECT TRUE WHERE EXISTS (SELECT 1 FROM wgs WHERE g4326 IS NOT NULL)),
  'lat',     (SELECT ST_Y(g4326) FROM wgs),
  'lon',     (SELECT ST_X(g4326) FROM wgs),
  'geojson', (SELECT ST_AsGeoJSON(g4326)::jsonb FROM wgs),
  'message', CASE WHEN EXISTS (SELECT 1 FROM wgs WHERE g4326 IS NOT NULL) THEN NULL
                  ELSE 'Intersección no encontrada o geometría no puntual.' END
);
$$;

-- Drop function if exists to avoid parameter name conflicts
-- Drop all possible variants of the function
DO $$
DECLARE
  func_rec RECORD;
BEGIN
  -- Drop any version of sugerencias_calles function
  FOR func_rec IN 
    SELECT oid::regprocedure::text AS func_signature
    FROM pg_proc
    WHERE proname = 'sugerencias_calles'
      AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || func_rec.func_signature || ' CASCADE';
  END LOOP;
EXCEPTION
  WHEN OTHERS THEN NULL;
END$$;

-- Now create the function with proper parameters
-- Note: Using CREATE (not CREATE OR REPLACE) because we've already dropped all variants above.
-- This ensures a clean creation without parameter name conflicts.
CREATE FUNCTION public.sugerencias_calles(q text, lim int DEFAULT 20)
RETURNS TABLE(numero_cal text, nombre_cal text, score numeric)
LANGUAGE sql STABLE AS $$
  SELECT * FROM public.resolve_calle(q, lim);
$$;

-- Deduplicar sugerencias por nombre: tomar el mejor score por nombre_cal
CREATE OR REPLACE FUNCTION public.resolve_calle(q text, lim int DEFAULT 10)
RETURNS TABLE(numero_cal text, nombre_cal text, score numeric)
LANGUAGE sql STABLE AS $$
WITH params AS (
  SELECT public.norm_text(q) AS qnorm,
         public.drop_prefix_tokens(string_to_array(public.norm_text(q), ' ')) AS qtoks
),
pat AS (
  SELECT CASE WHEN array_length(qtoks,1) IS NULL THEN '%'
              ELSE '%' || array_to_string(qtoks, '%') || '%'
         END AS like_pat
  FROM params
),
c AS (
  SELECT numero_cal::text AS numero_cal,
         nombre_cal,
         public.norm_text(nombre_cal) AS nnorm
  FROM public.callejero_geolocalizador
),
scored AS (
  SELECT
    c.numero_cal,
    c.nombre_cal,
    GREATEST(
      similarity(c.nnorm, (SELECT qnorm FROM params)),
      CASE WHEN c.nnorm ILIKE (SELECT like_pat FROM pat) THEN 0.7 ELSE 0 END,
      (
        SELECT COALESCE(
          SUM(CASE WHEN t <> '' AND position(t in c.nnorm) > 0 THEN 0.15 ELSE 0 END),
          0
        )
        FROM unnest((SELECT qtoks FROM params)) t
      )
    ) AS score
  FROM c
  WHERE c.nnorm ILIKE (SELECT like_pat FROM pat)
     OR similarity(c.nnorm, (SELECT qnorm FROM params)) > 0.35
),
ranked AS (
  SELECT
    numero_cal, nombre_cal, score,
    ROW_NUMBER() OVER (PARTITION BY nombre_cal ORDER BY score DESC, nombre_cal) AS rn
  FROM scored
)
SELECT numero_cal, nombre_cal, score
FROM ranked
WHERE rn = 1
ORDER BY score DESC, nombre_cal
LIMIT COALESCE(lim, 10);
$$;

-- Backfill y estadísticas
DO $$
BEGIN
  -- Only backfill if both column and function exist
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='intersecciones_geolocalizador'
               AND column_name='nums_norm')
     AND EXISTS (SELECT 1 FROM pg_proc WHERE proname='calc_nums_norm' AND pronamespace = 'public'::regnamespace) THEN
    UPDATE public.intersecciones_geolocalizador
    SET nums_norm = public.calc_nums_norm(num_calle)
    WHERE nums_norm IS NULL;
  END IF;
END$$;

ANALYZE public.callejero_geolocalizador;
ANALYZE public.intersecciones_geolocalizador;

