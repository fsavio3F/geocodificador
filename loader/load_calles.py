import os, time, json, requests, psycopg2

PG = dict(
  host=os.getenv("PGHOST","db"),
  port=int(os.getenv("PGPORT","5432")),
  dbname=os.getenv("PGDB","postgres"),
  user=os.getenv("PGUSER","postgres"),
  password=os.getenv("PGPASSWORD","postgres"),
)
ES = os.getenv("ES_URL","http://elasticsearch:9200")
INDEX = "calles"

def wait(url, tries=60):
  for _ in range(tries):
    try:
      requests.get(url, timeout=2).raise_for_status()
      return
    except Exception:
      time.sleep(2)
  raise RuntimeError(f"Timeout esperando {url}")

def ensure_index():
  r = requests.get(f"{ES}/{INDEX}")
  if r.status_code == 404:
    with open("calles_index.json","r",encoding="utf-8") as f:
      body = json.load(f)
    requests.put(f"{ES}/{INDEX}", json=body).raise_for_status()

def rows():
  sql = """
  SELECT id, numero_cal::text, nombre_cal,
         ST_Y(ST_Centroid(ST_Transform(geom,4326))) AS lat,
         ST_X(ST_Centroid(ST_Transform(geom,4326))) AS lon
  FROM public.callejero_geolocalizador;
  """
  with psycopg2.connect(**PG) as conn, conn.cursor() as cur:
    cur.execute(sql)
    for r in cur.fetchall():
      yield {"index":{"_index":INDEX,"_id":r[0]}}
      yield {
        "id": r[0],
        "numero_cal": r[1] or "",
        "nombre_cal": r[2] or "",
        "centroid": {"lat": float(r[3]), "lon": float(r[4])}
      }

def bulk():
  data = "\n".join(json.dumps(x, ensure_ascii=False) for x in rows()) + "\n"
  r = requests.post(f"{ES}/_bulk", data=data.encode("utf-8"), headers={"Content-Type":"application/x-ndjson"})
  r.raise_for_status()

if __name__ == "__main__":
  wait(ES)
  ensure_index()
  # esperar a que el SQL init corra (por si el loader arranca muy rápido)
  wait(f"http://{PG['host']}:{PG['port']}")
  bulk()
  print("Index calles cargado.")
