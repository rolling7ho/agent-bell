#!/bin/zsh
set -euo pipefail
umask 077

if [[ "$#" -ne 2 ]]; then
  echo "Usage: verify-release.sh <dmg-path> <developer-id|adhoc>" >&2
  exit 64
fi

dmg_path="${1:A}"
distribution_mode="$2"
if [[ ! -f "${dmg_path}" || -L "${dmg_path}" ]]; then
  echo "Release DMG must be a regular, non-symlink file." >&2
  exit 1
fi
if [[ "${distribution_mode}" != "developer-id"
      && "${distribution_mode}" != "adhoc" ]]; then
  echo "Unknown distribution mode: ${distribution_mode}" >&2
  exit 64
fi

/usr/bin/hdiutil verify "${dmg_path}" >/dev/null
/usr/bin/codesign --verify --strict --verbose=2 "${dmg_path}"
dmg_signature=$(/usr/bin/codesign -dvvv "${dmg_path}" 2>&1)

mount_directory=$(/usr/bin/mktemp -d "/tmp/turnring-verify.XXXXXX")
mounted=false
cleanup() {
  if [[ "${mounted}" == "true" ]]; then
    /usr/bin/hdiutil detach "${mount_directory}" >/dev/null 2>&1 || true
  fi
  /bin/rmdir "${mount_directory}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "${mount_directory}" \
  "${dmg_path}" >/dev/null
mounted=true

app_bundle="${mount_directory}/Turnring.app"
main_executable="${app_bundle}/Contents/MacOS/Turnring"
hook_executable="${app_bundle}/Contents/Helpers/TurnringHook"
vsix_path="${app_bundle}/Contents/Resources/VSCode/turnring-focus.vsix"

for required_path in \
  "${app_bundle}" \
  "${main_executable}" \
  "${hook_executable}" \
  "${vsix_path}"
do
  if [[ ! -e "${required_path}" ]]; then
    echo "Release is missing ${required_path:t}." >&2
    exit 1
  fi
done

unexpected_source=$(
  /usr/bin/find "${app_bundle}" -type f \
    \( -name '*.swift' -o -name '*.dSYM' -o -name '*.map' \) \
    -print -quit
)
if [[ -n "${unexpected_source}" ]]; then
  echo "Release contains source or debug metadata: ${unexpected_source}" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_bundle}"
app_signature=$(/usr/bin/codesign -dvvv "${app_bundle}" 2>&1)
hook_signature=$(/usr/bin/codesign -dvvv "${hook_executable}" 2>&1)

if [[ "${app_signature}" != *"flags="*"runtime"* \
      || "${hook_signature}" != *"flags="*"runtime"* ]]; then
  echo "Hardened runtime is missing from an executable." >&2
  exit 1
fi

vsix_entries=$(/usr/bin/unzip -Z1 "${vsix_path}")
for expected_entry in \
  "[Content_Types].xml" \
  "extension/" \
  "extension/README.md" \
  "extension/main.js" \
  "extension/package.json" \
  "extension.vsixmanifest"
do
  if [[ $'\n'"${vsix_entries}"$'\n' != *$'\n'"${expected_entry}"$'\n'* ]]; then
    echo "VSIX is missing ${expected_entry}." >&2
    exit 1
  fi
done
entry_count=$(print -r -- "${vsix_entries}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if [[ "${entry_count}" != "6" ]]; then
  echo "VSIX contains unexpected files." >&2
  exit 1
fi
packaged_javascript=$(/usr/bin/unzip -p "${vsix_path}" extension/main.js)
if [[ "${packaged_javascript}" == *"isValidRequestID"* \
      || "${packaged_javascript}" == *"validatedResumeOptions"* ]]; then
  echo "VSIX JavaScript was not hardened for distribution." >&2
  exit 1
fi

if [[ "${distribution_mode}" == "developer-id" ]]; then
  if [[ "${app_signature}" != *"Authority=Developer ID Application:"* \
        || "${app_signature}" == *"TeamIdentifier=not set"* ]]; then
    echo "App is not signed by a Developer ID Application identity." >&2
    exit 1
  fi
  if [[ "${dmg_signature}" != *"Authority=Developer ID Application:"* \
        || "${dmg_signature}" == *"TeamIdentifier=not set"* ]]; then
    echo "DMG is not signed by a Developer ID Application identity." >&2
    exit 1
  fi
  /usr/bin/xcrun stapler validate "${app_bundle}"
  /usr/bin/xcrun stapler validate "${dmg_path}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${app_bundle}"
  /usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "${dmg_path}"
else
  if [[ "${app_signature}" != *"Signature=adhoc"* \
        || "${hook_signature}" != *"Signature=adhoc"* \
        || "${dmg_signature}" != *"Signature=adhoc"* ]]; then
    echo "Expected an explicitly ad-hoc-signed free-distribution build." >&2
    exit 1
  fi
  echo "WARNING: ad-hoc release has integrity seals but no Apple-trusted publisher identity." >&2
fi

echo "Verified ${distribution_mode} release: ${dmg_path}"
