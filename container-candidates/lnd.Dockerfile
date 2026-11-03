# syntax=docker/dockerfile:1
FROM golang:1.27.3-alpine3.24@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS builder
ARG source_commit
WORKDIR /src
COPY . .
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca apk add --no-cache make git
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca go get golang.org/x/net@v0.60.0 \
      google.golang.org/grpc@v1.83.2 \
      go.etcd.io/etcd/client/pkg/v3@v3.5.33 \
      go.etcd.io/etcd/client/v3@v3.5.33 \
      go.etcd.io/etcd/server/v3@v3.5.33 \
      github.com/sirupsen/logrus@v1.9.3 \
      github.com/opencontainers/runc@v1.2.8 && \
    SSL_CERT_FILE=/run/secrets/proxy_ca go mod download && \
    SSL_CERT_FILE=/run/secrets/proxy_ca GOMAXPROCS=4 \
    make release-install COMMIT="${source_commit}-owner-security"

FROM scratch AS dependency-manifest
COPY --from=builder /src/go.mod /src/go.sum /

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca apk add --no-cache ca-certificates bash jq
COPY --from=builder /go/bin/lnd /bin/lnd
COPY --from=builder /go/bin/lncli /bin/lncli
RUN sha256sum /bin/lnd /bin/lncli > /shasums.txt
VOLUME /root/.lnd
EXPOSE 9735 10009
ENTRYPOINT ["lnd"]
