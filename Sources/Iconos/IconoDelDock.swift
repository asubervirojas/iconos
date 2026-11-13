import Foundation

/// Apps que ponen su propio icono en el Dock mientras estan abiertas: llaman a
/// NSApp.applicationIconImage (eframe/egui en cada arranque; Zoom, Teams, Electron con
/// app.dock.setIcon para avisos o temas) o traen un NSDockTilePlugIn. El icono personalizado es del
/// bundle: Finder, Spotlight y el Dock con la app cerrada lo muestran, pero mientras la app corre el
/// Dock ensena lo que ella dibuja. Otra app no puede impedirlo sin modificarla (escribir en Contents o
/// inyectar codigo), asi que Iconos solo avisa
enum CambioDelDock: String, Codable, Equatable {
    /// Lo redibuja en cada arranque (eframe lo hace siempre en el primer fotograma)
    case siempre
    /// Tiene codigo que lo cambia en algun momento (un aviso, un tema, un estado)
    case aVeces
    /// Declara un NSDockTilePlugIn: dibuja su icono del Dock incluso cerrada
    case dibujaPropio

    var titulo: String {
        switch self {
        case .siempre: String(localized: "Esta app cambia su icono del Dock al abrirse")
        case .aVeces: String(localized: "Esta app puede cambiar su icono del Dock")
        case .dibujaPropio: String(localized: "Esta app dibuja su propio icono del Dock")
        }
    }

    var detalle: String {
        switch self {
        case .siempre:
            String(localized: "Cada vez que se abre, la app pone su propio icono en el Dock. El de Iconos se ve en Finder, Spotlight y en el Dock cuando está cerrada. macOS no deja que otra app lo impida.")
        case .aVeces:
            String(localized: "Mientras está abierta puede poner su propio icono en el Dock (por ejemplo, para mostrar un aviso). Cuando lo haga, verás el suyo hasta que la cierres. En Finder y Spotlight sigue el de Iconos.")
        case .dibujaPropio:
            String(localized: "Trae un complemento que dibuja su icono en el Dock, incluso cerrada. Puede que el Dock no muestre el de Iconos; en Finder y Spotlight sí se ve.")
        }
    }
}

/// Marca que se comparte con el analisis en curso para pararlo cuando se elige otra app
final class Cancelacion: @unchecked Sendable {
    private let candado = NSLock()
    private var valor = false
    var cancelada: Bool { candado.lock(); defer { candado.unlock() }; return valor }
    func cancelar() { candado.lock(); valor = true; candado.unlock() }
}

enum DetectorDock {
    private static let selector = Array("setApplicationIconImage:".utf8)
    private static let eframe = Array("eframe-".utf8)
    private struct Cancelado: Error {}

    private static var cache: [String: (clave: String, cambio: CambioDelDock?)] = [:]
    private static let candado = NSLock()
    /// Una cola serie fuera del pool cooperativo: los analisis leen cientos de MB (Office, Xcode) y no
    /// deben quitarle hilos a las vistas previas. Si se pide dos veces la misma app, la segunda espera
    /// a la primera y sale de la cache
    private static let cola = DispatchQueue(label: "io.github.asubervirojas.iconos.dock", qos: .utility)

    /// Para la ventana: se cancela con la tarea que lo espera (otra app elegida)
    static func analizarEnCola(_ ruta: String) async -> CambioDelDock? {
        let cancelacion = Cancelacion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuacion in
                cola.async { continuacion.resume(returning: analizar(ruta, cancelacion: cancelacion)) }
            }
        } onCancel: {
            cancelacion.cancelar()
        }
    }

    /// Se guarda en memoria por version del bundle y fecha y tamano del ejecutable. Un analisis
    /// cancelado devuelve nil y no se guarda
    static func analizar(_ ruta: String, cancelacion: Cancelacion? = nil) -> CambioDelDock? {
        let contents = URL(fileURLWithPath: ruta).resolvingSymlinksInPath().appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else { return nil }
        let ejecutable = (info["CFBundleExecutable"] as? String).map { contents.appendingPathComponent("MacOS").appendingPathComponent($0) }
        let atributos = ejecutable.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let clave = [info["CFBundleVersion"] as? String ?? "",
                     (atributos?[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? "",
                     (atributos?[.size] as? NSNumber)?.stringValue ?? ""].joined(separator: "|")
        candado.lock()
        if let c = cache[ruta], c.clave == clave {
            candado.unlock()
            return c.cambio
        }
        candado.unlock()
        guard let cambio = try? detectar(contents: contents, info: info, ejecutable: ejecutable, cancelacion) else { return nil }
        candado.lock()
        cache[ruta] = (clave, cambio)
        candado.unlock()
        return cambio
    }

    private static func detectar(contents: URL, info: [String: Any], ejecutable: URL?, _ c: Cancelacion?) throws -> CambioDelDock? {
        if info["NSDockTilePlugIn"] != nil { return .dibujaPropio }
        let fm = FileManager.default
        let recursos = contents.appendingPathComponent("Resources")
        // Electron trae el selector en su framework para app.dock.setIcon: solo cuenta si el JS de la
        // app lo llama. Algunas renombran el framework (ChatGPT), pero traen app.asar o app/
        let esElectron = fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/Electron Framework.framework").path)
            || fm.fileExists(atPath: recursos.appendingPathComponent("app.asar").path)
            || fm.fileExists(atPath: recursos.appendingPathComponent("app/package.json").path)
        if esElectron { return try electronCambiaIcono(recursos, c) ? .aVeces : nil }
        // Rust (objc2) y binarios nativos: el selector solo queda en el binario si se usa
        if let ejecutable {
            var haySelector = false, hayEframe = false
            _ = try recorrer(ejecutable, solape: selector.count, c) { datos in
                if !haySelector { haySelector = contiene(datos, selector) }
                if !hayEframe { hayEframe = contiene(datos, eframe) }
                return haySelector && hayEframe
            }
            if haySelector { return hayEframe ? .siempre : .aVeces }
        }
        // Codigo nativo que se carga en el mismo proceso (frameworks, dylibs, bundles)
        for binario in try bibliotecas(contents, c) {
            if try recorrer(binario, solape: selector.count, c, { contiene($0, selector) }) { return .aVeces }
        }
        return nil
    }

    /// Mach-O de Frameworks y PlugIns que corren dentro del proceso de la app. Las apps, extensiones y
    /// servicios anidados (Sparkle, informes de fallos) son otros procesos y su icono del Dock no es el
    /// de la app. El runtime de Java trae el selector en AWT para todas las apps: no cuenta
    static func bibliotecas(_ contents: URL, _ c: Cancelacion? = nil) throws -> [URL] {
        var salida: [URL] = []
        let claves: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        for carpeta in ["Frameworks", "PlugIns"] {
            guard let recorrido = FileManager.default.enumerator(at: contents.appendingPathComponent(carpeta),
                                                                 includingPropertiesForKeys: claves,
                                                                 errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in recorrido {
                if c?.cancelada == true { throw Cancelado() }
                let ext = url.pathExtension.lowercased()
                if ["app", "appex", "xpc", "jdk", "jre"].contains(ext) || url.lastPathComponent == "runtime" {
                    recorrido.skipDescendants()
                    continue
                }
                guard let v = try? url.resourceValues(forKeys: Set(claves)), v.isRegularFile == true,
                      v.isSymbolicLink != true, esMachO(url) else { continue }
                salida.append(url)
            }
        }
        return salida
    }

    /// app.dock.setIcon( o app.dock?.setIcon( en el JS de la app (app.asar, app.asar.unpacked o app/)
    private static func electronCambiaIcono(_ recursos: URL, _ c: Cancelacion?) throws -> Bool {
        var archivos = [recursos.appendingPathComponent("app.asar")]
        for carpeta in ["app.asar.unpacked", "app"] {
            guard let recorrido = FileManager.default.enumerator(at: recursos.appendingPathComponent(carpeta),
                                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                                 errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in recorrido where ["js", "cjs", "mjs"].contains(url.pathExtension.lowercased()) {
                archivos.append(url)
            }
        }
        // Solape: lo que se mira antes (dock?) y despues (espacios y parentesis) de ".setIcon"
        for archivo in archivos where try recorrer(archivo, solape: 256, c, llamaDockSetIcon) { return true }
        return false
    }

    /// Lee el archivo por bloques, sin mapearlo: un disco externo o de red que se desconecta, o un
    /// archivo que se acorta mientras se lee, no tumban Iconos. Cada bloque llega con el final del
    /// anterior para no perder lo que cae en el borde
    private static func recorrer(_ url: URL, solape: Int, _ c: Cancelacion?, _ encontrado: (Data) -> Bool) throws -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var cola = Data()
        while true {
            if c?.cancelada == true { throw Cancelado() }
            guard let bloque = try? h.read(upToCount: 4 << 20), !bloque.isEmpty else { return false }
            let datos = cola + bloque
            if encontrado(datos) { return true }
            cola = Data(datos.suffix(solape))
        }
    }

    /// Busca ".setIcon" precedido de "dock" o "dock?" y seguido (con espacios opcionales) de "("
    static func llamaDockSetIcon(_ datos: Data) -> Bool {
        let aguja = Array(".setIcon".utf8)
        let dock = Array("dock".utf8)
        let espacios: [UInt8] = [0x20, 0x09, 0x0a, 0x0d]
        return datos.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress, buf.count >= aguja.count else { return false }
            let bytes = buf.bindMemory(to: UInt8.self)
            var desde = 0
            while desde <= buf.count - aguja.count {
                guard let p = aguja.withUnsafeBytes({ memmem(base + desde, buf.count - desde, $0.baseAddress, aguja.count) }) else { return false }
                let i = base.distance(to: UnsafeRawPointer(p))
                desde = i + 1
                var antes = i
                if antes > 0, bytes[antes - 1] == UInt8(ascii: "?") { antes -= 1 }
                guard antes >= dock.count, Array(bytes[(antes - dock.count)..<antes]) == dock else { continue }
                var j = i + aguja.count
                while j < bytes.count, espacios.contains(bytes[j]) { j += 1 }
                if j < bytes.count, bytes[j] == UInt8(ascii: "(") { return true }
            }
            return false
        }
    }

    static func contiene(_ datos: Data, _ aguja: [UInt8]) -> Bool {
        datos.withUnsafeBytes { buf in
            guard let base = buf.baseAddress, buf.count >= aguja.count else { return false }
            return aguja.withUnsafeBytes { memmem(base, buf.count, $0.baseAddress, aguja.count) } != nil
        }
    }

    private static func esMachO(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        let magia = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        // MH_MAGIC(_64) y FAT_MAGIC(_64) en los dos ordenes de bytes
        return [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magia)
    }
}
