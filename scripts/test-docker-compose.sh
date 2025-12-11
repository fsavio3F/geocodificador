#!/bin/bash
# Test script for Docker Compose setup
set -e

echo "=== Docker Compose Test Script ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if docker compose is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed${NC}"
    exit 1
fi

echo "✓ Docker is installed"

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}Error: docker-compose.yml not found${NC}"
    exit 1
fi

echo "✓ docker-compose.yml found"

# Check if .env exists
if [ ! -f ".env" ]; then
    echo -e "${YELLOW}Warning: .env file not found, using defaults${NC}"
fi

# Check if data files exist
if [ ! -f "data/callejero_geolocalizador.geojson" ]; then
    echo -e "${RED}Error: data/callejero_geolocalizador.geojson not found${NC}"
    exit 1
fi

if [ ! -f "data/intersecciones_geolocalizador.geojson" ]; then
    echo -e "${RED}Error: data/intersecciones_geolocalizador.geojson not found${NC}"
    exit 1
fi

echo "✓ Data files found"

# Ask user if they want to clean volumes
echo ""
echo -e "${YELLOW}Do you want to remove existing volumes (recommended for clean start)? (y/N)${NC}"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Stopping containers and removing volumes..."
    docker compose down -v
    echo "✓ Volumes removed"
fi

# Build images
echo ""
echo "Building Docker images..."
docker compose build --no-cache importer loader api

echo "✓ Images built"

# Start services
echo ""
echo "Starting services..."
docker compose up -d db elasticsearch

# Wait for database
echo "Waiting for database to be ready..."
for i in {1..30}; do
    if docker compose exec -T db pg_isready -U postgres -d postgres > /dev/null 2>&1; then
        echo "✓ Database is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}Error: Database did not start in time${NC}"
        docker compose logs db
        exit 1
    fi
    sleep 2
done

# Wait for Elasticsearch
echo "Waiting for Elasticsearch to be ready..."
for i in {1..60}; do
    if curl -fsS http://localhost:9200/_cluster/health > /dev/null 2>&1; then
        echo "✓ Elasticsearch is ready"
        break
    fi
    if [ $i -eq 60 ]; then
        echo -e "${RED}Error: Elasticsearch did not start in time${NC}"
        docker compose logs elasticsearch
        exit 1
    fi
    sleep 2
done

# Run importer
echo ""
echo "Running importer..."
docker compose up importer

# Check importer exit code
if docker compose ps importer | grep -q "exited (0)"; then
    echo "✓ Importer completed successfully"
else
    echo -e "${RED}Error: Importer failed${NC}"
    docker compose logs importer
    exit 1
fi

# Run loader
echo ""
echo "Running loader..."
docker compose up loader

# Check loader exit code
if docker compose ps loader | grep -q "exited (0)"; then
    echo "✓ Loader completed successfully"
else
    echo -e "${RED}Error: Loader failed${NC}"
    docker compose logs loader
    exit 1
fi

# Start API
echo ""
echo "Starting API..."
docker compose up -d api

# Wait for API
echo "Waiting for API to be ready..."
for i in {1..30}; do
    if curl -fsS http://localhost:8000/health > /dev/null 2>&1; then
        echo "✓ API is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}Error: API did not start in time${NC}"
        docker compose logs api
        exit 1
    fi
    sleep 2
done

# Test API
echo ""
echo "Testing API endpoints..."

# Health check
if curl -fsS http://localhost:8000/health | grep -q "ok"; then
    echo "✓ Health endpoint working"
else
    echo -e "${RED}Error: Health endpoint failed${NC}"
    exit 1
fi

# Test geocoding (if data is loaded)
echo ""
echo "Checking if geocoding is working..."
# Use --get with --data-urlencode for proper URL encoding
response=$(curl -fsS --get "http://localhost:8000/geocode" \
  --data-urlencode "calle=belgrano" \
  --data-urlencode "altura=100" 2>/dev/null || echo "")
if [ -n "$response" ]; then
    echo "✓ Geocoding endpoint responding"
    echo "  Sample response: $response" | head -c 100
    echo "..."
else
    echo -e "${YELLOW}Warning: Geocoding endpoint not responding (may need data)${NC}"
fi

echo ""
echo -e "${GREEN}=== All tests passed! ===${NC}"
echo ""
echo "Services running:"
docker compose ps

echo ""
echo "To view logs: docker compose logs -f"
echo "To stop: docker compose down"
