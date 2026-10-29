import Foundation

/// Identificadores del proyecto en un solo lugar. Deben coincidir con CFBundleIdentifier de
/// Recursos/Info.plist y Recursos/Agente-Info.plist: macOS guarda el permiso Gestion de apps por
/// identificador y firma, y cambiarlo despues de publicar le quita el permiso a todos
enum Identidad {
    static let app = "io.github.asubervirojas.iconos"
    static let agente = app + ".agente"
    /// Atributo de Icon\r con la variante puesta
    static let atributoVariante = app + ".variante"
    /// La ventana avisa al agente que cambio la configuracion
    static let avisoCambio = Notification.Name(app + ".cambio")
    /// Abrir Iconos con una app elegida (lo manda el agente al pulsar un aviso)
    static let avisoElegir = Notification.Name(app + ".elegir")
    /// Subsistema de os.Logger
    static let registro = app
}

/// Lo que el agente sabe y la ventana no ve: lo escribe el agente en cada revision
struct EstadoAgente: Codable, Equatable {
    var fecha = Date()
    /// macOS no deja escribir a Iconos Agente en las apps (falta Gestion de apps para el agente)
    var sinGestionDeApps = false
    /// nil hasta que el agente intenta escribir en alguna app; true si una escritura funciono,
    /// false si macOS la freno por Gestion de apps. La guia de permisos muestra "sin saber" con nil
    var gestionDeApps: Bool?
    /// CFBundleShortVersionString del agente que escribio el estado (si no es la de la app, el
    /// agente que corre es una version vieja)
    var version: String?
    /// Ultimo error por ruta de app
    var errores: [String: String] = [:]

    static var archivo: URL { Almacen.base.appendingPathComponent("estado-agente.json") }

    static func leer() -> EstadoAgente? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let datos = try? Data(contentsOf: archivo) else { return nil }
        return try? d.decode(EstadoAgente.self, from: datos)
    }

    func escribir() {
        let c = JSONEncoder()
        c.dateEncodingStrategy = .iso8601
        c.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Almacen.base, withIntermediateDirectories: true)
        try? c.encode(self).write(to: EstadoAgente.archivo, options: .atomic)
    }
}
