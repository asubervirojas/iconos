import AppKit
import os
import UserNotifications

/// Modo agente (lo lanza launchd con --agente): mantiene los iconos puestos. Cambia de variante
/// cuando cambia la apariencia, los vuelve a poner cuando una actualizacion reemplaza el bundle y
/// relee la configuracion cuando la app avisa.
final class Agente: NSObject {
    /// Carpetas vigiladas (/Applications, ~/Applications y las de cada app gestionada)
    private var vigilantes: [String: DispatchSourceFileSystemObject] = [:]
    private var pendiente: DispatchWorkItem?
    private var observacionApariencia: NSKeyValueObservation?
    /// Tras un error no se reintenta en cada revision: poco despues si la app se estaba
    /// actualizando, diez minutos si fue de permisos
    private var reintentarDesde: [String: Date] = [:]
    /// Mientras un actualizador reemplaza un bundle en una carpeta vigilada, el temporizador no revisa
    private var estabilizarHasta = Date.distantPast
    /// Para dejar en el registro cada cambio de apariencia que ve el agente
    private var ultimaApariencia: Bool?
    /// Regeneraciones de la migracion que fallaron, por app. Se reintenta en cada revision hasta el
    /// tope; despues se anota un pendiente y no se vuelve a intentar hasta reiniciar el agente
    private var fallosMigracion: [String: Int] = [:]
    private static let topeMigracion = 3
    /// Apps cuyo ultimo error fue de Gestion de apps (para EstadoAgente.gestionDeApps). En memoria:
    /// al reiniciar el agente todas se reintentan en la primera revision
    private var sinGestionDeApps: Set<String> = []
    /// Version del agente (CFBundleShortVersionString de IconosAgente.app) para EstadoAgente.version:
    /// la ventana ve si el agente que corre es de otra version que ella
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    static func correr() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let agente = Agente()
        agente.empezar()
        app.run()
        exit(0)
    }

    static func log(_ mensaje: String) { Registro.escribir(mensaje) }

    func empezar() {
        observacionApariencia = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in self?.programar(0.5) }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(avisado), name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        dnc.addObserver(self, selector: #selector(configuracionCambiada), name: Almacen.aviso, object: nil)
        // La apariencia automatica puede cambiar mientras el Mac duerme
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(avisado), name: NSWorkspace.didWakeNotification, object: nil)
        Avisos.empezar()

        vigilarCarpetas()
        // Respaldo por si la actualizacion se hace dentro del bundle sin tocar la carpeta
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date() < self.estabilizarHasta { Almacen.latir() } else { self.revisar() }
        }
        programar(1)
        Agente.log("agente iniciado")
    }

    /// Una carpeta de apps cambia cuando un actualizador reemplaza un bundle
    private func carpetasVigiladas() -> Set<String> {
        var carpetas: Set<String> = ["/Applications",
                                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for g in Almacen.cargar().apps { carpetas.insert((g.ruta as NSString).deletingLastPathComponent) }
        return carpetas
    }

    /// Rehace los vigilantes: abre los que faltan y cierra los de carpetas que ya no hacen falta
    private func vigilarCarpetas() {
        let carpetas = carpetasVigiladas()
        for (carpeta, fuente) in vigilantes where !carpetas.contains(carpeta) {
            fuente.cancel()
            vigilantes[carpeta] = nil
        }
        for carpeta in carpetas where vigilantes[carpeta] == nil {
            let fd = open(carpeta, O_EVTONLY)
            guard fd >= 0 else { continue }
            let fuente = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link, .delete], queue: .main)
            fuente.setEventHandler { [weak self, weak fuente] in
                guard let self else { return }
                // Si la carpeta se borro o se movio, el descriptor ya no sirve: se vuelve a abrir
                if let fuente, !fuente.data.isDisjoint(with: [.rename, .delete]) {
                    fuente.cancel()
                    self.vigilantes[carpeta] = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.vigilarCarpetas() }
                }
                self.estabilizarHasta = Date().addingTimeInterval(15)
                self.programar(15)
            }
            fuente.setCancelHandler { close(fd) }
            fuente.resume()
            vigilantes[carpeta] = fuente
        }
    }

    @objc private func avisado(_ nota: Notification) { programar(0.5) }

    /// La ventana aplico, restauro o cambio un ajuste: lo que fallo antes se intenta ya
    @objc private func configuracionCambiada(_ nota: Notification) {
        reintentarDesde.removeAll()
        vigilarCarpetas()
        programar(0.5)
    }

    /// Agrupa eventos seguidos en una sola revision
    private func programar(_ segundos: TimeInterval) {
        pendiente?.cancel()
        let trabajo = DispatchWorkItem { [weak self] in self?.revisar() }
        pendiente = trabajo
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: trabajo)
    }

    func revisar() {
        Almacen.latir()
        let oscuro = Almacen.oscuroAhora()
        if oscuro != ultimaApariencia {
            ultimaApariencia = oscuro
            Agente.log("apariencia: \(oscuro ? "oscura" : "clara")")
        }
        var reiniciarDock = false
        var reintentarPronto = false
        // Alguna escritura de Aplicador.aplicar funciono en esta revision (macOS dejo escribir al agente)
        var escribio = false
        // Las que se saltan por reintentarDesde conservan el error de la revision anterior
        var estado = EstadoAgente.leer() ?? EstadoAgente()
        Almacen.conBloqueo {
            var config = Almacen.cargar()
            if revisarIconosNuevos(&config) {
                do { try Almacen.guardar(config) } catch { Agente.log("no se pudo guardar la configuración: \(error.localizedDescription)") }
            }
            // Fuera del estado las que ya no se gestionan o no estan en su sitio
            let presentes = Set(config.apps.map(\.ruta).filter { FileManager.default.fileExists(atPath: $0) })
            estado.errores = estado.errores.filter { presentes.contains($0.key) }
            let sinPermiso = Set(Almacen.pendientes().filter { $0.motivo == .sinPermiso }.map(\.ruta))
            for g in config.apps where presentes.contains(g.ruta) {
                let deseada = g.modo.variante(oscuroAhora: oscuro)
                // Sin Icon\r completo (la app se actualizo o quedo a medias) se vuelve a poner. Tras
                // regenerar los icns se invalida la variante (Aplicador.invalidarVariante) y tambien entra
                if Aplicador.variantePuesta(g.ruta) == deseada {
                    // La ventana la arreglo (Permitir cambios y Aplicar)
                    if sinPermiso.contains(g.ruta) { Almacen.resolverPendiente(ruta: g.ruta, motivo: .sinPermiso) }
                    anotarBien(g.ruta, en: &estado)
                    continue
                }
                if let desde = reintentarDesde[g.ruta], Date() < desde { continue }
                // Otra app en la ruta, del sistema o protegida: no se toca
                do {
                    try validar(g)
                } catch {
                    reintentarDesde[g.ruta] = Date().addingTimeInterval(600)
                    anotarError(error, de: g, en: &estado)
                    continue
                }
                do {
                    try Aplicador.aplicar(icns: Almacen.icns(g.ruta, deseada), a: g.ruta, variante: deseada)
                    reintentarDesde[g.ruta] = nil
                    escribio = true
                    if sinPermiso.contains(g.ruta) { Almacen.resolverPendiente(ruta: g.ruta, motivo: .sinPermiso) }
                    anotarBien(g.ruta, en: &estado)
                    Agente.log("\(g.nombre): icono \(deseada.rawValue)")
                    if config.reiniciarDock, Aplicador.estaEnDock(g.ruta) { reiniciarDock = true }
                } catch {
                    let transitorio = (error as? ErrorIconos)?.transitorio ?? false
                    reintentarDesde[g.ruta] = Date().addingTimeInterval(transitorio ? 20 : 600)
                    if transitorio { reintentarPronto = true }
                    anotarError(error, de: g, en: &estado)
                    // Una actualizacion reemplazo el bundle de root y el nuevo no trae la ACL
                    if !transitorio, !Aplicador.escribible(g.ruta), !Aplicador.esDelSistema(g.ruta),
                       !Aplicador.bloqueadaPorFabricante(g.ruta),
                       Almacen.anotarPendiente(Pendiente(ruta: g.ruta, nombre: g.nombre, motivo: .sinPermiso)) {
                        Avisos.mandar("\(g.nombre) se actualizó y perdió el permiso de Iconos", "Abre Iconos y pulsa Permitir cambios.", ruta: g.ruta)
                    }
                }
            }
        }
        sinGestionDeApps.formIntersection(estado.errores.keys)
        estado.gestionDeApps = Agente.gestionDeApps(antes: estado.gestionDeApps, frenadas: !sinGestionDeApps.isEmpty, escribio: escribio)
        estado.sinGestionDeApps = estado.gestionDeApps == false
        estado.version = Agente.version
        estado.fecha = Date()
        estado.escribir()
        if reintentarPronto { programar(21) }
        if reiniciarDock {
            // Margen para que IconServices vea el icono nuevo antes de que el Dock lo pida
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Aplicador.refrescarDock()
                Agente.log("Dock actualizado")
            }
        }
    }

    /// Gestion de apps segun lo que el agente vio. false mientras alguna app tenga como ultimo error el de
    /// Gestion de apps (tambien las que se saltan por reintentarDesde, que conservan su error). true tras
    /// una escritura que funciono, y se conserva entre revisiones aunque no se escriba nada. Un false sin
    /// apps frenadas (dejaron de gestionarse o la ventana les puso el icono) ya no lo confirma nada: vuelve
    /// a nil hasta el siguiente intento. nil si el agente aun no intento escribir
    private static func gestionDeApps(antes: Bool?, frenadas: Bool, escribio: Bool) -> Bool? {
        if frenadas { return false }
        if escribio { return true }
        return antes == false ? nil : antes
    }

    /// Antes de escribir: en la ruta sigue la app gestionada (mismo bundleId) y se puede tocar
    private func validar(_ g: Gestionada) throws {
        try Aplicador.validar(g.ruta, bundleId: g.bundleId)
    }

    /// La app ya tiene su icono: sale del estado
    private func anotarBien(_ ruta: String, en estado: inout EstadoAgente) {
        estado.errores[ruta] = nil
        sinGestionDeApps.remove(ruta)
    }

    private func anotarError(_ error: Error, de g: Gestionada, en estado: inout EstadoAgente) {
        Agente.log("\(g.nombre): \(error.localizedDescription)")
        estado.errores[g.ruta] = error.localizedDescription
        if Agente.faltaGestionDeApps(error, ruta: g.ruta) { sinGestionDeApps.insert(g.ruta) } else { sinGestionDeApps.remove(g.ruta) }
    }

    /// macOS frena la escritura por Gestion de apps: el codigo del error o un EPERM sobre una app que
    /// por permisos de archivo se puede escribir (si no se puede, el problema es la ACL, no Gestion de apps)
    private static func faltaGestionDeApps(_ error: Error, ruta: String) -> Bool {
        if let e = error as? ErrorIconos { return e.codigo == .sinGestionDeApps }
        let ns = error as NSError
        let subyacente = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let eperm = [ns, subyacente].contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EPERM) }
        return eperm && Aplicador.escribible(ruta)
    }

    /// El fabricante cambio su icono (otra huella): se regenera el logo, o si sale con confianza baja
    /// se deja el anterior y se pide revisarlo. Va dentro del bloqueo. Devuelve si cambio la configuracion
    private func revisarIconosNuevos(_ config: inout Configuracion) -> Bool {
        var cambio = false
        for i in config.apps.indices {
            var g = config.apps[i]
            // Gestionadas de antes de la huella: se sellan y se regeneran con la mejor fuente del bundle
            // (antes podian salir del icns de 256 px), sin avisar
            if g.huella == nil, FileManager.default.fileExists(atPath: g.ruta) {
                if migrar(&g) {
                    config.apps[i] = g
                    cambio = true
                }
                continue
            }
            guard let vieja = g.huella, FileManager.default.fileExists(atPath: g.ruta),
                  let nueva = Almacen.huellaIcono(g.ruta), nueva != vieja else { continue }
            cambio = true
            if g.propia {
                // Con imagenes propias el icono del fabricante no se usa
                g = Almacen.sellar(g)
                g.huella = nueva
                config.apps[i] = g
                Agente.log("\(g.nombre): icono nuevo del fabricante (usa imágenes propias)")
                continue
            }
            // El original guardado es el icono viejo
            try? FileManager.default.removeItem(at: Almacen.original(g.ruta))
            let arte = Almacen.arteOriginal(g.ruta)
            let d = Almacen.diagnostico(g, arte: arte)
            var generado = false
            if d.confianza > .baja || g.ajustes.estilo != .automatico {
                do {
                    try generarConservando(g, arte: arte)
                    generado = true
                } catch {
                    Agente.log("\(g.nombre): no se pudo generar el logo nuevo: \(error.localizedDescription)")
                }
            }
            if generado {
                g = Almacen.sellar(g)
                g.huella = nueva
                g.confianza = d.confianza
                g.metodo = d.metodo
                invalidar(g)
                Almacen.anotarPendiente(Pendiente(ruta: g.ruta, nombre: g.nombre, motivo: .iconoNuevo))
                Agente.log("\(g.nombre): icono nuevo del fabricante, logo regenerado (\(d.metodo), confianza \(d.confianza.rawValue))")
                Avisos.mandar("\(g.nombre) cambió su icono: Iconos generó el logo nuevo", nil, ruta: g.ruta)
            } else {
                // Se conservan los icns actuales; solo la huella, para no repetirlo en cada revision
                g.huella = nueva
                Almacen.anotarPendiente(Pendiente(ruta: g.ruta, nombre: g.nombre, motivo: .revisar))
                Agente.log("\(g.nombre): icono nuevo del fabricante, se deja el logo anterior (\(d.metodo), confianza \(d.confianza.rawValue))")
                Avisos.mandar("\(g.nombre) cambió su icono: revisa el logo en Iconos", nil, ruta: g.ruta)
            }
            config.apps[i] = g
        }
        return cambio
    }

    /// Migra una gestionada sin huella. bundleId y version se sellan siempre (aunque el bundle no traiga
    /// icono y no haya huella), para que reubicables la encuentre. La huella solo se sella cuando el logo
    /// quedo resuelto: regenerado, con imagenes propias o con confianza baja (pendiente de revisar). Si
    /// generar falla no se sella, y la siguiente revision lo reintenta hasta el tope. Devuelve si cambio
    private func migrar(_ g: inout Gestionada) -> Bool {
        let antes = g
        let sellada = Almacen.sellar(g)
        g.bundleId = sellada.bundleId
        g.version = sellada.version
        guard let nueva = sellada.huella else { return g != antes }
        if g.propia {
            g.huella = nueva
            Agente.log("\(g.nombre): sellada (imágenes propias)")
            return true
        }
        let fallos = fallosMigracion[g.ruta, default: 0]
        guard fallos < Agente.topeMigracion else { return g != antes }
        let arte = Almacen.arteOriginal(g.ruta)
        let d = Almacen.diagnostico(g, arte: arte)
        guard d.confianza > .baja || g.ajustes.estilo != .automatico else {
            // Se conservan los icns actuales y se pide revisarlo, como con un icono nuevo de confianza baja
            g.huella = nueva
            g.confianza = d.confianza
            g.metodo = d.metodo
            Almacen.anotarPendiente(Pendiente(ruta: g.ruta, nombre: g.nombre, motivo: .revisar))
            Agente.log("\(g.nombre): sellada, se deja el logo anterior (\(d.metodo), confianza \(d.confianza.rawValue))")
            return true
        }
        do {
            try generarConservando(g, arte: arte)
        } catch {
            let intento = fallos + 1
            fallosMigracion[g.ruta] = intento
            Agente.log("\(g.nombre): no se pudo regenerar el logo al sellar (intento \(intento) de \(Agente.topeMigracion)): \(error.localizedDescription)")
            if intento >= Agente.topeMigracion {
                Almacen.anotarPendiente(Pendiente(ruta: g.ruta, nombre: g.nombre, motivo: .revisar))
                Agente.log("\(g.nombre): se deja el logo anterior; no se reintenta hasta reiniciar el agente")
            }
            return g != antes
        }
        fallosMigracion[g.ruta] = nil
        g.huella = nueva
        g.confianza = d.confianza
        g.metodo = d.metodo
        invalidar(g)
        // El de un tope alcanzado antes de reiniciar el agente
        Almacen.resolverPendiente(ruta: g.ruta, motivo: .revisar)
        Agente.log("\(g.nombre): sellada, logo regenerado (\(d.metodo), confianza \(d.confianza.rawValue))")
        return true
    }

    /// Genera los dos icns; si falla, deja los que habia para no mezclar una variante nueva con una vieja
    private func generarConservando(_ g: Gestionada, arte: CGImage?) throws {
        let previos = Variante.allCases.map { v in (Almacen.icns(g.ruta, v), try? Data(contentsOf: Almacen.icns(g.ruta, v))) }
        do {
            try Almacen.generar(g, arte: arte)
        } catch {
            for (destino, datos) in previos {
                if let datos { try? datos.write(to: destino, options: .atomic) } else { try? FileManager.default.removeItem(at: destino) }
            }
            throw error
        }
    }

    /// Icns regenerados: la variante puesta deja de contar como puesta y el bucle de revisar la vuelve a
    /// escribir. Queda en Icon\r, asi que sobrevive a un reinicio del agente
    private func invalidar(_ g: Gestionada) {
        Aplicador.invalidarVariante(g.ruta)
        if Aplicador.variantePuesta(g.ruta) != nil {
            Agente.log("\(g.nombre): no se pudo marcar el icono para volver a ponerlo")
        }
    }
}

/// Notificaciones del agente. Al pulsar una se abre Iconos (con la app del aviso elegida)
final class Avisos: NSObject, UNUserNotificationCenterDelegate {
    private static let compartido = Avisos()
    private static let iconos = Identidad.app
    /// Para la ventana ya abierta: object es la ruta de la app a elegir
    static let elegir = Identidad.avisoElegir
    /// UNUserNotificationCenter solo funciona dentro de un bundle (no con swift run)
    private static var disponible: Bool { Bundle.main.bundleIdentifier != nil }

    static func empezar() {
        guard disponible else { return }
        let centro = UNUserNotificationCenter.current()
        centro.delegate = compartido
        centro.requestAuthorization(options: [.alert, .sound]) { concedido, error in
            if let error { Agente.log("notificaciones: \(error.localizedDescription)") }
            else if !concedido { Agente.log("notificaciones: sin permiso") }
        }
    }

    /// Con ruta, al pulsar el aviso Iconos abre con esa app elegida. Los textos se traducen aqui, con el
    /// catalogo de IconosAgente.app
    static func mandar(_ titulo: String.LocalizationValue, _ cuerpo: String.LocalizationValue?, ruta: String? = nil) {
        guard disponible else { return }
        let contenido = UNMutableNotificationContent()
        contenido.title = String(localized: titulo)
        if let cuerpo { contenido.body = String(localized: cuerpo) }
        if let ruta { contenido.userInfo = ["ruta": ruta] }
        let pedido = UNNotificationRequest(identifier: UUID().uuidString, content: contenido, trigger: nil)
        UNUserNotificationCenter.current().add(pedido) { error in
            if let error { Agente.log("notificación no enviada: \(error.localizedDescription)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let ruta = response.notification.request.content.userInfo["ruta"] as? String
        let configuracion = NSWorkspace.OpenConfiguration()
        if let ruta {
            // Solo llegan si Iconos no estaba abierta; si lo esta, se le avisa aparte
            configuracion.arguments = ["--elegir", ruta]
            if !NSRunningApplication.runningApplications(withBundleIdentifier: Avisos.iconos).isEmpty {
                DistributedNotificationCenter.default().postNotificationName(Avisos.elegir, object: ruta, userInfo: nil, deliverImmediately: true)
            }
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Avisos.iconos) {
            NSWorkspace.shared.openApplication(at: app, configuration: configuracion)
        }
        completionHandler()
    }
}

/// Registro del agente en ~/Library/Logs/Iconos-agente.log (y en el registro unificado). Se escribe
/// directo al archivo: el StandardErrorPath de launchd se abre una vez al lanzar y, si alguien mueve
/// el archivo, todo sigue yendo al movido
enum Registro {
    static let archivo = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Iconos-agente.log").path
    /// Pasado este tamano pasa a Iconos-agente.log.1 (se pierde el .1 anterior)
    static var limite: off_t = 1_000_000
    private static let logger = Logger(subsystem: Identidad.registro, category: "agente")
    private static let cerrojo = NSLock()
    private static var fd: Int32 = -1

    static func escribir(_ mensaje: String) {
        logger.log("\(mensaje, privacy: .public)")
        let hora = ISO8601DateFormatter().string(from: Date())
        let linea = Data("\(hora) \(mensaje)\n".utf8)
        cerrojo.lock()
        defer { cerrojo.unlock() }
        guard let fd = abierto() else { return }
        _ = linea.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Descriptor del archivo que hay ahora en la ruta: lo reabre si se movio, se borro o se roto
    private static func abierto() -> Int32? {
        var enRuta = stat(), propio = stat()
        if fd >= 0 {
            let sigue = stat(archivo, &enRuta) == 0 && fstat(fd, &propio) == 0
                && enRuta.st_dev == propio.st_dev && enRuta.st_ino == propio.st_ino
            if !sigue { close(fd); fd = -1 }
        }
        if fd >= 0, propio.st_size >= limite {
            close(fd)
            fd = -1
            rename(archivo, archivo + ".1")
        }
        if fd < 0 {
            try? FileManager.default.createDirectory(atPath: (archivo as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fd = open(archivo, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        return fd >= 0 ? fd : nil
    }
}

/// El agente como LaunchAgent del usuario: IconosAgente.app (el mismo ejecutable) con --agente
enum ServicioAgente {
    static let etiqueta = Identidad.agente
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(etiqueta).plist")
    }
    static var dominio: String { "gui/\(getuid())" }

    /// El agente es su propia app dentro de Iconos.app (Identidad.agente). Con el ejecutable
    /// de Iconos, macOS lo registraba como Iconos abierta y al abrir la app solo activaba el agente
    private static let agenteDentro = "Contents/Helpers/IconosAgente.app"

    /// El agente de la copia de Iconos abierta (la que lo instala), aunque sea una copia provisional
    static var ejecutable: String { ejecutable(bundle: Bundle.main.bundleURL) }

    /// El agente dentro de la copia de Iconos en bundle
    static func ejecutable(bundle: URL) -> String {
        bundle.appendingPathComponent(agenteDentro + "/Contents/MacOS/IconosAgente").path
    }

    /// Info.plist leido del disco: Bundle.main guarda su ruta y su Info.plist al abrir y no se entera si la
    /// app se mueve mientras corre
    private static func info(_ bundle: URL) -> NSDictionary? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    /// El ejecutable comprobado para dejarlo en launchd: de una copia que no va a desaparecer y de la
    /// misma version que la app. bundle es la copia de Iconos.app (tras moverla, la ruta nueva)
    static func ejecutableParaInstalar(bundle: URL = Bundle.main.bundleURL) throws -> String {
        if let motivo = copiaProvisional(bundle) {
            throw ErrorIconos("Mueve Iconos a Aplicaciones antes de activar el agente: esta copia \(motivo) y el agente dejaría de funcionar.")
        }
        let ruta = ejecutable(bundle: bundle)
        guard FileManager.default.isExecutableFile(atPath: ruta) else {
            throw ErrorIconos("No se encontró el agente dentro de Iconos.app. Vuelve a descargar Iconos.")
        }
        let versionAgente = info(bundle.appendingPathComponent(agenteDentro))?["CFBundleShortVersionString"] as? String
        let versionApp = info(bundle)?["CFBundleShortVersionString"] as? String
        guard let versionAgente, versionAgente == versionApp else {
            throw ErrorIconos("El agente dentro de Iconos.app es de otra versión (\(versionAgente ?? String(localized: "desconocida"))) que la app (\(versionApp ?? String(localized: "desconocida"))). Vuelve a descargar Iconos.")
        }
        return ruta
    }

    /// Por que la copia de Iconos en url no sirve para el agente (nil si sirve; ya traducido): sin mover, macOS la
    /// abre traslocada desde una ruta de solo lectura que cambia; build/ y las temporales se borran
    static func copiaProvisional(_ url: URL) -> String? {
        let ruta = url.resolvingSymlinksInPath().path
        if ruta.contains("/AppTranslocation/") { return String(localized: "se abrió sin moverla de donde se descargó") }
        if url.deletingLastPathComponent().lastPathComponent == "build" { return String(localized: "es la compilada en build/") }
        // Resueltas igual que ruta (resolvingSymlinksInPath tambien quita /private del principio)
        let temporales = [NSTemporaryDirectory(), "/private/tmp", "/private/var/folders"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        if temporales.contains(where: { ruta.hasPrefix($0) }) { return String(localized: "está en una carpeta temporal") }
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return String(localized: "está en un disco de solo lectura (una imagen de disco)")
        }
        return nil
    }

    /// Cargado en launchd; no quiere decir que el proceso funcione
    static func registrado() -> Bool {
        launchctl(["print", "\(dominio)/\(etiqueta)"]) == 0
    }

    /// El agente revisa al menos cada minuto y en cada revision deja el latido
    static func respondio() -> Bool {
        guard let fecha = (try? FileManager.default.attributesOfItem(atPath: Almacen.latido.path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(fecha) < 150
    }

    /// Escribe el plist apuntando al agente de bundle (por defecto esta copia) y lo (re)carga. Tras mover
    /// la app hay que pasar la ruta nueva: Bundle.main.bundleURL sigue dando la vieja
    static func instalar(bundle: URL = Bundle.main.bundleURL) throws {
        let ejecutable = try ejecutableParaInstalar(bundle: bundle)
        let contenido: [String: Any] = [
            "Label": etiqueta,
            "ProgramArguments": [ejecutable, "--agente"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "AssociatedBundleIdentifiers": [info(bundle)?["CFBundleIdentifier"] as? String ?? Identidad.app],
            // El registro normal lo escribe el agente (Registro); aqui solo llegan los fallos del proceso
            "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Iconos-agente-errores.log").path,
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let datos = try PropertyListSerialization.data(fromPropertyList: contenido, format: .xml, options: 0)
        try datos.write(to: plist, options: .atomic)
        _ = launchctl(["bootout", "\(dominio)/\(etiqueta)"])
        guard launchctl(["bootstrap", dominio, plist.path]) == 0 else { throw ErrorIconos("launchctl no pudo cargar el agente") }
    }

    static func desinstalar() {
        _ = launchctl(["bootout", "\(dominio)/\(etiqueta)"])
        try? FileManager.default.removeItem(at: plist)
    }

    /// Si la app se movio o se recompilo en otra ruta, el plist apunta a otro ejecutable
    static func apuntaAEsteEjecutable() -> Bool {
        guard let datos = try? Data(contentsOf: plist),
              let dic = try? PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any],
              let args = dic["ProgramArguments"] as? [String] else { return false }
        return args.first == ejecutable
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
