#!/bin/zsh
set -euo pipefail
umask 077

if [[ "$#" -ne 2 ]]; then
  echo "Usage: create-free-release-key.sh <private-key.pem> <public-key.pem>" >&2
  exit 64
fi

project_directory="${0:A:h:h}"
private_key_path="${1:A}"
public_key_path="${2:A}"
private_parent="${private_key_path:h}"
public_parent="${public_key_path:h}"

if [[ ! -d "${private_parent}" || ! -d "${public_parent}" ]]; then
  echo "Create the destination directories first." >&2
  exit 1
fi
if [[ "${private_key_path}" == "${project_directory}"/* ]]; then
  echo "Refusing to store a release private key inside the source tree." >&2
  exit 1
fi
if [[ -e "${private_key_path}" || -e "${public_key_path}" ]]; then
  echo "Refusing to overwrite an existing release key." >&2
  exit 1
fi

/usr/bin/openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -out "${private_key_path}"
/bin/chmod 600 "${private_key_path}"
/usr/bin/openssl pkey \
  -in "${private_key_path}" \
  -pubout \
  -out "${public_key_path}"
/bin/chmod 644 "${public_key_path}"

public_der=$(/usr/bin/mktemp "/tmp/agentbell-public-key.XXXXXX")
trap '/bin/rm -f "${public_der}"' EXIT
/usr/bin/openssl pkey \
  -pubin \
  -in "${public_key_path}" \
  -outform DER \
  -out "${public_der}"
fingerprint=$(/usr/bin/shasum -a 256 "${public_der}" | /usr/bin/awk '{print $1}')

echo "Private key: ${private_key_path}"
echo "Public key:  ${public_key_path}"
echo "Public-key SHA-256 fingerprint: ${fingerprint}"
echo "Back up the private key securely and publish the public-key fingerprint through an independent trusted channel."
