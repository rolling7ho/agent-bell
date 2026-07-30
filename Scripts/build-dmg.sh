#!/bin/zsh
set -euo pipefail

project_directory="${0:A:h:h}"
configuration="${1:-release}"
build_directory="${project_directory}/.build"
app_bundle="${build_directory}/AgentBell.app"
info_plist="${app_bundle}/Contents/Info.plist"
output_directory="${project_directory}/outputs"
signing_identity="${AGENTBELL_SIGNING_IDENTITY:--}"

/bin/zsh "${project_directory}/Scripts/build-app.sh" "${configuration}"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "${info_plist}")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${info_plist}")
output_dmg="${output_directory}/AgentBell-${version}-build${build}-arm64.dmg"
staging_directory=$(/usr/bin/mktemp -d \
  "${build_directory}/AgentBell-dmg.XXXXXX")

cleanup() {
  /bin/rm -rf "${staging_directory}"
}
trap cleanup EXIT

mkdir -p "${output_directory}" "${staging_directory}/root"
/usr/bin/ditto "${app_bundle}" \
  "${staging_directory}/root/AgentBell.app"
/bin/ln -s /Applications "${staging_directory}/root/Applications"

/bin/rm -f "${output_dmg}"
/usr/bin/hdiutil create \
  -volname "AgentBell ${version}" \
  -srcfolder "${staging_directory}/root" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "${output_dmg}"

if [[ "${signing_identity}" != "-" ]]; then
  /usr/bin/codesign --force --sign "${signing_identity}" \
    --timestamp "${output_dmg}"
fi

if [[ -n "${AGENTBELL_NOTARY_PROFILE:-}" ]]; then
  if [[ "${signing_identity}" == "-" ]]; then
    echo "AGENTBELL_NOTARY_PROFILE requires a Developer ID signing identity." >&2
    exit 1
  fi
  /usr/bin/xcrun notarytool submit "${output_dmg}" \
    --keychain-profile "${AGENTBELL_NOTARY_PROFILE}" \
    --wait
  /usr/bin/xcrun stapler staple "${output_dmg}"
  /usr/bin/xcrun stapler validate "${output_dmg}"
fi

/usr/bin/hdiutil verify "${output_dmg}"
echo "${output_dmg}"
