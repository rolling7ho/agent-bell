#!/bin/zsh
set -euo pipefail
umask 077

project_directory="${0:A:h:h}"
configuration="${1:-release}"
distribution_mode="${TURNRING_DISTRIBUTION_MODE:-local}"
build_directory="${project_directory}/.build"
app_bundle="${build_directory}/Turnring.app"
vsix_path="${build_directory}/turnring-focus.vsix"
vsix_staging_directory="${build_directory}/VSIXStaging"
notary_archive="${build_directory}/Turnring-notary.zip"
icon_source_png="${project_directory}/Resources/AppIcon.png"
iconset_directory="${build_directory}/AppIcon.iconset"

if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
  echo "Configuration must be debug or release." >&2
  exit 64
fi
case "${distribution_mode}" in
  local)
    signing_identity="-"
    if [[ -n "${TURNRING_SIGNING_IDENTITY:-}"
          || -n "${TURNRING_NOTARY_PROFILE:-}" ]]; then
      echo "Local mode does not accept distribution credentials." >&2
      exit 64
    fi
    ;;
  adhoc)
    signing_identity="-"
    if [[ "${configuration}" != "release" ]]; then
      echo "Ad-hoc distribution must use the release configuration." >&2
      exit 64
    fi
    if [[ -n "${TURNRING_SIGNING_IDENTITY:-}"
          || -n "${TURNRING_NOTARY_PROFILE:-}" ]]; then
      echo "Ad-hoc mode must not be given Apple distribution credentials." >&2
      exit 64
    fi
    ;;
  developer-id)
    if [[ "${configuration}" != "release" ]]; then
      echo "Developer ID distribution must use the release configuration." >&2
      exit 64
    fi
    signing_identity="${TURNRING_SIGNING_IDENTITY:-}"
    if [[ "${signing_identity}" != "Developer ID Application:"* ]]; then
      echo "TURNRING_SIGNING_IDENTITY must name a Developer ID Application identity." >&2
      exit 1
    fi
    if [[ -z "${TURNRING_NOTARY_PROFILE:-}" ]]; then
      echo "TURNRING_NOTARY_PROFILE is required for Developer ID distribution." >&2
      exit 1
    fi
    identities=$(/usr/bin/security find-identity -v -p codesigning)
    if [[ "${identities}" != *"\"${signing_identity}\""* ]]; then
      echo "The requested Developer ID identity is not available in Keychain." >&2
      exit 1
    fi
    ;;
  *)
    echo "TURNRING_DISTRIBUTION_MODE must be local, adhoc, or developer-id." >&2
    exit 64
    ;;
esac

cd "${project_directory}"
export CLANG_MODULE_CACHE_PATH="${build_directory}/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${build_directory}/module-cache"
/bin/mkdir -p "${CLANG_MODULE_CACHE_PATH}"

if [[ -f "${project_directory}/Package.resolved" ]]; then
  echo "Unexpected third-party Swift dependencies are not allowed in this build." >&2
  exit 1
fi
unsafe_link=$(
  /usr/bin/find \
    "${project_directory}/Sources" \
    "${project_directory}/Resources" \
    "${project_directory}/VSCodeExtension" \
    -type l -print -quit
)
if [[ -n "${unsafe_link}" ]]; then
  echo "Build inputs must not contain symlinks: ${unsafe_link}" >&2
  exit 1
fi
unsafe_writable_input=$(
  /usr/bin/find \
    "${project_directory}/Sources" \
    "${project_directory}/Resources" \
    "${project_directory}/VSCodeExtension" \
    -perm +022 -print -quit
)
if [[ -n "${unsafe_writable_input}" ]]; then
  echo "Build inputs must not be group- or world-writable: ${unsafe_writable_input}" >&2
  exit 1
fi

swift_compiler=$(/usr/bin/xcrun --find swift)
if [[ "${swift_compiler}" != /Applications/Xcode.app/* \
      && "${swift_compiler}" != /Library/Developer/CommandLineTools/* ]]; then
  echo "Swift compiler must come from the selected Apple developer tools." >&2
  exit 1
fi
swift_owner=$(/usr/bin/stat -f '%Su' "${swift_compiler}")
swift_mode=$(/usr/bin/stat -f '%Lp' "${swift_compiler}")
swift_group_digit="${swift_mode[-2]}"
swift_other_digit="${swift_mode[-1]}"
if [[ "${swift_owner}" != "root"
      || "${swift_group_digit}" == [2367]
      || "${swift_other_digit}" == [2367] ]]; then
  echo "Swift compiler must be root-owned and not group- or world-writable." >&2
  exit 1
fi
/usr/bin/xcrun swift build -c "${configuration}" --arch arm64
swift_bin_path=$(
  /usr/bin/xcrun swift build \
    -c "${configuration}" \
    --arch arm64 \
    --show-bin-path
)
swift_bin_path="${swift_bin_path:A}"
if [[ "${swift_bin_path}" != "${build_directory}"/* ]]; then
  echo "SwiftPM reported an unexpected binary directory: ${swift_bin_path}" >&2
  exit 1
fi
for product in Turnring TurnringHook; do
  if [[ ! -f "${swift_bin_path}/${product}" \
        || -L "${swift_bin_path}/${product}" ]]; then
    echo "SwiftPM product is missing or unsafe: ${swift_bin_path}/${product}" >&2
    exit 1
  fi
done

node_path=""
for candidate in /usr/local/bin/node /opt/homebrew/bin/node; do
  if [[ -x "${candidate}" ]]; then
    node_path="${candidate:A}"
    break
  fi
done
if [[ -z "${node_path}" ]]; then
  echo "A trusted local Node.js installation is required to package the VS Code companion." >&2
  exit 1
fi
node_owner=$(/usr/bin/stat -f '%Su' "${node_path}")
node_mode=$(/usr/bin/stat -f '%Lp' "${node_path}")
node_group_digit="${node_mode[-2]}"
node_other_digit="${node_mode[-1]}"
if [[ "${node_owner}" != "root"
      || "${node_group_digit}" == [2367]
      || "${node_other_digit}" == [2367] ]]; then
  echo "Node.js must be root-owned and not group- or world-writable." >&2
  exit 1
fi

/bin/rm -rf "${app_bundle}" "${vsix_staging_directory}"
/bin/mkdir -p \
  "${app_bundle}/Contents/MacOS" \
  "${app_bundle}/Contents/Helpers" \
  "${app_bundle}/Contents/Resources/Brand" \
  "${app_bundle}/Contents/Resources/VSCode" \
  "${app_bundle}/Contents/Resources/ProviderIcons"

/bin/cp \
  "${project_directory}/Resources/Info.plist" \
  "${app_bundle}/Contents/Info.plist"
/bin/cp \
  "${swift_bin_path}/Turnring" \
  "${app_bundle}/Contents/MacOS/Turnring"
/bin/cp \
  "${swift_bin_path}/TurnringHook" \
  "${app_bundle}/Contents/Helpers/TurnringHook"

/bin/rm -rf "${iconset_directory}"
/bin/mkdir -p "${iconset_directory}"
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
/bin/cp \
  "${icon_source_png}" \
  "${app_bundle}/Contents/Resources/AppIcon.png"
/bin/cp \
  "${project_directory}/Resources/Brand/"*.svg \
  "${app_bundle}/Contents/Resources/Brand/"
/bin/cp \
  "${project_directory}/Resources/ProviderIcons/"*.svg \
  "${app_bundle}/Contents/Resources/ProviderIcons/"

"${node_path}" \
  "${project_directory}/Scripts/package-vsix.mjs" \
  "${project_directory}/VSCodeExtension/VSIXRoot" \
  "${vsix_staging_directory}" >/dev/null
/bin/rm -f "${vsix_path}"
(
  cd "${vsix_staging_directory}"
  /usr/bin/zip -q -X -r "${vsix_path}" .
)
/bin/cp \
  "${vsix_path}" \
  "${app_bundle}/Contents/Resources/VSCode/turnring-focus.vsix"

if [[ "${configuration}" == "release" ]]; then
  /usr/bin/strip -S -x "${app_bundle}/Contents/MacOS/Turnring"
  /usr/bin/strip -S -x "${app_bundle}/Contents/Helpers/TurnringHook"
fi

/usr/bin/find "${app_bundle}" -type d -exec /bin/chmod 755 {} +
/usr/bin/find "${app_bundle}" -type f -exec /bin/chmod 644 {} +
/bin/chmod 755 \
  "${app_bundle}/Contents/MacOS/Turnring" \
  "${app_bundle}/Contents/Helpers/TurnringHook"

codesign_arguments=(
  --force
  --sign "${signing_identity}"
  --options runtime
)
if [[ "${signing_identity}" == "-" ]]; then
  codesign_arguments+=(--timestamp=none)
else
  codesign_arguments+=(--timestamp)
fi

/usr/bin/codesign "${codesign_arguments[@]}" \
  --identifier com.turnring.hook \
  "${app_bundle}/Contents/Helpers/TurnringHook"
/usr/bin/codesign "${codesign_arguments[@]}" \
  --identifier com.turnring.app \
  "${app_bundle}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_bundle}"

app_signature=$(/usr/bin/codesign -dvvv "${app_bundle}" 2>&1)
if [[ "${app_signature}" != *"flags="*"runtime"* ]]; then
  echo "Hardened runtime was not applied to Turnring." >&2
  exit 1
fi

if [[ "${distribution_mode}" == "developer-id" ]]; then
  /bin/rm -f "${notary_archive}"
  /usr/bin/ditto -c -k --keepParent "${app_bundle}" "${notary_archive}"
  /usr/bin/xcrun notarytool submit "${notary_archive}" \
    --keychain-profile "${TURNRING_NOTARY_PROFILE}" \
    --wait
  /usr/bin/xcrun stapler staple "${app_bundle}"
  /usr/bin/xcrun stapler validate "${app_bundle}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${app_bundle}"
fi

echo "Built ${distribution_mode} app: ${app_bundle}"
