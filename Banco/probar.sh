#!/bin/zsh
# probar.sh <carpeta con Extractor.swift> [apps...]: compila y genera salida/ con hoja por app
set -euo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
D="$(cd "${1:-$B/../Sources/Iconos}" && pwd)"
if (( $# > 0 )); then shift; fi
if [[ ! -d "$B/muestras" ]]; then
    print -u2 'Faltan las muestras locales. Ejecuta primero Banco/muestras.sh.'
    exit 1
fi
S="${BANCO_SALIDA:-$B/salida/actual}"
mkdir -p "$S" "$B/salida/modulos"
swiftc -O -module-cache-path "$B/salida/modulos" "$B/ficha.swift" -o "$S/ficha"
swiftc -O -module-cache-path "$B/salida/modulos" "$D/Extractor.swift" "$D/Capas.swift" \
    "$B/base/Confianza.swift" "$B/base/Lienzo.swift" "$B/base/main.swift" -o "$S/banco"
"$S/banco" "$B/muestras" "$S" "$@" | tee "$S/log.tsv"
for d in "$S"/*/(N); do s=$(basename "$d"); "$S/ficha" "$d" "$S/$s.png" "$s"; done
