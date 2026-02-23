# =================================================================
#
# Geo pygeoapi image — GDAL + file-based geospatial providers.
# No database clients (PostgreSQL, MongoDB, Elasticsearch, etc.).
# Supports: OGR, Rasterio, Fiona, GeoPackage, Shapefile, Parquet,
#           xarray/NetCDF, CSV, GeoJSON, TinyDB, Filesystem,
#           geopandas.
#
# Addresses:
#   #1753 - Docker container variants
#   #2180 - Missing geopandas (now included)
#   #2221 - gunicorn/gevent conflict (pure pip, no python3-* apt)
#
# Base: ghcr.io/osgeo/gdal:ubuntu-small — provides a single system
# GDAL installation. Python packages (rasterio, fiona, pyogrio) are
# built from source against the system GDAL libs, eliminating the
# ~250 MB of duplicated libgdal copies that pip binary wheels bundle.
#
# =================================================================

ARG GDAL_VERSION=3.11.4

# =================================================================
# Stage 1: BUILDER — compile native extensions against system GDAL
# =================================================================
FROM ghcr.io/osgeo/gdal:ubuntu-small-${GDAL_VERSION} AS builder

ENV DEBIAN_FRONTEND="noninteractive"

# Build deps: compilers + Python headers.
# NOTE: Do NOT install libgdal-dev or any GDAL apt packages —
# the osgeo base image provides GDAL at /usr/local/gdal-internal/.
# Tip: with DOCKER_BUILDKIT=1, you can replace the rm -rf with:
#   --mount=type=cache,target=/var/cache/apt,sharing=locked
#   --mount=type=cache,target=/var/lib/apt,sharing=locked
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        build-essential \
        python3-dev \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Create venv with --system-site-packages to reuse the GDAL Python
# bindings and numpy already installed in the osgeo base image.
# This avoids reinstalling osgeo/ (~50 MB) and numpy (~70 MB).
RUN python3 -m venv --system-site-packages /venv \
    && /venv/bin/python3 -m pip install --no-cache-dir \
        --upgrade pip setuptools wheel Cython

# Install core pygeoapi dependencies (pure Python, no GDAL needed)
COPY docker-proposals/requirements-slim.txt ./
RUN /venv/bin/python3 -m pip install --no-cache-dir \
    -r requirements-slim.txt

# Build rasterio, fiona, pyogrio from source against system GDAL.
# --no-binary forces pip to compile from source instead of using
# pre-built wheels that bundle their own libgdal (~50 MB each).
# The resulting .so files link dynamically to /usr/local/gdal-internal/lib/libgdal.so
RUN /venv/bin/python3 -m pip install --no-cache-dir \
    --no-binary rasterio \
    --no-binary fiona \
    --no-binary pyogrio \
    rasterio fiona pyogrio

# Install remaining geo packages (pure Python or binary-safe)
COPY docker-proposals/requirements-geo.txt ./
RUN /venv/bin/python3 -m pip install --no-cache-dir \
    -r requirements-geo.txt

# Install pygeoapi (non-editable, --no-deps to avoid pulling
# rasterio again from setup.py's install_requires)
COPY . /build/pygeoapi
RUN /venv/bin/python3 -m pip install --no-cache-dir \
    --no-deps /build/pygeoapi

# Download OGC schemas in builder (avoids curl/unzip in runtime)
RUN curl -sSO http://schemas.opengis.net/SCHEMAS_OPENGIS_NET.zip \
    && unzip -q SCHEMAS_OPENGIS_NET.zip "ogcapi/*" -d /schemas.opengis.net \
    && rm -f SCHEMAS_OPENGIS_NET.zip

# Clean up venv: strip binaries, purge caches
RUN /venv/bin/python3 -m pip uninstall -y pip setuptools wheel Cython \
    && find /venv -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; true \
    && find /venv -type f -name '*.pyc' -delete \
    && find /venv -type f -name '*.so' -exec strip -s {} + 2>/dev/null; true \
    && rm -rf /venv/share /venv/include

# =================================================================
# Stage 2: RUNTIME — system GDAL + lean venv, no compilers
# =================================================================
FROM ghcr.io/osgeo/gdal:ubuntu-small-${GDAL_VERSION}

LABEL maintainer="Just van den Broecke <justb4@gmail.com>"

# Geo pygeoapi: GDAL + file-based geospatial providers, no databases.
# Same entrypoint.sh and ENV interface as the full image.

ARG TZ="Etc/UTC"
ARG LANG="en_US.UTF-8"

ENV TZ=${TZ} \
    LANG=${LANG} \
    DEBIAN_FRONTEND="noninteractive"

WORKDIR /pygeoapi

# Runtime deps: locale + venv support only.
# GDAL, PROJ, GEOS, SpatiaLite are provided by the osgeo base image.
# Tip: with DOCKER_BUILDKIT=1, you can replace the rm -rf with:
#   --mount=type=cache,target=/var/cache/apt,sharing=locked
#   --mount=type=cache,target=/var/lib/apt,sharing=locked
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        locales \
        tzdata \
        python3-venv \
    && localedef -i en_US -c -f UTF-8 \
        -A /usr/share/locale/locale.alias en_US.UTF-8 \
    && echo "For ${TZ} date=$(date)" && echo "Locale=$(locale)" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# OGC schemas from builder
COPY --from=builder /schemas.opengis.net /schemas.opengis.net

# Pre-built venv (rasterio/fiona/pyogrio linked to system GDAL)
COPY --from=builder /venv /venv

# Copy only what's needed — exclude tests/, docs/, .git/
COPY docker /pygeoapi/docker
COPY pygeoapi /pygeoapi/pygeoapi
COPY locale /pygeoapi/locale
COPY pygeoapi-config.yml /pygeoapi/pygeoapi-config.yml
COPY setup.py /pygeoapi/setup.py
COPY README.md /pygeoapi/README.md
COPY requirements.txt /pygeoapi/requirements.txt
COPY tests/data /pygeoapi/tests/data

RUN cp /pygeoapi/docker/default.config.yml /pygeoapi/local.config.yml \
    && cp /pygeoapi/docker/entrypoint.sh /entrypoint.sh \
    && cd /pygeoapi \
    && for i in locale/*; do \
        if [ "$i" != "locale/README.md" ]; then \
            echo $i \
            && /venv/bin/pybabel compile -d locale -l $(basename $i); \
        fi; \
    done \
    && chmod -R g=u /pygeoapi

ENTRYPOINT ["/entrypoint.sh"]
