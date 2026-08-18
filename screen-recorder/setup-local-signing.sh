#!/bin/bash

set -euo pipefail

IDENTITY_NAME="Screen Recorder Local Signing"
USER_KEYCHAIN="$(security default-keychain -d user | tr -d '"' | xargs)"

identity_count() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F -c "\"${IDENTITY_NAME}\"" \
        || true
}

if [[ "$(identity_count)" -eq 1 ]]; then
    echo "Signing identity already exists: ${IDENTITY_NAME}"
    exit 0
fi

if [[ "$(identity_count)" -gt 1 ]]; then
    echo "More than one '${IDENTITY_NAME}' identity exists in the user keychain." >&2
    echo "Remove the duplicate in Keychain Access before continuing." >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d /private/tmp/screen-recorder-local-signing.XXXXXX)"
P12_PASSWORD="$(openssl rand -hex 24)"

cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

openssl req \
    -x509 \
    -newkey rsa:3072 \
    -sha256 \
    -days 3650 \
    -nodes \
    -subj "/CN=${IDENTITY_NAME}/O=Local Screen Recorder/OU=Local Development" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "${TEMP_DIR}/identity.key" \
    -out "${TEMP_DIR}/identity.crt" \
    >/dev/null 2>&1

openssl pkcs12 \
    -export \
    -legacy \
    -name "${IDENTITY_NAME}" \
    -inkey "${TEMP_DIR}/identity.key" \
    -in "${TEMP_DIR}/identity.crt" \
    -out "${TEMP_DIR}/identity.p12" \
    -passout "pass:${P12_PASSWORD}"

security import "${TEMP_DIR}/identity.p12" \
    -P "${P12_PASSWORD}" \
    -x \
    -T /usr/bin/codesign \
    >/dev/null

# Trust is limited to code signing in the current user's trust domain. This is
# a local Keychain operation; no certificate request is sent to Apple.
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    "${TEMP_DIR}/identity.crt"

if [[ "$(identity_count)" -ne 1 ]]; then
    echo "The identity was imported but is not available for code signing." >&2
    echo "Open Keychain Access and verify the certificate and private key." >&2
    exit 1
fi

echo "Created local signing identity: ${IDENTITY_NAME}"
echo "The private key is non-exportable and remains in ${USER_KEYCHAIN}."
