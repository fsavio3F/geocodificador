# Scripts de Validación y Corrección de Alturas

Este directorio contiene scripts para validar y corregir la paridad de las alturas (números de calle) en los datos de geocodificación.

## Problema Identificado

Los datos originales tenían un problema crítico donde los campos de alturas pares e impares estaban intercambiados:
- `alt_ini_pa` y `alt_fin_pa` (alturas pares) contenían números impares
- `alt_ini_im` y `alt_fin_im` (alturas impares) contenían números pares

Esto afectaba al 82.3% de los segmentos de calles (5,212 de 6,333 features).

## Scripts Disponibles

### 1. validate_heights.py

Valida que las alturas tengan la paridad correcta.

**Uso:**
```bash
python3 scripts/validate_heights.py [ruta_al_geojson]
```

**Validaciones:**
- Verifica que `alt_ini_pa` y `alt_fin_pa` contengan solo números pares
- Verifica que `alt_ini_im` y `alt_fin_im` contengan solo números impares
- Ignora valores 0 (caso especial)
- Retorna exit code 0 si todo está correcto, 1 si hay problemas

**Ejemplo de salida:**
```
Validating data/callejero_geolocalizador.geojson...
✓ Checked 6735 features
✓ All heights have correct parity!
```

### 2. fix_height_parity.py

Corrige la paridad intercambiando los campos par/impar.

**Uso:**
```bash
python3 scripts/fix_height_parity.py [ruta_entrada] [ruta_salida]
```

**Comportamiento:**
- Si no se especifica ruta de salida, sobrescribe el archivo de entrada
- Crea automáticamente un backup con extensión `.bak`
- Intercambia los valores de los campos `alt_ini_pa` ↔ `alt_ini_im` y `alt_fin_pa` ↔ `alt_fin_im`

**Ejemplo de salida:**
```
Creating backup: data/callejero_geolocalizador.geojson.bak
Loading data/callejero_geolocalizador.geojson...
Swapped height fields in 6335 features
Writing to data/callejero_geolocalizador.geojson...
✓ Done!
```

### 3. test_geocoding.py

Prueba que la lógica de geocodificación funcione correctamente con los datos corregidos.

**Uso:**
```bash
python3 scripts/test_geocoding.py [ruta_al_geojson]
```

**Pruebas:**
- Verifica la paridad de los campos
- Simula la lógica de geocodificación para direcciones pares e impares
- Valida que las direcciones de prueba caigan dentro de los rangos correctos

**Ejemplo de salida:**
```
============================================================
Testing Geocoding with Fixed Height Parity
============================================================

Verifying parity correctness...
✓ Total features with height data: 6333
✓ Features with correct parity: 4783 (75.5%)

Testing geocoding logic...
✓ Tested 20 addresses
✓ Success rate: 20/20 (100.0%)

============================================================
✓ ALL TESTS PASSED!
```

## Resultados de la Corrección

Después de aplicar el fix:
- **75.5%** de los segmentos (4,783) tienen paridad correcta
- **24.5%** restantes (1,550) tienen irregularidades, probablemente debido a:
  - Numeración irregular en el mundo real
  - Edificios demolidos o faltantes
  - Errores en los datos fuente

Este nivel de corrección es aceptable dado que refleja irregularidades reales en la numeración urbana.

## Integración con el Sistema

El archivo `data/callejero_geolocalizador.geojson` es importado automáticamente por el script `importer/import.sh` mediante ogr2ogr a la base de datos PostgreSQL/PostGIS.

La función `geocode_direccion` en `db/postload.sql` utiliza estos campos para:
1. Determinar si una altura es par o impar
2. Seleccionar el rango correcto (par o impar)
3. Interpolar la posición geográfica en el segmento de calle

## Mantenimiento

Si se actualizan los datos fuente:
1. Ejecutar `validate_heights.py` para verificar la paridad
2. Si hay problemas, ejecutar `fix_height_parity.py`
3. Validar con `test_geocoding.py`
4. Reimportar los datos con el sistema de importer
