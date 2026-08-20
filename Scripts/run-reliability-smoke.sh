#!/bin/zsh
set -euo pipefail
umask 077

project_directory="${0:A:h:h}"
build_directory="${project_directory}/.build"
binary="${build_directory}/turnring-reliability-smoke"

cd "${project_directory}"
export CLANG_MODULE_CACHE_PATH="${build_directory}/module-cache"
/bin/mkdir -p "${CLANG_MODULE_CACHE_PATH}"

/usr/bin/xcrun swiftc \
  -swift-version 6 \
  Sources/TurnringCore/*.swift \
  Scripts/reliability-smoke.swift \
  -o "${binary}"
"${binary}"
