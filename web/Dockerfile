# syntax=docker/dockerfile:1
#
# Web image: builds the app with Node, serves it with nginx (ADR 0003,
# ADR 0004). Base images are pinned by tag and digest (multi-arch index)
# in literal `FROM` lines so Dependabot can propose updates; it does not
# resolve `ARG` values in `FROM`. Note upgrades in CHANGELOG.md. Keep Node
# on the same version as pipeline/Dockerfile and the web-dev compose
# service.
#
# Runtime contract:
#   - listens on 8080
#   - serves /tiles/ from /srv/tiles (mount the pipeline output read-only)

# ---------------------------------------------------------------------------
# Build the static app into /app/dist.
FROM node:26.13.0-bookworm-slim@sha256:add5c17c14752c54d2f3d519ec46a3815684d41c33f198bcb09fb998f7dcbf68 AS build
WORKDIR /app

# Dependencies first, so source edits do not re-run npm ci.
COPY package.json package-lock.json .npmrc ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY . .
RUN npm run build

# ---------------------------------------------------------------------------
# Runtime: unprivileged nginx (runs as uid 101, listens on 8080).
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03 AS runtime

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/ /usr/share/nginx/html/

EXPOSE 8080
