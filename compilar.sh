#!/bin/zsh
# Compila Iconos.app en build/ (solo Apple Silicon).
#   --instalar     la copia a ~/Applications y, si el agente estaba activo, lo vuelve a instalar
#                  apuntando a esa copia
#   --release      crea build/Iconos-<version>.zip y su .sha256 para publicar en GitHub Releases
#   --sin-firma    permite --instalar con firma ad hoc (--release siempre exige la identidad)
#   --crear-firma  crea la identidad de firma (certificado autofirmado) en el llavero y termina
# La identidad de firma se elige con ICONOS_FIRMA (por defecto "Iconos firma local").
# ICONOS_LLAVERO cambia el llavero donde --crear-firma la guarda (por defecto el de inicio de sesion) y,
# al compilar, el unico donde se busca la identidad (por defecto la lista de busqueda del usuario).
# Recursos/firma.sha1 guarda la huella SHA-1 del certificado con que se publico la primera version:
# --release no firma con otro.
set -euo pipefail
cd "${0:A:h}"

instalar=0
sin_firma=0
release=0
crear_firma=0
for arg in "$@"; do
  case $arg in
    --instalar) instalar=1 ;;
    --sin-firma) sin_firma=1 ;;
    --release) release=1 ;;
    --crear-firma) crear_firma=1 ;;
    *) echo "Opción desconocida: $arg (usa --instalar, --release, --sin-firma o --crear-firma)" >&2; exit 2 ;;
  esac
done

identidad=${ICONOS_FIRMA:-Iconos firma local}
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" }
archivo_huella=Recursos/firma.sha1
# Huellas SHA-1 de las identidades de firma de codigo llamadas exactamente $identidad, sin repetir
# (find-identity sin -v lista cada una dos veces: todas y validas). Con un llavero, solo en ese
huellas() {
  security find-identity -p codesigning "$@" 2>/dev/null \
    | awk -v nombre="\"$identidad\"" '$1 ~ /^[0-9]+\)$/ && $2 ~ /^[0-9A-F]{40}$/ && index($0, nombre) { print $2 }' \
    | sort -u
}

# Identificadores y version salen de los Info.plist, como en Identidad.swift: la etiqueta de launchd
# del agente es su CFBundleIdentifier (Identidad.agente)
bundle_id=$(plist Recursos/Info.plist CFBundleIdentifier)
etiqueta=$(plist Recursos/Agente-Info.plist CFBundleIdentifier)
version=$(plist Recursos/Info.plist CFBundleShortVersionString)
if [[ $etiqueta != $bundle_id.agente ]]; then
  echo "Error: el identificador del agente ($etiqueta) debe ser el de la app más .agente ($bundle_id.agente)." >&2
  exit 1
fi
if [[ $(plist Recursos/Agente-Info.plist CFBundleShortVersionString) != $version ]]; then
  echo "Error: Recursos/Info.plist y Recursos/Agente-Info.plist deben tener la misma CFBundleShortVersionString." >&2
  exit 1
fi
# Marcador provisional: publicada con el, cambiar despues el identificador le quita Gestion de apps a
# todos y deja un LaunchAgent viejo junto al nuevo. El repositorio es el enlace de Acerca de
if (( release )); then
  repositorio=$(sed -nE 's/^[[:space:]]*static let repositorio = "(.*)"[[:space:]]*$/\1/p' Sources/Iconos/Estudio.swift)
  if [[ -z $repositorio || $bundle_id == *USUARIO* || $repositorio == *USUARIO* ]]; then
    echo "Error: cambia io.github.USUARIO (Recursos/Info.plist, Recursos/Agente-Info.plist e Identidad.swift) y Estudio.repositorio por los definitivos antes de publicar." >&2
    echo "Identificador: $bundle_id. Repositorio: ${repositorio:-no encontrado en Sources/Iconos/Estudio.swift}." >&2
    exit 1
  fi
fi

# --crear-firma: certificado autofirmado de firma de codigo, con su clave, importado al llavero. Lo
# crea /usr/bin/openssl (LibreSSL): su pkcs12 usa el cifrado que entiende security import
if (( crear_firma )); then
  if [[ ! $identidad =~ '^[A-Za-z0-9 ._-]+$' ]]; then
    echo "Error: ICONOS_FIRMA solo puede llevar letras sin acentos, números, espacios, punto, guion y guion bajo." >&2
    exit 2
  fi
  llavero=${ICONOS_LLAVERO:-$(security login-keychain | sed -E 's/^[[:space:]]*"(.*)"$/\1/')}
  if [[ -n $(huellas "$llavero") ]]; then
    echo "Ya existe la identidad \"$identidad\" en $llavero: no se crea otra."
    exit 0
  fi
  # macOS pide permiso para usar la clave la primera vez que se firma, y por SSH o con el llavero
  # bloqueado no puede preguntar: el import o la firma fallan (errSecInternalComponent)
  if [[ -n ${SSH_CONNECTION:-} || $(launchctl managername 2>/dev/null) != Aqua ]]; then
    echo "Error: ejecuta ./compilar.sh --crear-firma desde Terminal en la sesión gráfica del Mac (no por SSH): macOS tiene que poder preguntar por el llavero." >&2
    exit 1
  fi
  if ! security show-keychain-info "$llavero" >/dev/null 2>&1; then
    echo "Error: el llavero $llavero está bloqueado o no se puede abrir. Desbloquéalo (security unlock-keychain \"$llavero\") y vuelve a intentarlo." >&2
    exit 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/iconos-firma.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  cat > $tmp/firma.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identidad
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  clave=$(/usr/bin/openssl rand -hex 24)
  if ! /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 -config $tmp/firma.cnf \
      -keyout $tmp/clave.pem -out $tmp/cert.pem 2>$tmp/openssl.log \
    || ! /usr/bin/openssl pkcs12 -export -inkey $tmp/clave.pem -in $tmp/cert.pem -name "$identidad" \
      -out $tmp/firma.p12 -passout "pass:$clave" 2>>$tmp/openssl.log; then
    cat $tmp/openssl.log >&2
    echo "Error: openssl no pudo crear el certificado." >&2
    exit 1
  fi
  # Huella del certificado recien creado: para borrar justo ese si algo falla despues de importarlo
  nueva=$(/usr/bin/openssl x509 -in $tmp/cert.pem -noout -fingerprint -sha1 | sed -E 's/^.*=//; s/://g' | tr a-f A-F)
  # -T: codesign puede usar la clave sin preguntar por cada firma
  if ! security import $tmp/firma.p12 -k "$llavero" -f pkcs12 -P "$clave" -T /usr/bin/codesign >/dev/null 2>$tmp/import.log; then
    cat $tmp/import.log >&2
    echo "Error: no se pudo importar el certificado en $llavero (¿llavero bloqueado?)." >&2
    exit 1
  fi
  if [[ $(huellas "$llavero") != $nueva ]]; then
    # Se borra para que otro --crear-firma no deje dos con el mismo nombre (codesign: ambiguous)
    security delete-identity -Z "$nueva" "$llavero" >/dev/null 2>&1 || true
    echo "Error: se importó el certificado pero no aparece como identidad de firma en $llavero. Se borró lo importado." >&2
    exit 1
  fi
  # Firma de prueba: macOS pregunta ahora si codesign puede usar la clave, y no en medio de una compilacion
  cp /usr/bin/true $tmp/prueba
  if ! codesign --force --sign "$nueva" --keychain "$llavero" --timestamp=none $tmp/prueba 2>$tmp/firma.log; then
    cat $tmp/firma.log >&2
    echo "Aviso: la identidad se creó, pero la firma de prueba falló. Si macOS preguntó por la clave, vuelve a firmar y elige Permitir siempre." >&2
  fi
  # La compilacion busca la identidad en la lista de busqueda del usuario (o solo en ICONOS_LLAVERO)
  if ! security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/' | grep -qxF "$llavero"; then
    echo "Aviso: $llavero no está en la lista de búsqueda de llaveros. Compila con ICONOS_LLAVERO=\"$llavero\" o añádelo con:" >&2
    echo "  security list-keychains -d user -s $(security list-keychains -d user | tr -d '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //') \"$llavero\"" >&2
  fi
  cat <<EOF
Creada la identidad de firma "$identidad" en $llavero.

Qué es: un certificado autofirmado de firma de código (válido 10 años) con su clave privada, que solo
existe en este Mac. Con él cada compilación de Iconos lleva la misma firma y macOS no le quita a
Iconos el permiso Gestión de apps al recompilar. No lo emite Apple: Gatekeeper sigue pidiendo
Abrir igualmente en otros Macs.

La primera vez que firmes, macOS puede preguntar si codesign puede usar la clave: elige Permitir siempre.

Respaldo: exporta la identidad a un .p12 (Acceso a Llaveros > Mis certificados > Exportar) y guárdalo
fuera del Mac. Si se pierde y creas otra, las apps firmadas con la nueva vuelven a pedir Gestión de apps.

Publicar: el primer ./compilar.sh --release guarda la huella de este certificado en $archivo_huella
(súbelo al repositorio). Los siguientes no firman con otro certificado aunque se llame igual.

Para borrarla: security delete-identity -Z $nueva "$llavero"
EOF
  exit 0
fi

# Firma con la identidad del llavero si existe: la identidad que guarda macOS para Gestion de apps
# (nombre + certificado) no cambia al recompilar. Con firma ad hoc cambia en cada compilacion y macOS
# quita el permiso. Se mira antes de compilar para abortar pronto
respaldo="exporta la identidad a un .p12 (Acceso a Llaveros > Mis certificados > Exportar) y guárdalo fuera del Mac"
llavero=(${ICONOS_LLAVERO:+$ICONOS_LLAVERO})
firma=-
candidatas=($(huellas "${llavero[@]}"))
publicada=$( [[ -f $archivo_huella ]] && tr -d '[:space:]' < $archivo_huella | tr a-f A-F || true)
if (( ${#candidatas} )); then
  # Se firma con la huella, no con el nombre: con dos identidades del mismo nombre codesign no elige
  # (ambiguous), y asi se firma con la que se comprobo
  if [[ -n $publicada ]]; then
    if (( ${candidatas[(Ie)$publicada]} )); then
      firma=$publicada
    else
      aviso="La identidad \"$identidad\" del llavero (${(j:, :)candidatas}) no es el certificado con que se publicó Iconos ($publicada, en $archivo_huella)."
      aviso+=" macOS guarda Gestión de apps por identificador y certificado: firmada con otro, quien actualice pierde el permiso para Iconos y para Iconos Agente, y nada se lo explica."
      aviso+=" Importa el respaldo .p12 del certificado original. Solo si se perdió para siempre, borra $archivo_huella para empezar con este (todos tendrán que volver a dar el permiso)."
      if (( release )); then
        echo "Error: $aviso" >&2
        exit 1
      fi
      echo "Aviso: $aviso" >&2
      firma=${candidatas[1]}
    fi
  fi
  if [[ $firma == - ]]; then
    if (( ${#candidatas} > 1 )); then
      echo "Error: hay ${#candidatas} identidades llamadas \"$identidad\" (${(j:, :)candidatas}). Borra las que sobran (security delete-identity -Z <huella>) o elige el llavero con ICONOS_LLAVERO." >&2
      exit 1
    fi
    firma=${candidatas[1]}
  fi
else
  aviso="No está la identidad de firma \"$identidad\" en el llavero: la app se firmaría ad hoc y macOS le quitaría a Iconos el permiso Gestión de apps en cada instalación."
  aviso+=" Créala con ./compilar.sh --crear-firma o, si tienes su respaldo .p12, impórtalo con: security import <archivo>.p12 -T /usr/bin/codesign"
  if (( release )); then
    echo "Error: $aviso" >&2
    echo "No se publica una versión firmada ad hoc: cada actualización le quitaría el permiso a quien la use." >&2
    exit 1
  fi
  if (( instalar && ! sin_firma )); then
    echo "Error: $aviso" >&2
    echo "No se instala. Para instalar igualmente con firma ad hoc, añade --sin-firma." >&2
    exit 1
  fi
  echo "Aviso: $aviso" >&2
fi

swift build -c release
bin=$(swift build -c release --show-bin-path)
if [[ $(lipo -archs $bin/Iconos) != arm64 ]]; then
  echo "Error: Iconos es solo para Apple Silicon y el ejecutable salió para $(lipo -archs $bin/Iconos)." >&2
  exit 1
fi
app=build/Iconos.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/Iconos $app/Contents/MacOS/
cp Recursos/Info.plist $app/Contents/

# Icono nativo de Icon Composer (Recursos/Iconos.icon): actool genera Assets.car, con las variantes
# clara, oscura, tintada y transparente que macOS elige solo, y Iconos.icns para sistemas sin ellas
# Rutas absolutas: con rutas relativas actool puede no generar nada y no da error
xcrun actool --compile "$PWD/$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon Iconos --output-partial-info-plist "$PWD/build/icono-partial.plist" "$PWD/Recursos/Iconos.icon" >/dev/null
if [[ ! -f $app/Contents/Resources/Assets.car || ! -f $app/Contents/Resources/Iconos.icns ]]; then
  echo "Error: actool no generó el icono (Assets.car e Iconos.icns). Hace falta Xcode completo." >&2
  exit 1
fi

# El agente va en su propia app (otro identificador): si fuera Iconos.app, macOS lo tomaria por la app
# ya abierta y al abrir Iconos solo activaria el agente, que no tiene ventana
agente=$app/Contents/Helpers/IconosAgente.app
mkdir -p $agente/Contents/MacOS $agente/Contents/Resources
cp $bin/Iconos $agente/Contents/MacOS/IconosAgente
cp Recursos/Agente-Info.plist $agente/Contents/Info.plist
cp $app/Contents/Resources/Assets.car $app/Contents/Resources/Iconos.icns $agente/Contents/Resources/

# Textos traducidos: el español es el idioma de desarrollo (sus textos son las claves) y xcstringstool
# deja un <idioma>.lproj por cada traduccion. El agente lleva el mismo Localizable para sus avisos y su
# propio InfoPlist (el permiso Gestion de apps se explica con otro texto). Antes de firmar: los .lproj
# entran en la firma. Para sumar al catalogo las cadenas nuevas del codigo (sin Xcode):
#   swift build -c release -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <carpeta>
#   xcrun xcstringstool sync Recursos/Localizable.xcstrings --stringsdata <carpeta>/*.stringsdata
# y luego traducir las que quedan sin "en"
loc=build/textos
rm -rf $loc
mkdir -p $loc/app $loc/agente
for destino in $loc/app $loc/agente; do
  xcrun xcstringstool compile Recursos/Localizable.xcstrings --output-directory $destino
done
xcrun xcstringstool compile Recursos/InfoPlist.xcstrings --output-directory $loc/app
xcrun xcstringstool compile Recursos/Agente-InfoPlist.xcstrings --output-directory $loc/agente
for f in $loc/agente/*.lproj/Agente-InfoPlist.strings(N); do mv $f ${f:h}/InfoPlist.strings; done
lproj=($loc/app/*.lproj(N/))
if (( ! ${#lproj} )); then
  echo "Error: xcstringstool no generó ninguna traducción en $loc/app." >&2
  exit 1
fi
cp -R $loc/app/*.lproj $app/Contents/Resources/
cp -R $loc/agente/*.lproj $agente/Contents/Resources/
firmar=(--force --sign "$firma" --timestamp=none)
[[ $firma != - && -n ${llavero[1]:-} ]] && firmar+=(--keychain "${llavero[1]}")
codesign $firmar $agente
codesign $firmar $app
echo "Listo: $PWD/$app ($version)"

if (( release )); then
  codesign --verify --deep --strict $app
  zip=Iconos-$version.zip
  rm -f build/$zip build/$zip.sha256
  ditto -c -k --keepParent $app build/$zip
  # Desde build/ para que el .sha256 lleve solo el nombre y se compruebe con shasum -c
  (cd build && shasum -a 256 $zip > $zip.sha256)
  echo "Versión $version: $PWD/build/$zip y $zip.sha256"
  if [[ -z $publicada ]]; then
    echo $firma > $archivo_huella
    echo "Primera versión publicada con esta identidad: su huella quedó en $archivo_huella. Súbelo al repositorio: los --release siguientes no firman con otro certificado."
  fi
  echo "Recuerda: $respaldo. Si se pierde, las versiones siguientes ya no tendrán la misma firma."
fi

if (( instalar )); then
  mkdir -p ~/Applications
  osascript -e "quit app id \"$bundle_id\"" 2>/dev/null || true
  rm -rf ~/Applications/Iconos.app
  cp -R $app ~/Applications/
  echo "Instalada en ~/Applications/Iconos.app"
  # Reinstalar (no kickstart): si se activo desde otra copia, el plist apunta a otro ejecutable
  if launchctl print gui/$(id -u)/$etiqueta >/dev/null 2>&1; then
    ~/Applications/Iconos.app/Contents/MacOS/Iconos --instalar-agente
    echo "Agente reinstalado con la copia de ~/Applications"
  fi
  # Agentes de Iconos con otra etiqueta (de un identificador anterior): no se tocan
  for p in ~/Library/LaunchAgents/*.plist(N); do
    programa=$(plist $p ProgramArguments:0 2>/dev/null) || continue
    [[ $programa == */IconosAgente.app/Contents/MacOS/IconosAgente || $programa == */Iconos.app/Contents/MacOS/Iconos ]] || continue
    otra=$(plist $p Label 2>/dev/null) || continue
    [[ $otra == $etiqueta ]] && continue
    echo "Aviso: hay un agente de Iconos con otra etiqueta ($otra, en $p). No se toca: desactívalo a mano si ya no lo usas." >&2
  done
fi
