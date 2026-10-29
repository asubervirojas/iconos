#!/bin/zsh
# Compila una copia con base temporal: nunca usa los datos reales de Iconos.
set -euo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d /private/tmp/iconos-seguridad.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fuentes" "$T/modulos"
cp "$B/../Sources/Iconos/"{Aplicador,Almacen,Mantenimiento,Capas,Extractor,Lienzo,Identidad}.swift "$T/fuentes/"
python3 - "$T/fuentes/Almacen.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
a = 'static let base: URL = FileManager.default.homeDirectoryForCurrentUser\n        .appendingPathComponent("Library/Application Support/Iconos", isDirectory: true)'
assert s.count(a) == 1
s = s.replace(a, 'static let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)')
a = 'let carpetas = ["/Applications", "/Applications/Utilities",\n                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] + config.carpetasExtra'
assert s.count(a) == 1
s = s.replace(a, 'let carpetas = config.carpetasExtra')
p.write_text(s)
PY
swiftc -module-cache-path "$T/modulos" "$T/fuentes/"*.swift "$B/pruebas/main.swift" -o "$T/pruebas"
"$T/pruebas" "$T/datos"

# Prueba tambien el circuito de muestras con arte sintetico, sin crear Banco/muestras.
swiftc -module-cache-path "$T/modulos" "$B/base/Lienzo.swift" "$B/apps/Arte.swift" "$B/generador/main.swift" -o "$T/muestrear"
"$T/muestrear" "$T/muestras" "$T/Muestras"
swiftc -module-cache-path "$T/modulos" "$B/../Sources/Iconos/Extractor.swift" "$B/../Sources/Iconos/Capas.swift" \
    "$B/base/Confianza.swift" "$B/base/Lienzo.swift" "$B/base/main.swift" -o "$T/banco"
"$T/banco" "$T/muestras" "$T/salida"
claros=("$T/salida/"*/claro.png(N))
oscuros=("$T/salida/"*/oscuro.png(N))
(( $#claros == 1 && $#oscuros == 1 ))
print 'OK: generador y extractor con muestra sintética'
