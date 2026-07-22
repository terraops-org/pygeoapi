# Docker Proposals

Proposed Dockerfile variants for pygeoapi, addressing issues#2221, #2180, #1753.

## Problem

The current Dockerfile mixes `python3-*` apt packages with pip packages, causing:
- **#2221**: gunicorn/gevent version mismatch (apt gevent 24.2.1 vs pip gunicorn 24+)
- **#2180**: Missing geopindas (requirements-provider.txt not installed in Docker)
- **#1753**: Monolithic ~1.5GB image, no variant strategy

## Approach

- **Slim/Alpine**: Pure pip on `ubuntu:26.04` (LTS) / Alpine, no GDAL
- **Distroless** (experimental): `gcr.io/distroless/python3-debian13` (Python 3.13, no shell, no apt), pure pip, no GDAL it is a hardened "slim"
- **Standard/Full**: `ghcr.io/osgeo/gdal:ubuntu-small` as base, rasterio/fiona/pyogrio built from source against system GDAL

### Why osgeo/gdal base for standard/full?

Pip binary wheels for rasterio, fiona, pyogrio, GDAL each **bundle their own copy** of
libgdal/libproj/libgeos (~50MB each). Installing all four from pip creates 120MB of
duplicated GDAL libraries on top of whatever system GDAL is already installed.

The `ghcr.io/osgeo/gdal:ubuntu-small` base image provides a single, optimized GDAL
installation. Building rasterio/fiona/pyogrio from source (`--no-binary`) makes them
link dynamically to the system libgdal (~3-5MB each instead of ~50MB).

Additional benefits:
- rasterio links against the base's GDAL (currently 3.12.4) instead of the older GDAL bundled in pip wheels (indicated by Francesco)
- The osgeo base includes GDAL Python bindings and numpy pre-installed
- Using `--system-site-packages` avoids reinstalling these (~120 MB savings)


## Current Status (updated 2026-07-22)

All five image variants build and serve. slim moved to Ubuntu 26.04 LTS
(Python 3.14); distroless runs on Debian 13 (Python 3.13); standard/full use
`ghcr.io/osgeo/gdal:ubuntu-small-3.12.4` (Ubuntu 24.04, Python 3.12, GDAL 3.12.4),
bumped from 3.11.4. standard/full source-build rasterio/fiona/pyogrio against the
single system GDAL (~1.07 GB, vs ~1.5 GB / ~600 MB compressed upstream).

Serve-testing standard/full (previously only import-tested) surfaced three
pre-existing issues, all now handled — see "Standard/Full images" below:
a numpy 2.x ABI break, a SpatiaLite×GDAL crash, and an outdated `GDAL<=3.11.3` pin.

### Image size comparison

| Image | Base | Uncompressed | Compressed (Docker Hub) |
|-------|------|-------------|------------------------|
| Upstream `geopython/pygeoapi:latest` | Ubuntu Noble | ~1.5 GB | ~600 MB |
| **`pygeoapi:slim` (optimized)** | Ubuntu 26.04 LTS | **429 MB** | **~144 MB** |
| **`pygeoapi:alpine` (just to have an idea)** | Alpine 3.x | **312 MB** | **~97 MB** |
| **`pygeoapi:distroless` (experimental, no SpatiaLite yet)** | distroless/python3-debian13 | **272 MB** | **~89 MB** |
| **`pygeoapi:standard`** | osgeo/gdal:ubuntu-small-3.12.4 | **1.07 GB** | **~330 MB** |
| **`pygeoapi:full`** | osgeo/gdal:ubuntu-small-3.12.4 | **1.06 GB** | **~350 MB** |

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

1. **`pip install --no-deps pygeoapi`** with `setup.py` reads `requirements.txt`
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

### Distroless image (experimental, verified 2026-07-22)

`Dockerfile.distroless` builds a **hardened slim** image on
`gcr.io/distroless/python3-debian13` — **no shell, no package manager**, minimal
attack surface. This is primarily an attack-surface play, not a size play,
though it also happens to be the smallest variant so far
(**272 MB uncompressed / ~89 MB compressed**).

**Iteration 1 caveat**: pure-Python providers only (CSV, GeoJSON, TinyDB).
SQLiteGPKG/SpatiaLite is NOT included yet, that needs `mod_spatialite` +
`libproj`/`libgeos` copied into the distroless runtime (iteration 2). So the
size is not yet apples-to-apples with slim/alpine (which include SpatiaLite).

Key design decisions:

1. **`gcr.io/distroless/python3-debian13` (Python 3.13.5)**  Debian 13 (trixie)
   is the first distroless Python that satisfies pygeoapi's
   `python_requires='>=3.12'`. The `-debian12` image is Python 3.11 — too old.

2. **`debian:trixie-slim` builder** The venv is built with Debian's system
   python3 so the cp313 wheels and interpreter paths (`/usr/bin/python3.13`,
   `/usr/lib/python3.13`) match the distroless runtime exactly.

3. **No hand-copied native libs** The distroless base already ships
   libssl/libsqlite3/libffi/liblzma/etc., so every stdlib native module imports.
   `shapely`/`pyproj` wheels bundle their own libgeos/libproj, so the pure-Python
   providers need zero system geo libs.

4. **Shell-free `entrypoint.py`** Tthe bash `docker/entrypoint.sh` cannot run
   (no shell). `entrypoint.py` reproduces the default `run` path: generate the
   OpenAPI (+ best-effort AsyncAPI) documents, then `exec` gunicorn. Same ENV
   interface as the bash entrypoint.

**Verified**: landing / collections / items / openapi all return HTTP 200;
gunicorn 26.0.0 + gevent on Python 3.13.5; `lakes` collection returns 10 features.

### Standard/Full images: osgeo/gdal base approach (verified 2026-07-22)

Both `Dockerfile.standard` and `Dockerfile.full` use `ghcr.io/osgeo/gdal:ubuntu-small-3.12.4`
as their base image (Ubuntu 24.04, Python 3.12, GDAL 3.12.4), parameterised via
`ARG GDAL_VERSION=3.12.4`.

**Verified package versions** (GDAL 3.12.4 build):
- GDAL 3.12.4 (system, from osgeo base)
- rasterio 1.5.0 / fiona / pyogrio 0.13.0 (built from source against system GDAL)
- geopandas 1.1.4 (fixes #2180)
- gunicorn + gevent from pip (fixes #2221, no version conflict)
- psycopg2 2.9.12, pymongo 4.6.3, oracledb 4.0.2, pymysql 2.2.8, elasticsearch (full only)

**No duplicate GDAL libraries in `/venv`** — `find /venv -name 'libgdal*'` returns
empty; the only `libgdal.so` is the system copy at `/usr/lib/x86_64-linux-gnu/`.

Key design decisions:

1. **`--system-site-packages` venv** it reuses the GDAL Python bindings (`osgeo/`)
   and `numpy` pre-installed in the osgeo base image. No duplication.

2. **`--no-binary rasterio --no-binary fiona --no-binary pyogrio`** — forces
   source compilation. The resulting `.so` files are ~3-5 MB each (linked to
   system libgdal) instead of ~50 MB each (bundled libgdal in wheels).

3. **psycopg2 from source** (full only) it built against `libpq-dev` in the
   builder stage, links to `libpq5` at runtime. No bundled libpq.

4. **No `apt install libgdal-dev`** inside the osgeo container — the osgeo
   README explicitly warns against this. GDAL headers are available at
   `/usr/local/gdal-internal/include/` and `gdal-config` is on PATH.

#### Three fixes exposed by serve-testing (all pre-existing, not from the GDAL bump)

These images had only ever been *import*-tested. Actually *serving* the default
config surfaced three latent issues:

1. **numpy 2.x ABI** — the osgeo base's GDAL bindings are built against numpy
   1.26.x, but the scientific stack (scipy/pandas/geopandas) pulls numpy 2.5.x,
   which crashes `osgeo._gdal_array` (`std::bad_alloc`). Fix: `numpy<2` in
   `requirements-standard.txt`, keeping the base numpy.

2. **SpatiaLite × GDAL crash** — the `SQLiteGPKG` (SpatiaLite) provider and any
   `OGR`/GDAL provider in the same process → `std::bad_alloc`/deadlock (two
   SpatiaLite copies collide). standard/full therefore serve GeoPackage via
   **OGR**, never `SQLiteGPKG`, and do **not** install `mod_spatialite`. They set
   `PYGEOAPI_OPENAPI_GENERATE_FAIL_ON_INVALID_COLLECTION=false` so the stock
   config's one `SQLiteGPKG` collection is skipped instead of aborting startup.
   Full analysis + a draft upstream issue: **`SPATIALITE-GDAL-CONFLICT.md`**.

3. **Outdated `GDAL<=3.11.3` pin** — `requirements-provider.txt` caps GDAL at
   3.11.3, so pip tried to source-build that old binding against GDAL 3.12
   headers and failed (`GetGeoTransform` signature). Fix: strip GDAL from that
   pip install (`grep -iv '^gdal'`) since the osgeo base already provides the
   matching `osgeo.gdal`. The cap looks outdated upstream — GDAL 3.12.4 works fine.

### Note on pyproj bundled libproj

The pyproj pip wheel bundles its own `libproj` shared library inside
`/venv/lib/python3.12/site-packages/pyproj.libs/libproj-*.so` (~9 MB).


### Provider dependency map

| Provider | GDAL needed | Image tier |
|----------|-------------|------------|
| CSV, GeoJSON, TinyDB, SQLiteGPKG, Filesystem | No | slim |
| OGR, MapScript | Yes (osgeo.gdal/ogr/osr) | standard, full |
| Rasterio | Yes (via rasterio) | standard, full |
| PostgreSQL, Elasticsearch, MongoDB, Oracle | No (database clients) | full |

### Open items

1. **GDAL version pinning**: `ARG GDAL_VERSION=3.12.4` in standard/full pins the
   osgeo base. Bump it for a newer stable GDAL. Note: `ubuntu-small-3.13.1` is the
   first stable-GDAL tag on Ubuntu 26.04 / Python 3.14, but the scientific stack is
   not yet fully py3.14-ready (see the slim notes), so 3.12.4 (24.04/py3.12) is the
   pragmatic choice for now.

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

Minimal image, NO GDAL. Ubuntu 26.04 LTS ("resolute", Python 3.14) base with
source-built SpatiaLite. Base pinned via `ARG UBUNTU_VERSION=resolute-20260707`
(immutable dated tag, never `:latest`).
Supports: CSV, GeoJSON, TinyDB, Filesystem, SQLiteGPKG providers.
Size: **429 MB** uncompressed, **~144 MB** on Docker Hub.

> Ported from Ubuntu Noble (24.04) to 26.04 LTS. The only change required was
> dropping the obsolete `localedef -A /usr/share/locale/locale.alias` argument
> (26.04's `locales` package no longer ships that alias file). All apt package
> names (`libproj25`, `libgeos-c1t64`, `libsqlite3-0`, `libminizip1t64`) are
> unchanged, and Python 3.14 already has wheels for shapely/pyproj/pydantic-core.

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

### Dockerfile.distroless (experimental, verified)

Hardened "slim" on `gcr.io/distroless/python3-debian13`  **no shell, no apt**.
Pure-Python providers only (CSV, GeoJSON, TinyDB); SpatiaLite/SQLiteGPKG not yet
included (iteration 2). Uses `entrypoint.py` instead of the bash entrypoint.
Size: **272 MB** uncompressed, **~89 MB** compressed — smallest variant so far.

```bash
docker build -f docker-proposals/Dockerfile.distroless -t pygeoapi:distroless .
docker run -p 5000:80 pygeoapi:distroless
```

Because there is no shell, provider checks run through the venv interpreter
directly (`--entrypoint /venv/bin/python3`), not `/bin/bash`.

### Dockerfile.standard (osgeo/gdal base, verified)

Mid-tier with GDAL + rasterio + fiona + geopandas, no database clients.
Base: `ghcr.io/osgeo/gdal:ubuntu-small-3.12.4` (Ubuntu 24.04, Python 3.12).
rasterio/fiona/pyogrio built from source against system GDAL. GeoPackage is
served via OGR (not SQLiteGPKG — see the SpatiaLite×GDAL note above).
Size: **1.07 GB** uncompressed.

Verified: GDAL 3.12.4, rasterio 1.5.0, pyogrio 0.13.0, geopandas 1.1.4,
OGR + Rasterio + CSV + GeoJSON; serves 10 collections (HTTP 200).

```bash
docker build -f docker-proposals/Dockerfile.standard -t pygeoapi:standard .
docker run -p 5000:80 pygeoapi:standard
```

### Dockerfile.full (osgeo/gdal base, verified)

All providers including database clients (PostgreSQL, Elasticsearch, MongoDB, Oracle).
Base: `ghcr.io/osgeo/gdal:ubuntu-small-3.12.4` (Ubuntu 24.04, Python 3.12).
Same source-build approach as standard, plus psycopg2 from source against libpq.
Size: **1.06 GB** uncompressed.

Verified: everything from standard, plus psycopg2 2.9.12, pymongo 4.6.3,
oracledb 4.0.2, pymysql 2.2.8, elasticsearch; serves 10 collections (HTTP 200).

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
docker build -f docker-proposals/Dockerfile.distroless -t pygeoapi:distroless .
docker build -f docker-proposals/Dockerfile.standard -t pygeoapi:standard .
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

# Verify distroless — NO shell, so go through the venv interpreter (not /bin/bash)
docker run --rm --entrypoint /venv/bin/python3 pygeoapi:distroless -c '
import sys; print("python", sys.version.split()[0])
from pygeoapi.api import API; print("API: OK")
from pygeoapi.provider.csv_ import CSVProvider; print("CSV: OK")
from pygeoapi.provider.geojson import GeoJSONProvider; print("GeoJSON: OK")
import shapely, pyproj, gunicorn, gevent
print("shapely", shapely.__version__, "| pyproj", pyproj.__version__)
'
# Confirm there is genuinely no shell (this should fail)
docker run --rm --entrypoint /bin/sh pygeoapi:distroless -c "echo hi" \
    || echo "no /bin/sh — distroless confirmed"

# Verify standard providers + geopandas (#2180)
docker run --rm --entrypoint /bin/bash pygeoapi:standard -c "/venv/bin/python3 -c '
from osgeo import gdal, ogr, osr; print(f\"GDAL {gdal.__version__}: OK\")
import rasterio; print(f\"rasterio {rasterio.__version__}: OK\")
import fiona; print(f\"fiona {fiona.__version__}: OK\")
import pyogrio; print(f\"pyogrio {pyogrio.__version__}: OK\")
import geopandas; print(f\"geopandas {geopandas.__version__}: OK\")
from pygeoapi.provider.rasterio_ import RasterioProvider; print(\"Rasterio provider: OK\")
from pygeoapi.provider.ogr import OGRProvider; print(\"OGR provider: OK\")
'"

# Verify no duplicate libgdal in venv (should be empty)
docker run --rm --entrypoint /bin/bash pygeoapi:standard -c \
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
docker run --rm --entrypoint /venv/bin/python3 pygeoapi:standard -c \
    "import gevent, gunicorn; print(f'gevent={gevent.__version__} gunicorn={gunicorn.__version__}')"

# Compressed sizes
for img in slim alpine distroless standard full; do
    docker save pygeoapi:$img | gzip | wc -c | awk -v img="$img" '{printf "%s: %.0f MB compressed\n", img, $1/1024/1024}'
done
```

## Files

- `Dockerfile.slim` - Optimized minimal image, Ubuntu 26.04 LTS (no GDAL, vector providers only)
- `Dockerfile.alpine` - Experimental minimal image, Alpine Linux (smallest possible)
- `Dockerfile.distroless` - Experimental hardened-slim image (distroless/python3-debian13, no shell, no SpatiaLite yet)
- `Dockerfile.standard` - Geospatial image (osgeo/gdal base, GDAL + file providers, no databases)
- `Dockerfile.full` - Full image (osgeo/gdal base, all providers including databases)
- `requirements-slim.txt` - Minimal requirements (excludes rasterio, no GDAL)
- `requirements-standard.txt` - Geospatial requirements (excludes rasterio/fiona/pyogrio — --no-binary in Dockerfile; pins numpy<2 for the osgeo GDAL bindings)
- `slim.config.yml` - Default config for slim images (CSV, GeoJSON, SQLiteGPKG only)
- `entrypoint.py` - Shell-free entrypoint for the distroless image (replaces bash docker/entrypoint.sh)
- `distroless.config.yml` - Default config for the distroless image (CSV, GeoJSON only — no SpatiaLite)
- `SPATIALITE-GDAL-CONFLICT.md` - Root-cause analysis + draft upstream issue for the SQLiteGPKG×GDAL crash
