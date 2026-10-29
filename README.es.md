# Iconos

**Dale a cada app de tu Mac un icono limpio y uniforme: solo su logo, sobre una ficha blanca en modo claro y oscura en modo oscuro.**

Iconos lee el icono de cada app, extrae solo el logo (sin la placa de fondo del fabricante) y lo pone sobre una ficha al estilo de macOS. Un pequeño agente en segundo plano cambia cada icono entre la variante clara y la oscura cuando cambias la apariencia, y lo vuelve a poner si la app se actualiza.

Gratis y de código abierto (MIT). [Read in English](README.md).

## Requisitos

- macOS 26 o posterior
- Apple Silicon (M1 o posterior)

## Instalación

1. Descarga `Iconos-x.y.z.zip` desde [Releases](https://github.com/asubervirojas/iconos/releases). Puedes comprobarlo con `shasum -a 256 -c Iconos-x.y.z.zip.sha256`.
2. Descomprímelo y mueve **Iconos.app** a la carpeta **Aplicaciones**.
3. Ábrela. Como Iconos no está notarizada por Apple (es un proyecto gratis, sin cuenta de pago de Apple Developer), macOS bloquea la primera apertura:
   - Abre **Ajustes del Sistema > Privacidad y seguridad**.
   - Baja hasta el mensaje de Iconos, pulsa **Abrir igualmente** y confirma **Abrir**.
   - Solo se hace una vez.

Luego Iconos muestra una guía corta con cada permiso que necesita y un botón para cada uno.

## Permisos y por qué

| Permiso | Para qué |
|---|---|
| **Gestión de apps** para *Iconos* e *Iconos Agente* (Ajustes del Sistema > Privacidad y seguridad > Gestión de apps) | macOS protege las apps de cambios. Iconos escribe el icono personalizado dentro de cada app (el archivo estándar `Icon\r` que usa Finder), así que la app y su agente necesitan este permiso. |
| **Notificaciones** (opcional) | El agente te avisa si una actualización le quitó el permiso a un icono o si el fabricante cambió su logo. |
| **Tu contraseña, en Terminal** (solo para algunas apps) | Las apps instaladas con `.pkg` o desde la App Store pertenecen al sistema (root): ni con Gestión de apps se puede escribir en ellas. Para esas, Iconos te muestra primero el comando exacto y abre Terminal para que **tú** escribas la contraseña (Iconos nunca la ve). El comando añade una regla de acceso solo en la carpeta principal de esa app, para que tu usuario pueda crear el archivo del icono. No toca nada dentro de la app (`Contents`) y se puede revertir: **Restaurar** en Iconos la quita, o ejecuta `sudo chmod -a "<tu usuario> allow add_file,writeattr,writeextattr" /Applications/App.app`. Puedes verla con `ls -led /Applications/App.app`. Para este paso Terminal también necesita Gestión de apps. |

Las apps del volumen del sistema (Safari) o bloqueadas por su fabricante no se pueden cambiar; Iconos las marca con un candado gris.

## Cómo funciona

- **Extracción del logo.** En los iconos hechos con Icon Composer de Apple (la mayoría de las apps nuevas), Iconos lee las capas originales: el logo sale exacto y con la variante oscura del propio fabricante. Los demás pasan por un extractor de píxeles que separa el logo de su placa. Cada resultado tiene un nivel de confianza; si no se ve bien, elige *Icono completo* o usa tus propias imágenes.
- **No sube nada.** Iconos no se conecta a internet. Todo queda en tu Mac, en `~/Library/Application Support/Iconos`.
- **Aviso de API privada.** Para leer las capas de Icon Composer usa el framework privado CoreUI de Apple. Si una versión futura de macOS lo cambia, Iconos usa el extractor de píxeles. Probado en macOS 26 y 27.

## Desinstalar

Abre Iconos > Ajustes > **Desinstalar Iconos…**. Restaura el icono original de cada app, apaga el agente, quita las reglas de acceso que añadió (pidiendo tu contraseña una vez si hay alguna), borra sus datos y se mueve a la Papelera.

## Compilar desde el código

Necesita Xcode 26 o posterior (Xcode completo, no solo las Command Line Tools, porque el icono se compila con `actool`).

```bash
git clone https://github.com/asubervirojas/iconos.git
cd iconos
./compilar.sh --crear-firma   # una vez: crea una identidad de firma local autofirmada en tu llavero
./compilar.sh --instalar      # compila, firma e instala en ~/Applications
```

macOS recuerda el permiso Gestión de apps por la firma de la app. Firma siempre con la misma identidad (la variable `ICONOS_FIRMA` fija su nombre); si no, macOS volverá a pedir el permiso tras cada compilación. `./compilar.sh --release` genera el zip y su SHA-256.

## Créditos

Hecho por Armando Subervi con ayuda de IA: Claude (Anthropic) y Codex (OpenAI).

Los nombres, iconos y logos de las apps pertenecen a sus dueños. Iconos no está afiliado ni respaldado por ninguno de ellos, ni por Apple.

## Licencia

[MIT](LICENSE)
