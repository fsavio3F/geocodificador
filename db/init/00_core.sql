-- 00_core.sql: sólo cosas que NO referencian tablas
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Utilitarios de normalización (no dependen de tablas)
CREATE OR REPLACE FUNCTION public.norm_text(s text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT regexp_replace(public.unaccent(lower(coalesce(s,''))), '\s+', ' ', 'g');
$$;

CREATE OR REPLACE FUNCTION public.drop_prefix_tokens(tokens text[])
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $$
  SELECT ARRAY(
    SELECT t FROM unnest(tokens) t
    WHERE t <> ALL(ARRAY[
      'avenida','av','avda','av.','calle',
      'fray','pbro','pbro.','mons','monseñor','monsenor',
      'gral','gral.','general','dr','dr.','pte','pte.','presidente'
    ])
  );
$$;

CREATE OR REPLACE FUNCTION public.norm_code(s text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT upper(regexp_replace(coalesce(s,''), '\s+', '', 'g'));
$$;
