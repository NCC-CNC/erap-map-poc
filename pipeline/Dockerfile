# syntax=docker/dockerfile:1
#
# Pipeline image: GDAL/OGR, tippecanoe, the pmtiles CLI (ADR 0002) and Node
# for the display config tool (ADR 0007).
# Every tool is pinned. To upgrade one, change its ARG (and digest or
# checksum) here and note it in CHANGELOG.md.

# GDAL base, pinned by tag and digest. The digest is the multi-arch index.
ARG GDAL_IMAGE=ghcr.io/osgeo/gdal:ubuntu-small-3.13.3@sha256:64250faf833c06d4b21afce4c27190039ba7ab58d70f0eebc87cf77d929c0b40

# Node, for the display config tool (style/, ADR 0007). Same pinned image as
# web/Dockerfile and the web-dev compose service.
ARG NODE_IMAGE=node:26.13.0-bookworm-slim@sha256:add5c17c14752c54d2f3d519ec46a3815684d41c33f198bcb09fb998f7dcbf68

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
# Fetch bats-core (test stage only) from a pinned release tag, checked
# against its commit.
FROM ${GDAL_IMAGE} AS bats
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG BATS_VERSION=1.14.0
ARG BATS_COMMIT=eb7f42f8d608ac693d7a4b67474f6714ea68cfc5

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "v${BATS_VERSION}" \
      https://github.com/bats-core/bats-core.git /src/bats-core \
 && test "$(git -C /src/bats-core rev-parse HEAD)" = "${BATS_COMMIT}" \
 && /src/bats-core/install.sh /opt/bats

# ---------------------------------------------------------------------------
# The display config tool's packages (ajv, the MapLibre style spec), from
# its committed lockfile. Plain JavaScript, so they run on the GDAL base.
FROM ${NODE_IMAGE} AS style
WORKDIR /opt/pipeline/style
COPY style/package.json style/package-lock.json style/.npmrc ./
RUN npm ci --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------------------
# Shared base for the runtime and test images.
FROM ${GDAL_IMAGE} AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# jq: write and read manifest.json. libsqlite3/zlib: tippecanoe runtime libs.
# libatomic1: Node runtime lib.
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq libatomic1 libsqlite3-0 zlib1g \
 && rm -rf /var/lib/apt/lists/*

COPY --from=tippecanoe /opt/tippecanoe/bin/ /usr/local/bin/
COPY --from=pmtiles /usr/local/bin/pmtiles /usr/local/bin/pmtiles
COPY --from=style /usr/local/bin/node /usr/local/bin/node

# Pipeline scripts, layer configs, the display schema and tool, and the
# synthetic fixture, from the build context (pipeline/).
COPY bin/ /opt/pipeline/bin/
COPY lib/ /opt/pipeline/lib/
COPY layers/ /opt/pipeline/layers/
COPY schema/ /opt/pipeline/schema/
COPY style/ /opt/pipeline/style/
COPY --from=style /opt/pipeline/style/node_modules/ /opt/pipeline/style/node_modules/
COPY tests/ /opt/pipeline/tests/

# Run as a non-root user. docker-compose can override the uid with `user:`
# so files written to bind mounts match the host user on Linux.
RUN useradd --create-home --uid 10001 pipeline
USER 10001
WORKDIR /work

# ---------------------------------------------------------------------------
# Test image: `docker build --target test pipeline`. Running it runs every
# bats test in /opt/pipeline/tests.
FROM base AS test

COPY --from=bats /opt/bats/ /usr/local/

ENTRYPOINT ["bats"]
CMD ["/opt/pipeline/tests"]

# ---------------------------------------------------------------------------
# Runtime image. Last, so it is the default target.
# `docker compose run --rm pipeline [layer ...]` passes the layer names to
# run.sh; with no names it builds every layer. For a shell, add
# `--entrypoint bash`.
FROM base AS runtime

ENTRYPOINT ["/opt/pipeline/bin/run.sh"]
CMD []
