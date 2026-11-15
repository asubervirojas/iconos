import Foundation

/// Comprobaciones de la opcion "Mantener el icono de Iconos en el Dock" (Gestionada.mantenerIconoDock).
///
/// Algunas apps de Electron llaman a app.dock.setIcon en cada ventana nueva (Antigravity), y el Dock
/// ensena entonces el icono del fabricante mientras la app corre, por encima del de Iconos. Un reinicio
/// del Dock no lo quita: la app lo vuelve a mandar. La opcion lo resuelve en memoria, sin escribir en la
/// app: el agente (MantenedorDock) activa el inspector de Electron un instante, cambia app.dock.setIcon
/// por una funcion vacia y devuelve el Dock al icono del bundle. Se pierde al cerrar la app.
///
/// Este archivo solo tiene lo que se puede comprobar sin tocar ninguna app: si la app admite la opcion,
/// y las dos comprobaciones de seguridad que el agente hace antes de actuar.
enum DisponibilidadParche: Equatable {
    /// Electron con el inspector permitido por el fabricante
    case disponible
    /// Electron, pero el fabricante apago el inspector (fusible EnableNodeCliInspectArguments) o no se
    /// pudo leer el fusible. Sin inspector no hay forma de hacerlo
    case noDisponible
    case noEsElectron
}

enum ParcheDock {
    /// Puerto del inspector que abre SIGUSR1. Node no deja elegir otro por senal
    static let puerto: UInt16 = 9229

    private static let centinela = Array("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX".utf8)
    /// Posicion de EnableNodeCliInspectArguments en el cable de fusibles de la version 1
    /// (@electron/fuses, FuseV1Options)
    private static let posicionInspector = 3

    private static var cache: [String: (clave: String, valor: DisponibilidadParche)] = [:]
    private static let candado = NSLock()

    // MARK: Disponibilidad de la app

    /// Solo lee archivos de la app. Se guarda en memoria por fecha y tamano del framework de Electron
    static func disponibilidad(_ ruta: String) -> DisponibilidadParche {
        let contents = URL(fileURLWithPath: ruta).resolvingSymlinksInPath().appendingPathComponent("Contents")
        guard DetectorDock.esElectron(contents) else { return .noEsElectron }
        let candidatos = marcosGrandes(contents)
        guard !candidatos.isEmpty else { return .noDisponible }
        let clave = candidatos.map { "\($0.path)|\($0.fecha)|\($0.tamano)" }.joined(separator: ";")
        candado.lock()
        if let c = cache[ruta], c.clave == clave {
            candado.unlock()
            return c.valor
        }
        candado.unlock()
        var valor = DisponibilidadParche.noDisponible
        for candidato in candidatos {
            // El primero que trae el cable de fusibles manda (Electron trae uno solo)
            if let activado = inspectorPermitido(archivo: candidato.url) {
                // Ademas hace falta una version de Electron que se pueda cerrar el inspector con seguridad
                valor = activado && versionSuficiente(candidato.informacion) ? .disponible : .noDisponible
                break
            }
        }
        candado.lock()
        cache[ruta] = (clave, valor)
        candado.unlock()
        return valor
    }

    private struct Marco { let url: URL; let path: String; let fecha: TimeInterval; let tamano: Int; let informacion: URL }

    /// Primera version mayor de Electron admitida. Cerrar el inspector necesita process.getBuiltinModule
    /// (Node 20.16 o 22.3): todas las versiones publicadas de Electron 34 traen Node 20.16 o mas (tabla
    /// de https://electronjs.org/headers/index.json). Con un Node anterior el inspector no se puede cerrar
    /// de forma fiable y el puerto quedaria abierto mientras la app viva
    static let electronMinimo = 34

    /// CFBundleVersion del Info.plist del framework de Electron ("44.9.1"): la version mayor, o nil
    static func versionMayor(informacion: URL) -> Int? {
        guard let info = NSDictionary(contentsOf: informacion) as? [String: Any],
              let version = info["CFBundleVersion"] as? String ?? info["CFBundleShortVersionString"] as? String,
              let mayor = version.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        return mayor
    }

    static func versionSuficiente(_ informacion: URL) -> Bool {
        (versionMayor(informacion: informacion) ?? 0) >= electronMinimo
    }

    /// Binarios de Frameworks/*.framework de mas de 30 MB: el de Electron pesa cientos de MB. Algunas
    /// apps renombran el framework, asi que no se busca por nombre. El de nombre "Electron Framework"
    /// va primero
    private static func marcosGrandes(_ contents: URL) -> [Marco] {
        let fm = FileManager.default
        let carpeta = contents.appendingPathComponent("Frameworks")
        let nombres = ((try? fm.contentsOfDirectory(atPath: carpeta.path)) ?? [])
            .filter { $0.hasSuffix(".framework") }
            .sorted { ($0 == "Electron Framework.framework") && ($1 != "Electron Framework.framework") }
        var salida: [Marco] = []
        for nombre in nombres {
            let base = String(nombre.dropLast(".framework".count))
            let binario = carpeta.appendingPathComponent(nombre).appendingPathComponent("Versions/Current/\(base)")
                .resolvingSymlinksInPath()
            guard let a = try? fm.attributesOfItem(atPath: binario.path), a[.type] as? FileAttributeType == .typeRegular,
                  let tamano = (a[.size] as? NSNumber)?.intValue, tamano > 30 << 20 else { continue }
            let informacion = carpeta.appendingPathComponent(nombre).appendingPathComponent("Versions/Current/Resources/Info.plist")
            salida.append(Marco(url: binario, path: binario.path,
                                fecha: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, tamano: tamano,
                                informacion: informacion))
        }
        return salida
    }

    /// nil si el archivo no trae el cable de fusibles (o es de otra version del cable)
    static func inspectorPermitido(archivo: URL) -> Bool? {
        guard let h = try? FileHandle(forReadingFrom: archivo) else { return nil }
        defer { try? h.close() }
        var cola = Data()
        while let bloque = try? h.read(upToCount: 4 << 20), !bloque.isEmpty {
            let datos = cola + bloque
            if let r = inspectorPermitido(enDatos: datos) { return r.valor }
            // Conserva el final por si el cable queda partido entre dos bloques
            cola = Data(datos.suffix(centinela.count + 2 + 64))
        }
        return nil
    }

    /// Busca el centinela y lee el cable que le sigue: version (1 byte), largo (1 byte) y un byte por
    /// fusible ("0" apagado, "1" encendido, "r" quitado). Devuelve nil mientras el cable no este entero.
    /// Un fusible quitado o de una version que no se conoce cuenta como apagado
    static func inspectorPermitido(enDatos datos: Data) -> (valor: Bool, version: UInt8)? {
        guard let inicio = buscar(datos, centinela) else { return nil }
        let desde = datos.startIndex + inicio + centinela.count
        guard desde + 2 <= datos.endIndex else { return nil }
        let version = datos[desde]
        let largo = Int(datos[desde + 1])
        guard desde + 2 + largo <= datos.endIndex else { return nil }
        guard version == 1, largo > posicionInspector else { return (false, version) }
        return (datos[desde + 2 + posicionInspector] == UInt8(ascii: "1"), version)
    }

    private static func buscar(_ datos: Data, _ aguja: [UInt8]) -> Int? {
        datos.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int? in
            guard let base = buf.baseAddress, buf.count >= aguja.count else { return nil }
            return aguja.withUnsafeBytes { a -> Int? in
                guard let p = memmem(base, buf.count, a.baseAddress, aguja.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(p))
            }
        }
    }

    // MARK: Seguridad antes de actuar

    /// El proceso tiene un manejador para la senal. Mandar SIGUSR1 a un proceso que no lo tiene lo
    /// termina, asi que es la comprobacion que decide si se puede avisar a una app. Se lee del nucleo
    /// (sysctl kern.proc.pid), que guarda las senales capturadas e ignoradas de cada proceso
    static func senalCapturada(_ pid: pid_t, _ senal: Int32 = SIGUSR1) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var tamano = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &tamano, nil, 0) == 0, tamano > 0, info.kp_proc.p_pid == pid else { return false }
        let bit = UInt32(1) << UInt32(senal - 1)
        return UInt32(info.kp_proc.p_sigcatch) & bit != 0 && UInt32(info.kp_proc.p_sigignore) & bit == 0
    }

    /// Momento de arranque del proceso segun el nucleo (kp_proc.p_starttime), o nil. Respaldo de
    /// NSRunningApplication.launchDate, que puede faltar
    static func inicioProceso(_ pid: pid_t) -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var tamano = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &tamano, nil, 0) == 0, tamano > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        guard t.tv_sec > 0 else { return nil }
        return TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000
    }

    /// El proceso pid tiene un socket TCP escuchando en el puerto. Se lee del nucleo (libproc) sin
    /// conectarse a nada: asi el agente decide de quien es el puerto antes de hablar con el oyente.
    /// Ante cualquier fallo al preguntar dice que no, y entonces el agente no se conecta
    static func escuchaEnPuerto(_ pid: pid_t, _ puerto: UInt16 = ParcheDock.puerto) -> Bool {
        let paso = MemoryLayout<proc_fdinfo>.stride
        let necesario = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard necesario > 0 else { return false }
        // Margen por si abre descriptores entre las dos llamadas
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(necesario) / paso + 32)
        let leidos = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard leidos > 0 else { return false }
        for fd in fds.prefix(Int(leidos) / paso) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let tamano = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, tamano) == tamano else { continue }
            guard si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport guarda el puerto en orden de red en sus 16 bits bajos (lsof usa ntohs)
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == puerto { return true }
        }
        return false
    }

    /// Algo escucha en 127.0.0.1:puerto. Ante un fallo al preguntar se dice que si: no se actua
    static func puertoAbierto(_ puerto: UInt16 = ParcheDock.puerto) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var dir = sockaddr_in()
        dir.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dir.sin_family = sa_family_t(AF_INET)
        dir.sin_port = puerto.bigEndian
        dir.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let r = withUnsafePointer(to: &dir) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }
}
