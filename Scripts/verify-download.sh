#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "Usage: verify-download.sh <dmg> <sha256-file> <signature> <public-key>" >&2
  exit 64
fi

dmg_path="${1:A}"
checksum_path="${2:A}"
signature_path="${3:A}"
public_key_path="${4:A}"

for required_file in \
  "${dmg_path}" \
  "${checksum_path}" \
  "${signature_path}" \
  "${public_key_path}"
do
  if [[ ! -f "${required_file}" || -L "${required_file}" ]]; then
    echo "Verification input must be a regular, non-symlink file: ${required_file}" >&2
    exit 1
  fi
done

/usr/bin/openssl dgst \
  -sha256 \
  -verify "${public_key_path}" \
  -signature "${signature_path}" \
  "${checksum_path}"

checksum_line=$(/bin/cat "${checksum_path}")
expected_hash="${checksum_line%% *}"
expected_name="${checksum_line#*  }"
if [[ ! "${expected_hash}" =~ '^[0-9a-f]{64}$' ]]; then
  echo "Invalid SHA-256 manifest." >&2
  exit 1
fi
if [[ "${expected_name}" != "${dmg_path:t}" ]]; then
  echo "SHA-256 manifest names an unexpected file." >&2
  exit 1
fi
actual_hash=$(/usr/bin/shasum -a 256 "${dmg_path}" | /usr/bin/awk '{print $1}')
if [[ "${actual_hash}" != "${expected_hash}" ]]; then
  echo "DMG checksum mismatch." >&2
  exit 1
fi

echo "Detached signature and SHA-256 verified for ${dmg_path:t}."
