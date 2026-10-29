#!/bin/zsh
# Genera muestras del arte original; no escribe en los bundles instalados.
set -euo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
S="$B/salida/generador"
mkdir -p "$S" "$B/salida/modulos"
swiftc -O -module-cache-path "$B/salida/modulos" \
    "$B/base/Lienzo.swift" "$B/apps/Arte.swift" "$B/generador/main.swift" -o "$S/muestras"
if (( $# == 0 )); then set -- /Applications "$HOME/Applications"; fi
"$S/muestras" "$B/muestras" "$@"
