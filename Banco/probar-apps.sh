#!/bin/zsh
# Compila un diagnostico independiente y lee los bundles instalados, sin aplicarlos.
set -euo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
S="$B/salida/apps"
mkdir -p "$S" "$B/salida/modulos"
swiftc -O -module-cache-path "$B/salida/modulos" \
    "$B/../Sources/Iconos/Extractor.swift" "$B/../Sources/Iconos/Capas.swift" \
    "$B/base/Confianza.swift" "$B/base/Lienzo.swift" "$B/apps/Arte.swift" "$B/apps/main.swift" -o "$S/diagnostico"
"$S/diagnostico" "$S" "$@" | tee "$S/log.tsv"
