import AppKit
import CryptoKit

// Contrato comun entre la extraccion, el agente y la ventana. Los tipos son fijos; las funciones de
// Almacen de este archivo las mantiene quien mantiene Almacen.

/// Que tan fiable es el logo que salio de la extraccion
enum Confianza: String, Codable, CaseIterable, Comparable {
    case baja, media, alta

    private var orden: Int { switch self { case .baja: 0; case .media: 1; case .alta: 2 } }
    static func < (a: Confianza, b: Confianza) -> Bool { a.orden < b.orden }

    var titulo: String {
        switch self {
        case .alta: String(localized: "Logo fiable")
        case .media: String(localized: "Revisa el logo")
        case .baja: String(localized: "El logo no salió bien")
        }
    }

    /// Para la linea de comandos (rawValue es la clave guardada)
    var nombre: String {
        switch self {
        case .alta: String(localized: "alta")
        case .media: String(localized: "media")
        case .baja: String(localized: "baja")
        }
    }
}

/// Como salio el logo de una app, para mostrarlo en la ventana
struct Diagnostico: Equatable {
    /// "capas del icono", "extracción por píxeles", "icono completo", "imágenes propias"
    var metodo: String
    var confianza: Confianza
    var motivos: [String]
    /// Lado en pixeles de la mejor representacion del icono del bundle (0 si no hay)
    var fuentePx: Int

    /// El metodo para mostrarlo: metodo es una clave interna que se compara en el codigo y se guarda
    static func titulo(metodo: String) -> String {
        switch metodo {
        case "capas del icono": String(localized: "capas del icono")
        case "extracción por píxeles": String(localized: "extracción por píxeles")
        case "icono completo": String(localized: "icono completo")
        case "imágenes propias": String(localized: "imágenes propias")
        case "sin icono propio": String(localized: "sin icono propio")
        default: metodo
        }
    }

    /// Los motivos del extractor son textos fijos en español (Extractor.swift lo comparte el banco de
    /// pruebas): se traducen aqui, al armar el diagnostico
    static func texto(motivo: String) -> String {
        switch motivo {
        case "dibujo de plantilla sin ficha": String(localized: "dibujo de plantilla sin ficha")
        case "dibujo con marco cerrado": String(localized: "dibujo con marco cerrado")
        case "el icono no tiene contenido opaco": String(localized: "el icono no tiene contenido opaco")
        case "fondo no separable con confianza": String(localized: "fondo no separable con confianza")
        case "silueta libre sin ficha": String(localized: "silueta libre sin ficha")
        case "emblema circular unido; se conserva el aro": String(localized: "emblema circular unido; se conserva el aro")
        case "fondo circular anidado": String(localized: "fondo circular anidado")
        case "ficha demasiado pequeña": String(localized: "ficha demasiado pequeña")
        case "extracción vacía; se conserva el arte": String(localized: "extracción vacía; se conserva el arte")
        case "logo cerca del borde; puede quedar parte del aro": String(localized: "logo cerca del borde; puede quedar parte del aro")
        case "glifo de marca con votación dudosa": String(localized: "glifo de marca con votación dudosa")
        case "ficha separada con confianza": String(localized: "ficha separada con confianza")
        case "el logo ocupa casi todo el icono": String(localized: "el logo ocupa casi todo el icono")
        case "logo separado por capas": String(localized: "logo separado por capas")
        default: motivo
        }
    }
}

/// Algo que el usuario tiene que resolver. Lo anota el agente (o la ventana) y lo muestra la ventana
struct Pendiente: Codable, Equatable, Identifiable {
    enum Motivo: String, Codable {
        /// Se actualizo y el bundle nuevo ya no tiene el permiso de Iconos
        case sinPermiso
        /// El fabricante cambio su icono y se regenero el logo
        case iconoNuevo
        /// El fabricante cambio su icono pero el logo nuevo salio con confianza baja: se dejo el anterior
        case revisar
    }

    var ruta: String
    var nombre: String
    var motivo: Motivo
    var fecha = Date()

    var id: String { ruta + "|" + motivo.rawValue }
}

extension Almacen {
    static let archivoPendientes = base.appendingPathComponent("pendientes.json")

    // MARK: Pendientes

    /// Bloqueo propio de pendientes.json: se puede tomar dentro de conBloqueo (el agente anota
    /// mientras revisa)
    private static func conBloqueoPendientes<T>(crear: Bool = false, _ trabajo: () -> T) -> T {
        if crear { try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
        let flags = O_RDWR | O_CLOEXEC | (crear ? O_CREAT : 0)
        let fd = open(base.appendingPathComponent(".bloqueo-pendientes").path, flags, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return trabajo()
    }

    private static func leerPendientes() -> [Pendiente] {
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        guard let datos = try? Data(contentsOf: archivoPendientes),
              let lista = try? decodificador.decode([Pendiente].self, from: datos) else { return [] }
        return lista
    }

    private static func escribirPendientes(_ lista: [Pendiente]) {
        let codificador = JSONEncoder()
        codificador.dateEncodingStrategy = .iso8601
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? codificador.encode(lista).write(to: archivoPendientes, options: .atomic)
    }

    /// Lista guardada en pendientes.json (vacia si no hay)
    static func pendientes() -> [Pendiente] { conBloqueoPendientes { leerPendientes() } }

    /// Anota o reemplaza el pendiente con la misma ruta y motivo. Devuelve true si es nuevo (para
    /// notificar solo una vez)
    @discardableResult
    static func anotarPendiente(_ p: Pendiente) -> Bool {
        conBloqueoPendientes(crear: true) {
            var lista = leerPendientes()
            if let i = lista.firstIndex(where: { $0.ruta == p.ruta && $0.motivo == p.motivo }) {
                var nuevo = p
                nuevo.fecha = lista[i].fecha
                guard lista[i] != nuevo else { return false }
                lista[i] = nuevo
                escribirPendientes(lista)
                return false
            }
            lista.append(p)
            escribirPendientes(lista)
            return true
        }
    }

    /// Quita los pendientes de una app (de un motivo, o todos)
    static func resolverPendiente(ruta: String, motivo: Pendiente.Motivo? = nil) {
        conBloqueoPendientes {
            let lista = leerPendientes()
            let quedan = lista.filter { !($0.ruta == ruta && (motivo == nil || $0.motivo == motivo)) }
            if quedan.count != lista.count { escribirPendientes(quedan) }
        }
    }

    // MARK: Huella

    private static var huellas: [String: (clave: String, huella: String?)] = [:]
    private static let candadoHuellas = NSLock()

    /// Huella del icono que trae el bundle: cambia si el fabricante cambia su icono. SHA256 del icono
    /// dibujado a 128 px (la misma fuente que arteOriginal, sin original.png). Se guarda en memoria por
    /// fecha y tamano del icns y del Assets.car: el agente la pide cada minuto
    static func huellaIcono(_ ruta: String) -> String? {
        let i = iconoBundle(ruta)
        candadoHuellas.lock()
        if let h = huellas[ruta], h.clave == i.clave {
            candadoHuellas.unlock()
            return h.huella
        }
        candadoHuellas.unlock()
        var huella: String?
        if let fuente = fuenteBundle(ruta, i), let c = rasterizar(fuente.imagen, lado: 128), let datos = c.data {
            let bytes = Data(bytes: datos, count: c.bytesPerRow * c.height)
            huella = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        candadoHuellas.lock()
        huellas[ruta] = (i.clave, huella)
        candadoHuellas.unlock()
        return huella
    }

    /// Completa bundleId, version y huella de una gestionada al aplicar
    static func sellar(_ g: Gestionada) -> Gestionada {
        guard FileManager.default.fileExists(atPath: g.ruta) else { return g }
        var g = g
        // Del Info.plist en disco: Bundle(path:) guarda la version de la primera lectura
        let info = NSDictionary(contentsOf: URL(fileURLWithPath: g.ruta).appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        g.bundleId = info?["CFBundleIdentifier"] as? String ?? Bundle(path: g.ruta)?.bundleIdentifier ?? g.bundleId
        g.version = info?["CFBundleShortVersionString"] as? String
            ?? Bundle(path: g.ruta)?.infoDictionary?["CFBundleShortVersionString"] as? String
        g.huella = huellaIcono(g.ruta)
        return g
    }

    // MARK: Diagnostico

    /// Como sale el logo de una gestionada con su arte
    static func diagnostico(_ g: Gestionada, arte: CGImage?) -> Diagnostico {
        let px = fuentePx(g.ruta)
        if g.propia { return Diagnostico(metodo: "imágenes propias", confianza: .alta, motivos: [], fuentePx: px) }
        // Sin icono en el bundle, arteOriginal da el original guardado o el generico del sistema
        guard let arte, px > 0 else {
            return Diagnostico(metodo: "sin icono propio", confianza: .baja, motivos: [String(localized: "La app no trae icono propio")], fuentePx: px)
        }
        if g.ajustes.estilo == .completo { return Diagnostico(metodo: "icono completo", confianza: .alta, motivos: [], fuentePx: px) }
        let x = Extractor.extraer(arte, app: g.ruta)
        var confianza = x.confianza
        // Los motivos salen ya traducidos; metodo sigue siendo la clave interna
        var motivos = x.motivos.map(Diagnostico.texto(motivo:))
        // Las capas se dibujan del catalogo a 1024 aunque el icono plano del bundle sea pequeno
        if px < 512, x.mode != "capas del icono" {
            confianza = min(confianza, px < 256 ? .baja : .media)
            motivos.append(String(localized: "Icono de baja resolución (\(px) px)"))
        }
        return Diagnostico(metodo: x.mode == "capas del icono" ? "capas del icono" : "extracción por píxeles",
                           confianza: confianza, motivos: motivos, fuentePx: px)
    }

    // MARK: Restaurar y reubicar

    static let fuentes = base.appendingPathComponent("Fuentes", isDirectory: true)

    private static func avisarAgente() {
        DistributedNotificationCenter.default().postNotificationName(aviso, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Nombre de carpeta sin barras ni caracteres raros
    private static func nombreSeguro(_ nombre: String) -> String {
        let limpio = nombre.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " || $0 == "." }
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return limpio.isEmpty ? "App" : limpio
    }

    /// Nunca reemplaza un archivo o una carpeta ya conservados.
    private static func sinColision(_ url: URL) -> URL {
        var destino = url
        var sufijo = 2
        while (try? FileManager.default.attributesOfItem(atPath: destino.path)) != nil {
            let extensionArchivo = url.hasDirectoryPath ? "" : url.pathExtension
            let nombre = extensionArchivo.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            destino = url.deletingLastPathComponent().appendingPathComponent("\(nombre) \(sufijo)")
            if !extensionArchivo.isEmpty { destino.appendPathExtension(extensionArchivo) }
            sufijo += 1
        }
        return destino
    }

    /// Restaura todas las gestionadas (con el bloqueo) y las quita de la configuracion. Con
    /// conservarPropias, las imagenes propias pasan a Fuentes/ en vez de borrarse. Devuelve los
    /// errores como "Nombre: mensaje". Las que no se pudieron restaurar siguen en la configuracion
    static func restaurarTodas(conservarPropias: Bool) -> [String] {
        let fm = FileManager.default
        var errores: [String] = []
        var enDock = false
        conBloqueo {
            var config = cargar()
            guard !configDanada else { errores.append(String(localized: "La configuración está dañada o no se puede leer; no se restauró ninguna app.")); return }
            for g in config.apps {
                if fm.fileExists(atPath: g.ruta) {
                    do {
                        try Aplicador.validar(g.ruta, bundleId: g.bundleId)
                        try Aplicador.restaurar(g.ruta)
                    } catch {
                        errores.append("\(g.nombre): \(error.localizedDescription)")
                        continue
                    }
                    if config.reiniciarDock, Aplicador.estaEnDock(g.ruta) { enDock = true }
                }
                if conservarPropias {
                    let resumen = SHA256.hash(data: Data(g.ruta.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                    let destino = sinColision(fuentes.appendingPathComponent("\(nombreSeguro(g.nombre)) \(resumen)", isDirectory: true))
                    do {
                        // Copiar: si falla el archivado o el guardado, los originales siguen intactos.
                        for v in Variante.allCases where fm.fileExists(atPath: propia(g.ruta, v).path) {
                            try fm.createDirectory(at: destino, withIntermediateDirectories: true)
                            let archivo = destino.appendingPathComponent(propia(g.ruta, v).lastPathComponent)
                            try fm.copyItem(at: propia(g.ruta, v), to: archivo)
                        }
                    } catch {
                        // destino es nuevo (sinColision): no queda una copia a medias en Fuentes
                        try? fm.removeItem(at: destino)
                        errores.append(String(localized: "\(g.nombre): no se pudieron conservar las imágenes propias (\(error.localizedDescription))"))
                        continue
                    }
                }
                var siguiente = config
                siguiente.apps.removeAll { $0.ruta == g.ruta }
                do {
                    try guardar(siguiente)
                } catch {
                    errores.append(String(localized: "\(g.nombre): no se pudo guardar la configuración (\(error.localizedDescription))"))
                    continue
                }
                config = siguiente
                do {
                    if fm.fileExists(atPath: carpeta(g.ruta).path) { try fm.removeItem(at: carpeta(g.ruta)) }
                } catch {
                    errores.append(String(localized: "\(g.nombre): no se pudieron borrar los iconos guardados (\(error.localizedDescription))"))
                }
                resolverPendiente(ruta: g.ruta)
            }
        }
        if enDock {
            // Margen para que IconServices vea el icono restaurado antes de que el Dock lo pida
            Thread.sleep(forTimeInterval: 1)
            Aplicador.refrescarDock()
        }
        avisarAgente()
        return errores
    }

    /// Gestionadas cuya ruta ya no existe pero cuyo bundleId aparece en otra ruta escaneada (que no
    /// este ya gestionada)
    static func reubicables(_ apps: [AppEncontrada], _ config: Configuracion) -> [(vieja: String, nueva: String)] {
        let gestionadas = Set(config.apps.map(\.ruta))
        var usadas = Set<String>()
        var salida: [(vieja: String, nueva: String)] = []
        for g in config.apps {
            guard let id = g.bundleId, !FileManager.default.fileExists(atPath: g.ruta),
                  let nueva = apps.first(where: {
                      $0.bundleId == id && $0.ruta != g.ruta && !gestionadas.contains($0.ruta) && !usadas.contains($0.ruta)
                  }) else { continue }
            usadas.insert(nueva.ruta)
            salida.append((g.ruta, nueva.ruta))
        }
        return salida
    }

    /// Pasa los ajustes y las imagenes de una ruta vieja a la nueva
    static func reubicar(vieja: String, nueva: String) throws {
        let fm = FileManager.default
        try conBloqueo {
            var config = cargar()
            guard let i = config.apps.firstIndex(where: { $0.ruta == vieja }) else {
                throw ErrorIconos("La app ya no está en la lista de Iconos.")
            }
            guard !config.apps.contains(where: { $0.ruta == nueva }) else {
                throw ErrorIconos("La app de la ruta nueva ya tiene su icono en Iconos.")
            }
            guard !fm.fileExists(atPath: vieja) else { throw ErrorIconos("La app de la ruta anterior todavía existe.") }
            try Aplicador.validar(nueva, bundleId: config.apps[i].bundleId)
            guard !configDanada else { throw ErrorIconos("La configuración está dañada; no se reubicó la app.") }
            let origen = carpeta(vieja), destino = carpeta(nueva)
            let apartada = base.appendingPathComponent(".reubicar-" + UUID().uuidString, isDirectory: true)
            var movida = false, habiaDestino = false
            do {
                if fm.fileExists(atPath: origen.path) {
                    if fm.fileExists(atPath: destino.path) {
                        // Una copia residual de una reubicacion antigua solo se sustituye
                        // si su respaldo identifica al mismo bundle validado en la ruta nueva.
                        struct IdentidadRespaldo: Decodable { var bundleId: String? }
                        guard let id = config.apps[i].bundleId,
                              let datos = try leerSeguro(destino.appendingPathComponent("icono-previo.json")),
                              try JSONDecoder().decode(IdentidadRespaldo.self, from: datos).bundleId == id else {
                            throw ErrorIconos("La ruta nueva tiene datos de identidad desconocida; no se sobrescribieron.")
                        }
                        try fm.moveItem(at: destino, to: apartada)
                        habiaDestino = true
                    }
                    try fm.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // El respaldo viaja con el bundle. Mover permite volver de B a A.
                    try fm.moveItem(at: origen, to: destino)
                    movida = true
                }
                config.apps[i].ruta = nueva
                config.apps[i].nombre = (fm.displayName(atPath: nueva) as NSString).deletingPathExtension
                try guardar(config)
            } catch {
                do {
                    if movida { try fm.moveItem(at: destino, to: origen) }
                    if habiaDestino { try fm.moveItem(at: apartada, to: destino) }
                } catch let deshacer {
                    throw ErrorIconos("No se pudo deshacer la reubicación. Datos conservados en \(origen.path), \(destino.path) o \(apartada.path): \(deshacer.localizedDescription)")
                }
                throw error
            }
            if habiaDestino { try fm.removeItem(at: apartada) }
            resolverPendiente(ruta: vieja)
        }
        avisarAgente()
    }

    // MARK: Exportar e importar

    private static func ditto(_ argumentos: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = argumentos
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ErrorIconos("ditto falló (\(p.terminationStatus)).") }
    }

    /// Guarda config.json, imagenes propias y Fuentes/ en un .zip
    static func exportar(a url: URL) throws {
        let fm = FileManager.default
        let temporal = fm.temporaryDirectory.appendingPathComponent("iconos-exportar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporal, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporal) }
        try conBloqueo {
            guard fm.fileExists(atPath: archivoConfig.path) else { throw ErrorIconos("No hay nada que exportar todavía.") }
            try fm.copyItem(at: archivoConfig, to: temporal.appendingPathComponent("config.json"))
            let apps = base.appendingPathComponent("Apps", isDirectory: true)
            let nombres = fm.fileExists(atPath: apps.path) ? try fm.contentsOfDirectory(atPath: apps.path) : []
            for nombre in nombres where !nombre.hasPrefix(".") {
                let carpetaApp = apps.appendingPathComponent(nombre, isDirectory: true)
                for v in Variante.allCases {
                    let archivo = carpetaApp.appendingPathComponent("propia-\(v.rawValue).png")
                    guard fm.fileExists(atPath: archivo.path) else { continue }
                    let destino = temporal.appendingPathComponent("Apps/\(nombre)", isDirectory: true)
                    try fm.createDirectory(at: destino, withIntermediateDirectories: true)
                    try fm.copyItem(at: archivo, to: destino.appendingPathComponent(archivo.lastPathComponent))
                }
            }
            if fm.fileExists(atPath: fuentes.path) {
                try fm.copyItem(at: fuentes, to: temporal.appendingPathComponent("Fuentes", isDirectory: true))
            }
        }
        // -c -k: zip (PKZip); sin --keepParent el zip tiene config.json en la raiz. --norsrc: sin
        // atributos ni ACL. Se comprime al lado del destino y se cambia al final: si ditto falla, el
        // zip anterior sigue
        let parcial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).parcial")
        try? fm.removeItem(at: parcial)
        do {
            try ditto(["-c", "-k", "--norsrc", temporal.path, parcial.path])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: parcial)
            } else {
                try fm.moveItem(at: parcial, to: url)
            }
        } catch {
            try? fm.removeItem(at: parcial)
            throw error
        }
    }

    /// Copia una imagen pasando por CGImage: el zip puede traer cualquier cosa (enlaces, no imagenes)
    private static func copiarImagen(_ origen: URL, a destino: URL) -> Bool {
        guard let valores = try? origen.resourceValues(forKeys: [.isRegularFileKey]), valores.isRegularFile == true,
              let img = Lienzo.leerImagen(origen) else { return false }
        return (try? Lienzo.escribirPNG(img, en: destino)) != nil
    }

    /// Lee un .zip de exportar; devuelve cuantas apps quedaron gestionadas (las rutas que existen).
    /// El agente las aplica al recibir el aviso
    static func importar(de url: URL) throws -> Int {
        let fm = FileManager.default
        let temporal = fm.temporaryDirectory.appendingPathComponent("iconos-importar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporal, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporal) }
        do {
            try ditto(["-x", "-k", url.path, temporal.path])
        } catch {
            throw ErrorIconos("No se pudo abrir el archivo (¿es un .zip exportado por Iconos?).")
        }
        guard let datos = try? Data(contentsOf: temporal.appendingPathComponent("config.json")),
              let traida = try? JSONDecoder().decode(Configuracion.self, from: datos) else {
            throw ErrorIconos("El archivo no tiene una configuración de Iconos válida.")
        }

        var cuantas = 0
        var errores: [String] = []
        let encontradas = escanear()
        // Rutas que ya tienen su propia entrada en el zip: una app movida no se queda con ellas
        let reservadas = Set(traida.apps.map(\.ruta).filter { fm.fileExists(atPath: $0) })
        conBloqueo {
            var config = cargar()
            guard !configDanada else { errores.append(String(localized: "La configuración está dañada o no se puede leer; no se importó ninguna app.")); return }
            var usadas = Set<String>()
            for var g in traida.apps {
                let vieja = g.ruta
                if !fm.fileExists(atPath: g.ruta) {
                    guard let id = g.bundleId, let nueva = encontradas.first(where: {
                        $0.bundleId == id && !reservadas.contains($0.ruta) && !usadas.contains($0.ruta)
                    }) else {
                        errores.append(String(localized: "\(g.nombre): no se encontró la app instalada."))
                        continue
                    }
                    g.ruta = nueva.ruta
                    g.nombre = nueva.nombre
                }
                guard usadas.insert(g.ruta).inserted else {
                    errores.append(String(localized: "\(g.nombre): varias entradas apuntan a la misma app."))
                    continue
                }
                // Mismo volumen que el destino: permite intercambiar carpetas atomicamente.
                let preparada = base.appendingPathComponent(".importar-\(UUID().uuidString)", isDirectory: true)
                var conservarRespaldo = false
                defer { if !conservarRespaldo { try? fm.removeItem(at: preparada) } }
                do {
                    try Aplicador.validar(g.ruta, bundleId: g.bundleId)
                    if let actual = config.apps.first(where: { $0.ruta == g.ruta }) {
                        try Aplicador.validar(g.ruta, bundleId: actual.bundleId)
                    }
                    let destino = carpeta(g.ruta)
                    let existia = fm.fileExists(atPath: destino.path)
                    if existia { try fm.copyItem(at: destino, to: preparada) }
                    else { try fm.createDirectory(at: preparada, withIntermediateDirectories: true) }
                    for v in Variante.allCases {
                        for nombre in ["propia-\(v.rawValue).png", "propia-\(v.rawValue).borrador.png"] {
                            let archivo = preparada.appendingPathComponent(nombre)
                            if fm.fileExists(atPath: archivo.path) { try fm.removeItem(at: archivo) }
                        }
                    }
                    // Buscar con la ruta exportada; guardar bajo la ruta instalada.
                    let traidas = temporal.appendingPathComponent("Apps/\(carpeta(vieja).lastPathComponent)", isDirectory: true)
                    var hayPropias = false
                    for v in Variante.allCases {
                        let nombre = "propia-\(v.rawValue).png"
                        let origen = traidas.appendingPathComponent(nombre)
                        guard (try? fm.attributesOfItem(atPath: origen.path)) != nil else { continue }
                        guard copiarImagen(origen, a: preparada.appendingPathComponent(nombre)) else {
                            throw ErrorIconos("No se pudo importar la imagen \(v.nombre).")
                        }
                        hayPropias = true
                    }
                    if g.propia && !hayPropias { throw ErrorIconos("Faltan las imágenes propias de esta app.") }
                    let arte = arteOriginal(g.ruta)
                    try generarImportacion(g, arte: arte, en: preparada)
                    g = sellar(g)
                    let d = diagnostico(g, arte: arte)
                    g.confianza = d.confianza
                    g.metodo = d.metodo
                    var siguiente = config
                    siguiente.apps.removeAll { $0.ruta == g.ruta }
                    siguiente.apps.append(g)
                    try fm.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let resultado = existia ? renamex_np(preparada.path, destino.path, UInt32(RENAME_SWAP))
                        : renamex_np(preparada.path, destino.path, UInt32(RENAME_EXCL))
                    guard resultado == 0 else { throw ErrorIconos("No se pudieron reemplazar los iconos: \(String(cString: strerror(errno)))") }
                    do {
                        try guardar(siguiente)
                    } catch {
                        let deshacer = existia ? renamex_np(preparada.path, destino.path, UInt32(RENAME_SWAP))
                            : renamex_np(destino.path, preparada.path, UInt32(RENAME_EXCL))
                        if deshacer != 0 {
                            conservarRespaldo = true
                            throw ErrorIconos("Falló el guardado y no se pudo deshacer el reemplazo. Respaldo en \(existia ? preparada.path : destino.path). \(error.localizedDescription)")
                        }
                        throw error
                    }
                    config = siguiente
                    Aplicador.invalidarVariante(g.ruta)
                    cuantas += 1
                } catch {
                    errores.append("\(g.nombre): \(error.localizedDescription)")
                }
            }
            // Las fuentes se validan en provisional y se suman sin sobrescribir.
            let fuentesTraidas = temporal.appendingPathComponent("Fuentes", isDirectory: true)
            if fm.fileExists(atPath: fuentesTraidas.path) {
                do {
                    for nombre in try fm.contentsOfDirectory(atPath: fuentesTraidas.path) where !nombre.hasPrefix(".") {
                        let origen = fuentesTraidas.appendingPathComponent(nombre, isDirectory: true)
                        let preparada = base.appendingPathComponent(".fuentes-\(UUID().uuidString)", isDirectory: true)
                        defer { try? fm.removeItem(at: preparada) }
                        do {
                            try fm.createDirectory(at: preparada, withIntermediateDirectories: true)
                            for archivo in try fm.contentsOfDirectory(atPath: origen.path) where archivo.hasSuffix(".png") {
                                let destino = sinColision(preparada.appendingPathComponent(nombreSeguro((archivo as NSString).deletingPathExtension) + ".png"))
                                guard copiarImagen(origen.appendingPathComponent(archivo), a: destino) else {
                                    throw ErrorIconos("No se pudo importar \(archivo).")
                                }
                            }
                            try fm.createDirectory(at: fuentes, withIntermediateDirectories: true)
                            try fm.moveItem(at: preparada, to: sinColision(fuentes.appendingPathComponent(nombreSeguro(nombre), isDirectory: true)))
                        } catch { errores.append("Fuentes/\(nombre): \(error.localizedDescription)") }
                    }
                } catch { errores.append("Fuentes: \(error.localizedDescription)") }
            }
        }
        if cuantas > 0 { avisarAgente() }
        if !errores.isEmpty {
            throw ErrorIconos(texto: String(localized: "Apps importadas: \(cuantas). No se pudo completar la importación:") + "\n" + errores.joined(separator: "\n"))
        }
        return cuantas
    }

    /// Usa solo las propias preparadas; no altera los archivos de la app gestionada.
    private static func generarImportacion(_ g: Gestionada, arte: CGImage?, en destino: URL) throws {
        let original = destino.appendingPathComponent("original.png")
        if let arte, !FileManager.default.fileExists(atPath: original.path) { try Lienzo.escribirPNG(arte, en: original) }
        var sinPropias = g
        sinPropias.propia = false
        for v in Variante.allCases {
            let propia = destino.appendingPathComponent("propia-\(v.rawValue).png")
            let img: CGImage?
            if g.propia, let fuente = Lienzo.leerImagen(propia) { img = Lienzo.escalar(fuente, a: Int(Lienzo.lado)) }
            else { img = imagen(sinPropias, v, arte: arte) }
            guard let img else { throw ErrorIconos("No se pudo dibujar la variante \(v.nombre).") }
            try Lienzo.escribirICNS(img, en: destino.appendingPathComponent("\(v.rawValue).icns"))
        }
    }

    // MARK: Desinstalar

    /// Solo desinstala tras restaurar sin errores. Con ACL, Terminal termina la limpieza y mueve
    /// la app a la Papelera; sin ACL, la ventana se encarga de mover la app.
    static func desinstalar() -> (errores: [String], terminal: Bool) {
        let fm = FileManager.default
        var errores = restaurarTodas(conservarPropias: false)
        guard errores.isEmpty else { return (errores, false) }
        ServicioAgente.desinstalar()
        let acl: [String]
        do { acl = try Aplicador.permisosRegistrados() }
        catch { return ([error.localizedDescription], false) }
        if !acl.isEmpty {
            do {
                try Aplicador.desinstalarEnTerminal(acl, app: Bundle.main.bundlePath)
                return ([], true)
            } catch {
                return ([error.localizedDescription], false)
            }
        }
        if fm.fileExists(atPath: base.path) {
            do {
                try fm.removeItem(at: base)
            } catch {
                return ([String(localized: "No se pudo borrar la carpeta de datos: \(error.localizedDescription)")], false)
            }
        }
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        do {
            if fm.fileExists(atPath: logs.path) {
                // Tambien el rotado (Iconos-agente.log.1, ver Registro)
                for nombre in try fm.contentsOfDirectory(atPath: logs.path)
                where nombre.hasPrefix("Iconos-agente") && (nombre.hasSuffix(".log") || nombre.hasSuffix(".log.1")) {
                    try fm.removeItem(at: logs.appendingPathComponent(nombre))
                }
            }
        } catch { errores.append(String(localized: "No se pudieron borrar los registros: \(error.localizedDescription)")) }
        try? fm.removeItem(at: carpetaCatalogos)
        return (errores, false)
    }
}
