FROM python:3.11-slim
WORKDIR /app
RUN pip install requests psycopg2-binary
COPY load_calles.py .
COPY calles_index.json .