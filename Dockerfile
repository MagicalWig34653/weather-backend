FROM swift:6.2-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libwebp-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved* ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product radar --static-swift-stdlib

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libwebp7 libcurl4t64 libxml2 \
 && rm -rf /var/lib/apt/lists/* && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin radar
WORKDIR /app
COPY --from=build /src/.build/release/radar /usr/local/bin/radar
COPY migrations /app/migrations
ENV MIGRATIONS_DIR=/app/migrations HTTP_PORT=8080
USER radar
EXPOSE 8080
ENTRYPOINT ["radar"]
CMD ["serve"]
