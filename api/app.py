from fastapi import FastAPI, HTTPException, Query
import psycopg2, json, os, httpx

PG = dict(
    host=os.getenv("PGHOST","db"),
    port=int(os.getenv("PGPORT","5432")),
    dbname=os.getenv("PGDB","postgres"),
    user=os.getenv("PGUSER","postgres"),
    password=os.getenv("PGPASSWORD","postgres"),
)
ES = os.getenv("ES_URL","http://elasticsearch:9200")

def q(sql, params=()):
    with psycopg2.connect(**PG) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()

app = FastAPI(title="Geolocalizador", version="1.0")

@app.get("/health")
def health():
    q("SELECT 1;")
    return {"status":"ok"}

@app.get("/sugerencias")
def sugerencias(qstr: str = "", limit: int = Query(20, ge=1, le=50)):
    rows = q("SELECT * FROM public.sugerencias_calles(%s,%s);", (qstr, limit))
    items = [{"numero_cal": r[0], "nombre_cal": r[1], "score": float(r[2])} for r in rows]
    return {"items": items, "count": len(items)}

@app.get("/sugerencias_es2")
async def sugerencias_es2(qstr: str = "", limit: int = Query(10, ge=1, le=50)):
    body = {
        "size": limit,
        "query": {
            "bool": {
                "should": [
                    { "match_phrase": {
                        "nombre_cal": { "query": qstr, "slop": 3, "boost": 5 }
                    }},
                    { "multi_match": {
                        "query": qstr,
                        "type": "bool_prefix",
                        "fields": [
                            "nombre_cal",
                            "nombre_cal._2gram",
                            "nombre_cal._3gram",
                            "nombre_cal.sap"
                        ],
                        "boost": 3
                    }},
                    { "match": {
                        "nombre_cal": {
                            "query": qstr,
                            "fuzziness": "AUTO",
                            "prefix_length": 2,
                            "boost": 1.5
                        }
                    }}
                ],
                "minimum_should_match": 1
            }
        }
    }
    async with httpx.AsyncClient() as c:
        r = await c.post(f"{ES}/calles/_search", json=body, timeout=5.0)
    r.raise_for_status()
    hits = r.json()["hits"]["hits"]
    return {
        "items": [{"_id": h["_id"], "score": h["_score"], **h["_source"]} for h in hits],
        "count": len(hits)
    }


@app.get("/geocode_direccion")
def geocode_direccion(calle: str | None = None, altura: int = Query(...), numero_cal: str | None = None, fallback: bool = False):
    rows = q("SELECT public.geocode_direccion(%s,%s,%s,%s)::text;", (calle, altura, numero_cal, fallback))
    if not rows: raise HTTPException(500, "Sin respuesta")
    return json.loads(rows[0][0])

@app.get("/geocode_interseccion")
def geocode_interseccion(calle1: str = Query(...), calle2: str = Query(...)):
    rows = q("SELECT public.geocode_interseccion(%s,%s)::text;", (calle1, calle2))
    if not rows: raise HTTPException(500, "Sin respuesta")
    return json.loads(rows[0][0])
