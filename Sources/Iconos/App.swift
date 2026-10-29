import AppKit
import SwiftUI

/// Un solo ejecutable: la ventana, el agente (--agente) y herramientas de linea de comandos
@main
enum Principal {
    /// Opciones conocidas; las que no empiezan por "--" (-NSDocumentRevisionsDebugMode, -AppleLanguages...)
    /// las pone el sistema y se dejan pasar
    static let opciones: Set<String> = [
        "--agente", "--previa", "--quitar-blanco", "--usar-propias", "--estado", "--guion-permiso",
        "--restaurar-todas", "--conservar-propias", "--desinstalar", "--exportar", "--importar",
        "--diagnostico", "--restaurar", "--instalar-agente", "--oscuro", "--claro", "--elegir", "--bienvenida",
        "--reparar-agente",
    ]

    /// Se traduce entero (la clave es el texto); los nombres de las opciones no cambian
    static let uso = String(localized: """
        Uso: Iconos [opción]
          (sin opciones)                     abre la ventana
          --elegir <app>                     abre la ventana con esa app elegida
          --bienvenida                       abre la ventana con la guía de primeros pasos
          --reparar-agente                   abre la ventana y deja el agente con esta copia
          --oscuro | --claro                 fuerza la apariencia de la ventana
          --previa <app> <carpeta> [--quitar-blanco]
          --usar-propias <app> <claro.png> <oscuro.png>
          --diagnostico <app>
          --restaurar <app>
          --restaurar-todas [--conservar-propias]
          --exportar <zip> | --importar <zip>
          --estado
          --instalar-agente
          --desinstalar
          --guion-permiso <app>...

        """)

    static func main() {
        let args = CommandLine.arguments
        // Una opcion mal escrita o de otra version no abre la ventana (escanea y escribe en los datos).
        // Lo que sigue a --guion-permiso son rutas
        let fin = args.firstIndex(of: "--guion-permiso") ?? args.count
        if let rara = args[1..<max(1, fin)].first(where: { $0.hasPrefix("--") && !opciones.contains($0) }) {
            FileHandle.standardError.write(Data((String(localized: "Opción desconocida: \(rara)") + "\n\n" + uso).utf8))
            exit(2)
        }
        if args.contains("--agente") { Agente.correr() }
        if let i = args.firstIndex(of: "--previa"), args.count > i + 2 {
            exit(Herramientas.previa(app: args[i + 1], salida: args[i + 2], quitarBlanco: args.contains("--quitar-blanco")))
        }
        if let i = args.firstIndex(of: "--usar-propias"), args.count > i + 3 {
            exit(Herramientas.usarPropias(app: args[i + 1], claro: args[i + 2], oscuro: args[i + 3]))
        }
        if args.contains("--estado") { exit(Herramientas.estado()) }
        if let i = args.firstIndex(of: "--guion-permiso") {
            print(Aplicador.guionPermiso(Array(args[(i + 1)...])), terminator: "")
            exit(0)
        }
        if args.contains("--restaurar-todas") {
            exit(Herramientas.restaurarTodas(conservarPropias: args.contains("--conservar-propias")))
        }
        if args.contains("--desinstalar") { exit(Herramientas.desinstalar()) }
        if let i = args.firstIndex(of: "--exportar"), args.count > i + 1 {
            exit(Herramientas.exportar(args[i + 1]))
        }
        if let i = args.firstIndex(of: "--importar"), args.count > i + 1 {
            exit(Herramientas.importar(args[i + 1]))
        }
        if let i = args.firstIndex(of: "--diagnostico"), args.count > i + 1 {
            exit(Herramientas.diagnostico(app: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--restaurar"), args.count > i + 1 {
            exit(Herramientas.restaurar(app: args[i + 1]))
        }
        if args.contains("--instalar-agente") {
            do {
                try ServicioAgente.instalar()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "--elegir") {
            guard args.count > i + 1 else {
                FileHandle.standardError.write(Data((String(localized: "Falta la app de --elegir") + "\n\n" + uso).utf8))
                exit(2)
            }
            // Con la ventana ya abierta, que la elija esa (Estudio escucha el aviso)
            if pasarAVentanaAbierta(args[i + 1]) { exit(0) }
        }
        IconosApp.main()
    }

    /// Si otra copia de Iconos ya tiene la ventana abierta, le pide elegir la app y la trae al frente
    private static func pasarAVentanaAbierta(_ ruta: String) -> Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let otra = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
                  $0.processIdentifier != getpid() && $0.activationPolicy == .regular
              }) else { return false }
        DistributedNotificationCenter.default().postNotificationName(Estudio.avisoElegir, object: (ruta as NSString).standardizingPath,
                                                                     userInfo: nil, deliverImmediately: true)
        otra.activate()
        return true
    }
}

struct IconosApp: App {
    @NSApplicationDelegateAdaptor(Delegado.self) private var delegado
    @StateObject private var estudio = Estudio()

    var body: some Scene {
        Window("Iconos", id: "principal") {
            VistaPrincipal()
                .environmentObject(estudio)
        }
        .defaultSize(width: 1060, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Icono") { MenuIcono(e: estudio) }
            CommandGroup(before: .help) { BotonPrimerosPasos() }
        }
        // La guia de permisos: se abre sola la primera vez (VistaPrincipal) y desde Ajustes o Ayuda
        Window("Primeros pasos", id: VistaBienvenida.id) {
            VistaBienvenida()
                .environmentObject(estudio)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Settings {
            AjustesGenerales()
                .environmentObject(estudio)
        }
    }
}

final class Delegado: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// --oscuro / --claro fuerzan la apariencia de la ventana (para revisar el diseno sin tocar el sistema)
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--oscuro") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--claro") { NSApp.appearance = NSAppearance(named: .aqua) }
    }
}

enum Herramientas {
    /// Escribe claro.png y oscuro.png de una app con los ajustes por defecto (para probar sin ventana);
    /// --quitar-blanco usa el icono completo, el unico estilo que lo tiene en cuenta
    static func previa(app: String, salida: String, quitarBlanco: Bool) -> Int32 {
        let carpeta = URL(fileURLWithPath: salida, isDirectory: true)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        guard let arte = Almacen.arteOriginal(app) else {
            FileHandle.standardError.write(Data((String(localized: "sin icono original") + "\n").utf8))
            return 1
        }
        var g = Gestionada(ruta: app, nombre: (app as NSString).lastPathComponent)
        g.ajustes.quitarBlanco = quitarBlanco ? .siempre : .nunca
        if quitarBlanco { g.ajustes.estilo = .completo }
        if g.ajustes.estilo == .automatico {
            // Lo que decidio el extractor, para revisar los casos dificiles
            let x = Extractor.extraer(arte, app: app)
            // mode y details son del extractor, para depurar: no se traducen
            let ficha = x.plate ? String(localized: "sí") : String(localized: "no")
            print(String(localized: "modo: \(x.mode) ficha: \(ficha) \(x.details)"))
        }
        do {
            try Lienzo.escribirPNG(arte, en: carpeta.appendingPathComponent("original.png"))
            for v in Variante.allCases {
                guard let img = Almacen.imagen(g, v, arte: arte) else { return 1 }
                try Lienzo.escribirPNG(img, en: carpeta.appendingPathComponent("\(v.rawValue).png"))
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        return 0
    }

    /// Lo mismo que elegir imagenes propias y Aplicar en la ventana (modo automatico)
    static func usarPropias(app: String, claro: String, oscuro: String) -> Int32 {
        let nombre = (FileManager.default.displayName(atPath: app) as NSString).deletingPathExtension
        var enDock = false
        do {
            try Almacen.conBloqueo {
                var config = Almacen.cargar()
                var g = config.apps.first { $0.ruta == app } ?? Gestionada(ruta: app, nombre: nombre)
                g.propia = true
                try FileManager.default.createDirectory(at: Almacen.carpeta(app), withIntermediateDirectories: true)
                for (v, archivo) in [(Variante.claro, claro), (.oscuro, oscuro)] {
                    guard let img = Lienzo.leerImagen(URL(fileURLWithPath: archivo)) else { throw ErrorIconos("No se pudo leer \(archivo)") }
                    try Lienzo.escribirPNG(img, en: Almacen.propia(app, v))
                }
                try Almacen.generar(g, arte: Almacen.arteOriginal(app))
                // Sin ventana no hay apariencia resuelta: el agente pone la variante correcta al revisar
                let v = g.modo.variante(oscuroAhora: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
                try Aplicador.aplicar(icns: Almacen.icns(app, v), a: app, variante: v)
                config.apps.removeAll { $0.ruta == app }
                config.apps.append(g)
                try Almacen.guardar(config)
                enDock = config.reiniciarDock && Aplicador.estaEnDock(app)
                print(String(localized: "\(nombre): icono \(v.nombre) puesto"))
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        avisar()
        refrescarDock(enDock)
        return 0
    }

    /// Quita el icono y deja de gestionar la app (lo mismo que Restaurar original en la ventana)
    static func restaurar(app: String) -> Int32 {
        var enDock = false
        do {
            try Almacen.conBloqueo {
                let anterior = Almacen.cargar()
                var config = anterior
                config.apps.removeAll { $0.ruta == app }
                try Almacen.guardar(config)
                do {
                    try Aplicador.restaurar(app)
                    enDock = anterior.reiniciarDock && Aplicador.estaEnDock(app)
                } catch {
                    try? Almacen.guardar(anterior)
                    throw error
                }
                try? FileManager.default.removeItem(at: Almacen.carpeta(app))
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
        avisar()
        refrescarDock(enDock)
        return 0
    }

    /// Todas las gestionadas vuelven a su icono; --conservar-propias guarda las imagenes propias.
    /// Almacen.restaurarTodas ya reinicia el Dock y avisa al agente
    static func restaurarTodas(conservarPropias: Bool) -> Int32 {
        let rutas = Almacen.cargar().apps.map(\.ruta)
        let errores = Almacen.restaurarTodas(conservarPropias: conservarPropias)
        for e in errores { FileHandle.standardError.write(Data("\(e)\n".utf8)) }
        let quedan = Almacen.cargar().apps.count
        print(String(localized: "restauradas: \(rutas.count - quedan) de \(rutas.count)"))
        return errores.isEmpty ? 0 : 1
    }

    /// Lo mismo que Desinstalar en Ajustes, sin mover la app a la Papelera
    static func desinstalar() -> Int32 {
        let (errores, terminal) = Almacen.desinstalar()
        guard errores.isEmpty else {
            for e in errores { FileHandle.standardError.write(Data("\(e)\n".utf8)) }
            FileHandle.standardError.write(Data((String(localized: "No se desinstaló nada; se puede volver a intentar.") + "\n").utf8))
            return 1
        }
        if terminal {
            print(String(localized: "Escribe tu contraseña en Terminal: quita los permisos, borra los datos y mueve Iconos.app a la Papelera."))
        } else {
            print(String(localized: "Iconos quedó desinstalado. Falta mover Iconos.app a la Papelera."))
        }
        return 0
    }

    static func exportar(_ zip: String) -> Int32 {
        do {
            try Almacen.exportar(a: URL(fileURLWithPath: zip))
            print(String(localized: "exportado: \(zip)"))
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func importar(_ zip: String) -> Int32 {
        do {
            let n = try Almacen.importar(de: URL(fileURLWithPath: zip))
            print(String(localized: "apps gestionadas: \(n)"))
            avisar()
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Como sale el logo de una app con sus ajustes guardados (o los de por defecto)
    static func diagnostico(app: String) -> Int32 {
        guard FileManager.default.fileExists(atPath: app) else {
            FileHandle.standardError.write(Data((String(localized: "no existe \(app)") + "\n").utf8))
            return 1
        }
        let nombre = (FileManager.default.displayName(atPath: app) as NSString).deletingPathExtension
        let g = Almacen.cargar().apps.first { $0.ruta == app } ?? Gestionada(ruta: app, nombre: nombre)
        let d = Almacen.diagnostico(g, arte: Almacen.arteOriginal(app))
        // metodo es una clave interna: se traduce al mostrarlo. Los motivos ya vienen traducidos
        print(String(localized: "método: \(d.metodo.isEmpty ? "?" : Diagnostico.titulo(metodo: d.metodo))"))
        print(String(localized: "confianza: \(d.confianza.nombre) (\(d.confianza.titulo))"))
        for m in d.motivos { print(String(localized: "motivo: \(m)")) }
        if d.fuentePx > 0 { print(String(localized: "fuente: \(d.fuentePx) px")) }
        return 0
    }

    /// Lo que ve el agente: apariencia y, por app gestionada, la variante puesta y la que toca
    static func estado() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let oscuro = Almacen.oscuroAhora()
        let ahora = oscuro ? String(localized: "sí") : String(localized: "no")
        print(String(localized: "apariencia: \(app.effectiveAppearance.name.rawValue) (oscuro: \(ahora))"))
        for g in Almacen.cargar().apps {
            let puesta = Aplicador.variantePuesta(g.ruta)?.nombre ?? String(localized: "ninguna")
            let toca = g.modo.variante(oscuroAhora: oscuro).nombre
            print(String(localized: "\(g.nombre): modo \(g.modo.titulo), puesta \(puesta), toca \(toca)"))
        }
        return 0
    }

    /// El agente ve la variante ya puesta y no reinicia el Dock: lo hace la CLI
    private static func refrescarDock(_ enDock: Bool) {
        guard enDock else { return }
        // Margen para que IconServices vea el icono nuevo (sin run loop, espera sincrona)
        Thread.sleep(forTimeInterval: 1)
        Aplicador.refrescarDock()
    }

    private static func avisar() {
        DistributedNotificationCenter.default().postNotificationName(Almacen.aviso, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
