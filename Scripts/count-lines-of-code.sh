#!/bin/zsh
set -euo pipefail

project_directory="${0:A:h:h}"
source_files=("${project_directory}/Package.swift")

while IFS= read -r -d '' source_file; do
  source_files+=("${source_file}")
done < <(
  /usr/bin/find \
    "${project_directory}/Sources" \
    "${project_directory}/Tests" \
    "${project_directory}/Scripts" \
    "${project_directory}/VSCodeExtension/VSIXRoot/extension" \
    -type f \
    \( -name '*.swift' -o -name '*.sh' -o -name '*.mjs' -o -name '*.js' \
       -o -name '*.ts' -o -name '*.tsx' -o -name '*.css' \) \
    -print0
)

total=0
for source_file in "${source_files[@]}"; do
  line_count=$(/usr/bin/wc -l < "${source_file}" | /usr/bin/tr -d ' ')
  (( total += line_count ))
done

print -r -- "${total}"
