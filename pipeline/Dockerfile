# syntax=docker/dockerfile:1
#
# Pipeline image: GDAL/OGR, tippecanoe and the pmtiles CLI (ADR 0002).
# Every tool is pinned. To upgrade one, change its ARG (and digest or
# checksum) here and note it in CHANGELOG.md.

# GDAL base, pinned by tag and digest. The digest is the multi-arch index.
ARG GDAL_IMAGE=ghcr.io/osgeo/gdal:ubuntu-small-3.13.3@sha256:64250faf833c06d4b21afce4c27190039ba7ab58d70f0eebc87cf77d929c0b40

# ---------------------------------------------------------------------------
# Build tippecanoe from a pinned release tag, checked against its commit.
FROM ${GDAL_IMAGE} AS tippecanoe
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TIPPECANOE_VERSION=2.79.0
ARG TIPPECANOE_COMMIT=68ab8dcc229f95b8b25877697d5e8d66783af503

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git libsqlite3-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${TIPPECANOE_VERSION}" \
      https://github.com/felt/tippecanoe.git /src/tippecanoe \
 && test "$(git -C /src/tippecanoe rev-parse HEAD)" = "${TIPPECANOE_COMMIT}" \
 && make -C /src/tippecanoe -j"$(nproc)" \
 && make -C /src/tippecanoe install PREFIX=/opt/tippecanoe

# ---------------------------------------------------------------------------
# Fetch the pmtiles CLI (protomaps/go-pmtiles) and verify its checksum.
FROM ${GDAL_IMAGE} AS pmtiles
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PMTILES_VERSION=1.31.2
ARG PMTILES_SHA256=3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/pmtiles.tar.gz \
      "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz" \
 && echo "${PMTILES_SHA256}  /tmp/pmtiles.tar.gz" | sha256sum --check --strict - \
 && tar -xzf /tmp/pmtiles.tar.gz -C /usr/local/bin pmtiles \
 && rm /tmp/pmtiles.tar.gz

# ---------------------------------------------------------------------------
# Runtime image.
FROM ${GDAL_IMAGE} AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# jq: write and read manifest.json. libsqlite3/zlib: tippecanoe runtime libs.
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq libsqlite3-0 zlib1g \
 && rm -rf /var/lib/apt/lists/*

COPY --from=tippecanoe /opt/tippecanoe/bin/ /usr/local/bin/
COPY --from=pmtiles /usr/local/bin/pmtiles /usr/local/bin/pmtiles

# Run as a non-root user. docker-compose can override the uid with `user:`
# so files written to bind mounts match the host user on Linux.
RUN useradd --create-home --uid 10001 pipeline
USER 10001
WORKDIR /work

# The entry script arrives with #5; until then the image opens a shell.
CMD ["bash"]
