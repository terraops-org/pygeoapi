# Docker Proposals

Proposed Dockerfile variants for pygeoapi, addressing issues#2221, #2180, #1753.

## Problem

The current Dockerfile mixes `python3-*` apt packages with pip packages, causing:
- **#2221**: gunicorn/gevent version mismatch (apt gevent 24.2.1 vs pip gunicorn 24+)
- **#2180**: Missing geopindas (requirements-provider.txt not installed in Docker)
- **#1753**: Monolithic ~1.5GB image, no variant strategy

## Approach

- **Slim/Alpine**: Pure pip on `ubuntu:noble` / Alpine, no GDAL
- **Geo/Full**: `ghcr.io/osgeo/gdal:ubuntu-small` as base, rasterio/fiona/pyogrio built from source against system GDAL

### Why osgeo/gdal base for geo/full?

Pip binary wheels for rasterio, fiona, pyogrio, GDAL each **bundle their own copy** of
libgdal/libproj/libgeos (~50MB each). Installing all four from pip creates 120MB of
duplicated GDAL libraries on top of whatever system GDAL is already installed.

The `ghcr.io/osgeo/gdal:ubuntu-small` base image provides a single, optimized GDAL
installation. Building rasterio/fiona/pyogrio from source (`--no-binary`) makes them
link dynamically to the system libgdal (~3-5MB each instead of ~50MB).

Additional benefits:
- rasterio links against GDAL 3.11.4 instead of the older GDAL bundled in pip wheels (indicated by Francesco)
- The osgeo base includes GDAL Python bindings and numpy pre-installed
- Using `--system-site-packages` avoids reinstalling these (~120 MB savings)


## Current Status (2026-02-23)

All four image variants are built and verified. The geo/full images were
rewritten from `ubuntu:noble` + pip binary wheels (1.6 GB, with duplicated
GDAL libraries) to `ghcr.io/osgeo/gdal:ubuntu-small-3.11.4` + source builds
(1.08 GB, single system GDAL). Compressed sizes dropped from ~600 MB
(upstream) to 331-348 MB for geo/full.

### Image size comparison

| Image | Base | Uncompressed | Compressed (Docker Hub) |
|-------|------|-------------|------------------------|
| Upstream `geopython/pygeoapi:latest` | Ubuntu Noble | ~1.5 GB | ~600 MB |
| **`pygeoapi:slim` (optimized)** | Ubuntu Noble | **415 MB** | **~138 MB** |
| **`pygeoapi:alpine` (just to have an idea)** | Alpine 3.x | **312 MB** | **~97 MB** |
| **`pygeoapi:geo`** | osgeo/gdal:ubuntu-small-3.11.4 | **1.08 GB** | **~331 MB** |
| **`pygeoapi:full`** | osgeo/gdal:ubuntu-small-3.11.4 | **1.08 GB** | **~348 MB** |

### Slim optimization history

| Milestone | Uncompressed | Change |
|-----------|-------------|--------|
| Initial build | 642 MB | baseline |
| + `--no-deps` (drop rasterio) | 525 MB | -117 MB |
| + SpatiaLite from source | 500 MB | -25 MB |
| + strip/cleanup/selective COPY | 415 MB | -85 MB |
| Alpine variant | 312 MB | -103 MB vs Ubuntu |

**All core providers**: CSV, GeoJSON, TinyDB, SQLiteGPKG, SpatiaLite 5.1.0.

### Slim optimizations applied

1. **`pip install --no-deps pygeoapi`** — `setup.py` reads `requirements.txt`
   into `install_requires`, which includes `rasterio`. Since rasterio is only
   used by the Rasterio coverage provider (not needed for vector-only slim),
   `--no-deps` prevents it from being pulled in. The slim requirements file
   (`requirements-slim.txt`) provides all needed dependencies explicitly.
   Saves ~117 MB (rasterio 112 MB + numpy 69 MB, minus numpy kept by shapely).

2. **SpatiaLite built from source** with optional features disabled:
   ```
   --enable-libxml2=no   # drops libxml2 (2 MB) + libicu74 (36 MB)
   --enable-freexl=no    # drops libfreexl (0.15 MB)
   --enable-rttopo=no    # drops librttopo (0.5 MB)
   ```
   The Ubuntu `libsqlite3-mod-spatialite` package depends on libxml2, which
   depends on libicu74 (36 MB). pygeoapi's SQLiteGPKG provider doesn't use
   SpatiaLite's XML functions, so disabling libxml2 is safe. The mod_spatialite
   `.so` is compiled in the builder stage and copied to the runtime image.
   Saves +/-38 MB.

3. **Venv cleanup in builder stage**:
   - Uninstall pip, setuptools, wheel (~21 MB)
   - Strip all `.so` files with `strip -s` (~30 MB)
   - Remove `__pycache__` dirs and `.pyc` files (~3 MB)
   - Remove `/venv/share` and `/venv/include`

4. **OGC schemas downloaded in builder stage** — avoids installing curl and
   unzip in the runtime image. The schemas are copied via `COPY --from=builder`.

5. **Slim-specific config** (`slim.config.yml`) — only references providers
   available in the slim image (CSV, GeoJSON, SQLiteGPKG, HelloWorld process).
   No OGR or coverage collections that would fail without GDAL.

### Geo/Full images: osgeo/gdal base approach (verified 2026-02-23)

Both `Dockerfile.geo` and `Dockerfile.full` use `ghcr.io/osgeo/gdal:ubuntu-small-3.11.4`
as their base image (Ubuntu 24.04, Python 3.12, GDAL 3.11.4).

**Verified package versions** (from build output):
- GDAL 3.11.4 (system, from osgeo base)
- rasterio 1.5.0 (built from source against system GDAL)
- fiona 1.10.1 (built from source against system GDAL)
- pyogrio 0.12.1 (built from source against system GDAL)
- geopandas 1.1.2 (fixes #2180)
- gunicorn 25.1.0 + gevent 25.9.1 (fixes #2221, no version conflict)
- psycopg2 2.9.11 (full only, built from source against libpq)

**No duplicate GDAL libraries in `/venv`** — verified with `find /venv -name 'libgdal*'`
returning empty. The only `libgdal.so` is the system copy at `/usr/lib/x86_64-linux-gnu/`.

Key design decisions:

1. **`--system-site-packages` venv** — reuses the GDAL Python bindings (`osgeo/`)
   and `numpy` pre-installed in the osgeo base image. No duplication.

2. **`--no-binary rasterio --no-binary fiona --no-binary pyogrio`** — forces
   source compilation. The resulting `.so` files are ~3-5 MB each (linked to
   system libgdal) instead of ~50 MB each (bundled libgdal in wheels).

3. **psycopg2 from source** (full only) — built against `libpq-dev` in the
   builder stage, links to `libpq5` at runtime. No bundled libpq.

4. **No `apt install libgdal-dev`** inside the osgeo container — the osgeo
   README explicitly warns against this. GDAL headers are available at
   `/usr/local/gdal-internal/include/` and `gdal-config` is on PATH.

### Note on pyproj bundled libproj

The pyproj pip wheel bundles its own `libproj` shared library inside
`/venv/lib/python3.12/site-packages/pyproj.libs/libproj-*.so` (~9 MB).


### Provider dependency map

| Provider | GDAL needed | Image tier |
|----------|-------------|------------|
| CSV, GeoJSON, TinyDB, SQLiteGPKG, Filesystem | No | slim |
| OGR, MapScript | Yes (osgeo.gdal/ogr/osr) | geo, full |
| Rasterio | Yes (via rasterio) | geo, full |
| PostgreSQL, Elasticsearch, MongoDB, Oracle | No (database clients) | full |

### Open items

1. **GDAL version pinning**: The `ARG GDAL_VERSION=3.11.4` in geo/full
   Dockerfiles should be updated when a new GDAL 3.11.x bugfix is released.
   The osgeo base image release cadence is independent from pygeoapi's.

2. **`latest` tag policy**: Once variants ship, the community needs to decide
   whether `geopython/pygeoapi:latest` points to `full` (current behavior)
   or `slim`. This is a user-facing decision.

3. **CI/CD multi-tag publishing**: The current CI (`.github/workflows/containers.yml`)
   only builds a single image. It needs updating to build and publish all
   four variants with appropriate tags.

### Upstream improvement: rasterio as optional dependency

`setup.py` line 159 uses `install_requires=read('requirements.txt').splitlines()`,
which makes rasterio a hard dependency for all installs. Since rasterio is only
imported by the Rasterio, Filesystem (lazy), and Azure (lazy) providers, it
should be an optional extra:

```python
# Proposed change to setup.py
extras_require={
    'rasterio': ['rasterio'],
},
```

This would allow `pip install pygeoapi` without GDAL, and
`pip install pygeoapi[rasterio]` for coverage support.

## Variants

### Dockerfile.slim (optimized, ready for testing)

Minimal image, NO GDAL. Ubuntu Noble base with source-built SpatiaLite.
Supports: CSV, GeoJSON, TinyDB, Filesystem, SQLiteGPKG providers.
Size: **415 MB** uncompressed, **~138 MB** on Docker Hub.

```bash
docker build -f docker-proposals/Dockerfile.slim -t pygeoapi:slim .
docker run -p 5000:80 pygeoapi:slim
```

### Dockerfile.alpine (testing things)

Same as slim but on Alpine Linux. Smallest possible image.
Uses musl libc instead of glibc — all providers work, minor pyproj warning
about PROJ database path (cosmetic, does not affect functionality).
Size: **312 MB** uncompressed, **~97 MB** on Docker Hub.

```bash
docker build -f docker-proposals/Dockerfile.alpine -t pygeoapi:alpine .
docker run -p 5000:80 pygeoapi:alpine
```

### Dockerfile.geo (osgeo/gdal base, verified)

Mid-tier with GDAL + rasterio + fiona + geopandas, no database clients.
Base: `ghcr.io/osgeo/gdal:ubuntu-small-3.11.4`.
rasterio/fiona/pyogrio built from source against system GDAL.
Size: **1.08 GB** uncompressed, **~331 MB** compressed.

Verified providers: GDAL 3.11.4, rasterio 1.5.0, fiona 1.10.1,
pyogrio 0.12.1, geopandas 1.1.2, OGR, Rasterio, CSV, GeoJSON.

```bash
docker build -f docker-proposals/Dockerfile.geo -t pygeoapi:geo .
docker run -p 5000:80 pygeoapi:geo
```

### Dockerfile.full (osgeo/gdal base, verified)

All providers including database clients (PostgreSQL, Elasticsearch, MongoDB, Oracle).
Base: `ghcr.io/osgeo/gdal:ubuntu-small-3.11.4`.
Same source-build approach as geo, plus psycopg2 from source against libpq.
Size: **1.08 GB** uncompressed, **~348 MB** compressed.

Verified providers: everything from geo, plus psycopg2 2.9.11,
pymongo 4.6.3, elasticsearch-dsl, oracledb 3.4.2, pymysql 1.4.6, paho-mqtt.

```bash
docker build -f docker-proposals/Dockerfile.full -t pygeoapi:full .
docker run -p 5000:80 pygeoapi:full
```

## Testing

```bash
cd /home/mende012/git/to.pygeoapi

# Build all variants
docker build -f docker-proposals/Dockerfile.slim -t pygeoapi:slim .
docker build -f docker-proposals/Dockerfile.alpine -t pygeoapi:alpine .
docker build -f docker-proposals/Dockerfile.geo -t pygeoapi:geo .
docker build -f docker-proposals/Dockerfile.full -t pygeoapi:full .

# Compare sizes
docker images pygeoapi

# Verify slim providers
docker run --rm --entrypoint /bin/bash pygeoapi:slim -c "/venv/bin/python3 -c '
from pygeoapi.api import API; print(\"API: OK\")
from pygeoapi.provider.csv_ import CSVProvider; print(\"CSV: OK\")
from pygeoapi.provider.geojson import GeoJSONProvider; print(\"GeoJSON: OK\")
from pygeoapi.provider.tinydb_ import TinyDBCatalogueProvider; print(\"TinyDB: OK\")
from pygeoapi.provider.sqlite import SQLiteGPKGProvider; print(\"SQLiteGPKG: OK\")
'"

# Verify geo providers + geopandas (#2180)
docker run --rm --entrypoint /bin/bash pygeoapi:geo -c "/venv/bin/python3 -c '
from osgeo import gdal, ogr, osr; print(f\"GDAL {gdal.__version__}: OK\")
import rasterio; print(f\"rasterio {rasterio.__version__}: OK\")
import fiona; print(f\"fiona {fiona.__version__}: OK\")
import pyogrio; print(f\"pyogrio {pyogrio.__version__}: OK\")
import geopandas; print(f\"geopandas {geopandas.__version__}: OK\")
from pygeoapi.provider.rasterio_ import RasterioProvider; print(\"Rasterio provider: OK\")
from pygeoapi.provider.ogr import OGRProvider; print(\"OGR provider: OK\")
'"

# Verify no duplicate libgdal in venv (should be empty)
docker run --rm --entrypoint /bin/bash pygeoapi:geo -c \
    "find /venv -name 'libgdal*' -o -name 'libproj*' | head -20"

# Verify full image has database clients
docker run --rm --entrypoint /bin/bash pygeoapi:full -c "/venv/bin/python3 -c '
import psycopg2; print(\"psycopg2: OK\")
import pymongo; print(\"pymongo: OK\")
from elasticsearch_dsl import Q; print(\"elasticsearch-dsl: OK\")
import oracledb; print(\"oracledb: OK\")
import geopandas; print(f\"geopandas {geopandas.__version__}: OK\")
'"

# Verify gunicorn/gevent no conflict (#2221)
docker run --rm --entrypoint /venv/bin/python3 pygeoapi:geo -c \
    "import gevent, gunicorn; print(f'gevent={gevent.__version__} gunicorn={gunicorn.__version__}')"

# Compressed sizes
for img in slim alpine geo full; do
    docker save pygeoapi:$img | gzip | wc -c | awk -v img="$img" '{printf "%s: %.0f MB compressed\n", img, $1/1024/1024}'
done
```

## Files

- `Dockerfile.slim` - Optimized minimal image, Ubuntu Noble (no GDAL, vector providers only)
- `Dockerfile.alpine` - Experimental minimal image, Alpine Linux (smallest possible)
- `Dockerfile.geo` - Geospatial image (osgeo/gdal base, GDAL + file providers, no databases)
- `Dockerfile.full` - Full image (osgeo/gdal base, all providers including databases)
- `requirements-slim.txt` - Minimal requirements (excludes rasterio, no GDAL)
- `requirements-geo.txt` - Geospatial requirements (excludes rasterio/fiona/pyogrio — those are --no-binary in Dockerfile)
- `slim.config.yml` - Default config for slim images (CSV, GeoJSON, SQLiteGPKG only)
