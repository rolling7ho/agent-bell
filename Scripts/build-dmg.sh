#!/bin/zsh
set -euo pipefail
umask 077

project_directory="${0:A:h:h}"
configuration="${1:-release}"
distribution_mode="${AGENTBELL_DISTRIBUTION_MODE:-local}"
build_directory="${project_directory}/.build"
app_bundle="${build_directory}/AgentBell.app"
info_plist="${app_bundle}/Contents/Info.plist"
output_directory="${project_directory}/outputs"
release_private_key="${AGENTBELL_RELEASE_PRIVATE_KEY:-}"

if [[ "${distribution_mode}" == "local" ]]; then
  echo "DMG creation is a distribution action. Choose one mode:" >&2
  echo "  AGENTBELL_DISTRIBUTION_MODE=developer-id (Apple-trusted)" >&2
  echo "  AGENTBELL_DISTRIBUTION_MODE=adhoc (explicit free/untrusted fallback)" >&2
  exit 64
fi
if [[ "${distribution_mode}" != "developer-id"
      && "${distribution_mode}" != "adhoc" ]]; then
  echo "AGENTBELL_DISTRIBUTION_MODE must be developer-id or adhoc." >&2
  exit 64
fi
if [[ "${configuration}" != "release" ]]; then
  echo "Distribution DMGs must use the release configuration." >&2
  exit 64
fi
if [[ "${distribution_mode}" == "adhoc"
      && -z "${release_private_key}" ]]; then
  echo "Free/ad-hoc distribution requires AGENTBELL_RELEASE_PRIVATE_KEY." >&2
  echo "Create a free detached-signing key with Scripts/create-free-release-key.sh." >&2
  exit 1
fi

if [[ -n "${release_private_key}" ]]; then
  release_private_key="${release_private_key:A}"
  if [[ ! -f "${release_private_key}" || -L "${release_private_key}" ]]; then
    echo "Release private key must be a regular, non-symlink file." >&2
    exit 1
  fi
  if [[ "${release_private_key}" == "${project_directory}"/* ]]; then
    echo "Release private key must not be stored inside the source tree." >&2
    exit 1
  fi
  private_key_mode=$(/usr/bin/stat -f '%Lp' "${release_private_key}")
  if [[ "${private_key_mode}" != "600"
        && "${private_key_mode}" != "400" ]]; then
    echo "Release private key permissions must be 600 or 400." >&2
    exit 1
  fi
  /usr/bin/openssl pkey \
    -in "${release_private_key}" \
    -noout
fi

/bin/zsh "${project_directory}/Scripts/build-app.sh" "${configuration}"

version=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "${info_plist}")
build=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "${info_plist}")
if [[ "${distribution_mode}" == "adhoc" ]]; then
  artifact_suffix="-UNTRUSTED-adhoc"
  signing_identity="-"
else
  artifact_suffix=""
  signing_identity="${AGENTBELL_SIGNING_IDENTITY}"
fi
output_dmg="${output_directory}/AgentBell-${version}-build${build}-arm64${artifact_suffix}.dmg"
checksum_path="${output_dmg}.sha256"
signature_path="${checksum_path}.sig"
public_key_path="${output_directory}/AgentBell-release-public.pem"
public_fingerprint_path="${output_directory}/AgentBell-release-public-key.sha256"
staging_directory=$(/usr/bin/mktemp -d \
  "${build_directory}/AgentBell-dmg.XXXXXX")

cleanup() {
  /bin/rm -rf "${staging_directory}"
}
trap cleanup EXIT

/bin/mkdir -p "${output_directory}" "${staging_directory}/root"
/usr/bin/ditto \
  "${app_bundle}" \
  "${staging_directory}/root/AgentBell.app"
/bin/ln -s /Applications "${staging_directory}/root/Applications"
if [[ "${distribution_mode}" == "adhoc" ]]; then
  /bin/cp \
    "${project_directory}/Resources/ADHOC_DISTRIBUTION_NOTICE.txt" \
    "${staging_directory}/root/UNTRUSTED BUILD - READ ME.txt"
fi

/bin/rm -f \
  "${output_dmg}" \
  "${checksum_path}" \
  "${signature_path}"
/usr/bin/hdiutil create \
  -volname "AgentBell ${version}" \
  -srcfolder "${staging_directory}/root" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "${output_dmg}"

if [[ "${distribution_mode}" == "developer-id" ]]; then
  /usr/bin/codesign \
    --force \
    --sign "${signing_identity}" \
    --timestamp \
    "${output_dmg}"
  /usr/bin/xcrun notarytool submit "${output_dmg}" \
    --keychain-profile "${AGENTBELL_NOTARY_PROFILE}" \
    --wait
  /usr/bin/xcrun stapler staple "${output_dmg}"
  /usr/bin/xcrun stapler validate "${output_dmg}"
else
  /usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    "${output_dmg}"
fi

/bin/zsh \
  "${project_directory}/Scripts/verify-release.sh" \
  "${output_dmg}" \
  "${distribution_mode}"

artifact_hash=$(/usr/bin/shasum -a 256 "${output_dmg}" | /usr/bin/awk '{print $1}')
print -r -- "${artifact_hash}  ${output_dmg:t}" > "${checksum_path}"
/bin/chmod 644 "${output_dmg}" "${checksum_path}"

if [[ -n "${release_private_key}" ]]; then
  temporary_public_key="${staging_directory}/release-public.pem"
  temporary_public_der="${staging_directory}/release-public.der"
  /usr/bin/openssl pkey \
    -in "${release_private_key}" \
    -pubout \
    -out "${temporary_public_key}"
  if [[ -f "${public_key_path}" ]]; then
    if ! /usr/bin/cmp -s "${temporary_public_key}" "${public_key_path}"; then
      echo "Release public key changed unexpectedly. Use a new output directory or intentionally rotate the pinned key." >&2
      exit 1
    fi
  else
    /bin/cp "${temporary_public_key}" "${public_key_path}"
    /bin/chmod 644 "${public_key_path}"
  fi
  /usr/bin/openssl dgst \
    -sha256 \
    -sign "${release_private_key}" \
    -out "${signature_path}" \
    "${checksum_path}"
  /bin/chmod 644 "${signature_path}"
  /usr/bin/openssl pkey \
    -pubin \
    -in "${public_key_path}" \
    -outform DER \
    -out "${temporary_public_der}"
  public_fingerprint=$(
    /usr/bin/shasum -a 256 "${temporary_public_der}" \
      | /usr/bin/awk '{print $1}'
  )
  print -r -- "${public_fingerprint}  AgentBell-release-public.pem" \
    > "${public_fingerprint_path}"
  /bin/chmod 644 "${public_fingerprint_path}"
  /bin/zsh \
    "${project_directory}/Scripts/verify-download.sh" \
    "${output_dmg}" \
    "${checksum_path}" \
    "${signature_path}" \
    "${public_key_path}"
fi

if [[ "${distribution_mode}" == "adhoc" ]]; then
  echo "WARNING: this free build is not Apple-trusted or notarized." >&2
  echo "Users must verify the detached signature and pinned public-key fingerprint." >&2
fi
echo "${output_dmg}"
echo "${checksum_path}"
if [[ -f "${signature_path}" ]]; then
  echo "${signature_path}"
  echo "${public_key_path}"
  echo "${public_fingerprint_path}"
fi
