from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from psycopg2.pool import SimpleConnectionPool
import psycopg2, json, os, httpx, time

# -----------------------------
# Config por entorno
# -----------------------------
PG = dict(
    host=os.getenv("PGHOST", "db"),
    port=int(os.getenv("PGPORT", "5432")),
    dbname=os.getenv("PGDB", "postgres"),
    user=os.getenv("PGUSER", "postgres"),
    password=os.getenv("PGPASSWORD", "postgres"),
)
ES_URL = os.getenv("ES_URL", "http://elasticsearch:9200").rstrip("/")
ES_INDEX = os.getenv("ES_INDEX", "calles")
CORS_ORIGINS = [o for o in os.getenv("CORS_ORIGINS", "").split(",") if o] or [
    # Ajustá estos para tus pruebas en LAN
    "http://localhost:3000",
    "http://127.0.0.1:3000",
]

# Timeouts y reintentos sensatos para LAN
ES_TIMEOUT = float(os.getenv("ES_TIMEOUT", "5.0"))
ES_RETRIES = int(os.getenv("ES_RETRIES", "2"))

# -----------------------------
# App & middlewares
# -----------------------------
app = FastAPI(title="Geolocalizador", version="1.1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS if CORS_ORIGINS else ["*"],  # abrir para pruebas
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -----------------------------
# Recursos (pool DB y cliente ES)
# -----------------------------
db_pool: SimpleConnectionPool | None = None
es_client: httpx.AsyncClient | None = None

def db_query(sql: str, params=()):
    if db_pool is None:
        raise RuntimeError("DB pool no inicializado")
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    finally:
        db_pool.putconn(conn)

async def es_post(path: str, json_body: dict):
    # Reintentos simples para picos/arranque
    last_exc = None
    for attempt in range(ES_RETRIES + 1):
        try:
            assert es_client is not None
            resp = await es_client.post(path, json=json_body, timeout=ES_TIMEOUT)
            resp.raise_for_status()
            return resp.json()
        except Exception as e:
            last_exc = e
            if attempt < ES_RETRIES:
                time.sleep(0.15 * (attempt + 1))
            else:
                raise

# -----------------------------
# Ciclo de vida
# -----------------------------
@app.on_event("startup")
async def _startup():
    global db_pool, es_client
    # Pool de 1..10 conexiones (ajustá a tu carga real)
    db_pool = SimpleConnectionPool(minconn=1, maxconn=10, **PG)
    es_client = httpx.AsyncClient(base_url=ES_URL)

@app.on_event("shutdown")
async def _shutdown():
    global db_pool, es_client
    if es_client is not None:
        await es_client.aclose()
        es_client = None
    if db_pool is not None:
        db_pool.closeall()
        db_pool = None

# -----------------------------
# Endpoints
# -----------------------------
@app.get("/health")
async def health():
    # DB
    try:
        db_query("SELECT 1;")
        db_ok = True
    except Exception as e:
        db_ok = False

    # ES
    es_ok = False
    try:
        assert es_client is not None
        r = await es_client.get("/", timeout=ES_TIMEOUT)
        es_ok = r.is_success
    except Exception:
        es_ok = False

    status = "ok" if (db_ok and es_ok) else "degraded" if (db_ok or es_ok) else "down"
    return {"status": status, "db": db_ok, "es": es_ok, "version": app.version}

@app.get("/sugerencias")
def sugerencias(
    qstr: str = Query("", min_length=0, max_length=100),
    limit: int = Query(20, ge=1, le=50)
):
    try:
        rows = db_query("SELECT * FROM public.sugerencias_calles(%s,%s);", (qstr, limit))
    except Exception as e:
        raise HTTPException(500, f"Error DB sugerencias: {e!s}")
    items = [{"numero_cal": r[0], "nombre_cal": r[1], "score": float(r[2])} for r in rows]
    return {"items": items, "count": len(items)}

@app.get("/sugerencias_es2")
async def sugerencias_es2(
    qstr: str = Query("", min_length=1, max_length=100),
    limit: int = Query(10, ge=1, le=50)
):
    # Pedimos más hits para poder deduplicar por nombre
    es_size = min(limit * 5, 200)

    # Búsqueda híbrida: frase > prefijo > fuzzy
    body = {
        "size": es_size,
        "query": {
            "bool": {
                "should": [
                    {"match_phrase": {"nombre_cal": {"query": qstr, "slop": 3, "boost": 5}}},
                    {"multi_match": {
                        "query": qstr,
                        "type": "bool_prefix",
                        "fields": ["nombre_cal", "nombre_cal._2gram", "nombre_cal._3gram", "nombre_cal.sap"],
                        "boost": 3
                    }},
                    {"match": {"nombre_cal": {"query": qstr, "fuzziness": "AUTO", "prefix_length": 2, "boost": 1.5}}}
                ],
                "minimum_should_match": 1
            }
        }
    }
    try:
        res = await es_post(f"/{ES_INDEX}/_search", body)
    except Exception as e:
        raise HTTPException(502, f"Error Elasticsearch: {e!s}")

    hits = res.get("hits", {}).get("hits", [])

    # Deduplicar por nombre_cal, priorizando el hit de mayor score (ya viene ordenado)
    seen = set()
    items = []
    for h in hits:
        src = h.get("_source") or {}
        nombre = src.get("nombre_cal")
        if not nombre or nombre in seen:
            continue
        items.append({"_id": h.get("_id"), "score": h.get("_score"), **src})
        seen.add(nombre)
        if len(items) >= limit:
            break

    return {"items": items, "count": len(items)}

@app.get("/geocode_direccion")
def geocode_direccion(
    calle: str | None = None,
    altura: int = Query(..., ge=0, le=200000),  # cotas defensivas; ajustá si tenés alturas mayores
    numero_cal: str | None = None,
    fallback: bool = False
):
    try:
        rows = db_query(
            "SELECT public.geocode_direccion(%s,%s,%s,%s)::text;",
            (calle, altura, numero_cal, fallback)
        )
    except Exception as e:
        raise HTTPException(500, f"Error DB geocode_direccion: {e!s}")
    if not rows:
        raise HTTPException(500, "Sin respuesta")
    try:
        return json.loads(rows[0][0])
    except Exception as e:
        raise HTTPException(500, f"Respuesta no parseable: {e!s}")

@app.get("/geocode_interseccion")
def geocode_interseccion(
    calle1: str = Query(..., min_length=1, max_length=100),
    calle2: str = Query(..., min_length=1, max_length=100)
):
    try:
        rows = db_query(
            "SELECT public.geocode_interseccion(%s,%s)::text;",
            (calle1, calle2)
        )
    except Exception as e:
        raise HTTPException(500, f"Error DB geocode_interseccion: {e!s}")
    if not rows:
        raise HTTPException(404, "Intersección no encontrada")
    try:
        return json.loads(rows[0][0])
    except Exception as e:
        raise HTTPException(500, f"Respuesta no parseable: {e!s}")
