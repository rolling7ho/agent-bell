#!/bin/zsh
set -euo pipefail

project_directory="${0:A:h:h}"
configuration="${1:-release}"
build_directory="${project_directory}/.build"
app_bundle="${build_directory}/AgentBell.app"
vsix_path="${build_directory}/agentbell-focus.vsix"
notary_archive="${build_directory}/AgentBell-notary.zip"
icon_source_png="${project_directory}/Resources/AppIcon.png"
iconset_directory="${build_directory}/AppIcon.iconset"
signing_identity="${AGENTBELL_SIGNING_IDENTITY:--}"

cd "${project_directory}"
export CLANG_MODULE_CACHE_PATH="${build_directory}/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${build_directory}/module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}"
swift build -c "${configuration}" --arch arm64

rm -rf "${app_bundle}"
mkdir -p \
  "${app_bundle}/Contents/MacOS" \
  "${app_bundle}/Contents/Helpers" \
  "${app_bundle}/Contents/Resources/VSCode" \
  "${app_bundle}/Contents/Resources/ProviderIcons"

cp "${project_directory}/Resources/Info.plist" "${app_bundle}/Contents/Info.plist"
cp "${build_directory}/arm64-apple-macosx/${configuration}/AgentBell" \
  "${app_bundle}/Contents/MacOS/AgentBell"
cp "${build_directory}/arm64-apple-macosx/${configuration}/AgentBellHook" \
  "${app_bundle}/Contents/Helpers/AgentBellHook"

rm -rf "${iconset_directory}"
mkdir -p "${iconset_directory}"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "${size}" "${size}" "${icon_source_png}" \
    --out "${iconset_directory}/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256 512; do
  doubled_size=$((size * 2))
  /usr/bin/sips -z "${doubled_size}" "${doubled_size}" "${icon_source_png}" \
    --out "${iconset_directory}/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "${iconset_directory}" \
  -o "${app_bundle}/Contents/Resources/AppIcon.icns"
cp "${icon_source_png}" \
  "${app_bundle}/Contents/Resources/AppIcon.png"
cp "${project_directory}/Resources/ProviderIcons/"*.svg \
  "${app_bundle}/Contents/Resources/ProviderIcons/"

rm -f "${vsix_path}"
(
  cd "${project_directory}/VSCodeExtension/VSIXRoot"
  /usr/bin/zip -q -r "${vsix_path}" .
)
cp "${vsix_path}" "${app_bundle}/Contents/Resources/VSCode/agentbell-focus.vsix"

codesign_arguments=(--force --sign "${signing_identity}")
if [[ "${signing_identity}" == "-" ]]; then
  codesign_arguments+=(--timestamp=none)
else
  codesign_arguments+=(--options runtime --timestamp)
fi

/usr/bin/codesign "${codesign_arguments[@]}" \
  --identifier com.agentbell.hook \
  "${app_bundle}/Contents/Helpers/AgentBellHook"
/usr/bin/codesign "${codesign_arguments[@]}" \
  --identifier com.agentbell.app \
  "${app_bundle}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_bundle}"

if [[ -n "${AGENTBELL_NOTARY_PROFILE:-}" ]]; then
  if [[ "${signing_identity}" == "-" ]]; then
    echo "AGENTBELL_NOTARY_PROFILE requires a Developer ID signing identity." >&2
    exit 1
  fi
  rm -f "${notary_archive}"
  /usr/bin/ditto -c -k --keepParent "${app_bundle}" "${notary_archive}"
  /usr/bin/xcrun notarytool submit "${notary_archive}" \
    --keychain-profile "${AGENTBELL_NOTARY_PROFILE}" \
    --wait
  /usr/bin/xcrun stapler staple "${app_bundle}"
  /usr/bin/xcrun stapler validate "${app_bundle}"
fi

echo "${app_bundle}"
