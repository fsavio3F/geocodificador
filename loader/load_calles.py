# load_calles.py  — reemplazo completo
import os, time, json, io, requests, psycopg2
from psycopg2.extras import RealDictCursor

PG = {
    "host": os.getenv("PGHOST", "db"),
    "port": int(os.getenv("PGPORT", "5432")),
    "dbname": os.getenv("PGDB", "postgres"),
    "user": os.getenv("PGUSER", "postgres"),
    "password": os.getenv("PGPASSWORD", "postgres"),
}
ES_URL = os.getenv("ES_URL", "http://elasticsearch:9200")
INDEX  = os.getenv("ES_INDEX", "calles")

# ---------- Esperas robustas ----------
def wait_db(max_seconds=120):
    start = time.time()
    while True:
        try:
            with psycopg2.connect(**PG) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
            print("[loader] Postgres OK")
            return
        except Exception as e:
            if time.time() - start > max_seconds:
                raise RuntimeError(f"Timeout esperando Postgres {PG['host']}:{PG['port']}") from e
            print(f"[loader] Esperando Postgres... {e}")
            time.sleep(2)

def wait_es(max_seconds=120):
    start = time.time()
    url = f"{ES_URL}/_cluster/health"
    while True:
        try:
            r = requests.get(url, timeout=3)
            if r.ok:
                print("[loader] Elasticsearch OK")
                return
        except Exception:
            pass
        if time.time() - start > max_seconds:
            raise RuntimeError(f"Timeout esperando Elasticsearch {url}")
        print("[loader] Esperando Elasticsearch...")
        time.sleep(2)

# ---------- Índice ----------
def ensure_index():
    r = requests.get(f"{ES_URL}/{INDEX}", timeout=5)
    if r.status_code == 404:
        print(f"[loader] Creando índice {INDEX}…")
        body = {}
        try:
            with open("calles_index.json", "r", encoding="utf-8") as f:
                body = json.load(f)
        except FileNotFoundError:
            print("[loader][WARN] calles_index.json no encontrado; creando índice vacío con defaults")
        rq = requests.put(f"{ES_URL}/{INDEX}", json=body, headers={"Content-Type":"application/json"}, timeout=10)
        rq.raise_for_status()
    elif r.ok:
        print(f"[loader] Índice {INDEX} ya existe")
    else:
        r.raise_for_status()

# ---------- Lectura de filas ----------
def iter_rows(batch_size=2000):
    """
    Itera en lotes desde Postgres. Ajusta nombres de columnas si difieren.
    """
    sql = """
    SELECT
      id,                          -- PK o identificador único
      numero_cal::text AS numero_cal,
      nombre_cal,
      ST_Y(ST_Centroid(ST_Transform(geom,4326))) AS lat,
      ST_X(ST_Centroid(ST_Transform(geom,4326))) AS lon
    FROM public.callejero_geolocalizador
    """
    with psycopg2.connect(**PG) as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.itersize = batch_size
            cur.execute(sql)
            for row in cur:
                # Sanitizar nulos
                row["numero_cal"] = row["numero_cal"] or ""
                row["nombre_cal"] = row["nombre_cal"] or ""
                # Si no hay geom, saltear
                if row["lat"] is None or row["lon"] is None:
                    continue
                # Acción bulk + documento
                meta = {"index": {"_index": INDEX, "_id": row["id"]}}
                doc  = {
                    "id": row["id"],
                    "numero_cal": row["numero_cal"],
                    "nombre_cal": row["nombre_cal"],
                    # geo_point como objeto {lat, lon}
                    "centroid": {"lat": float(row["lat"]), "lon": float(row["lon"])}
                }
                yield meta, doc

# ---------- Bulk a ES con chequeo de errores ----------
def post_bulk(buf: io.StringIO):
    data = buf.getvalue().encode("utf-8")
    if not data.strip():
        return
    r = requests.post(f"{ES_URL}/_bulk", data=data,
                      headers={"Content-Type":"application/x-ndjson"}, timeout=30)
    r.raise_for_status()
    resp = r.json()
    if resp.get("errors"):
        # Mostrar hasta 3 errores para depurar rápido
        bad = [it for it in resp.get("items", []) if list(it.values())[0].get("error")]
        print(json.dumps(bad[:3], ensure_ascii=False, indent=2))
        raise RuntimeError("Bulk devolvió errors=true")

def bulk_load(chunk_size=2000):
    print(f"[loader] Iniciando bulk hacia {INDEX}…")
    buf = io.StringIO()
    n = 0
    for meta, doc in iter_rows(batch_size=chunk_size):
        buf.write(json.dumps(meta, ensure_ascii=False) + "\n")
        buf.write(json.dumps(doc,  ensure_ascii=False) + "\n")
        n += 1
        if n % chunk_size == 0:
            post_bulk(buf)
            buf = io.StringIO()
            print(f"[loader] Enviados {n} documentos…")
    post_bulk(buf)
    # refresh para visibilidad inmediata
    requests.post(f"{ES_URL}/{INDEX}/_refresh", timeout=10)
    print(f"[loader] Bulk finalizado. Total enviados: {n}")

if __name__ == "__main__":
    wait_db()
    wait_es()
    ensure_index()
    bulk_load()
    print("[loader] DONE")
