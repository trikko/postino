#!/bin/sh
# End-to-end tests against two Mailpit servers in docker (https://mailpit.axllent.org):
# one plain, one that requires STARTTLS with a self-signed certificate.
# Usage: tests/mailpit.sh
set -e
cd "$(dirname "$0")/.."

DOCKER=${DOCKER:-docker}
CERTS=$(mktemp -d)
cleanup() {
    $DOCKER rm -f postino-mailpit postino-mailpit-tls >/dev/null 2>&1 || true
    rm -rf "$CERTS"
}
trap cleanup EXIT INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=mailpit \
    -keyout "$CERTS/key.pem" -out "$CERTS/cert.pem" 2>/dev/null
chmod a+rx "$CERTS"
chmod a+r "$CERTS"/*.pem

$DOCKER run -d --rm --name postino-mailpit -p 31025:1025 -p 38025:8025 \
    axllent/mailpit --smtp-auth-accept-any --smtp-auth-allow-insecure >/dev/null

$DOCKER run -d --rm --name postino-mailpit-tls -p 31026:1025 -p 38026:8025 -v "$CERTS:/certs:ro" \
    axllent/mailpit --smtp-auth-accept-any --smtp-require-starttls \
    --smtp-tls-cert /certs/cert.pem --smtp-tls-key /certs/key.pem >/dev/null

for port in 38025 38026; do
    until curl -sf "http://127.0.0.1:$port/api/v1/messages" >/dev/null; do sleep 0.2; done
done

dub run -q --single tests/mailpit.d
