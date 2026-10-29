import AppKit

/// Pone y quita iconos personalizados en apps de otros. Escribe el icns tal cual en el recurso del
/// icono personalizado (Icon\r), sin que NSWorkspace lo recodifique, y marca kHasCustomIcon.
enum Aplicador {
    /// Variante escrita en Icon\r, para no reescribir (ni reiniciar el Dock) si ya esta puesta.
    /// Se escribe al final: si esta, el resto del icono tambien
    static let atributoVariante = Identidad.atributoVariante

    static func iconoPersonalizado(_ app: String) -> String { app + "/Icon\r" }

    /// Valida desde disco, sin la cache de Bundle ni enlaces dentro de Contents.
    static func validar(_ ruta: String, bundleId: String? = nil) throws {
        let dir = try abrirValidada(ruta, bundleId: bundleId)
        close(dir)
    }

    private static func abrirValidada(_ ruta: String, bundleId: String?) throws -> Int32 {
        guard ruta.hasPrefix("/"), URL(fileURLWithPath: ruta).pathExtension.lowercased() == "app" else {
            throw ErrorIconos("La ruta no es un bundle .app válido: \(ruta)")
        }
        let dir: Int32
        do {
            let url = URL(fileURLWithPath: ruta)
            // Solo el ultimo componente puede ser un enlace; su padre se abre sin seguirlos.
            let padre = try Almacen.directorioSeguro(url.deletingLastPathComponent())
            defer { close(padre) }
            var st = stat()
            guard fstatat(padre, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw errorEscritura(errno)
            }
            let destino: URL
            if st.st_mode & S_IFMT == S_IFLNK {
                guard let real = realpath(ruta, nil) else { throw errorEscritura(errno) }
                defer { free(real) }
                destino = URL(fileURLWithPath: String(cString: real))
            } else { destino = url }
            dir = try Almacen.directorioSeguro(destino)
        }
        catch { throw ErrorIconos("No se puede abrir la app sin seguir enlaces: \(ruta). \(error.localizedDescription)") }
        do {
            let id = try identificador(dir)
            if let bundleId, bundleId != id {
                throw ErrorIconos("La app de \(ruta) no coincide: se esperaba \(bundleId) y se encontró \(id ?? String(localized: "sin identificador")). No se modificó.")
            }
            return dir
        } catch { close(dir); throw error }
    }

    private static func identificador(_ dir: Int32) throws -> String? {
        let contents = openat(dir, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { throw ErrorIconos("La app no tiene un directorio Contents válido.") }
        defer { close(contents) }
        let plist = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard plist >= 0 else { throw ErrorIconos("La app no tiene un Contents/Info.plist válido.") }
        defer { close(plist) }
        guard let info = try PropertyListSerialization.propertyList(from: Almacen.leerRegular(plist), format: nil) as? [String: Any] else {
            throw ErrorIconos("Contents/Info.plist no describe una aplicación.")
        }
        if let tipo = info["CFBundlePackageType"], !["APPL", "AAPL"].contains(tipo as? String ?? "") {
            throw ErrorIconos("Contents/Info.plist no describe una aplicación (APPL o AAPL).")
        }
        return info["CFBundleIdentifier"] as? String
    }

    private static func identidadGuardada(_ app: String) throws -> String? {
        let config = Almacen.cargar()
        guard !Almacen.configDanada else {
            throw ErrorIconos("La configuración está dañada o no se puede leer. Revisa su copia antes de cambiar apps.")
        }
        return config.apps.first { $0.ruta == app }?.bundleId
    }

    private static func comprobarProteccion(_ app: String) throws {
        if esDelSistema(app) || bloqueadaPorFabricante(app) || bloqueadaPorFabricante(iconoPersonalizado(app)) {
            throw ErrorIconos("macOS o su fabricante protegen esta app; no se puede modificar.", codigo: .protegida)
        }
    }

    /// Una instantanea antes del primer cambio; nil en archivo significa que no existia Icon\r.
    /// Los atributos se guardan como bytes, tambien cuando FinderInfo no existia.
    private struct Respaldo: Codable {
        var bundleId: String?
        var archivo: Data?
        var recurso: Data?
        var finderIcono: Data?
        var finderCarpeta: Data?
    }

    private static func leerAtributo(_ fd: Int32, _ nombre: String) throws -> Data? {
        let n = fgetxattr(fd, nombre, nil, 0, 0, 0)
        if n < 0, errno == ENOATTR { return nil }
        guard n >= 0, n <= 64 * 1024 * 1024 else { throw errorEscritura(errno) }
        var datos = Data(count: n)
        let leidos = datos.withUnsafeMutableBytes { fgetxattr(fd, nombre, $0.baseAddress, n, 0, 0) }
        guard leidos == n else { throw ErrorIconos("El atributo del icono cambió durante el respaldo.") }
        return datos
    }

    private static func respaldoURL(_ app: String) -> URL { Almacen.carpeta(app).appendingPathComponent("icono-previo.json") }

    private static func conservarIcono(_ dir: Int32, app: String) throws {
        try Almacen.conBloqueoArchivo(".bloqueo-respaldos") {
            if let datos = try Almacen.leerSeguro(respaldoURL(app)) {
                let previo = try JSONDecoder().decode(Respaldo.self, from: datos)
                guard previo.bundleId == (try identificador(dir)) else {
                    throw ErrorIconos("El respaldo del icono pertenece a otra app. No se modificó \(app).")
                }
                return
            }
            var previo = Respaldo(bundleId: try identificador(dir), finderCarpeta: try leerAtributo(dir, "com.apple.FinderInfo"))
            let icono = openat(dir, "Icon\r", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if icono >= 0 {
                defer { close(icono) }
                let archivo = try Almacen.leerRegular(icono)
                let recurso = try leerAtributo(icono, "com.apple.ResourceFork")
                if try leerAtributo(icono, atributoVariante) != nil || esRecursoDeIconos(recurso) {
                    // El icono propio nunca es el original, aunque la etiqueta haya cambiado.
                    previo = sinIconoPropio(previo)
                } else {
                    previo.archivo = archivo
                    previo.recurso = recurso
                    previo.finderIcono = try leerAtributo(icono, "com.apple.FinderInfo")
                }
            } else if errno != ENOENT { throw errorEscritura(errno) }
            try Almacen.escribirSeguro(JSONEncoder().encode(previo), en: respaldoURL(app))
        }
    }

    private static func devolverAtributo(_ fd: Int32, _ nombre: String, _ valor: Data?) throws {
        if let valor { try fijar(fd, nombre, valor) }
        else if fremovexattr(fd, nombre, 0) != 0, errno != ENOATTR { throw errorEscritura(errno) }
    }

    /// Se puede poner el icono: la carpeta es del usuario o ya tiene la ACL de Iconos (apps de root)
    static func escribible(_ app: String) -> Bool {
        access(app, W_OK) == 0 || tieneACL(app)
    }

    /// Marca inmutable (chflags schg/uchg): el fabricante la pone para que nadie toque la app, ni root
    /// (FortiClient)
    static func bloqueadaPorFabricante(_ app: String) -> Bool {
        var info = stat()
        guard stat(app, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_IMMUTABLE | UF_IMMUTABLE) != 0
    }

    /// Safari y compania viven en el volumen del sistema, de solo lectura
    static func esDelSistema(_ app: String) -> Bool {
        URL(fileURLWithPath: app).resolvingSymlinksInPath().path.hasPrefix("/System/")
    }

    // MARK: Apps de root

    /// Lo que la ACL deja hacer en la raiz del bundle: crear Icon\r y cambiar los atributos de la
    /// carpeta (kHasCustomIcon). Sin delete_child (permitiria borrar Contents) y sin herencia: nada
    /// cambia dentro de Contents
    static let permisosACL = "add_file,writeattr,writeextattr"

    static func tieneACL(_ app: String) -> Bool {
        guard let acl = acl_get_file(app, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let texto = acl_to_text(acl, nil) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(texto)) }
        // Formato: user:<uuid>:<nombre>:<uid>:allow:write,writeattr,... En una carpeta acl_to_text
        // escribe add_file como "write" (es el mismo bit)
        return String(cString: texto).split(separator: "\n").contains { linea in
            guard linea.contains(":\(getuid()):allow:"), let lista = linea.split(separator: ":").last else { return false }
            let permisos = Set(lista.split(separator: ",").map(String.init))
            return (permisos.contains("add_file") || permisos.contains("write")) && permisos.contains("writeextattr")
        }
    }

    private struct PermisoACL: Codable, Equatable {
        var ruta: String
        var dispositivo: Int32
        var inodo: UInt64
        var bundleId: String?
        var retirada: String?
    }

    private static let archivoACL = Almacen.base.appendingPathComponent("acl-puestas.json")
    private static let archivoSolicitudes = Almacen.base.appendingPathComponent("acl-solicitadas.json")

    private static func leerPermisos(_ url: URL) throws -> [PermisoACL] {
        guard let datos = try Almacen.leerSeguro(url) else { return [] }
        do { return try JSONDecoder().decode([PermisoACL].self, from: datos) }
        catch { throw ErrorIconos("El registro de permisos \(url.lastPathComponent) está dañado. No se quitará ninguna ACL.") }
    }

    private static func identidadACL(_ ruta: String, config: Configuracion? = nil) throws -> PermisoACL {
        let id: String?
        if let config { id = config.apps.first { $0.ruta == ruta }?.bundleId }
        else { id = try identidadGuardada(ruta) }
        let dir = try abrirValidada(ruta, bundleId: id)
        defer { close(dir) }
        var st = stat()
        guard fstat(dir, &st) == 0 else { throw errorEscritura(errno) }
        return PermisoACL(ruta: ruta, dispositivo: st.st_dev, inodo: st.st_ino, bundleId: try identificador(dir))
    }

    /// La regla exacta, sin permisos adicionales de otro origen.
    private static func estadoACLExacta(_ app: String) -> Bool? {
        guard let acl = acl_get_file(app, ACL_TYPE_EXTENDED) else {
            // macOS devuelve ENOENT tambien al quitar la ultima ACL. permisoVigente
            // comprueba el mismo inodo antes y despues: una app ausente no pierde su registro.
            return errno == ENOENT ? false : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let texto = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(texto)) }
        return String(cString: texto).split(separator: "\n").contains { linea in
            guard linea.contains(":\(getuid()):allow:"), let lista = linea.split(separator: ":").last else { return false }
            let permisos = Set(lista.split(separator: ",").map { $0 == "write" ? "add_file" : String($0) })
            return permisos == Set(permisosACL.split(separator: ",").map(String.init))
        }
    }

    private static func tieneACLExacta(_ app: String) -> Bool { estadoACLExacta(app) == true }

    /// nil significa que no se pudo confirmar la identidad o leer la ACL; no es una retirada.
    private static func permisoVigente(_ permiso: PermisoACL, config: Configuracion) -> Bool? {
        guard let actual = try? identidadACL(permiso.ruta, config: config),
              actual.dispositivo == permiso.dispositivo, actual.inodo == permiso.inodo,
              actual.bundleId == permiso.bundleId else { return nil }
        let estado = estadoACLExacta(permiso.ruta)
        var st = stat()
        guard stat(permiso.ruta, &st) == 0, st.st_dev == permiso.dispositivo, st.st_ino == permiso.inodo else { return nil }
        return estado
    }

    static func confirmarPermisos(rutasEscaneadas: [String]? = nil) throws {
        let config = Almacen.cargar()
        guard !Almacen.configDanada else {
            throw ErrorIconos("La configuración está dañada; se conserva el registro de permisos.")
        }
        try Almacen.conBloqueoArchivo(".bloqueo-acl") {
            let migrar = try Almacen.leerSeguro(archivoACL) == nil
            let solicitudes = try leerPermisos(archivoSolicitudes)
            let anteriores = try leerPermisos(archivoACL)
            var puestas: [PermisoACL] = []
            // Migracion de una sola vez: antes de existir acl-puestas.json, las reglas exactas
            // del uid actual en las carpetas escaneadas se adoptan como permisos de Iconos.
            // Incluso vacio, el archivo marca el fin de la migracion: no adopta ACL posteriores.
            if migrar {
                for ruta in rutasEscaneadas ?? Almacen.rutasEscaneadas(config) {
                    guard !esDelSistema(ruta), tieneACLExacta(ruta) else { continue }
                    let permiso = try identidadACL(ruta, config: config)
                    guard permisoVigente(permiso, config: config) == true else {
                        throw ErrorIconos("La app cambió durante la migración de permisos: \(ruta)")
                    }
                    puestas.append(permiso)
                }
            }
            for permiso in anteriores {
                if let retirada = permiso.retirada {
                    guard UUID(uuidString: retirada) != nil else { throw ErrorIconos("El registro de retirada de permisos está dañado.") }
                    let recibo = Almacen.base.appendingPathComponent(".acl-retirada-" + retirada)
                    if try Almacen.leerSeguro(recibo) != nil { continue }
                }
                if permisoVigente(permiso, config: config) != false { puestas.append(permiso) }
            }
            var pendientes: [PermisoACL] = []
            for solicitud in solicitudes {
                if permisoVigente(solicitud, config: config) == true {
                    puestas.removeAll { $0.ruta == solicitud.ruta }
                    puestas.append(solicitud)
                } else { pendientes.append(solicitud) }
            }
            if migrar || puestas != anteriores {
                try Almacen.escribirSeguro(JSONEncoder().encode(puestas), en: archivoACL)
            }
            if pendientes != solicitudes {
                try Almacen.escribirSeguro(JSONEncoder().encode(pendientes), en: archivoSolicitudes)
            }
        }
    }

    /// Una identidad incierta impide desinstalar y borrar el unico registro de una ACL pendiente.
    static func permisosRegistrados() throws -> [String] {
        try confirmarPermisos()
        return try leerPermisosVigentes()
    }

    private static func leerPermisosVigentes() throws -> [String] {
        let config = Almacen.cargar()
        guard !Almacen.configDanada else { throw ErrorIconos("La configuración está dañada; se conservan los permisos.") }
        return try leerPermisos(archivoACL).compactMap { permiso in
            guard let vigente = permisoVigente(permiso, config: config) else {
                throw ErrorIconos("No se pudo verificar el permiso de \(permiso.ruta); se conserva su registro.")
            }
            return vigente ? permiso.ruta : nil
        }
    }

    /// Consulta para la ventana: escanear() ya reconcilio una vez los permisos.
    static func conACL() -> [String] { (try? leerPermisosVigentes()) ?? [] }

    /// La contrasena se escribe en Terminal; Iconos no la ve.
    static func permitirEnTerminal(_ apps: [String]) throws {
        var validas: [String] = []
        try Almacen.conBloqueoArchivo(".bloqueo-acl") {
            _ = try leerPermisos(archivoACL)
            var solicitudes = try leerPermisos(archivoSolicitudes)
            for app in Set(apps).sorted() {
                let identidad = try identidadACL(app)
                try comprobarProteccion(app)
                // Tras la migracion inicial, una ACL previa nunca se adopta como propia.
                guard access(app, W_OK) != 0, !tieneACL(app) else { continue }
                solicitudes.removeAll { $0.ruta == app }
                solicitudes.append(identidad)
                validas.append(app)
            }
            try Almacen.escribirSeguro(JSONEncoder().encode(solicitudes), en: archivoSolicitudes)
        }
        guard !validas.isEmpty else { return }
        try abrirEnTerminal(guionACL(validas, quitar: false), nombre: "Iconos-permiso.command")
    }

    /// Terminal deja un recibo al retirar la ACL. Asi no se reclama una regla de otro origen
    /// agregada antes de que la ventana vuelva a revisar los permisos.
    private static func prepararRetirada(_ apps: [String]) throws {
        try Almacen.conBloqueoArchivo(".bloqueo-acl") {
            var puestas = try leerPermisos(archivoACL)
            for i in puestas.indices where apps.contains(puestas[i].ruta) && puestas[i].retirada == nil {
                puestas[i].retirada = UUID().uuidString
            }
            try Almacen.escribirSeguro(JSONEncoder().encode(puestas), en: archivoACL)
        }
    }

    static func quitarPermisoEnTerminal(_ apps: [String]) throws {
        let propias = Set(try permisosRegistrados())
        let validas = apps.filter { propias.contains($0) }
        for app in validas { try validar(app, bundleId: identidadGuardada(app)); try comprobarProteccion(app) }
        guard !validas.isEmpty else { return }
        try prepararRetirada(validas)
        try abrirEnTerminal(guionACL(validas, quitar: true), nombre: "Iconos-quitar-permiso.command")
    }

    static func desinstalarEnTerminal(_ apps: [String], app: String) throws {
        let propias = Set(try permisosRegistrados())
        let validas = apps.filter { propias.contains($0) }
        for ruta in validas { try validar(ruta, bundleId: identidadGuardada(ruta)); try comprobarProteccion(ruta) }
        try prepararRetirada(validas)
        try abrirEnTerminal(guionACL(validas, quitar: true, appADesinstalar: app), nombre: "Iconos-desinstalar.command")
    }

    /// El guion vive fuera de Almacen.base para poder terminar aunque borre los datos.
    private static func abrirEnTerminal(_ texto: String, nombre: String) throws {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent("Iconos-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let guion = carpeta.appendingPathComponent(nombre)
        try texto.write(to: guion, atomically: true, encoding: .utf8)
        guard chmod(guion.path, 0o700) == 0 else { throw ErrorIconos("No se pudo preparar el comando.") }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ErrorIconos("No se encontró Terminal.")
        }
        NSWorkspace.shared.open([guion], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// El guion que corre Terminal (--guion-permiso lo imprime para revisarlo)
    static func guionPermiso(_ validas: [String]) -> String { guionACL(validas, quitar: false) }

    /// Guion de Terminal que pone (chmod +a) o quita (chmod -a) la misma regla en cada app
    static func guionACL(_ validas: [String], quitar: Bool, appADesinstalar: String? = nil) -> String {
        let propias = quitar ? Set(conACL()) : []
        let validas = validas.filter { (!quitar || propias.contains($0)) && (try? validar($0)) != nil }
        let registros = (try? leerPermisos(archivoACL)) ?? []
        let regla = comillasShell("\(NSUserName()) allow \(permisosACL)")
        let verbo = quitar ? "-a" : "+a"
        let cuantas = validas.count == 1 ? String(localized: "1 app") : String(localized: "\(validas.count) apps")
        // Los textos se traducen al generar el guion y van siempre entre comillas de shell: una
        // traduccion puede llevar apostrofos
        func eco(_ texto: String) -> String { "echo " + comillasShell(texto) }
        var lineas = [
            "#!/bin/zsh",
            "# " + (quitar ? String(localized: "Iconos: quita el permiso que puso en apps de root")
                : String(localized: "Iconos: deja poner el icono en apps de root (solo en la carpeta de la app, no dentro)")),
            "clear",
            eco(quitar ? String(localized: "Iconos: quitar el permiso de cambiar el icono de \(cuantas)")
                : String(localized: "Iconos: permiso para cambiar el icono de \(cuantas)")),
            eco(String(localized: "Escribe tu contraseña de Mac (no se ve al escribir) y pulsa Intro.")),
            "echo",
            "fallo=0",
            "if ! sudo -v; then",
            "  " + eco(String(localized: "Falló sudo: contraseña incorrecta o cuenta sin permisos de administrador. No se cambió ninguna app.")),
            "  exit 1",
            "fi",
            // Para que los mensajes de chmod y sudo salgan en ingles y fallar() los reconozca
            "export LC_ALL=C",
            "fallar() {",
            "  case \"$1\" in",
            "    *'Read-only file system'*) " + eco(String(localized: "El volumen es de solo lectura; no se puede modificar la app.")) + " ;;",
            "    *'Operation not permitted'*) " + eco(String(localized: "macOS bloqueó el cambio. Permite Terminal en Privacidad y seguridad > Gestión de apps.")) + " ;;",
            "    *'sudo:'*) " + eco(String(localized: "Falló sudo: la autorización caducó o la cuenta no tiene permisos de administrador.")) + " ;;",
            "    *'Permission denied'*) " + eco(String(localized: "Permiso de escritura denegado por el propietario o la ACL de la app.")) + " ;;",
            "    *) echo " + comillasShell(String(localized: "No se pudo cambiar el permiso:")) + " \"$1\" ;;",
            "  esac",
            "  fallo=1",
            "}",
        ]
        let hecho = quitar ? String(localized: "quitado") : String(localized: "listo")
        for app in validas {
            let ruta = comillasShell(app)
            guard let identidad = try? identidadACL(app) else { continue }
            let sello = comillasShell("\(identidad.dispositivo):\(identidad.inodo)")
            let id = identidad.bundleId ?? ""
            let retirada = registros.first { $0.ruta == app }?.retirada
            let recibo = retirada.map { Almacen.base.appendingPathComponent(".acl-retirada-" + $0).path }
            if quitar && recibo == nil {
                lineas.append(eco(String(localized: "No se preparó el registro de retirada. Vuelve a abrir Iconos.")) + "; fallo=1")
                continue
            }
            lineas += [
                "ruta=\(ruta)",
                "cambiada=0",
                "recibo=\(comillasShell(recibo ?? ""))",
                "segura=1; parte=\"$ruta/Contents/Info.plist\"",
                "while [[ \"$parte\" != / ]]; do [[ -L \"$parte\" ]] && segura=0; parte=${parte:h}; done",
                "if [[ -n \"$recibo\" && ( -e \"$recibo\" || -L \"$recibo\" ) ]]; then",
                "  " + eco(String(localized: "Este permiso ya se retiró. Vuelve a abrir Iconos para revisar el estado.")) + "; fallo=1",
                "elif [[ $segura != 1 || ! -d \"$ruta\" || ! -f \"$ruta/Contents/Info.plist\" || $(/usr/bin/stat -f '%d:%i' \"$ruta\") != \(sello) ]]; then",
                "  " + eco(String(localized: "La app cambió o contiene enlaces. No se tocó.")) + "; fallo=1",
                "elif [[ $(/usr/bin/plutil -extract CFBundlePackageType raw -o - \"$ruta/Contents/Info.plist\" 2>/dev/null) != APPL ]]; then",
                "  " + eco(String(localized: "Info.plist ya no describe una app. No se tocó.")) + "; fallo=1",
                "elif [[ -n \(comillasShell(id)) && $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \"$ruta/Contents/Info.plist\" 2>/dev/null) != \(comillasShell(id)) ]]; then",
                "  " + eco(String(localized: "El identificador de la app cambió. No se tocó.")) + "; fallo=1",
                "elif [[ $(/usr/bin/stat -f '%Sf' \"$ruta\") == *chg* || \"$ruta\" == /System/* ]]; then",
                "  " + eco(String(localized: "La app está protegida por macOS o por su fabricante.")) + "; fallo=1",
                "else",
                "  if resultado=$(sudo -n /bin/chmod \(verbo) \(regla) \"$ruta\" 2>&1); then cambiada=1; echo \(comillasShell("  " + hecho + ":")) \"$ruta\"; else fallar \"$resultado\"; fi",
                "fi",
            ]
            if quitar {
                // ls -e muestra la ACL en disco. Un error de lectura tambien impide la limpieza.
                let prueba = "$2 == usuario && $3 == \"allow\" { n=split($4,p,\",\"); a=0; b=0; c=0; for(i=1;i<=n;i++){if(p[i]==\"add_file\" || p[i]==\"write\")a++; if(p[i]==\"writeattr\")b++; if(p[i]==\"writeextattr\")c++} if(n==3 && a==1 && b==1 && c==1)queda=1 } END { exit queda ? 1 : 0 }"
                let confirmar = recibo.map { "(set -C; : > \(comillasShell($0))) || { \(eco(String(localized: "No se pudo registrar la retirada del permiso."))); fallo=1; }" } ?? ":"
                let sinVerificar = comillasShell("  " + String(localized: "no se pudo verificar la retirada del permiso:"))
                lineas.append("if [[ $cambiada == 1 ]] && acl=$(/bin/ls -lde \(ruta)) && /usr/bin/awk -v usuario=\(comillasShell("user:" + NSUserName())) \(comillasShell(prueba)) <<< \"$acl\"; then \(confirmar); else echo \(sinVerificar) \(ruta); fallo=1; fi")
            }
        }
        if quitar, let app = appADesinstalar {
            let fm = FileManager.default
            let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs").path
            let papelera = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
            // Todos los fallos de desinstalar terminan igual
            let reintentar = String(localized: "Puedes reintentar abriendo Iconos.")
            lineas += [
                "if [ $fallo != 0 ]; then",
                "  " + eco(String(localized: "No se borró ningún dato ni se movió Iconos.") + " " + reintentar),
                "  exit 1",
                "fi",
                "app=\(comillasShell(app))",
                "if [[ ! -d \"$app\" || \"$app\" != *.app ]]; then",
                "  " + eco(String(localized: "No se encontró Iconos.app. No se borró ningún dato.") + " " + reintentar),
                "  exit 1",
                "fi",
                "if ! /bin/rm -rf \(comillasShell(Almacen.base.path)); then",
                "  " + eco(String(localized: "No se pudieron borrar los datos.") + " " + reintentar) + "; exit 1",
                "fi",
                // Tambien el rotado (Iconos-agente.log.1, ver Registro)
                "for registro in \(comillasShell(logs))/Iconos-agente*.log(N) \(comillasShell(logs))/Iconos-agente*.log.1(N); do",
                "  if ! /bin/rm -f \"$registro\"; then " + eco(String(localized: "No se pudieron borrar los registros.") + " " + reintentar) + "; exit 1; fi",
                "done",
                "papelera=\(comillasShell(papelera))",
                "if ! /bin/mkdir -p \"$papelera\"; then " + eco(String(localized: "No se pudo abrir la Papelera.") + " " + reintentar) + "; exit 1; fi",
                "nombre=${app:t}",
                "destino=\"$papelera/$nombre\"",
                "sufijo=2",
                "while [[ -e \"$destino\" || -L \"$destino\" ]]; do destino=\"$papelera/${nombre:r} $sufijo.app\"; ((sufijo++)); done",
                "if ! /bin/mv -n \"$app\" \"$destino\" || [[ -e \"$app\" || -L \"$app\" ]]; then",
                "  " + eco(String(localized: "No se pudo mover Iconos a la Papelera.") + " " + reintentar) + "; exit 1",
                "fi",
                eco(String(localized: "Iconos se desinstaló y se movió a la Papelera. Puedes cerrar esta ventana.")),
            ]
            return lineas.joined(separator: "\n") + "\n"
        }
        lineas += [
            "echo",
            "if [ $fallo = 0 ]; then",
            "  " + eco(quitar ? String(localized: "Listo. Iconos ya no puede cambiar estas apps. Puedes cerrar esta ventana.")
                : String(localized: "Listo. Vuelve a Iconos y pulsa Aplicar. Puedes cerrar esta ventana.")),
            "else",
            "  " + eco(String(localized: "No se completaron todos los cambios. Revisa el motivo indicado para cada app.")),
            "fi",
        ]
        return lineas.joined(separator: "\n") + "\n"
    }

    private static func comillasShell(_ texto: String) -> String {
        "'" + texto.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sin delete_child en la carpeta, Icon\r necesita su propio permiso de borrado para restaurar
    private static func permitirBorrado(_ archivo: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["+a", "\(NSUserName()) allow delete", archivo]
        try? p.run()
        p.waitUntilExit()
    }

    static func aplicar(icns url: URL, a app: String, variante: Variante) throws {
        let dir = try abrirValidada(app, bundleId: identidadGuardada(app))
        defer { close(dir) }
        try comprobarProteccion(app)
        guard let elementos = elementosICNS(url) else { throw ErrorIconos("No se pudo leer \(url.lastPathComponent)") }
        let icns = "icns".data(using: .ascii)! + be32(UInt32(elementos.count + 8)) + elementos

        // Todo va contra el directorio abierto: si un actualizador reemplaza el bundle a mitad, se
        // escribe entero en el viejo y se detecta al final, en vez de repartirlo entre los dos
        try conservarIcono(dir, app: app)
        let existia = faccessat(dir, "Icon\r", F_OK, AT_SYMLINK_NOFOLLOW) == 0
        let icono = openat(dir, "Icon\r", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard icono >= 0 else { throw errorEscritura(errno) }
        defer { close(icono) }
        var st = stat()
        guard fstat(icono, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
            throw ErrorIconos("El archivo del icono no es regular o tiene enlaces adicionales.")
        }
        if !existia, access(app, W_OK) != 0 { permitirBorrado(iconoPersonalizado(app)) }

        var oculto = Data(count: 32)
        oculto[8] = 0x40  // kIsInvisible
        if fremovexattr(icono, atributoVariante, 0) != 0, errno != ENOATTR { throw errorEscritura(errno) }
        try fijar(icono, "com.apple.ResourceFork", resourceFork(icns: icns))
        try fijar(icono, "com.apple.FinderInfo", oculto)
        try marcarIconoPersonalizado(dir)
        guard mismoArchivo(dir, app) else { throw ErrorIconos("La app cambió mientras se ponía el icono.", transitorio: true) }
        try fijar(icono, atributoVariante, Data(variante.rawValue.utf8))
        futimes(icono, nil)  // fecha nueva en Icon\r, como cuando NSWorkspace.setIcon lo reescribe
        NSWorkspace.shared.noteFileSystemChanged(app)
    }

    /// Variante puesta y completa: recurso en Icon\r, kHasCustomIcon en el bundle y la etiqueta
    static func variantePuesta(_ app: String) -> Variante? {
        let archivo = iconoPersonalizado(app)
        guard getxattr(archivo, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) > 0 else { return nil }
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(app, "com.apple.FinderInfo", &info, 32, 0, 0) == 32, info[8] & 0x04 != 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 16)
        let n = getxattr(archivo, atributoVariante, &buf, buf.count, 0, XATTR_NOFOLLOW)
        return n > 0 ? Variante(rawValue: String(decoding: buf[0..<n], as: UTF8.self)) : nil
    }

    /// Olvida que variante esta puesta (quita el atributo de Icon\r): la proxima revision del agente la
    /// vuelve a escribir aunque coincida. Para icns regenerados (importar, icono nuevo, migracion) sin
    /// depender de memoria del agente
    static func invalidarVariante(_ app: String) {
        // La firma existente no lanza errores: ante una duda se deja el icono intacto.
        let dir: Int32
        do { dir = try abrirValidada(app, bundleId: identidadGuardada(app)) }
        catch { return }
        defer { close(dir) }
        guard (try? comprobarProteccion(app)) != nil, (try? conservarIcono(dir, app: app)) != nil else { return }
        let icono = openat(dir, "Icon\r", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard icono >= 0 else { return }
        defer { close(icono) }
        fremovexattr(icono, atributoVariante, 0)
    }

    static func tieneIconoPersonalizado(_ app: String) -> Bool {
        FileManager.default.fileExists(atPath: iconoPersonalizado(app))
    }

    /// Devuelve el icono anterior; para instalaciones antiguas sin respaldo, quita el de Iconos.
    static func restaurar(_ app: String) throws {
        let dir = try abrirValidada(app, bundleId: identidadGuardada(app))
        defer { close(dir) }
        try comprobarProteccion(app)
        var previo = try Almacen.leerSeguro(respaldoURL(app)).map { try JSONDecoder().decode(Respaldo.self, from: $0) }
        // Repara tambien respaldos contaminados por una version anterior.
        if let guardado = previo, esRecursoDeIconos(guardado.recurso) { previo = sinIconoPropio(guardado) }
        if let previo {
            guard previo.bundleId == (try identificador(dir)) else {
                throw ErrorIconos("El respaldo del icono pertenece a otra app. No se modificó \(app).")
            }
            if let datos = previo.archivo {
                let icono = openat(dir, "Icon\r", O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
                guard icono >= 0 else { throw errorEscritura(errno) }
                defer { close(icono) }
                var st = stat()
                guard fstat(icono, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
                    throw ErrorIconos("El archivo del icono no es un archivo regular seguro.")
                }
                guard ftruncate(icono, 0) == 0 else { throw errorEscritura(errno) }
                var escritos = 0
                while escritos < datos.count {
                    let n = datos.withUnsafeBytes { write(icono, $0.baseAddress!.advanced(by: escritos), $0.count - escritos) }
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw errorEscritura(errno) }
                    escritos += n
                }
                try devolverAtributo(icono, "com.apple.ResourceFork", previo.recurso)
                try devolverAtributo(icono, "com.apple.FinderInfo", previo.finderIcono)
                try devolverAtributo(icono, atributoVariante, nil)
            } else if unlinkat(dir, "Icon\r", 0) != 0, errno != ENOENT { throw errorEscritura(errno) }
            try devolverAtributo(dir, "com.apple.FinderInfo", previo.finderCarpeta)
        } else {
            if unlinkat(dir, "Icon\r", 0) != 0, errno != ENOENT { throw errorEscritura(errno) }
            if var info = try leerAtributo(dir, "com.apple.FinderInfo"), info.count == 32, info[8] & 0x04 != 0 {
                info[8] &= ~0x04
                try devolverAtributo(dir, "com.apple.FinderInfo", info.allSatisfy { $0 == 0 } ? nil : info)
            }
        }
        guard mismoArchivo(dir, app) else { throw ErrorIconos("La app cambió mientras se restauraba el icono.", transitorio: true) }
        NSWorkspace.shared.noteFileSystemChanged(app)
    }

    // MARK: Dock

    /// El Dock solo hace falta reiniciarlo si la app esta en el Dock (fijada o abierta con ventana;
    /// las de la barra de menus no salen en el Dock)
    static func estaEnDock(_ app: String) -> Bool {
        let objetivo = URL(fileURLWithPath: app).standardizedFileURL.path
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path == objetivo
        }) {
            return true
        }
        let fijadas = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        return fijadas.contains { item in
            guard let tile = item["tile-data"] as? [String: Any], let file = tile["file-data"] as? [String: Any],
                  let texto = file["_CFURLString"] as? String, let url = URL(string: texto) else { return false }
            return url.standardizedFileURL.path == objetivo
        }
    }

    /// El Dock guarda los iconos en su propia cache y no relee un icono personalizado cuando cambia el
    /// archivo; ni reiniciarlo basta si la cache sigue ahi
    static func refrescarDock() {
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 {
            unlink(String(cString: buf) + "com.apple.dock.iconcache")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Formato

    private static func errorEscritura(_ codigo: Int32) -> ErrorIconos {
        switch codigo {
        case EACCES:
            ErrorIconos("La app es de root: pulsa Permitir cambios (pide tu contraseña en Terminal una vez).", codigo: .sinPermisoRoot)
        case EPERM:
            ErrorIconos("macOS no dejó modificar la app. Permite Iconos e Iconos Agente en Privacidad y seguridad > Gestión de apps.", codigo: .sinGestionDeApps)
        case EROFS:
            ErrorIconos("La app está en un volumen de solo lectura.", codigo: .protegida)
        case ENOENT, ENOTDIR:
            ErrorIconos("La app no está en su sitio (quizá se está actualizando).", transitorio: true)
        default:
            ErrorIconos("No se pudo escribir el icono (\(String(cString: strerror(codigo)))).")
        }
    }

    /// El descriptor sigue siendo el bundle que hay ahora en la ruta
    private static func mismoArchivo(_ fd: Int32, _ ruta: String) -> Bool {
        var abierto = stat(), actual = stat()
        return fstat(fd, &abierto) == 0 && stat(ruta, &actual) == 0
            && abierto.st_dev == actual.st_dev && abierto.st_ino == actual.st_ino
    }

    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    private static func leer32(_ d: Data, _ off: Int) -> Int {
        Int(d[off]) << 24 | Int(d[off + 1]) << 16 | Int(d[off + 2]) << 8 | Int(d[off + 3])
    }

    /// Elementos de un icns (sin la cabecera 'icns' ni el 'TOC '). Rechaza archivos truncados, con
    /// bytes de mas o sin imagenes
    private static func elementosICNS(_ url: URL) -> Data? {
        guard let d = try? Data(contentsOf: url), d.count > 8, d.prefix(4) == "icns".data(using: .ascii)!,
              leer32(d, 4) == d.count else { return nil }
        var salida = Data(), off = 8
        while off < d.count {
            guard off + 8 <= d.count else { return nil }
            let len = leer32(d, off + 4)
            guard len >= 8, off + len <= d.count else { return nil }
            if d[off..<off + 4] != "TOC ".data(using: .ascii)! { salida += d[off..<off + len] }
            off += len
        }
        return salida.isEmpty ? nil : salida
    }

    /// Resource fork con un unico recurso 'icns' id -16455 (kCustomIconResource)
    private static func resourceFork(icns: Data) -> Data {
        let inicioDatos: UInt32 = 256, largoMapa: UInt32 = 50
        let cuerpo = be32(UInt32(icns.count)) + icns
        let inicioMapa = inicioDatos + UInt32(cuerpo.count)
        let cabecera = be32(inicioDatos) + be32(inicioMapa) + be32(UInt32(cuerpo.count)) + be32(largoMapa)
        var mapa = cabecera + Data(count: 8) + be16(28) + be16(50)
        mapa += be16(0) + "icns".data(using: .ascii)! + be16(0) + be16(10)
        mapa += be16(UInt16(bitPattern: -16455)) + be16(0xFFFF) + Data(count: 8)
        return cabecera + Data(count: 240) + cuerpo + mapa
    }

    /// Firma estructural exacta: datos en 256, mapa de 50 bytes y un icns id -16455.
    /// No depende de identificadores privados de instalaciones anteriores.
    private static func esRecursoDeIconos(_ datos: Data?) -> Bool {
        guard let datos, datos.count >= 318, leer32(datos, 0) == 256,
              leer32(datos, 12) == 50 else { return false }
        let largo = leer32(datos, 8), mapa = leer32(datos, 4)
        guard largo >= 12, mapa == 256 + largo, mapa + 50 == datos.count,
              leer32(datos, 256) == largo - 4 else { return false }
        let icns = Data(datos[260..<mapa])
        guard icns.prefix(4) == Data("icns".utf8), leer32(icns, 4) == icns.count else { return false }
        return datos == resourceFork(icns: icns)
    }

    private static func sinIconoPropio(_ previo: Respaldo) -> Respaldo {
        var limpio = previo
        limpio.archivo = nil
        limpio.recurso = nil
        limpio.finderIcono = nil
        if var info = limpio.finderCarpeta, info.count == 32 {
            info[8] &= ~0x04
            limpio.finderCarpeta = info.allSatisfy { $0 == 0 } ? nil : info
        }
        return limpio
    }

    private static func fijar(_ fd: Int32, _ nombre: String, _ valor: Data) throws {
        // ResourceFork escribe desde el offset cero pero no siempre trunca la cola anterior.
        if nombre == "com.apple.ResourceFork", fremovexattr(fd, nombre, 0) != 0, errno != ENOATTR {
            throw errorEscritura(errno)
        }
        let codigo = valor.withUnsafeBytes { fsetxattr(fd, nombre, $0.baseAddress, valor.count, 0, 0) == 0 ? 0 : errno }
        if codigo != 0 { throw errorEscritura(codigo) }
    }

    /// kHasCustomIcon en el bundle conservando el resto de FinderInfo
    private static func marcarIconoPersonalizado(_ dir: Int32) throws {
        var info = Data(count: 32)
        let n = info.withUnsafeMutableBytes { fgetxattr(dir, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        if n != 32 { info = Data(count: 32) }
        info[8] |= 0x04
        try fijar(dir, "com.apple.FinderInfo", info)
    }
}
