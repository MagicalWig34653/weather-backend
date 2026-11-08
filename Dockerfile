# Dashboard (statischer SvelteKit-Build). Node-LTS "Lithium" (26), per Digest gepinnt.
FROM node:26-slim@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39 AS dashboard
WORKDIR /build
COPY dashboard/package.json dashboard/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY dashboard/ ./
RUN npm run build

FROM swift:6.2-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libwebp-dev zlib1g-dev libbz2-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved* ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product radar --static-swift-stdlib

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libwebp7 libcurl4t64 libxml2 zlib1g libbz2-1.0 \
 && rm -rf /var/lib/apt/lists/* && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin radar
WORKDIR /app
COPY --from=build /src/.build/release/radar /usr/local/bin/radar
COPY migrations /app/migrations
COPY --from=dashboard /build/build /app/dashboard
ARG BUILD_REVISION=
ENV BUILD_REVISION=$BUILD_REVISION
ENV MIGRATIONS_DIR=/app/migrations HTTP_PORT=8080
USER radar
EXPOSE 8080
ENTRYPOINT ["radar"]
CMD ["serve"]
