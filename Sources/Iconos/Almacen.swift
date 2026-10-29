import AppKit
import CryptoKit

enum Modo: String, Codable, CaseIterable, Identifiable {
    /// Claro u oscuro segun la apariencia (el agente lo cambia; reinicia el Dock si la app esta en el)
    case automatico
    case claro
    case oscuro

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .automatico: String(localized: "Automático")
        case .claro: String(localized: "Siempre claro")
        case .oscuro: String(localized: "Siempre oscuro")
        }
    }

    func variante(oscuroAhora: Bool) -> Variante {
        switch self {
        case .automatico: oscuroAhora ? .oscuro : .claro
        case .claro: .claro
        case .oscuro: .oscuro
        }
    }
}

enum QuitarBlanco: String, Codable, CaseIterable, Identifiable {
    case nunca, enOscuro, siempre

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .nunca: String(localized: "No")
        case .enOscuro: String(localized: "Solo en oscuro")
        case .siempre: String(localized: "Siempre")
        }
    }

    func aplica(_ v: Variante) -> Bool { self == .siempre || (self == .enOscuro && v == .oscuro) }
}

enum EstiloLogo: String, Codable, CaseIterable, Identifiable {
    /// Quita la ficha original y deja solo el logo, con el color adaptado a cada ficha
    case automatico
    /// El icono entero, con su ficha (para iconos sin ficha o si la extraccion no convence)
    case completo

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .automatico: String(localized: "Solo el logo")
        case .completo: String(localized: "Icono completo")
        }
    }
}

struct Ajustes: Codable, Equatable {
    var estilo: EstiloLogo = .automatico
    /// Tamano del logo respecto al de su diseno original (1 = el mismo)
    var tamano: Double = 1
    var quitarBlanco: QuitarBlanco = .nunca

    init() {}

    private enum CodingKeys: String, CodingKey { case estilo, tamano, quitarBlanco }
    /// Antes habia una escala absoluta (0.62 por defecto)
    private enum Antiguas: String, CodingKey { case escala }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let viejas = try decoder.container(keyedBy: Antiguas.self)
        estilo = try c.decodeIfPresent(EstiloLogo.self, forKey: .estilo) ?? .automatico
        tamano = try c.decodeIfPresent(Double.self, forKey: .tamano)
            ?? (try viejas.decodeIfPresent(Double.self, forKey: .escala)).map { $0 / 0.62 } ?? 1
        quitarBlanco = try c.decodeIfPresent(QuitarBlanco.self, forKey: .quitarBlanco) ?? .nunca
    }
}

/// Una app con icono puesto por Iconos
struct Gestionada: Codable, Identifiable, Equatable {
    var ruta: String
    var nombre: String
    var modo: Modo = .automatico
    var ajustes = Ajustes()
    /// Usa imagenes propias (propia-claro.png / propia-oscuro.png) en vez de generar la ficha
    var propia = false
    /// Para reconocer la app si se reinstala en otra ruta
    var bundleId: String?
    /// Version del bundle cuando se aplico
    var version: String?
    /// Huella del icono del fabricante cuando se aplico (Almacen.huellaIcono)
    var huella: String?
    /// Como salio el logo al aplicar
    var confianza: Confianza?
    var metodo: String?

    var id: String { ruta }
}

struct Configuracion: Codable {
    var apps: [Gestionada] = []
    /// El Dock no relee un icono personalizado: para verlo hay que reiniciarlo (parpadea un segundo).
    /// Apagado, el Dock muestra el cambio la proxima vez que se reinicie solo
    var reiniciarDock = true
    /// Carpetas de apps que el usuario agrego a mano, ademas de /Applications y ~/Applications
    var carpetasExtra: [String] = []

    init() {}

    // Configuraciones guardadas antes de que existiera reiniciarDock
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = try c.decodeIfPresent([Gestionada].self, forKey: .apps) ?? []
        reiniciarDock = try c.decodeIfPresent(Bool.self, forKey: .reiniciarDock) ?? true
        carpetasExtra = try c.decodeIfPresent([String].self, forKey: .carpetasExtra) ?? []
    }
}

struct AppEncontrada: Identifiable, Hashable {
    let ruta: String
    let nombre: String
    let escribible: Bool
    let personalizado: Bool
    /// En el volumen del sistema (Safari): no se puede cambiar ni con contrasena
    var sistema = false
    /// Con marca inmutable de su fabricante (FortiClient): tampoco
    var bloqueada = false
    var bundleId: String?
    /// Variante que tiene puesta ahora (Icon\r de Iconos completo), nil si no tiene
    var puesta: Variante?

    /// Apps de root sin el permiso de Iconos: se arreglan con Permitir cambios
    var necesitaPermiso: Bool { !escribible && !sistema && !bloqueada }

    var id: String { ruta }
}

enum Almacen {
    static let base: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Iconos", isDirectory: true)
    static let archivoConfig = base.appendingPathComponent("config.json")
    /// La app avisa al agente que cambio la configuracion
    static let aviso = Identidad.avisoCambio

    private static let candadoConfig = NSLock()
    private static var danada = false
    static var configDanada: Bool {
        candadoConfig.lock()
        defer { candadoConfig.unlock() }
        return danada
    }

    /// ENOENT o un archivo vacio significan configuracion ausente; otros errores la protegen.
    static func cargar() -> Configuracion {
        candadoConfig.lock()
        defer { candadoConfig.unlock() }
        do {
            guard let datos = try leerSeguro(archivoConfig), !datos.isEmpty else { danada = false; return Configuracion() }
            do {
                let config = try JSONDecoder().decode(Configuracion.self, from: datos)
                danada = false
                return config
            } catch {
                danada = true
                try? conservarConfigDanada(datos)
            }
        } catch { danada = true }
        return Configuracion()
    }

    private static func conservarConfigDanada(_ datos: Data) throws {
        // El resumen evita acumular una copia por cada revision del agente.
        let resumen = SHA256.hash(data: datos).prefix(8).map { String(format: "%02x", $0) }.joined()
        let fecha = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let copia = base.appendingPathComponent("config.corrupto-\(fecha)-\(resumen).json")
        if try leerSeguro(copia) != datos { try escribirSeguro(datos, en: copia) }
    }

    static func guardar(_ config: Configuracion) throws {
        candadoConfig.lock()
        defer { candadoConfig.unlock() }
        guard !danada else { throw ErrorIconos("La configuración está dañada; no se sobrescribió.") }
        try conBloqueoArchivo(".bloqueo-config") {
            if let anterior = try leerSeguro(archivoConfig), !anterior.isEmpty {
                if (try? JSONDecoder().decode(Configuracion.self, from: anterior)) == nil {
                    danada = true
                    try conservarConfigDanada(anterior)
                    throw ErrorIconos("La configuración está dañada; no se sobrescribió.")
                }
                try escribirSeguro(anterior, en: base.appendingPathComponent("config.json.bak"))
            }
            let codificador = JSONEncoder()
            codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
            try escribirSeguro(codificador.encode(config), en: archivoConfig)
            danada = false
        }
    }

    /// Archivos propios: sin enlaces, escritura atomica y bloqueo que falla de forma cerrada.
    /// El descriptor del padre evita seguir un enlace colocado entre la comprobacion y el rename.
    static func directorioSeguro(_ url: URL, crear: Bool = false) throws -> Int32 {
        // Se resuelve solo la base de datos (o su antecesor existente), no sus archivos.
        // Despues, cada componente se abre con O_NOFOLLOW para rechazar cambios de enlaces.
        let ruta: String
        if url.path == base.path || url.path.hasPrefix(base.path + "/") {
            ruta = try baseReal(base).path + String(url.path.dropFirst(base.path.count))
        } else { ruta = url.path }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for parte in ruta.split(separator: "/") {
            var siguiente = openat(fd, String(parte), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if siguiente < 0, errno == ENOENT, crear {
                if mkdirat(fd, String(parte), 0o700) == 0 || errno == EEXIST {
                    siguiente = openat(fd, String(parte), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            let codigo = errno
            close(fd)
            guard siguiente >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: codigo) ?? .EIO) }
            fd = siguiente
        }
        return fd
    }

    private static func baseReal(_ url: URL) throws -> URL {
        if let real = realpath(url.path, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real), isDirectory: true)
        }
        let codigo = errno
        guard codigo == ENOENT, url.path != "/" else {
            throw POSIXError(POSIXErrorCode(rawValue: codigo) ?? .EIO)
        }
        return try baseReal(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    static func leerSeguro(_ url: URL) throws -> Data? {
        let padre: Int32
        do { padre = try directorioSeguro(url.deletingLastPathComponent()) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        defer { close(padre) }
        let fd = openat(padre, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        return try leerRegular(fd)
    }

    static func leerRegular(_ fd: Int32) throws -> Data {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
              st.st_size >= 0, st.st_size <= 64 * 1024 * 1024 else {
            throw ErrorIconos("El archivo no es regular o es demasiado grande.")
        }
        var datos = Data(count: Int(st.st_size))
        var leidos = 0
        while leidos < datos.count {
            let n = datos.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: leidos), $0.count - leidos) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw ErrorIconos("No se pudo leer el archivo completo.") }
            leidos += n
        }
        return datos
    }

    static func escribirSeguro(_ datos: Data, en url: URL) throws {
        let padre = try directorioSeguro(url.deletingLastPathComponent(), crear: true)
        defer { close(padre) }
        let temporal = ".iconos-" + UUID().uuidString
        let fd = openat(padre, temporal, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlinkat(padre, temporal, 0) }
        var escritos = 0
        while escritos < datos.count {
            let n = datos.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: escritos), $0.count - escritos) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            escritos += n
        }
        guard fsync(fd) == 0, renameat(padre, temporal, padre, url.lastPathComponent) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func conBloqueoArchivo<T>(_ nombre: String, _ trabajo: () throws -> T) throws -> T {
        let padre = try directorioSeguro(base, crear: true)
        defer { close(padre) }
        let fd = openat(padre, nombre, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
              flock(fd, LOCK_EX) == 0 else { throw ErrorIconos("No se pudo bloquear el archivo de datos.") }
        defer { flock(fd, LOCK_UN) }
        return try trabajo()
    }

    /// Bloqueo entre procesos (ventana, agente, linea de comandos): leer la configuracion y tocar los
    /// iconos va junto, para que restaurar no se cruce con el agente poniendo el icono otra vez.
    /// No se puede anidar
    static func conBloqueo<T>(_ trabajo: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fd = open(base.appendingPathComponent(".bloqueo").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try trabajo()
    }

    /// El agente lo toca en cada revision; la ventana mira la fecha para saber si responde
    static let latido = base.appendingPathComponent("agente.latido")

    static func latir() {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: latido.path, contents: Data("\(getpid())\n".utf8))
    }

    /// Carpeta de cada app: nombre legible y un resumen de la ruta (dos apps pueden llamarse igual)
    static func carpeta(_ ruta: String) -> URL {
        let nombre = URL(fileURLWithPath: ruta).deletingPathExtension().lastPathComponent
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }
        let resumen = SHA256.hash(data: Data(ruta.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("Apps/\(nombre) \(resumen)", isDirectory: true)
    }

    static func icns(_ ruta: String, _ v: Variante) -> URL { carpeta(ruta).appendingPathComponent("\(v.rawValue).icns") }
    /// Imagen propia; la de borrador es la elegida en la ventana y aun sin aplicar
    static func propia(_ ruta: String, _ v: Variante, borrador: Bool = false) -> URL {
        carpeta(ruta).appendingPathComponent(borrador ? "propia-\(v.rawValue).borrador.png" : "propia-\(v.rawValue).png")
    }
    static func original(_ ruta: String) -> URL { carpeta(ruta).appendingPathComponent("original.png") }

    /// Al aplicar, las imagenes de borrador pasan a ser las propias
    static func confirmarPropias(_ ruta: String) throws {
        for v in Variante.allCases {
            let borrador = propia(ruta, v, borrador: true)
            guard FileManager.default.fileExists(atPath: borrador.path) else { continue }
            guard rename(borrador.path, propia(ruta, v).path) == 0 else {
                throw v == .claro ? ErrorIconos("No se pudo guardar la imagen clara") : ErrorIconos("No se pudo guardar la imagen oscura")
            }
        }
    }

    static func descartarPropias(_ ruta: String) {
        for v in Variante.allCases { try? FileManager.default.removeItem(at: propia(ruta, v, borrador: true)) }
    }

    static func quitarPropias(_ ruta: String) {
        for v in Variante.allCases {
            try? FileManager.default.removeItem(at: propia(ruta, v))
            try? FileManager.default.removeItem(at: propia(ruta, v, borrador: true))
        }
    }

    // MARK: Apps

    /// La migracion ACL y la lista usan exactamente las mismas carpetas y profundidad.
    static func rutasEscaneadas(_ config: Configuracion) -> [String] {
        let fm = FileManager.default
        let carpetas = ["/Applications", "/Applications/Utilities",
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] + config.carpetasExtra
        var rutas = Set<String>()
        for carpeta in carpetas {
            guard let nombres = try? fm.contentsOfDirectory(atPath: carpeta) else { continue }
            for nombre in nombres where !nombre.hasPrefix(".") {
                let ruta = (carpeta as NSString).appendingPathComponent(nombre)
                if nombre.hasSuffix(".app") { rutas.insert(ruta) }
                else if carpeta != "/Applications/Utilities", let dentro = try? fm.contentsOfDirectory(atPath: ruta) {
                    for app in dentro where app.hasSuffix(".app") {
                        rutas.insert((ruta as NSString).appendingPathComponent(app))
                    }
                }
            }
        }
        return rutas.sorted()
    }

    static func escanear() -> [AppEncontrada] {
        let fm = FileManager.default
        let rutas = rutasEscaneadas(cargar())
        // Una sola reconciliacion por escaneo; escribible() no toca el registro.
        try? Aplicador.confirmarPermisos(rutasEscaneadas: rutas)
        var salida: [AppEncontrada] = []
        for ruta in rutas {
            let sistema = Aplicador.esDelSistema(ruta)
            guard sistema || (try? Aplicador.validar(ruta, bundleId: nil)) != nil else { continue }
            let info = NSDictionary(contentsOf: URL(fileURLWithPath: ruta).appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            let id = info?["CFBundleIdentifier"] as? String
            guard id == nil || id != Bundle.main.bundleIdentifier else { continue }
            let nombre = (fm.displayName(atPath: ruta) as NSString).deletingPathExtension
            salida.append(AppEncontrada(ruta: ruta, nombre: nombre, escribible: !sistema && Aplicador.escribible(ruta),
                                        personalizado: Aplicador.tieneIconoPersonalizado(ruta),
                                        sistema: sistema, bloqueada: Aplicador.bloqueadaPorFabricante(ruta),
                                        bundleId: id, puesta: Aplicador.variantePuesta(ruta)))
        }
        return salida.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }

    /// Icono original de la app: el que trae el bundle (Iconos solo escribe Icon\r, el icns y el
    /// Assets.car siguen intactos), el que se guardo antes del primer cambio o, si no tiene icono
    /// personalizado, el que muestra el sistema
    static func arteOriginal(_ ruta: String) -> CGImage? {
        if let fuente = fuenteBundle(ruta), let cg = mejor(fuente.imagen) { return cg }
        if let guardada = Lienzo.leerImagen(original(ruta)) { return guardada }
        if !Aplicador.tieneIconoPersonalizado(ruta) { return mejor(NSWorkspace.shared.icon(forFile: ruta)) }
        return nil
    }

    /// Lado en pixeles de la mejor representacion del icono del bundle (0 si no trae)
    static func fuentePx(_ ruta: String) -> Int { fuenteBundle(ruta)?.px ?? 0 }

    /// Donde esta el icono del bundle, leido del Info.plist en disco (Bundle guarda el de la primera
    /// lectura y el agente corre dias). La clave cambia si cambian el icns o el Assets.car
    struct IconoBundle {
        var icns: URL?
        var catalogo: String?
        var claveCatalogo: String
        var clave: String
    }

    static func iconoBundle(_ ruta: String) -> IconoBundle {
        let url = URL(fileURLWithPath: ruta)
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            ?? Bundle(path: ruta)?.infoDictionary ?? [:]
        var icns: URL?
        if var nombre = info["CFBundleIconFile"] as? String, !nombre.isEmpty {
            if (nombre as NSString).pathExtension.isEmpty { nombre += ".icns" }
            icns = url.appendingPathComponent("Contents/Resources/\(nombre)")
        }
        let catalogo = (info["CFBundleIconName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        func sello(_ archivo: URL?) -> String {
            guard let archivo, let a = try? FileManager.default.attributesOfItem(atPath: archivo.path),
                  let fecha = a[.modificationDate] as? Date else { return "-" }
            return String(format: "%.3f/%llu", fecha.timeIntervalSince1970, (a[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        let claveCatalogo = (catalogo ?? "") + "|" + sello(url.appendingPathComponent("Contents/Resources/Assets.car"))
        let clave = ruta + "|" + (icns?.lastPathComponent ?? "") + "|" + sello(icns) + "|" + claveCatalogo
        return IconoBundle(icns: icns, catalogo: catalogo, claveCatalogo: claveCatalogo, clave: clave)
    }

    /// El icono del bundle con mas pixeles entre el icns y el del catalogo (muchos icns solo llegan a
    /// 256 y el Assets.car trae 1024). A igual tamano, el icns
    static func fuenteBundle(_ ruta: String) -> (imagen: NSImage, px: Int)? {
        fuenteBundle(ruta, iconoBundle(ruta))
    }

    static func fuenteBundle(_ ruta: String, _ i: IconoBundle) -> (imagen: NSImage, px: Int)? {
        var elegida: (imagen: NSImage, px: Int)?
        if let icns = i.icns, let imagen = NSImage(contentsOf: icns) {
            let px = pixeles(imagen)
            if px > 0 { elegida = (imagen, px) }
        }
        if let nombre = i.catalogo, let imagen = bundleCatalogo(ruta, clave: i.claveCatalogo)?.image(forResource: nombre) {
            let px = pixeles(imagen)
            if px > (elegida?.px ?? 0) { elegida = (imagen, px) }
        }
        return elegida
    }

    /// Lado de la representacion mas grande; las vectoriales (sin pixeles) valen como 1024
    private static func pixeles(_ imagen: NSImage) -> Int {
        imagen.representations.map { r in
            r.pixelsWide <= 0 || r.pixelsHigh <= 0 ? Int(Lienzo.lado) : max(r.pixelsWide, r.pixelsHigh)
        }.max() ?? 0
    }

    /// Bundle(path:) y las imagenes del catalogo quedan en cache del proceso (por ruta y por
    /// identificador del bundle) y no ven un Assets.car nuevo. La primera vez se usa el bundle real;
    /// si el catalogo cambio despues, una copia temporal con otro identificador
    private static var catalogos: [String: (clave: String, bundle: Bundle, copia: URL?)] = [:]
    private static let candadoCatalogos = NSLock()
    static let carpetaCatalogos = FileManager.default.temporaryDirectory.appendingPathComponent("Iconos-catalogos", isDirectory: true)

    private static func bundleCatalogo(_ ruta: String, clave: String) -> Bundle? {
        candadoCatalogos.lock()
        defer { candadoCatalogos.unlock() }
        if let c = catalogos[ruta], c.clave == clave { return c.bundle }
        guard let anterior = catalogos[ruta] else {
            guard let b = Bundle(path: ruta) else { return nil }
            catalogos[ruta] = (clave, b, nil)
            return b
        }
        let fm = FileManager.default
        let car = URL(fileURLWithPath: ruta).appendingPathComponent("Contents/Resources/Assets.car")
        let copia = carpetaCatalogos.appendingPathComponent("\(UUID().uuidString).app", isDirectory: true)
        do {
            guard var info = NSDictionary(contentsOf: URL(fileURLWithPath: ruta).appendingPathComponent("Contents/Info.plist"))
                as? [String: Any] else { throw ErrorIconos("Sin Info.plist") }
            info["CFBundleIdentifier"] = "\(Identidad.app).lectura.\(UUID().uuidString)"
            try fm.createDirectory(at: copia.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: copia.appendingPathComponent("Contents/Info.plist"))
            // En APFS la copia es un clon: no duplica los datos
            try fm.copyItem(at: car, to: copia.appendingPathComponent("Contents/Resources/Assets.car"))
            guard let b = Bundle(path: copia.path) else { throw ErrorIconos("Sin bundle") }
            if let vieja = anterior.copia { try? fm.removeItem(at: vieja) }
            catalogos[ruta] = (clave, b, copia)
            return b
        } catch {
            try? fm.removeItem(at: copia)
            // Sin Assets.car (o sin poder copiarlo) queda el bundle de antes
            catalogos[ruta] = (clave, anterior.bundle, anterior.copia)
            return anterior.bundle
        }
    }

    /// Rasteriza a 1024 con apariencia clara: con el estilo de iconos oscuro de macOS 26, el icono del
    /// sistema y los de catalogo salen tintados si se dibujan en modo oscuro
    /// El icono de la app ya trae variante oscura (Icon Composer o catalogo con apariencia oscura) y
    /// macOS lo cambia solo. Se mira el Assets.car con assetutil; el resultado se guarda por fecha del
    /// catalogo porque leerlo tarda
    static func tieneOscuroPropio(_ ruta: String) -> Bool {
        guard let nombre = Bundle(path: ruta)?.infoDictionary?["CFBundleIconName"] as? String else { return false }
        let car = ruta + "/Contents/Resources/Assets.car"
        guard let fecha = (try? FileManager.default.attributesOfItem(atPath: car))?[.modificationDate] as? Date else { return false }
        let clave = ruta + "|" + String(Int(fecha.timeIntervalSince1970))
        var guardado = (try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: archivoOscuroPropio))) ?? [:]
        if let valor = guardado[clave] { return valor }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/assetutil")
        p.arguments = ["--info", car]
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let datos = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lista = (try? JSONSerialization.jsonObject(with: datos)) as? [[String: Any]] ?? []
        let valor = lista.contains { r in
            guard let n = r["Name"] as? String, n == nombre || n == nombre + "/Group" else { return false }
            let apariencia = r["Appearance"] as? String
            return apariencia == "NSAppearanceNameDarkAqua" || apariencia == "UIAppearanceDark"
        }
        guardado = guardado.filter { !$0.key.hasPrefix(ruta + "|") }
        guardado[clave] = valor
        try? JSONEncoder().encode(guardado).write(to: archivoOscuroPropio, options: .atomic)
        return valor
    }

    static let archivoOscuroPropio = base.appendingPathComponent("oscuro-propio.json")

    static func mejor(_ imagen: NSImage) -> CGImage? {
        // Se dibuja en un lienzo de 1024 px: cgImage(forProposedRect:) devolvia la representacion de 256
        // de muchos icns y el logo salia ampliado y borroso
        rasterizar(imagen, lado: Int(Lienzo.lado))?.makeImage()
    }

    /// Dibuja la imagen en un lienzo RGBA de n x n sin relleno entre filas (la huella lee los bytes)
    static func rasterizar(_ imagen: NSImage, lado n: Int) -> CGContext? {
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: Lienzo.espacio,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.clear(CGRect(x: 0, y: 0, width: n, height: n))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            imagen.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        return c
    }

    // MARK: Generar

    /// Imagen completa (1024) de una variante: la propia si la hay (con borrador, la elegida sin
    /// aplicar primero), si no la ficha con el logo
    static func imagen(_ g: Gestionada, _ v: Variante, arte: CGImage?, borrador: Bool = false) -> CGImage? {
        if g.propia, let propia = (borrador ? Lienzo.leerImagen(propia(g.ruta, v, borrador: true)) : nil)
            ?? Lienzo.leerImagen(propia(g.ruta, v)) {
            return Lienzo.escalar(propia, a: Int(Lienzo.lado))
        }
        guard let arte else { return Lienzo.renderizar(logo: nil, variante: v, escala: 0.62) }
        if g.ajustes.estilo == .completo {
            let logo = Lienzo.preparar(arte, quitarBlanco: g.ajustes.quitarBlanco.aplica(v))
            return Lienzo.renderizar(logo: logo, variante: v, escala: 0.62 * g.ajustes.tamano)
        }
        let x = Extractor.extraer(arte, app: g.ruta)
        return Lienzo.renderizar(logo: v == .claro ? x.light : x.dark, variante: v, escala: 0.62,
                                 destino: Extractor.marco(x, tamano: g.ajustes.tamano))
    }

    /// Guarda el original (antes de poner el icono) y genera los dos icns; con borrador, desde las
    /// imagenes propias aun sin confirmar
    static func generar(_ g: Gestionada, arte: CGImage?, borrador: Bool = false) throws {
        try Aplicador.validar(g.ruta, bundleId: g.bundleId)
        let fm = FileManager.default
        try fm.createDirectory(at: carpeta(g.ruta), withIntermediateDirectories: true)
        if let arte, !fm.fileExists(atPath: original(g.ruta).path) {
            try Lienzo.escribirPNG(arte, en: original(g.ruta))
        }
        for v in Variante.allCases {
            guard let img = imagen(g, v, arte: arte, borrador: borrador) else { throw ErrorIconos("No se pudo dibujar la variante \(v.nombre)") }
            try Lienzo.escribirICNS(img, en: icns(g.ruta, v))
        }
    }

    static func oscuroAhora() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
