import Foundation

/// Una instancia en marcha de una app con la opcion Mantener el icono de Iconos en el Dock
struct ObjetivoParche: Sendable, Equatable {
    let pid: pid_t
    /// launchDate de la instancia: junto al pid evita confundir un pid reutilizado
    let inicio: TimeInterval
    let ruta: String
    let nombre: String
    /// NSRunningApplication.isFinishedLaunching
    let listo: Bool

    var clave: String { "\(pid)-\(Int(inicio))" }
}

private struct ErrorParche: LocalizedError {
    let texto: String
    init(_ texto: String) { self.texto = texto }
    var errorDescription: String? { texto }
}

/// Lo que hace el agente por cada instancia de una app de Electron con la opcion activada:
///
/// 1. Comprueba que el proceso tiene manejador de SIGUSR1 (ParcheDock.senalCapturada). Sin el, la senal
///    terminaria la app. Tambien que la app admite la opcion (fusible del inspector) y que el puerto 9229
///    esta libre.
/// 2. Le manda SIGUSR1: Electron abre el inspector de Node en 127.0.0.1:9229.
/// 3. Se conecta, comprueba que quien responde es el pid esperado y su ejecutable, y evalua un script que
///    cambia app.dock.setIcon por una funcion vacia y pide al Dock el icono del bundle
///    (setApplicationIconImage nil). Todo en memoria: la app no se modifica y se pierde al cerrarla.
/// 4. Cierra el inspector y comprueba que el puerto quedo libre.
///
/// El puerto esta abierto menos de un segundo, solo en el bucle local. Mientras tanto cualquier proceso
/// del mismo equipo podria conectarse, igual que con un node --inspect: por eso solo se hace con las apps
/// que el usuario eligio y se comprueba el pid antes de evaluar nada.
actor MantenedorDock {
    static let compartido = MantenedorDock()

    private enum Resultado {
        case hecho
        /// Todavia no se puede (recien abierta, sin manejador de la senal): no cuenta como intento
        case esperar
        /// No corresponde y no va a cambiar mientras corra esta instancia
        case omitir(String)
        /// El puerto lo tiene otro proceso: no se hizo nada en la app, asi que no cuenta como intento
        case ocupado
        case fallo(String)
    }

    private static let maximoIntentos = 4
    private static let esperaTrasFallo: TimeInterval = 10
    /// Agotados los intentos, la instancia se vuelve a probar pasado este tiempo
    private static let esperaTrasAgotar: TimeInterval = 600
    private static let esperaPuertoOcupado: TimeInterval = 30
    /// Una app sin manejador de SIGUSR1 tras tanto tiempo abierta no lo va a tener
    private static let esperaMaxima: TimeInterval = 45

    private var hechos: Set<String> = []
    private var fallos: [String: (intentos: Int, hasta: Date)] = [:]
    /// Instancias para las que ya se anoto que el puerto lo tiene otro proceso (se anota una vez)
    private var avisadoOcupado: Set<String> = []
    private var ocupado = false
    private let sesion: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    /// Devuelve si conviene volver a mirar pronto (alguna instancia quedo esperando o en reintento)
    func mantener(_ objetivos: [ObjetivoParche]) async -> Bool {
        guard !ocupado else { return true }
        ocupado = true
        defer { ocupado = false }
        let vivos = Set(objetivos.map(\.clave))
        hechos.formIntersection(vivos)
        fallos = fallos.filter { vivos.contains($0.key) }
        avisadoOcupado.formIntersection(vivos)
        var pendiente = false
        for o in objetivos where !hechos.contains(o.clave) {
            if let f = fallos[o.clave] {
                // Un inspector que la app abrio tarde (tras un intento fallido) no espera al siguiente intento
                if Date() < f.hasta, ParcheDock.escuchaEnPuerto(o.pid) {
                    _ = await asegurarPuertoCerrado(pid: o.pid, ruta: o.ruta)
                }
                if f.intentos >= Self.maximoIntentos {
                    // Agotada: se vuelve a probar con intentos nuevos pasado un rato
                    guard Date() >= f.hasta else { continue }
                    fallos[o.clave] = nil
                } else if Date() < f.hasta {
                    // Los reintentos cortos los pide el agente; el puerto ocupado espera al temporizador
                    if f.intentos > 0 { pendiente = true }
                    continue
                }
            }
            switch await intentar(o) {
            case .hecho:
                hechos.insert(o.clave)
                fallos[o.clave] = nil
            case .esperar:
                pendiente = true
            case .omitir(let motivo):
                hechos.insert(o.clave)
                Registro.escribir("\(o.nombre): Dock sin parche, \(motivo)")
            case .ocupado:
                // No se toco la app: ni cuenta como intento ni se mira cada pocos segundos
                fallos[o.clave] = (fallos[o.clave]?.intentos ?? 0, Date().addingTimeInterval(Self.esperaPuertoOcupado))
                if avisadoOcupado.insert(o.clave).inserted {
                    Registro.escribir("\(o.nombre): el puerto \(ParcheDock.puerto) lo tiene otro proceso; se vuelve a probar más tarde")
                }
            case .fallo(let motivo):
                let intentos = (fallos[o.clave]?.intentos ?? 0) + 1
                if intentos >= Self.maximoIntentos {
                    fallos[o.clave] = (intentos, Date().addingTimeInterval(Self.esperaTrasAgotar))
                    Registro.escribir("\(o.nombre): no se pudo mantener el icono en el Dock (\(motivo)); se vuelve a probar en 10 minutos")
                } else {
                    fallos[o.clave] = (intentos, Date().addingTimeInterval(Self.esperaTrasFallo))
                    Registro.escribir("\(o.nombre): icono del Dock, intento \(intentos) de \(Self.maximoIntentos) sin exito (\(motivo))")
                    pendiente = true
                }
            }
        }
        return pendiente
    }

    /// Cambio de configuracion (por ejemplo apagar y encender la opcion): las instancias que agotaron
    /// intentos o esperan por el puerto se prueban otra vez
    func olvidarFallos() {
        fallos.removeAll()
        avisadoOcupado.removeAll()
    }

    private func intentar(_ o: ObjetivoParche) async -> Resultado {
        let edad = Date().timeIntervalSince1970 - o.inicio
        guard o.listo, edad >= 2 else { return .esperar }
        switch ParcheDock.disponibilidad(o.ruta) {
        case .disponible: break
        case .noEsElectron: return .omitir("no es una app de Electron")
        case .noDisponible: return .omitir("el fabricante desactivó el inspector de Electron o su Electron es anterior al \(ParcheDock.electronMinimo)")
        }
        // Sin manejador, SIGUSR1 mata el proceso: nunca se manda sin comprobarlo
        guard ParcheDock.senalCapturada(o.pid) else {
            return edad > Self.esperaMaxima ? .omitir("la app no atiende SIGUSR1") : .esperar
        }
        if ParcheDock.puertoAbierto() {
            // Resto de un intento anterior de esta instancia (o del agente anterior): se cierra, pero solo
            // si el nucleo dice que el oyente es esta app. Si es de otro proceso no se le conecta nada y no
            // se manda la senal
            guard ParcheDock.escuchaEnPuerto(o.pid) else { return .ocupado }
            _ = await asegurarPuertoCerrado(pid: o.pid, ruta: o.ruta)
            if ParcheDock.puertoAbierto() { return .ocupado }
        }
        guard kill(o.pid, SIGUSR1) == 0 else { return .fallo("no se pudo avisar al proceso (errno \(errno))") }
        var cliente: ClienteInspector?
        // Solo se evalua algo mas (parche o cierre) en un proceso ya identificado como la app
        var verificado = false
        do {
            let c = try await abrirInspector(pid: o.pid)
            cliente = c
            guard try await esLaApp(c, pid: o.pid, ruta: o.ruta) else {
                // El puerto es de otro proceso: no se toca, ni siquiera para cerrarlo
                c.cancelar()
                return .fallo("el inspector abierto no es de la app esperada")
            }
            verificado = true
            let respuesta = try await c.evaluar(Self.script)
            try await cerrar(c)
            guard let rd = respuesta.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: rd) as? [String: Any],
                  let estado = r["estado"] as? String else { return .fallo("respuesta inesperada de la app") }
            switch estado {
            case "parcheado":
                Registro.escribir("\(o.nombre): icono del Dock fijado (pid \(o.pid)); \(r["reinicio"] as? String ?? "")")
                return .hecho
            case "ya-parcheado":
                return .hecho
            case "sin-dock", "sin-setIcon":
                return .omitir("la app no tiene app.dock.setIcon")
            default:
                return .fallo("estado \(estado) \(r["error"] as? String ?? "")")
            }
        } catch {
            if let c = cliente {
                if verificado { try? await cerrar(c) } else { c.cancelar() }
            }
            _ = await asegurarPuertoCerrado(pid: o.pid, ruta: o.ruta)
            return .fallo(error.localizedDescription)
        }
    }

    /// El proceso que responde en el inspector es el pid esperado y su ejecutable esta dentro de la app
    private func esLaApp(_ c: ClienteInspector, pid: pid_t, ruta: String) async throws -> Bool {
        let quien = try await c.evaluar("JSON.stringify({pid: process.pid, exec: process.execPath})")
        guard let d = quien.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = j["pid"] as? Int, p == Int(pid), let exec = j["exec"] as? String else { return false }
        return esDentro(exec, de: ruta)
    }

    // MARK: Inspector

    /// Espera el inspector abierto por SIGUSR1 (hasta 6 s) y se conecta. Solo habla con el puerto si el
    /// nucleo dice que lo escucha el pid esperado: un oyente ajeno no recibe ni la peticion HTTP
    private func abrirInspector(pid: pid_t) async throws -> ClienteInspector {
        let url = URL(string: "http://127.0.0.1:\(ParcheDock.puerto)/json/list")!
        // Plazo total: un oyente que acepta y no responde no debe bloquear el actor
        let limite = Date().addingTimeInterval(6)
        while Date() < limite {
            try await Task.sleep(nanoseconds: 150_000_000)
            guard ParcheDock.escuchaEnPuerto(pid) else { continue }
            guard let (datos, _) = try? await sesion.data(from: url),
                  let lista = try? JSONSerialization.jsonObject(with: datos) as? [[String: Any]],
                  let texto = lista.first?["webSocketDebuggerUrl"] as? String, let ws = URL(string: texto),
                  ws.scheme == "ws", ws.host == "127.0.0.1", ws.port == Int(ParcheDock.puerto) else { continue }
            return ClienteInspector(url: ws, sesion: sesion)
        }
        throw ErrorParche("el inspector no se abrió en 6 s")
    }

    /// Cierra el inspector (la conexion se corta al cerrar, no hay respuesta) y comprueba el puerto
    private func cerrar(_ c: ClienteInspector) async throws {
        c.enviarSinEsperar(Self.cierre)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !ParcheDock.puertoAbierto() { c.cancelar(); return }
        }
        c.cancelar()
        throw ErrorParche("el puerto \(ParcheDock.puerto) siguió abierto tras cerrar el inspector")
    }

    /// Si el inspector abierto es el de la app (segun el nucleo y luego por pid y ejecutable), se cierra;
    /// si es de otro proceso no se le conecta nada. Devuelve si el puerto queda libre
    private func asegurarPuertoCerrado(pid: pid_t, ruta: String) async -> Bool {
        guard ParcheDock.puertoAbierto() else { return true }
        guard ParcheDock.escuchaEnPuerto(pid), let c = try? await abrirInspector(pid: pid) else { return false }
        if (try? await esLaApp(c, pid: pid, ruta: ruta)) == true {
            try? await cerrar(c)
        } else {
            c.cancelar()
        }
        return !ParcheDock.puertoAbierto()
    }

    private func esDentro(_ ejecutable: String, de ruta: String) -> Bool {
        let base = URL(fileURLWithPath: ruta).resolvingSymlinksInPath().path + "/"
        return URL(fileURLWithPath: ejecutable).resolvingSymlinksInPath().path.hasPrefix(base)
    }

    /// Cierra el inspector con la misma cadena de respaldos que el script. Las versiones de Electron que
    /// admite ParcheDock traen process.getBuiltinModule; los respaldos son por si acaso
    private static let cierre = """
    (() => {
      let i = null;
      try { i = process.getBuiltinModule('inspector'); } catch (_) {}
      if (!i && process.mainModule) { try { i = process.mainModule.require('inspector'); } catch (_) {} }
      try { if (i) { i.close(); } else { process._debugEnd(); } } catch (_) {}
    })()
    """

    /// Se evalua en el proceso principal de Electron. Devuelve un JSON con el estado. Es idempotente:
    /// la funcion vacia lleva una marca. app.dock.setIcon(null) deja el icono del bundle (Electron lo
    /// pasa a setApplicationIconImage:nil)
    private static let script = """
    (() => {
      const r = {};
      try {
        let e = null;
        try { e = process.getBuiltinModule('module').createRequire(process.execPath)('electron'); } catch (_) {}
        if (!e && process.mainModule) { try { e = process.mainModule.require('electron'); } catch (_) {} }
        if (!e || !e.app || !e.app.dock) { r.estado = 'sin-dock'; return JSON.stringify(r); }
        const dock = e.app.dock;
        const actual = dock.setIcon;
        if (typeof actual !== 'function') { r.estado = 'sin-setIcon'; return JSON.stringify(r); }
        if (actual.__iconos === true) { r.estado = 'ya-parcheado'; return JSON.stringify(r); }
        const vacia = function setIcon() {};
        vacia.__iconos = true;
        dock.setIcon = vacia;
        r.estado = dock.setIcon === vacia ? 'parcheado' : 'no-quedo';
        try { actual.call(dock, null); r.reinicio = 'icono del bundle restaurado'; }
        catch (err) { r.reinicio = 'no se pudo restaurar el icono: ' + String(err && err.message || err); }
      } catch (err) { r.estado = 'error'; r.error = String(err && err.message || err); }
      return JSON.stringify(r);
    })()
    """
}

/// Cliente minimo del protocolo del inspector (Chrome DevTools Protocol) para Runtime.evaluate
private final class ClienteInspector: @unchecked Sendable {
    private let tarea: URLSessionWebSocketTask
    private var siguiente = 0

    init(url: URL, sesion: URLSession) {
        tarea = sesion.webSocketTask(with: url)
        tarea.resume()
    }

    func cancelar() { tarea.cancel(with: .goingAway, reason: nil) }

    func enviarSinEsperar(_ expresion: String) {
        siguiente += 1
        guard let datos = mensaje(siguiente, expresion) else { return }
        tarea.send(.string(String(decoding: datos, as: UTF8.self))) { _ in }
    }

    /// Evalua la expresion y devuelve su valor, que debe ser un texto. Con tope de 5 s
    func evaluar(_ expresion: String) async throws -> String {
        siguiente += 1
        let id = siguiente
        guard let datos = mensaje(id, expresion) else { throw ErrorParche("mensaje no válido") }
        return try await conLimite(5) { [self] in
            try await tarea.send(.string(String(decoding: datos, as: UTF8.self)))
            while true {
                let m = try await tarea.receive()
                let texto: String
                switch m {
                case .string(let s): texto = s
                case .data(let d): texto = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                guard let d = texto.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      (j["id"] as? Int) == id else { continue }
                guard let res = j["result"] as? [String: Any], res["exceptionDetails"] == nil,
                      let valor = (res["result"] as? [String: Any])?["value"] as? String else {
                    throw ErrorParche("la app devolvió un error al evaluar")
                }
                return valor
            }
        }
    }

    private func mensaje(_ id: Int, _ expresion: String) -> Data? {
        let msg: [String: Any] = ["id": id, "method": "Runtime.evaluate",
                                  "params": ["expression": expresion, "returnByValue": true]]
        return try? JSONSerialization.data(withJSONObject: msg)
    }

    /// Si vence el tiempo se cancela el WebSocket para que el receive pendiente termine
    private func conLimite<T: Sendable>(_ segundos: Double, _ trabajo: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { grupo in
            grupo.addTask { try await trabajo() }
            grupo.addTask { [self] in
                try await Task.sleep(nanoseconds: UInt64(segundos * 1_000_000_000))
                cancelar()
                throw ErrorParche("tiempo agotado esperando al inspector")
            }
            defer { grupo.cancelAll() }
            guard let primero = try await grupo.next() else { throw ErrorParche("sin respuesta") }
            return primero
        }
    }
}
