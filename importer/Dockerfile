FROM ghcr.io/osgeo/gdal:ubuntu-small-3.9.0
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl postgresql-client \
    && rm -rf /var/lib/apt/lists/*
COPY importer/import.sh /app/import.sh
# Normalizar fin de línea por si el checkout fue CRLF en Windows
RUN sed -i 's/\r$//' /app/import.sh
# Opción 1: copiar el SQL a la imagen
COPY db/postload.sql /app/postload.sql
ENTRYPOINT ["/bin/sh", "/app/import.sh"]
