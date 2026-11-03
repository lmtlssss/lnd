# syntax=docker/dockerfile:1
FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914 AS frontend
WORKDIR /build
COPY frontend ./frontend
RUN --mount=type=secret,id=proxy_ca,required=true \
    cd frontend && NODE_EXTRA_CA_CERTS=/run/secrets/proxy_ca \
      yarn install --frozen-lockfile --network-timeout 300000 && yarn build:http

FROM golang:1.27.3-trixie@sha256:c65ecfe613b539ac74c62a4c3b2c27e8f8a6076384c8f27e8a3c0f3be17cc385 AS builder
WORKDIR /build
ENV CGO_ENABLED=1
COPY . .
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca go get github.com/labstack/echo/v4@v4.16.1 \
      golang.org/x/net@v0.60.0 google.golang.org/grpc@v1.83.2 && \
    SSL_CERT_FILE=/run/secrets/proxy_ca go mod download
COPY --from=frontend /build/frontend/dist ./frontend/dist
RUN GOMAXPROCS=4 go build -trimpath \
      -ldflags="-X github.com/getAlby/hub/version.Tag=v1.24.4+owner-security" \
      -o main cmd/http/main.go && \
    GOMAXPROCS=4 go build -trimpath -o db_migrate cmd/db_migrate/main.go && \
    bash build/docker/copy_dylibs.sh amd64

FROM scratch AS dependency-manifest
COPY --from=builder /build/go.mod /build/go.sum /

FROM builder AS backend-checks
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca GOMAXPROCS=4 go test ./...

FROM debian:13-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
ENV LD_LIBRARY_PATH=/usr/lib/nwc
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/libldk_node.so /usr/lib/nwc/
COPY --from=builder /build/main /bin/main
COPY --from=builder /build/db_migrate /bin/db_migrate
ENTRYPOINT ["/bin/main"]
