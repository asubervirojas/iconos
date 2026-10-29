import AppKit
import UniformTypeIdentifiers

/// Estado del agente tal como lo ve la ventana
enum EstadoDelAgente {
    case apagado
    /// Recien activado, aun sin el primer latido
    case arrancando
    case activo
    /// Cargado en launchd pero sin latido reciente (no arranca o se cae)
    case sinRespuesta
    /// Cargado pero apunta a otra copia de Iconos (se movio o se recompilo)
    case otraCopia
    /// Responde, pero es otra version: se reemplazo Iconos.app y sigue corriendo el agente viejo
    case otraVersion
}

/// Estado de una app en la lista, de lo mas grave a lo mas comun
enum EstadoFila {
    /// App del sistema o bloqueada por su fabricante
    case noSePuede
    /// App de root sin el permiso de Iconos (se arregla con Permitir cambios)
    case sinPermiso
    /// Gestionada pero sin la variante que toca puesta (pendiente o sin permiso)
    case falta
    /// Gestionada y con la variante que toca
    case puesto
    /// Su icono ya trae modo oscuro y macOS lo cambia solo
    case oscuroPropio
    case normal
}

/// Filtros de la barra lateral
enum FiltroApps: String, CaseIterable, Identifiable {
    case todas, personalizadas, sinPersonalizar, sinPermiso, noSePueden, oscuroPropio

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .todas: String(localized: "Todas")
        case .personalizadas: String(localized: "Personalizadas")
        case .sinPersonalizar: String(localized: "Sin personalizar")
        case .sinPermiso: String(localized: "Sin permiso")
        case .noSePueden: String(localized: "No se pueden cambiar")
        case .oscuroPropio: String(localized: "Con modo oscuro propio")
        }
    }
}

/// Gestionada cuya app se reinstalo en otra ruta
struct Reubicable: Identifiable, Equatable {
    let vieja: String
    let nueva: String
    var id: String { vieja }
}

/// Estado de la ventana: apps escaneadas, la que se edita y sus vistas previas
@MainActor
final class Estudio: ObservableObject {
    @Published private(set) var apps: [AppEncontrada] = []
    @Published private(set) var config = Almacen.cargar()
    @Published var busqueda = ""
    @Published var filtro = FiltroApps.todas
    /// Apps elegidas en la lista. Con una sola se edita esa; con varias se muestra el panel comun
    @Published var elegidas: Set<String> = [] {
        didSet {
            guard elegidas != oldValue else { return }
            let una = elegidas.count == 1 ? elegidas.first : nil
            if seleccion != una { seleccion = una }
            if elegidas.count > 1 { prepararVarias() }
        }
    }
    /// La app que se edita (solo cuando hay una elegida)
    @Published private(set) var seleccion: String? {
        didSet {
            guard seleccion != oldValue else { return }
            if let anterior = oldValue { Almacen.descartarPropias(anterior) }
            cargarSeleccion()
        }
    }
    @Published var borrador: Gestionada? {
        didSet { if borrador != oldValue { actualizarPrevias() } }
    }
    @Published private(set) var previaOriginal: NSImage?
    @Published private(set) var previaClaro: NSImage?
    @Published private(set) var previaOscuro: NSImage?
    /// Como sale el logo del borrador; se calcula junto a las previas
    @Published private(set) var diagnostico: Diagnostico?
    @Published private(set) var trabajando = false
    @Published private(set) var escaneando = false
    @Published private(set) var mensaje: String?
    @Published private(set) var error: String?
    /// Codigo del ultimo error: el boton que lo arregla se decide por el, no por el texto (se traduce)
    @Published private(set) var codigoError: ErrorIconos.Codigo?
    /// Apps recien restauradas que siguen con la ACL de Iconos: el aviso ofrece quitarla
    @Published private(set) var permisoQueSobra: [String] = []
    @Published private(set) var estadoAgente = EstadoDelAgente.apagado
    /// Lo que anoto el agente en su ultima revision (Gestion de apps y errores por app)
    @Published private(set) var informeAgente: EstadoAgente?
    /// Gestion de apps para Iconos segun la ultima escritura en una app: nil mientras no se sepa
    @Published private(set) var gestionDeApps: Bool? = Estudio.gestionDeAppsGuardada()
    /// Imagenes propias elegidas o quitadas sin aplicar (no cambian Gestionada)
    @Published private(set) var propiasPendientes = false
    /// Icono original de cada app (128 px) para la lista y la cabecera
    @Published private(set) var miniaturas: [String: NSImage] = [:]
    /// Apps cuyo icono ya trae modo oscuro propio (macOS lo cambia solo)
    @Published private(set) var oscuroPropio: Set<String> = []
    /// Lo que anoto el agente para el usuario (pendientes.json)
    @Published private(set) var pendientes: [Pendiente] = []
    @Published private(set) var reubicables: [Reubicable] = []
    /// Apps de las carpetas de apps con la ACL de Iconos (del ultimo escaneo)
    @Published private(set) var conACL: [String] = []
    /// Ajustes comunes del panel de varias apps
    @Published var modoVarias = Modo.automatico
    @Published var estiloVarias = EstiloLogo.automatico
    /// Errores de desinstalar (no se desinstalo nada); la ventana los muestra
    @Published var erroresDesinstalar: [String]?

    private var quitarPropiasPendiente = false
    private var arrancandoHasta = Date.distantPast
    private var arte: CGImage?
    /// Ruta cuyo arte ya se leyo (las previas esperan a tenerlo)
    private var arteDe: String?
    private var tareaArte: Task<Void, Never>?
    private var tareaPrevias: Task<Void, Never>?
    private var reloj: Timer?
    private var vigilantes: [DispatchSourceFileSystemObject] = []
    private var reescaneo: DispatchWorkItem?
    /// Solo cuenta el resultado del ultimo escaneo lanzado
    private var generacionEscaneo = 0
    /// Apariencia con la que se leyo la variante puesta de cada fila (escaneo o refrescarFila)
    private var oscuroLeido: [String: Bool] = [:]
    /// Desinstalando: nada vuelve a crear la carpeta de datos
    private var desinstalando = false
    /// App pedida con --elegir o con el aviso de elegir antes de que el escaneo la encuentre
    private var elegirAlEscanear: String?

    /// Otro proceso (por ejemplo un aviso del agente) pide elegir una app; object = ruta
    nonisolated static let avisoElegir = Identidad.avisoElegir
    /// Se cambia al publicar el repositorio
    static let repositorio = "https://github.com/asubervirojas/iconos"
    /// Carpetas de apps que siempre se miran (las del usuario van en Configuracion.carpetasExtra)
    static let carpetasFijas = ["/Applications", "/Applications/Utilities",
                                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    static let claveGestionDeApps = "gestionDeApps"
    /// CFBundleVersion con la que se anoto gestionDeApps
    static let claveGestionDeAppsVersion = "gestionDeAppsVersion"
    static let claveBienvenida = "bienvenidaVista"
    static let claveSinExplicarTerminal = "sinExplicarTerminal"

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--elegir"), CommandLine.arguments.count > i + 1 {
            elegirAlEscanear = (CommandLine.arguments[i + 1] as NSString).standardizingPath
        }
        escanear()
        vigilarCarpetas()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.programarEscaneo(0.3)
                // Al volver de Ajustes del Sistema (Gestion de apps) el agente prueba otra vez ya y la
                // guia muestra lo nuevo
                self?.comprobarAgente()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Estudio.avisoElegir, object: nil, queue: .main) { [weak self] aviso in
            guard let ruta = aviso.object as? String else { return }
            Task { @MainActor in
                self?.elegirDeFuera(ruta)
                NSApp.activate()
            }
        }
        revisarAgente()
        revisarPendientes()
        iniciarReloj()
        // La copia que se movio a Aplicaciones deja el agente con esta (moverAAplicaciones)
        if CommandLine.arguments.contains("--reparar-agente") { activarAgente() }
    }

    private func iniciarReloj() {
        reloj?.invalidate()
        reloj = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.revisarAgente()
                self?.revisarPendientes()
            }
        }
    }

    // MARK: Lista

    /// Apps que coinciden con la busqueda (sin el filtro de estado)
    private var porTexto: [AppEncontrada] {
        let texto = busqueda.trimmingCharacters(in: .whitespaces)
        guard !texto.isEmpty else { return apps }
        return apps.filter { $0.nombre.localizedCaseInsensitiveContains(texto) }
    }

    var filtradas: [AppEncontrada] { porTexto.filter { cumple($0, filtro) } }

    var gestionadas: [AppEncontrada] { filtradas.filter { gestionada($0.ruta) != nil } }
    var resto: [AppEncontrada] { filtradas.filter { gestionada($0.ruta) == nil } }

    func cumple(_ a: AppEncontrada, _ f: FiltroApps) -> Bool {
        switch f {
        case .todas: true
        case .personalizadas: gestionada(a.ruta) != nil
        case .sinPersonalizar: gestionada(a.ruta) == nil
        case .sinPermiso: a.necesitaPermiso
        case .noSePueden: a.sistema || a.bloqueada
        case .oscuroPropio: oscuroPropio.contains(a.ruta)
        }
    }

    /// Cuantas apps de la busqueda entran en cada filtro
    func cuantas(_ f: FiltroApps) -> Int { porTexto.lazy.filter { self.cumple($0, f) }.count }

    func gestionada(_ ruta: String) -> Gestionada? { config.apps.first { $0.ruta == ruta } }

    var appSeleccionada: AppEncontrada? { apps.first { $0.ruta == seleccion } }

    /// Elige una sola app (por ejemplo desde un aviso); quita filtro y busqueda si la esconden
    func elegir(_ ruta: String) {
        if let app = apps.first(where: { $0.ruta == ruta }), !filtradas.contains(app) {
            filtro = .todas
            busqueda = ""
        }
        elegidas = [ruta]
    }

    /// Elige una app pedida desde fuera (--elegir o el aviso de elegir); si el escaneo aun no la trae,
    /// espera al siguiente
    private func elegirDeFuera(_ ruta: String) {
        let ruta = (ruta as NSString).standardizingPath
        if apps.contains(where: { $0.ruta == ruta }) {
            revisar(ruta)
        } else {
            elegirAlEscanear = ruta
            if !escaneando { escanear() }
        }
    }

    /// Revisar un aviso: la app pudo cambiar de icono aunque ya estuviera elegida, asi que se releen la
    /// configuracion y su arte aunque la seleccion no cambie
    func revisar(_ ruta: String) {
        config = Almacen.cargar()
        let yaElegida = seleccion == ruta && elegidas == [ruta]
        elegir(ruta)
        if yaElegida { cargarSeleccion() }
    }

    func estadoFila(_ a: AppEncontrada) -> EstadoFila {
        if a.sistema || a.bloqueada { return .noSePuede }
        if a.necesitaPermiso { return .sinPermiso }
        if let g = gestionada(a.ruta) {
            // Al cambiar la apariencia el agente tarda en poner la otra variante: con el agente activo se
            // compara con la apariencia de cuando se leyo la fila, hasta el escaneo siguiente
            let oscuro = agenteActivo ? (oscuroLeido[a.ruta] ?? Almacen.oscuroAhora()) : Almacen.oscuroAhora()
            return a.puesta == g.modo.variante(oscuroAhora: oscuro) ? .puesto : .falta
        }
        if oscuroPropio.contains(a.ruta) { return .oscuroPropio }
        return .normal
    }

    /// Lee las apps fuera del hilo principal (ACL, stat y variante puesta de cada una) y publica el
    /// resultado aqui; la eleccion se mantiene porque va por ruta
    func escanear() {
        guard !desinstalando else { return }
        generacionEscaneo += 1
        let generacion = generacionEscaneo
        let oscuro = Almacen.oscuroAhora()
        escaneando = true
        Task { [weak self] in
            let (lista, acl) = await Task.detached(priority: .userInitiated) {
                (Almacen.escanear(), Aplicador.conACL())
            }.value
            guard let self, generacion == self.generacionEscaneo, !self.desinstalando else { return }
            self.escaneando = false
            self.oscuroLeido = Dictionary(lista.map { ($0.ruta, oscuro) }, uniquingKeysWith: { a, _ in a })
            self.apps = lista
            self.conACL = acl
            self.config = Almacen.cargar()
            self.cargarMiniaturas()
            self.revisarPendientes()
            if let ruta = self.elegirAlEscanear, lista.contains(where: { $0.ruta == ruta }) {
                self.elegirAlEscanear = nil
                self.revisar(ruta)
            }
        }
    }

    /// Apps instaladas, borradas o con permiso nuevo aparecen solas: al cambiar las carpetas de apps y al
    /// volver a Iconos (por ejemplo desde Terminal tras Permitir cambios; ese aviso se pone en init)
    private func vigilarCarpetas() {
        for v in vigilantes { v.cancel() }
        vigilantes = []
        for carpeta in Estudio.carpetasFijas + config.carpetasExtra {
            let fd = open(carpeta, O_EVTONLY)
            guard fd >= 0 else { continue }
            let fuente = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link, .delete], queue: .main)
            fuente.setEventHandler { [weak self] in self?.programarEscaneo(3) }
            fuente.setCancelHandler { close(fd) }
            fuente.resume()
            vigilantes.append(fuente)
        }
    }

    /// Para el reloj, los vigilantes y los escaneos: leer pendientes o el modo oscuro propio vuelve a
    /// crear la carpeta de datos que desinstalar borra
    private func pararVigilancia() {
        desinstalando = true
        reloj?.invalidate()
        reloj = nil
        reescaneo?.cancel()
        reescaneo = nil
        for v in vigilantes { v.cancel() }
        vigilantes = []
        // Un escaneo en marcha ya no publica
        generacionEscaneo += 1
        escaneando = false
    }

    private func reanudarVigilancia() {
        desinstalando = false
        vigilarCarpetas()
        iniciarReloj()
    }

    /// Un instalador hace muchos cambios seguidos: se escanea una vez cuando para. Tambien tras cambiar
    /// la apariencia, para ver la variante que puso el agente
    func programarEscaneo(_ segundos: TimeInterval) {
        reescaneo?.cancel()
        let trabajo = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.desinstalando else { return }
                // Con un aplicar o un restaurar en marcha se espera: si no, la lista se queda vieja
                if self.trabajando {
                    self.programarEscaneo(1)
                    return
                }
                self.escanear()
            }
        }
        reescaneo = trabajo
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: trabajo)
    }

    /// El arte original de cada app, fuera del hilo principal (leer y escalar ~40 icns tarda)
    private func cargarMiniaturas() {
        let rutas = apps.map(\.ruta).filter { miniaturas[$0] == nil }
        guard !rutas.isEmpty else { return }
        Task { [weak self] in
            let lista = await Task.detached(priority: .utility) {
                rutas.compactMap { ruta in Almacen.arteOriginal(ruta).flatMap { Lienzo.escalar($0, a: 128) }.map { (ruta, $0) } }
            }.value
            guard let self else { return }
            for (ruta, cg) in lista { self.miniaturas[ruta] = NSImage(cgImage: cg, size: NSSize(width: 64, height: 64)) }
            // tieneOscuroPropio escribe su cache en la carpeta de datos
            guard !self.desinstalando else { return }
            let oscuras = await Task.detached(priority: .utility) {
                Set(rutas.filter { Almacen.tieneOscuroPropio($0) })
            }.value
            self.oscuroPropio.formUnion(oscuras)
        }
    }

    /// Icono original para la lista y la cabecera: estable, sin la personalizacion de Iconos
    func miniatura(_ ruta: String) -> NSImage {
        miniaturas[ruta] ?? NSWorkspace.shared.icon(forFile: ruta)
    }

    /// Nombres repetidos (dos ChatGPT): la lista muestra donde esta cada una
    var nombresRepetidos: Set<String> {
        var vistos = Set<String>(), repetidos = Set<String>()
        for a in apps where !vistos.insert(a.nombre).inserted { repetidos.insert(a.nombre) }
        return repetidos
    }

    /// Otras apps para la simulacion del Dock alrededor de la elegida
    func vecinos(de ruta: String, cuantos: Int = 4) -> [NSImage] {
        Array(apps.lazy.filter { $0.ruta != ruta && self.miniaturas[$0.ruta] != nil }.prefix(cuantos))
            .compactMap { miniaturas[$0.ruta] }
    }

    /// Estado de la app elegida, en palabras
    var estado: String {
        guard let g = borrador else { return "" }
        guard let guardada = gestionada(g.ruta) else {
            return appSeleccionada?.personalizado == true ? String(localized: "Con otro icono personalizado")
                : String(localized: "Sin personalizar")
        }
        if cambiosSinAplicar { return String(localized: "Cambios sin aplicar") }
        if let app = appSeleccionada, estadoFila(app) == .falta { return String(localized: "Falta poner el icono") }
        let ahora = guardada.modo.variante(oscuroAhora: Almacen.oscuroAhora())
        switch guardada.modo {
        case .automatico:
            return ahora == .oscuro ? String(localized: "Aplicado · Automático · oscuro ahora")
                : String(localized: "Aplicado · Automático · claro ahora")
        case .claro: return String(localized: "Aplicado · Siempre claro")
        case .oscuro: return String(localized: "Aplicado · Siempre oscuro")
        }
    }

    // MARK: Pendientes

    var pendientesSinPermiso: [Pendiente] { pendientes.filter { $0.motivo == .sinPermiso } }
    var pendientesIconoNuevo: [Pendiente] { pendientes.filter { $0.motivo == .iconoNuevo } }
    var pendientesRevisar: [Pendiente] { pendientes.filter { $0.motivo == .revisar } }

    /// Relee pendientes.json y las apps reinstaladas en otra ruta. Un aviso de permiso perdido se quita
    /// solo cuando la app vuelve a ser escribible
    func revisarPendientes() {
        guard !desinstalando else { return }
        var resueltas = false
        for p in Almacen.pendientes() where p.motivo == .sinPermiso {
            if let a = apps.first(where: { $0.ruta == p.ruta }), a.escribible {
                Almacen.resolverPendiente(ruta: p.ruta, motivo: .sinPermiso)
                resueltas = true
            }
        }
        pendientes = Almacen.pendientes()
        reubicables = Almacen.reubicables(apps, config).map { Reubicable(vieja: $0.vieja, nueva: $0.nueva) }
        // Con el permiso de vuelta, el agente pone el icono que faltaba
        if resueltas { avisarAgente() }
    }

    /// Permiso otra vez para las apps que lo perdieron al actualizarse
    func permitirPendientes() {
        let rutas = pendientesSinPermiso.map(\.ruta).filter { FileManager.default.fileExists(atPath: $0) }
        permitir(rutas, despues: String(localized: "Al volver aquí, el cambio automático les pone el icono otra vez."))
    }

    /// Cierra los avisos de un motivo
    func entendido(_ motivo: Pendiente.Motivo) {
        for p in pendientes where p.motivo == motivo { Almacen.resolverPendiente(ruta: p.ruta, motivo: motivo) }
        pendientes = Almacen.pendientes()
    }

    func descartarPendiente(_ p: Pendiente) {
        Almacen.resolverPendiente(ruta: p.ruta, motivo: p.motivo)
        pendientes = Almacen.pendientes()
    }

    func nombreGestionada(_ ruta: String) -> String {
        gestionada(ruta)?.nombre ?? (URL(fileURLWithPath: ruta).deletingPathExtension().lastPathComponent)
    }

    /// Pasa los ajustes de una app reinstalada a su ruta nueva (reubicar toma el bloqueo)
    func moverAjustes(_ r: Reubicable) {
        guard !trabajando else { return }
        let nombre = nombreGestionada(r.vieja)
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let resultado = await Task.detached(priority: .userInitiated) {
                Result { try Almacen.reubicar(vieja: r.vieja, nueva: r.nueva) }
            }.value
            guard let self else { return }
            self.trabajando = false
            self.config = Almacen.cargar()
            switch resultado {
            case .failure(let fallo):
                self.mostrar(fallo)
            case .success:
                self.avisarAgente()
                if self.seleccion == r.nueva { self.cargarSeleccion() }
                self.mensaje = String(localized: "Se movieron los ajustes de \(nombre) a su nueva ubicación.")
            }
            self.escanear()
        }
    }

    // MARK: Edicion

    private func limpiarAvisos() {
        error = nil
        codigoError = nil
        mensaje = nil
        permisoQueSobra = []
    }

    /// Muestra un error con su codigo (si es de Iconos)
    private func mostrar(_ fallo: Error) {
        mostrarError(fallo.localizedDescription, codigo: (fallo as? ErrorIconos)?.codigo)
    }

    private func mostrarError(_ texto: String, codigo: ErrorIconos.Codigo?) {
        error = texto
        codigoError = codigo
        if codigo == .sinGestionDeApps { anotarGestionDeApps(false) }
    }

    /// Lo que se sabe de Gestion de apps para Iconos: macOS frena la escritura sin el, y una escritura
    /// que funciona dice que lo tiene. Se guarda para la guia de primeros pasos
    private func anotarGestionDeApps(_ tiene: Bool) {
        guard gestionDeApps != tiene, !desinstalando else { return }
        gestionDeApps = tiene
        UserDefaults.standard.set(tiene, forKey: Estudio.claveGestionDeApps)
        UserDefaults.standard.set(Estudio.versionCompilacion, forKey: Estudio.claveGestionDeAppsVersion)
    }

    /// Lo anotado vale solo para la misma compilacion: otra version puede venir con otra firma y macOS
    /// le quita el permiso
    private static func gestionDeAppsGuardada() -> Bool? {
        let d = UserDefaults.standard
        guard let version = d.string(forKey: claveGestionDeAppsVersion), version == versionCompilacion else { return nil }
        return d.object(forKey: claveGestionDeApps) as? Bool
    }

    /// CFBundleVersion de esta copia ("" compilada sin .app)
    private static var versionCompilacion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private func cargarSeleccion() {
        limpiarAvisos()
        propiasPendientes = false
        quitarPropiasPendiente = false
        diagnostico = nil
        tareaArte?.cancel()
        tareaPrevias?.cancel()
        arte = nil
        arteDe = nil
        previaOriginal = nil
        previaClaro = nil
        previaOscuro = nil
        guard let app = appSeleccionada else {
            borrador = nil
            return
        }
        let ruta = app.ruta
        // Un borrador de otra sesion no cuenta: lo pendiente se marca al elegir
        Almacen.descartarPropias(ruta)
        borrador = gestionada(ruta) ?? Gestionada(ruta: ruta, nombre: app.nombre)
        // Leer el icono del bundle tarda (icns, catalogo de recursos): va fuera del hilo principal para
        // que moverse por la lista con las flechas no de tirones. Solo publica si la app sigue elegida
        tareaArte = Task { [weak self] in
            let arte = await Task.detached(priority: .userInitiated) { Almacen.arteOriginal(ruta) }.value
            guard !Task.isCancelled, let self, self.seleccion == ruta else { return }
            self.arte = arte
            self.arteDe = ruta
            self.previaOriginal = arte.map { NSImage(cgImage: $0, size: .zero) }
            self.actualizarPrevias()
        }
    }

    private func actualizarPrevias() {
        guard let g = borrador else {
            previaClaro = nil
            previaOscuro = nil
            diagnostico = nil
            return
        }
        tareaPrevias?.cancel()
        // Sin el arte de esta app todavia: las previas se dibujan cuando llegue
        guard arteDe == g.ruta else { return }
        let arte = self.arte
        // El dibujo va fuera del hilo principal; el resultado vuelve aqui (la tarea hereda MainActor)
        tareaPrevias = Task { [weak self] in
            // Rebote: los pasos intermedios del deslizador se cancelan antes de dibujar
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let (claro, oscuro, diagnostico) = await Task.detached(priority: .userInitiated) {
                (Almacen.imagen(g, .claro, arte: arte, borrador: true), Almacen.imagen(g, .oscuro, arte: arte, borrador: true),
                 Almacen.diagnostico(g, arte: arte))
            }.value
            guard !Task.isCancelled, let self, self.borrador == g else { return }
            self.previaClaro = claro.map { NSImage(cgImage: $0, size: .zero) }
            self.previaOscuro = oscuro.map { NSImage(cgImage: $0, size: .zero) }
            self.diagnostico = diagnostico
        }
    }

    /// Vuelve a lo guardado (o a lo de por defecto si la app no esta gestionada)
    func descartar() {
        guard let app = appSeleccionada else { return }
        Almacen.descartarPropias(app.ruta)
        propiasPendientes = false
        quitarPropiasPendiente = false
        limpiarAvisos()
        borrador = gestionada(app.ruta) ?? Gestionada(ruta: app.ruta, nombre: app.nombre)
        actualizarPrevias()
    }

    /// Apps de root: abre Terminal con el permiso; al volver a Iconos la lista se actualiza sola
    func permitir() {
        guard let app = appSeleccionada, !trabajando else { return }
        permitir([app.ruta])
    }

    /// Gestionadas de root sin permiso (las que Iconos usa, no todas las de root)
    var gestionadasSinPermiso: [AppEncontrada] { apps.filter { $0.necesitaPermiso && gestionada($0.ruta) != nil } }

    func permitirTodas() { permitir(gestionadasSinPermiso.map(\.ruta)) }

    /// Apps con la ACL de Iconos que ya no estan gestionadas
    var permisosSobrantes: [String] { conACL.filter { gestionada($0) == nil } }

    func quitarPermisosSobrantes() { quitarPermiso(permisosSobrantes) }

    private func permitir(_ rutas: [String], despues: String = String(localized: "Al volver aquí, pulsa Aplicar.")) {
        limpiarAvisos()
        // El mismo filtro que permitirEnTerminal: la hoja muestra el guion que va a correr. Sin apps
        // validas no hay hoja: permitirEnTerminal da su error
        let validas = rutas.filter { !Aplicador.esDelSistema($0) && !Aplicador.bloqueadaPorFabricante($0) }
        let abrir = { [weak self] in
            guard let self else { return }
            do {
                try Aplicador.permitirEnTerminal(rutas)
                self.mensaje = String(localized: "Escribe tu contraseña en Terminal. \(despues)")
            } catch {
                self.mostrar(error)
            }
        }
        guard !validas.isEmpty else { return abrir() }
        explicarTerminal(quitar: false, guion: Aplicador.guionPermiso(validas), abrir: abrir)
    }

    /// Quita la ACL de Iconos desde Terminal
    func quitarPermiso(_ rutas: [String]) {
        guard !rutas.isEmpty else { return }
        limpiarAvisos()
        // Como quitarPermisoEnTerminal: solo las que tienen la ACL; sin ninguna no hay nada que hacer
        let validas = rutas.filter { Aplicador.tieneACL($0) && !Aplicador.esDelSistema($0) && !Aplicador.bloqueadaPorFabricante($0) }
        guard !validas.isEmpty else { return }
        explicarTerminal(quitar: true, guion: Aplicador.guionACL(validas, quitar: true)) { [weak self] in
            guard let self else { return }
            do {
                try Aplicador.quitarPermisoEnTerminal(rutas)
                self.mensaje = String(localized: "Escribe tu contraseña en Terminal para quitar el permiso.")
            } catch {
                self.mostrar(error)
            }
        }
    }

    /// Antes de abrir Terminal: por que pide la contrasena, que hace y el guion exacto. Va como hoja
    /// de la ventana de delante (la principal o Ajustes). "No volver a mostrar" abre Terminal directo
    private func explicarTerminal(quitar: Bool, guion: String, abrir: @escaping () -> Void) {
        if UserDefaults.standard.bool(forKey: Estudio.claveSinExplicarTerminal) { return abrir() }
        let alerta = NSAlert()
        alerta.messageText = String(localized: "Por qué pide tu contraseña")
        alerta.informativeText = quitar
            ? String(localized: "Iconos quita el permiso (una ACL) que puso en la carpeta de la app; dentro de Contents no cambia nada. Son apps de root, así que Terminal pide tu contraseña de administrador e Iconos no la ve.")
            : String(localized: "Iconos añade un permiso (una ACL) solo en la carpeta de la app para poder ponerle el icono; dentro de Contents no cambia nada y la firma de la app sigue intacta. Se puede quitar cuando quieras desde Ajustes; Terminal pide tu contraseña de administrador e Iconos no la ve.")
        let marco = NSTextView.scrollableTextView()
        marco.frame = NSRect(x: 0, y: 0, width: 460, height: 180)
        marco.borderType = .bezelBorder
        if let texto = marco.documentView as? NSTextView {
            texto.string = guion
            texto.isEditable = false
            texto.isSelectable = true
            texto.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            texto.setAccessibilityLabel(String(localized: "Comando que corre Terminal"))
        }
        alerta.accessoryView = marco
        alerta.addButton(withTitle: String(localized: "Abrir Terminal"))
        alerta.addButton(withTitle: String(localized: "Cancelar")).keyEquivalent = "\u{1b}"
        alerta.showsSuppressionButton = true
        alerta.suppressionButton?.title = String(localized: "No volver a mostrar")
        let fin: (NSApplication.ModalResponse) -> Void = { respuesta in
            if alerta.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Estudio.claveSinExplicarTerminal)
            }
            if respuesta == .alertFirstButtonReturn { abrir() }
        }
        if let ventana = NSApp.keyWindow, ventana.attachedSheet == nil {
            alerta.beginSheetModal(for: ventana, completionHandler: fin)
        } else {
            fin(alerta.runModal())
        }
    }

    /// Ajustes: mostrar o no la explicacion antes de abrir Terminal
    var explicarAntesDeTerminal: Bool {
        get { !UserDefaults.standard.bool(forKey: Estudio.claveSinExplicarTerminal) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(!newValue, forKey: Estudio.claveSinExplicarTerminal)
        }
    }

    /// Solo cuenta lo que se edita: huella, version, bundle, confianza y metodo los sella el agente o
    /// aplicar y no son cambios del usuario
    var cambiosSinAplicar: Bool {
        guard let g = borrador else { return false }
        if propiasPendientes { return true }
        guard let guardada = gestionada(g.ruta) else { return true }
        return guardada.modo != g.modo || guardada.ajustes != g.ajustes || guardada.propia != g.propia
    }

    /// La app no trae icono y no hay imagenes propias: no hay nada que poner
    var faltaIconoPropio: Bool {
        guard let g = borrador, diagnostico?.metodo == "sin icono propio" else { return false }
        return !(g.propia && tienePropias)
    }

    var puedeAplicar: Bool {
        guard let app = appSeleccionada, borrador != nil, !trabajando, !app.sistema, app.escribible, !faltaIconoPropio else { return false }
        // Sin cambios tambien se puede volver a poner un icono que falta
        return gestionada(app.ruta) == nil || cambiosSinAplicar || estadoFila(app) == .falta
    }

    var puedeRestaurar: Bool {
        guard let app = appSeleccionada, !trabajando else { return false }
        return app.personalizado || gestionada(app.ruta) != nil
    }

    func aplicar() {
        guard puedeAplicar, let g = borrador else { return }
        let variante = g.modo.variante(oscuroAhora: Almacen.oscuroAhora())
        let quitar = quitarPropiasPendiente
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let resultado: Result<(Configuracion, Gestionada, CGImage?), Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try Almacen.conBloqueo {
                        var config = Almacen.cargar()
                        let anterior = config.apps.first { $0.ruta == g.ruta }
                        // El arte se lee aqui y no al elegir: si la app cambio de icono mientras tanto, el
                        // icono y la huella que se sellan son los nuevos
                        let arte = Almacen.arteOriginal(g.ruta)
                        // Bundle, version y huella para reconocerla tras una actualizacion; y como salio el logo
                        let d = Almacen.diagnostico(g, arte: arte)
                        var guardada = Almacen.sellar(g)
                        guardada.confianza = d.confianza
                        guardada.metodo = d.metodo.isEmpty ? nil : d.metodo
                        // Las imagenes propias solo se tocan cuando el icono y la configuracion ya quedaron:
                        // si algo falla, Descartar vuelve de verdad a lo de antes
                        do {
                            try Almacen.generar(g, arte: arte, borrador: true)
                            try Aplicador.aplicar(icns: Almacen.icns(g.ruta, variante), a: g.ruta, variante: variante)
                            config.apps.removeAll { $0.ruta == g.ruta }
                            config.apps.append(guardada)
                            do {
                                try Almacen.guardar(config)
                            } catch {
                                // Sin configuracion el agente no lo cuidaria: mejor quitarlo que dejarlo suelto
                                if anterior == nil { try? Aplicador.restaurar(g.ruta) }
                                throw error
                            }
                        } catch {
                            // El agente usa estos icns: que vuelvan a ser los de lo guardado
                            if let anterior { try? Almacen.generar(anterior, arte: arte) }
                            throw error
                        }
                        if quitar { Almacen.quitarPropias(g.ruta) }
                        try Almacen.confirmarPropias(g.ruta)
                        return (config, guardada, arte)
                    }
                }
            }.value
            guard let self else { return }
            self.trabajando = false
            self.refrescarFila(g.ruta)
            let config: Configuracion
            switch resultado {
            case .failure(let fallo):
                self.mostrar(fallo)
                return
            case .success(let (c, guardada, arte)):
                config = c
                self.config = config
                if self.seleccion == g.ruta, self.arteDe == g.ruta {
                    // Las previas muestran el arte con el que se aplico
                    self.arte = arte
                    self.previaOriginal = arte.map { NSImage(cgImage: $0, size: .zero) }
                }
                // Lo sellado tambien es lo guardado: el borrador no queda con cambios sin aplicar
                if self.borrador?.ruta == g.ruta { self.borrador = guardada }
            }
            self.anotarGestionDeApps(true)
            if self.seleccion == g.ruta {
                self.propiasPendientes = false
                self.quitarPropiasPendiente = false
            }
            Almacen.resolverPendiente(ruta: g.ruta)
            self.pendientes = Almacen.pendientes()
            self.avisarAgente()
            let enDock = config.reiniciarDock && Aplicador.estaEnDock(g.ruta)
            self.mensaje = enDock ? String(localized: "Listo. El Dock se reinicia un momento para mostrarlo.") : String(localized: "Listo.")
            if enDock { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Aplicador.refrescarDock() } }
            if g.modo == .automatico, !self.agenteActivo { self.activarAgente() }
        }
    }

    func restaurar() {
        guard puedeRestaurar, let app = appSeleccionada else { return }
        let ruta = app.ruta
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let resultado: Result<(Configuracion, Bool), Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try Almacen.conBloqueo {
                        let anterior = Almacen.cargar()
                        var config = anterior
                        config.apps.removeAll { $0.ruta == ruta }
                        try Almacen.guardar(config)
                        do {
                            try Aplicador.restaurar(ruta)
                        } catch {
                            try? Almacen.guardar(anterior)
                            throw error
                        }
                        try? FileManager.default.removeItem(at: Almacen.carpeta(ruta))
                        // App de root con la ACL de Iconos: ya no hace falta
                        return (config, Aplicador.tieneACL(ruta) && access(ruta, W_OK) != 0)
                    }
                }
            }.value
            guard let self else { return }
            self.trabajando = false
            switch resultado {
            case .failure(let fallo):
                self.mostrar(fallo)
            case .success(let (config, conPermiso)):
                self.config = config
                self.anotarGestionDeApps(true)
                self.avisarAgente()
                if config.reiniciarDock, Aplicador.estaEnDock(ruta) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Aplicador.refrescarDock() }
                }
                self.refrescarFila(ruta)
                Almacen.resolverPendiente(ruta: ruta)
                self.pendientes = Almacen.pendientes()
                if self.seleccion == ruta { self.cargarSeleccion() }
                self.mensaje = String(localized: "Se restauró el icono original.")
                if conPermiso { self.permisoQueSobra = [ruta] }
            }
        }
    }

    /// Imagen propia (por ejemplo un icono dibujado a mano) para una variante. Queda de borrador
    /// hasta aplicar
    func elegirPropia(_ v: Variante) {
        guard var g = borrador else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .icns]
        panel.message = v == .claro ? String(localized: "Imagen cuadrada para la variante clara (idealmente 1024 × 1024)")
            : String(localized: "Imagen cuadrada para la variante oscura (idealmente 1024 × 1024)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let imagen = NSImage(contentsOf: url), let cg = Almacen.mejor(imagen) else {
            mostrarError(String(localized: "No se pudo leer la imagen."), codigo: nil)
            return
        }
        do {
            try FileManager.default.createDirectory(at: Almacen.carpeta(g.ruta), withIntermediateDirectories: true)
            try Lienzo.escribirPNG(cg, en: Almacen.propia(g.ruta, v, borrador: true))
            g.propia = true
            quitarPropiasPendiente = false
            propiasPendientes = true
            borrador = g
            actualizarPrevias()
        } catch {
            self.mostrar(error)
        }
    }

    func quitarPropias() {
        guard var g = borrador else { return }
        Almacen.descartarPropias(g.ruta)
        g.propia = false
        quitarPropiasPendiente = true
        propiasPendientes = true
        borrador = g
    }

    var tienePropias: Bool {
        guard let g = borrador else { return false }
        let fm = FileManager.default
        return Variante.allCases.contains {
            fm.fileExists(atPath: Almacen.propia(g.ruta, $0, borrador: true).path)
                || (!quitarPropiasPendiente && fm.fileExists(atPath: Almacen.propia(g.ruta, $0).path))
        }
    }

    private func refrescarFila(_ ruta: String) {
        guard let i = apps.firstIndex(where: { $0.ruta == ruta }) else { return }
        let a = apps[i]
        apps[i] = AppEncontrada(ruta: a.ruta, nombre: a.nombre, escribible: Aplicador.escribible(a.ruta),
                                personalizado: Aplicador.tieneIconoPersonalizado(a.ruta), sistema: a.sistema,
                                bloqueada: Aplicador.bloqueadaPorFabricante(a.ruta), bundleId: a.bundleId,
                                puesta: Aplicador.variantePuesta(a.ruta))
        oscuroLeido[ruta] = Almacen.oscuroAhora()
        NSWorkspace.shared.noteFileSystemChanged(ruta)
        // Un escaneo lanzado antes del cambio traeria la fila vieja: se repite
        if escaneando { escanear() }
    }

    /// El interruptor cambia en el acto; guardar espera el bloqueo (el agente puede tenerlo segundos)
    /// fuera del hilo principal
    var reiniciarDock: Bool {
        get { config.reiniciarDock }
        set {
            guard newValue != config.reiniciarDock else { return }
            config.reiniciarDock = newValue
            Task { [weak self] in
                let resultado = await Task.detached(priority: .userInitiated) {
                    Result {
                        try Almacen.conBloqueo {
                            var c = Almacen.cargar()
                            c.reiniciarDock = newValue
                            try Almacen.guardar(c)
                            return c
                        }
                    }
                }.value
                guard let self else { return }
                switch resultado {
                case .failure(let fallo):
                    self.mostrar(fallo)
                    self.config = Almacen.cargar()
                case .success(let c):
                    self.config = c
                    self.avisarAgente()
                }
            }
        }
    }

    // MARK: Carpetas de apps

    /// Carpetas con apps fuera de Aplicaciones (por ejemplo un disco externo); escanear las incluye
    func agregarCarpetas() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Agregar")
        panel.message = String(localized: "Elige carpetas con apps. Iconos ya busca en Aplicaciones y en la carpeta Aplicaciones de tu usuario.")
        guard panel.runModal() == .OK else { return }
        let fijas = Set(Estudio.carpetasFijas)
        let nuevas = panel.urls.map { $0.standardizedFileURL.path }
            .filter { !fijas.contains($0) && !config.carpetasExtra.contains($0) }
        guard !nuevas.isEmpty else { return }
        cambiarCarpetas { lista in
            for c in nuevas where !lista.contains(c) { lista.append(c) }
        }
    }

    func quitarCarpeta(_ carpeta: String) {
        cambiarCarpetas { $0.removeAll { $0 == carpeta } }
    }

    /// Como reiniciarDock: la lista cambia en el acto y se guarda con el bloqueo fuera del hilo
    /// principal. Despues se vigilan las carpetas nuevas y se escanea otra vez
    private func cambiarCarpetas(_ cambio: @escaping @Sendable (inout [String]) -> Void) {
        cambio(&config.carpetasExtra)
        Task { [weak self] in
            let resultado = await Task.detached(priority: .userInitiated) {
                Result {
                    try Almacen.conBloqueo {
                        var c = Almacen.cargar()
                        cambio(&c.carpetasExtra)
                        try Almacen.guardar(c)
                        return c
                    }
                }
            }.value
            guard let self, !self.desinstalando else { return }
            switch resultado {
            case .failure(let fallo):
                self.mostrar(fallo)
                self.config = Almacen.cargar()
            case .success(let c):
                self.config = c
                self.avisarAgente()
            }
            self.vigilarCarpetas()
            self.escanear()
        }
    }

    // MARK: Varias apps

    var appsElegidas: [AppEncontrada] { apps.filter { elegidas.contains($0.ruta) } }
    /// Las que se pueden cambiar ya (sin pedir permiso)
    var elegidasEscribibles: [AppEncontrada] { appsElegidas.filter { $0.escribible && !$0.sistema && !$0.bloqueada } }
    var elegidasRestaurables: [AppEncontrada] { appsElegidas.filter { $0.personalizado || gestionada($0.ruta) != nil } }

    /// Apariencia y estilo del panel: los que comparten las gestionadas elegidas, si los comparten
    private func prepararVarias() {
        let gs = elegidas.compactMap { gestionada($0) }
        let modos = Set(gs.map(\.modo)), estilos = Set(gs.map(\.ajustes.estilo))
        modoVarias = modos.count == 1 ? modos.first! : .automatico
        estiloVarias = estilos.count == 1 ? estilos.first! : .automatico
    }

    /// Aplica la apariencia y el estilo comunes a las elegidas escribibles: un solo bloqueo, un solo
    /// guardar, un refresco del Dock y un aviso al agente. Las imagenes propias ya aplicadas se conservan
    func aplicarVarias() {
        let lista = elegidasEscribibles
        guard !lista.isEmpty, !trabajando else { return }
        let saltadas = appsElegidas.count - lista.count
        let modo = modoVarias, estilo = estiloVarias
        let objetivos = lista.map { (ruta: $0.ruta, nombre: $0.nombre) }
        let variante = modo.variante(oscuroAhora: Almacen.oscuroAhora())
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let (config, hechas, errores, codigos) = await Task.detached(priority: .userInitiated) { () -> (Configuracion?, [String], [String], [ErrorIconos.Codigo]) in
                var errores: [String] = [], hechas: [String] = [], codigos: [ErrorIconos.Codigo] = []
                do {
                    let config = try Almacen.conBloqueo { () throws -> Configuracion in
                        var config = Almacen.cargar()
                        var nuevas: [String] = []
                        var anteriores: [(Gestionada, CGImage?)] = []
                        for app in objetivos {
                            // Lo guardado recien leido (otro proceso pudo poner imagenes propias o tamanos):
                            // solo cambian la apariencia y el estilo
                            var g = config.apps.first { $0.ruta == app.ruta } ?? Gestionada(ruta: app.ruta, nombre: app.nombre)
                            g.modo = modo
                            g.ajustes.estilo = estilo
                            let arte = Almacen.arteOriginal(g.ruta)
                            let d = Almacen.diagnostico(g, arte: arte)
                            if d.metodo == "sin icono propio", !g.propia {
                                errores.append(String(localized: "\(g.nombre): no trae icono propio; elige tus imágenes"))
                                continue
                            }
                            let anterior = config.apps.first { $0.ruta == g.ruta }
                            do {
                                try Almacen.generar(g, arte: arte)
                                try Aplicador.aplicar(icns: Almacen.icns(g.ruta, variante), a: g.ruta, variante: variante)
                            } catch {
                                if let anterior { try? Almacen.generar(anterior, arte: arte) }
                                errores.append("\(g.nombre): \(error.localizedDescription)")
                                if let codigo = (error as? ErrorIconos)?.codigo { codigos.append(codigo) }
                                continue
                            }
                            var guardada = Almacen.sellar(g)
                            guardada.confianza = d.confianza
                            guardada.metodo = d.metodo.isEmpty ? nil : d.metodo
                            config.apps.removeAll { $0.ruta == g.ruta }
                            config.apps.append(guardada)
                            if let anterior { anteriores.append((anterior, arte)) } else { nuevas.append(g.ruta) }
                            hechas.append(g.ruta)
                        }
                        guard !hechas.isEmpty else { return config }
                        do {
                            try Almacen.guardar(config)
                        } catch {
                            // Como con una sola: sin configuracion, fuera los iconos nuevos y los icns vuelven a lo guardado
                            for ruta in nuevas { try? Aplicador.restaurar(ruta) }
                            for (anterior, arte) in anteriores { try? Almacen.generar(anterior, arte: arte) }
                            throw error
                        }
                        return config
                    }
                    return (config, hechas, errores, codigos)
                } catch {
                    return (nil, [], errores + [error.localizedDescription], codigos + [(error as? ErrorIconos)?.codigo].compactMap { $0 })
                }
            }.value
            guard let self else { return }
            self.trabajando = false
            if let config { self.config = config }
            for ruta in lista.map(\.ruta) { self.refrescarFila(ruta) }
            for ruta in hechas { Almacen.resolverPendiente(ruta: ruta) }
            self.pendientes = Almacen.pendientes()
            if !hechas.isEmpty {
                self.anotarGestionDeApps(true)
                self.avisarAgente()
                let enDock = self.config.reiniciarDock && hechas.contains { Aplicador.estaEnDock($0) }
                if enDock { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Aplicador.refrescarDock() } }
                if modo == .automatico, !self.agenteActivo { self.activarAgente() }
                var texto = hechas.count == 1 ? String(localized: "Listo: 1 app.") : String(localized: "Listo: \(hechas.count) apps.")
                if saltadas > 0 { texto += " " + String(localized: "\(saltadas) no se podían cambiar.") }
                self.mensaje = texto
            }
            if !errores.isEmpty { self.mostrarError(errores.joined(separator: "\n"), codigo: Estudio.masUtil(codigos)) }
        }
    }

    /// Restaura las elegidas que tienen icono personalizado, con un solo bloqueo y un solo guardar
    func restaurarVarias() {
        let lista = elegidasRestaurables.map { (ruta: $0.ruta, nombre: $0.nombre) }
        guard !lista.isEmpty, !trabajando else { return }
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let (config, hechas, errores, conPermiso, codigos) = await Task.detached(priority: .userInitiated) { () -> (Configuracion?, [String], [String], [String], [ErrorIconos.Codigo]) in
                var errores: [String] = [], hechas: [String] = [], codigos: [ErrorIconos.Codigo] = []
                do {
                    let config = try Almacen.conBloqueo { () throws -> Configuracion in
                        var config = Almacen.cargar()
                        for app in lista {
                            do {
                                try Aplicador.restaurar(app.ruta)
                                hechas.append(app.ruta)
                            } catch {
                                errores.append("\(app.nombre): \(error.localizedDescription)")
                                if let codigo = (error as? ErrorIconos)?.codigo { codigos.append(codigo) }
                            }
                        }
                        config.apps.removeAll { hechas.contains($0.ruta) }
                        try Almacen.guardar(config)
                        for ruta in hechas { try? FileManager.default.removeItem(at: Almacen.carpeta(ruta)) }
                        return config
                    }
                    let conPermiso = hechas.filter { Aplicador.tieneACL($0) && access($0, W_OK) != 0 }
                    return (config, hechas, errores, conPermiso, codigos)
                } catch {
                    // Los iconos quitados siguen en la configuracion: el agente los vuelve a poner
                    return (nil, [], errores + [error.localizedDescription], [], codigos + [(error as? ErrorIconos)?.codigo].compactMap { $0 })
                }
            }.value
            guard let self else { return }
            self.trabajando = false
            if let config { self.config = config }
            for app in lista { self.refrescarFila(app.ruta) }
            for ruta in hechas { Almacen.resolverPendiente(ruta: ruta) }
            self.pendientes = Almacen.pendientes()
            if !hechas.isEmpty {
                self.anotarGestionDeApps(true)
                self.avisarAgente()
                if self.config.reiniciarDock, hechas.contains(where: { Aplicador.estaEnDock($0) }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Aplicador.refrescarDock() }
                }
                self.mensaje = hechas.count == 1 ? String(localized: "Se restauró 1 app.") : String(localized: "Se restauraron \(hechas.count) apps.")
                self.permisoQueSobra = conPermiso
            }
            if !errores.isEmpty { self.mostrarError(errores.joined(separator: "\n"), codigo: Estudio.masUtil(codigos)) }
        }
    }

    /// De varios errores, el codigo cuyo boton arregla mas: Gestion de apps frena todas las apps
    nonisolated private static func masUtil(_ codigos: [ErrorIconos.Codigo]) -> ErrorIconos.Codigo? {
        codigos.contains(.sinGestionDeApps) ? .sinGestionDeApps : codigos.first
    }

    // MARK: Mantenimiento

    /// Todas las gestionadas vuelven a su icono (restaurarTodas toma el bloqueo, reinicia el Dock y
    /// avisa al agente)
    func restaurarTodas(conservarPropias: Bool) {
        guard !trabajando else { return }
        let rutas = config.apps.map(\.ruta)
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let (errores, conPermiso) = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
                let errores = Almacen.restaurarTodas(conservarPropias: conservarPropias)
                let quedan = Set(Almacen.cargar().apps.map(\.ruta))
                return (errores, rutas.filter { !quedan.contains($0) && Aplicador.tieneACL($0) && access($0, W_OK) != 0 })
            }.value
            guard let self else { return }
            self.trabajando = false
            self.config = Almacen.cargar()
            for ruta in rutas { self.refrescarFila(ruta) }
            if self.seleccion != nil { self.cargarSeleccion() }
            let hechas = rutas.count - self.config.apps.filter { rutas.contains($0.ruta) }.count
            if hechas > 0 || errores.isEmpty {
                self.mensaje = hechas == 1 ? String(localized: "Se restauró 1 app.") : String(localized: "Se restauraron \(hechas) apps.")
                self.permisoQueSobra = conPermiso
            }
            if !errores.isEmpty { self.mostrarError(errores.joined(separator: "\n"), codigo: nil) }
        }
    }

    /// Guarda la configuracion y las imagenes propias en un .zip
    func exportar() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Iconos.zip"
        panel.message = String(localized: "Guarda los ajustes de Iconos y tus imágenes propias para llevarlos a otro Mac.")
        guard panel.runModal() == .OK, let url = panel.url, !trabajando else { return }
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let resultado = await Task.detached(priority: .userInitiated) { Result { try Almacen.exportar(a: url) } }.value
            guard let self else { return }
            self.trabajando = false
            switch resultado {
            case .failure(let fallo): self.mostrar(fallo)
            case .success: self.mensaje = String(localized: "Se guardó la configuración en \(url.lastPathComponent).")
            }
        }
    }

    /// Lee un .zip de exportar (importar toma el bloqueo); el agente pone los iconos
    func importar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = String(localized: "Elige un .zip exportado desde Iconos.")
        guard panel.runModal() == .OK, let url = panel.url, !trabajando else { return }
        trabajando = true
        limpiarAvisos()
        Task { [weak self] in
            let resultado = await Task.detached(priority: .userInitiated) { Result { try Almacen.importar(de: url) } }.value
            guard let self else { return }
            self.trabajando = false
            self.config = Almacen.cargar()
            if self.seleccion != nil { self.cargarSeleccion() }
            switch resultado {
            case .failure(let fallo):
                self.mostrar(fallo)
            case .success(let n):
                self.avisarAgente()
                let cuantas = n == 1 ? String(localized: "1 app") : String(localized: "\(n) apps")
                self.mensaje = self.agenteActivo
                    ? String(localized: "Se importaron \(cuantas). El cambio automático les pone el icono.")
                    : String(localized: "Se importaron \(cuantas). Activa el cambio automático para que se les ponga el icono.")
            }
            self.escanear()
        }
    }

    /// Deja el Mac como antes de Iconos. Con errores no se desinstalo nada y se puede reintentar. Si hay
    /// permisos que quitar, el guion de Terminal borra los datos y tira Iconos.app: la ventana solo termina.
    /// Si no, los datos ya se borraron y la ventana tira la app y termina
    func desinstalar() {
        guard !trabajando else { return }
        trabajando = true
        limpiarAvisos()
        // Antes de empezar: el reloj o un escaneo volverian a crear la carpeta de datos
        pararVigilancia()
        Task { [weak self] in
            let (errores, terminal) = await Task.detached(priority: .userInitiated) { Almacen.desinstalar() }.value
            guard let self else { return }
            self.trabajando = false
            self.revisarAgente()
            if !errores.isEmpty {
                // Sigue instalado: la ventana vuelve a funcionar con lo que quedo
                self.reanudarVigilancia()
                self.config = Almacen.cargar()
                if self.seleccion != nil { self.cargarSeleccion() }
                self.escanear()
                self.erroresDesinstalar = errores
            } else if terminal {
                Estudio.borrarPreferencias()
                NSApp.terminate(nil)
            } else {
                Estudio.borrarPreferencias()
                self.terminarDesinstalacion()
            }
        }
    }

    /// Lo que la ventana guarda en UserDefaults (guia vista, Gestion de apps, no volver a mostrar)
    private static func borrarPreferencias() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
    }

    /// Mueve Iconos.app (con el agente dentro) a la Papelera y termina
    private func terminarDesinstalacion() {
        let bundle = Bundle.main.bundleURL
        // Compilado con swift build no hay .app: no se tira la carpeta de compilacion
        guard bundle.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        NSWorkspace.shared.recycle([bundle]) { [weak self] _, fallo in
            DispatchQueue.main.async {
                if let fallo {
                    self?.mostrarError(String(localized: "No se pudo mover Iconos a la Papelera (\(fallo.localizedDescription)). Arrástrala tú."), codigo: nil)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: Agente

    var agenteActivo: Bool { estadoAgente == .activo || estadoAgente == .arrancando }

    func revisarAgente() {
        // Apagado, lo anotado es de antes y ya no cuenta
        var informe: EstadoAgente?
        if !ServicioAgente.registrado() {
            estadoAgente = .apagado
        } else {
            informe = EstadoAgente.leer()
            if !ServicioAgente.apuntaAEsteEjecutable() {
                estadoAgente = .otraCopia
            } else if ServicioAgente.respondio() {
                estadoAgente = Estudio.deOtraVersion(informe) ? .otraVersion : .activo
            } else {
                estadoAgente = Date() < arrancandoHasta ? .arrancando : .sinRespuesta
            }
        }
        if informe != informeAgente { informeAgente = informe }
    }

    /// El agente que corre es de otra version que esta app. Solo cuenta un estado escrito en la revision
    /// del ultimo latido: tras Reparar, el que dejo el agente viejo no dice nada del nuevo. El estado
    /// guarda la fecha sin fracciones de segundo, de ahi el margen
    private static func deOtraVersion(_ informe: EstadoAgente?) -> Bool {
        guard let informe, let suya = informe.version,
              let mia = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let latido = (try? FileManager.default.attributesOfItem(atPath: Almacen.latido.path))?[.modificationDate] as? Date,
              informe.fecha >= latido.addingTimeInterval(-2) else { return false }
        return suya != mia
    }

    /// Gestion de apps para Iconos Agente segun lo que anoto: nil si no se sabe (apagado o sin intentar
    /// escribir todavia en ninguna app)
    var agenteConGestionDeApps: Bool? {
        guard agenteActivo, let informe = informeAgente else { return nil }
        return informe.gestionDeApps
    }

    /// Tambien repara: vuelve a escribir el plist con este ejecutable y lo recarga
    func activarAgente() {
        do {
            try? FileManager.default.removeItem(at: Almacen.latido)
            try ServicioAgente.instalar()
            arrancandoHasta = Date().addingTimeInterval(12)
            mensaje = String(localized: "El agente quedó activo: mantiene los iconos y los cambia con el modo claro u oscuro.")
        } catch {
            self.mostrar(error)
        }
        revisarAgente()
        for espera in [2.0, 13.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + espera) { [weak self] in self?.revisarAgente() }
        }
    }

    func desactivarAgente() {
        ServicioAgente.desinstalar()
        revisarAgente()
    }

    /// El agente vacia sus reintentos y revisa ya
    func avisarAgente() {
        DistributedNotificationCenter.default().postNotificationName(Almacen.aviso, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Comprobar otra vez (guia) y volver a la app: el agente prueba ya lo que fallo (por ejemplo tras
    /// activar Gestion de apps) y se relee lo que anoto cuando termina su revision
    func comprobarAgente() {
        avisarAgente()
        revisarAgente()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.revisarAgente() }
    }

    // MARK: Configuracion danada

    /// config.json no se pudo leer: se guardo una copia y no se escribe nada hasta que se revise
    var configDanada: Bool { Almacen.configDanada }

    func mostrarDatosEnFinder() {
        NSWorkspace.shared.open(Almacen.base)
    }

    // MARK: Primeros pasos

    /// La guia se abre sola la primera vez (y con --bienvenida)
    var mostrarBienvenidaAlAbrir: Bool {
        !UserDefaults.standard.bool(forKey: Estudio.claveBienvenida) || CommandLine.arguments.contains("--bienvenida")
    }

    func bienvenidaVista() {
        UserDefaults.standard.set(true, forKey: Estudio.claveBienvenida)
    }

    /// Donde corre esta copia. macOS abre una app descargada y sin mover desde una copia temporal de
    /// solo lectura (App Translocation): el agente apuntaria a una ruta que desaparece
    static var ubicacion: UbicacionApp {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return .sinPaquete }
        let ruta = bundle.resolvingSymlinksInPath().path
        if ruta.contains("/AppTranslocation/") { return .translocada }
        let carpeta = (ruta as NSString).deletingLastPathComponent
        let casa = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return carpeta == "/Applications" || carpeta == casa ? .aplicaciones : .otra
    }

    /// En otro disco o en uno de solo lectura, moveItem copia y luego borra el origen: si no puede
    /// borrarlo falla con la copia ya hecha en Aplicaciones. Ahi se copia y el origen se queda
    static var seCopiaAAplicaciones: Bool {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return true }
        func disco(_ ruta: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: ruta))?[.systemNumber] as? Int
        }
        guard let deBundle = disco(bundle.path), let deAplicaciones = disco("/Applications") else { return true }
        return deBundle != deAplicaciones
    }

    /// Mueve (o copia, si esta en otro disco) esta copia a /Applications/Iconos.app, la abre desde alli
    /// con la guia y cierra esta. Una copia translocada no se puede mover: hay que arrastrarla
    func moverAAplicaciones() {
        guard Estudio.ubicacion == .otra, !trabajando else { return }
        limpiarAvisos()
        let fm = FileManager.default
        let destino = URL(fileURLWithPath: "/Applications/Iconos.app")
        guard !fm.fileExists(atPath: destino.path) else {
            mostrarError(String(localized: "Ya hay otra copia de Iconos en Aplicaciones. Ciérrala, muévela a la Papelera y vuelve a intentarlo."), codigo: nil)
            return
        }
        let copiar = Estudio.seCopiaAAplicaciones
        let conAgente = ServicioAgente.registrado()
        do {
            if copiar {
                try fm.copyItem(at: Bundle.main.bundleURL, to: destino)
            } else {
                try fm.moveItem(at: Bundle.main.bundleURL, to: destino)
            }
        } catch {
            // Una copia a medias haria decir "Ya hay otra copia" al reintentar (antes no habia nada)
            if copiar { try? fm.removeItem(at: destino) }
            let motivo = error.localizedDescription
            mostrarError(copiar ? String(localized: "No se pudo copiar Iconos a Aplicaciones (\(motivo)). Arrástrala tú en Finder.")
                : String(localized: "No se pudo mover Iconos a Aplicaciones (\(motivo)). Arrástrala tú en Finder."), codigo: nil)
            return
        }
        var argumentos = ["--bienvenida"]
        if conAgente {
            // El agente apuntaba dentro de esta copia. Bundle.main.bundleURL sigue dando la ruta de antes
            // aunque la app se haya movido: hay que decirle cual instalar
            do {
                try ServicioAgente.instalar(bundle: destino)
            } catch {
                // La copia nueva lo instala al abrir con su propia ruta y muestra el error si sigue fallando
                argumentos.append("--reparar-agente")
            }
        }
        let ajustes = NSWorkspace.OpenConfiguration()
        // Con el mismo identificador, sin esto macOS solo traeria al frente esta copia
        ajustes.createsNewApplicationInstance = true
        ajustes.arguments = argumentos
        NSWorkspace.shared.openApplication(at: destino, configuration: ajustes) { [weak self] _, fallo in
            DispatchQueue.main.async {
                if let fallo {
                    var texto = String(localized: "Iconos ya está en Aplicaciones, pero no se pudo abrir (\(fallo.localizedDescription)). Ábrela desde allí.")
                    if argumentos.contains("--reparar-agente") { texto += " " + String(localized: "Después pulsa Reparar en el cambio automático.") }
                    self?.mostrarError(texto, codigo: nil)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Donde corre Iconos (primer paso de la guia)
enum UbicacionApp {
    case aplicaciones
    /// Abierta sin mover desde Descargas: macOS la corre desde una copia temporal
    case translocada
    case otra
    /// Compilada con swift build, sin .app
    case sinPaquete
}
