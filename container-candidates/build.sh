#!/usr/bin/env bash
set -euo pipefail
case "${COMPONENT:?}" in lnd|albyhub) ;; *) exit 2;; esac
test "$(git -C source rev-parse HEAD)" = "${SOURCE_COMMIT:?}"
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH
image="owner-security/${COMPONENT}:cleanup-20261103"
recipe="container-candidates/${COMPONENT}.Dockerfile"
mkdir -p artifact/dependencies
docker --host=unix:///var/run/docker.sock build --platform linux/amd64 \
  --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt \
  --build-arg source_commit="$SOURCE_COMMIT" --file "$recipe" --tag "$image" source
docker --host=unix:///var/run/docker.sock build --platform linux/amd64 \
  --secret id=proxy_ca,src=/etc/ssl/certs/ca-certificates.crt \
  --build-arg source_commit="$SOURCE_COMMIT" --file "$recipe" \
  --target dependency-manifest --output type=local,dest=artifact/dependencies source
cp "$recipe" artifact/Dockerfile
printf '%s\n' "$image" > artifact/image-ref.txt
docker --host=unix:///var/run/docker.sock image inspect --format '{{.Id}}' "$image" > artifact/image-id.txt
printf '%s\n%s\n' "$SOURCE_REPOSITORY" "$SOURCE_COMMIT" > artifact/source.txt
if [ "$COMPONENT" = lnd ]; then
  docker --host=unix:///var/run/docker.sock run --rm --network none \
    --mount type=tmpfs,dst=/root/.lnd --entrypoint sha256sum "$image" /bin/lnd /bin/lncli > artifact/binaries.sha256
else
  docker --host=unix:///var/run/docker.sock run --rm --network none \
    --entrypoint sha256sum "$image" /bin/main /bin/db_migrate /usr/lib/nwc/libldk_node.so > artifact/binaries.sha256
fi
docker --host=unix:///var/run/docker.sock save "$image" | gzip -1 > artifact/image.tar.gz
(cd artifact && sha256sum image.tar.gz > image.tar.gz.sha256)
docker --host=unix:///var/run/docker.sock run --rm --user 0:0 \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock,readonly \
  -e DOCKER_HOST=unix:///var/run/docker.sock \
  -e GRYPE_CHECK_FOR_APP_UPDATE=false \
  anchore/grype@sha256:6b06708b036f74b2cd70e94b706b4586af96d1932e6ac46255940b2e39dd44a9 \
  "docker:$image" --output json --fail-on critical > artifact/grype.json
