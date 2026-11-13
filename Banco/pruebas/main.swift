import AppKit

// Sustituye solo el servicio externo: estas pruebas nunca cargan ni paran launchd.
enum ServicioAgente { static func desinstalar() {} }
// iconservices tampoco se toca: solo se anota para que app se pidio generar el icono
enum CacheDeIconos {
    static var pedidas: [String] = []
    @discardableResult static func preparar(_ ruta: String) -> Bool { pedidas.append(ruta); return true }
}
let fm = FileManager.default
let raiz = Almacen.base.deletingLastPathComponent()
var pruebas = 0
func comprobar(_ condicion: @autoclosure () throws -> Bool, _ mensaje: String) throws {
    guard try condicion() else { throw ErrorIconos(texto: "FALLO: " + mensaje) }
    pruebas += 1
    print("OK: " + mensaje)
}
func rechazar(_ mensaje: String, _ trabajo: () throws -> Void) throws {
    do { try trabajo() } catch { pruebas += 1; print("OK: " + mensaje); return }
    throw ErrorIconos(texto: "FALLO: se aceptó " + mensaje)
}
func app(_ nombre: String, id: String = "test.iconos", en padre: URL? = nil) throws -> URL {
    let url = (padre ?? raiz).appendingPathComponent(nombre + ".app")
    try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": id, "CFBundleName": nombre]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    return url
}
func atributo(_ ruta: String, _ nombre: String, _ datos: Data) throws {
    let r = datos.withUnsafeBytes { setxattr(ruta, nombre, $0.baseAddress, datos.count, 0, XATTR_NOFOLLOW) }
    guard r == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
}
func atributo(_ ruta: String, _ nombre: String) -> Data? {
    let n = getxattr(ruta, nombre, nil, 0, 0, XATTR_NOFOLLOW)
    guard n >= 0 else { return nil }
    var datos = Data(count: n)
    let r = datos.withUnsafeMutableBytes { getxattr(ruta, nombre, $0.baseAddress, n, 0, XATTR_NOFOLLOW) }
    return r == n ? datos : nil
}
func proceso(_ ejecutable: String, _ args: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: ejecutable); p.arguments = args
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw ErrorIconos(texto: "Falló " + ejecutable) }
}

do {
    try comprobar(!fm.fileExists(atPath: Almacen.base.path), "base aislada ausente")
    try comprobar(Almacen.cargar().apps.isEmpty && !Almacen.configDanada, "config ausente es nueva")
    var config = Configuracion()
    try Almacen.guardar(config)
    let inicial = try Data(contentsOf: Almacen.archivoConfig)
    config.reiniciarDock = false
    try Almacen.guardar(config)
    try comprobar(Data(contentsOf: Almacen.base.appendingPathComponent("config.json.bak")) == inicial, "bak conserva versión anterior")
    let roto = Data("{config truncada".utf8)
    try roto.write(to: Almacen.archivoConfig)
    _ = Almacen.cargar()
    try comprobar(Almacen.configDanada, "config corrupta se señala")
    let copias = try fm.contentsOfDirectory(at: Almacen.base, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("config.corrupto-") }
    try comprobar(copias.count == 1 && Data(contentsOf: copias[0]) == roto, "copia corrupta exacta")
    _ = Almacen.cargar()
    try comprobar(fm.contentsOfDirectory(atPath: Almacen.base.path).filter { $0.hasPrefix("config.corrupto-") }.count == 1, "no duplica copia en cada lectura")
    // Con la config danada no se sobrescribe: el usuario la revisa y la quita, y se empieza de cero
    try rechazar("guardar sobre config dañada") { try Almacen.guardar(Configuracion()) }
    try fm.removeItem(at: Almacen.archivoConfig)
    _ = Almacen.cargar()
    try Almacen.guardar(Configuracion())
    try comprobar(!Almacen.configDanada, "guardado recupera configuración")
    try fm.removeItem(at: Almacen.archivoConfig)
    try fm.createSymbolicLink(at: Almacen.archivoConfig, withDestinationURL: raiz.appendingPathComponent("inexistente"))
    _ = Almacen.cargar()
    try comprobar(Almacen.configDanada, "enlace roto no se confunde con config ausente")
    try rechazar("guardar sobre enlace de config") { try Almacen.guardar(config) }
    try fm.removeItem(at: Almacen.archivoConfig)
    _ = Almacen.cargar()
    try Almacen.guardar(Configuracion())
    let antesFallo = try Data(contentsOf: Almacen.archivoConfig)
    let bak = Almacen.base.appendingPathComponent("config.json.bak")
    try fm.removeItem(at: bak)
    try fm.createDirectory(at: bak, withIntermediateDirectories: true)
    try rechazar("fallo al conservar bak") { try Almacen.guardar(config) }
    try comprobar(Data(contentsOf: Almacen.archivoConfig) == antesFallo, "fallo de respaldo deja config intacta")
    try fm.removeItem(at: bak)

    let destino = try app("Previa")
    try Aplicador.validar(destino.path, bundleId: "test.iconos")
    try rechazar("bundleId distinto") { try Aplicador.validar(destino.path, bundleId: "test.otro") }
    let falsa = raiz.appendingPathComponent("Falsa.app")
    try fm.createDirectory(at: falsa, withIntermediateDirectories: true)
    try rechazar("carpeta con extensión app sin plist") { try Aplicador.validar(falsa.path) }
    let enlace = raiz.appendingPathComponent("Enlace.app")
    try fm.createSymbolicLink(at: enlace, withDestinationURL: destino)
    // Un enlace en el ultimo componente (apps en otro volumen) se valida en su destino real
    try Aplicador.validar(enlace.path)
    print("OK: bundle enlazado se valida en su destino")
    let enlazado = try app("ContentsEnlace")
    try fm.removeItem(at: enlazado.appendingPathComponent("Contents"))
    try fm.createSymbolicLink(at: enlazado.appendingPathComponent("Contents"), withDestinationURL: destino.appendingPathComponent("Contents"))
    try rechazar("Contents enlazado") { try Aplicador.validar(enlazado.path) }

    let icns = raiz.appendingPathComponent("prueba.icns")
    let imagen = Lienzo.renderizar(logo: nil, variante: .claro, escala: 0.62)!
    // ICNS sintetico: evita depender de iconutil y de servicios graficos del sistema.
    let png = raiz.appendingPathComponent("sintetico.png")
    try Lienzo.escribirPNG(imagen, en: png)
    let imagenPNG = try Data(contentsOf: png)
    func be32(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
    try (Data("icns".utf8) + be32(imagenPNG.count + 16) + Data("ic10".utf8)
         + be32(imagenPNG.count + 8) + imagenPNG).write(to: icns)
    let icono = URL(fileURLWithPath: Aplicador.iconoPersonalizado(destino.path))
    let bytes = Data("icono anterior".utf8), recurso = Data("recurso anterior".utf8)
    try bytes.write(to: icono)
    var finder = Data(count: 32); finder[8] = 0x04; finder[9] = 0x10
    var finderIcono = Data(count: 32); finderIcono[8] = 0x40
    try atributo(destino.path, "com.apple.FinderInfo", finder)
    try atributo(icono.path, "com.apple.FinderInfo", finderIcono)
    try atributo(icono.path, "com.apple.ResourceFork", recurso)
    let finderAntes = atributo(destino.path, "com.apple.FinderInfo")
    try Aplicador.aplicar(icns: icns, a: destino.path, variante: .claro)
    let respaldo = Almacen.carpeta(destino.path).appendingPathComponent("icono-previo.json")
    let copia = try Data(contentsOf: respaldo)
    try Aplicador.aplicar(icns: icns, a: destino.path, variante: .oscuro)
    try comprobar(Data(contentsOf: respaldo) == copia, "segundo cambio no pisa respaldo")
    try Aplicador.restaurar(destino.path)
    try comprobar(Data(contentsOf: icono) == bytes, "restaura bytes de Icon CR")
    try comprobar(atributo(icono.path, "com.apple.ResourceFork") == recurso, "restaura ResourceFork")
    try comprobar(atributo(icono.path, "com.apple.FinderInfo") == finderIcono, "restaura FinderInfo del icono")
    try comprobar(atributo(destino.path, "com.apple.FinderInfo") == finderAntes, "restaura FinderInfo del bundle")
    try comprobar(Aplicador.variantePuesta(destino.path) == nil, "restaurado sin marca de Iconos")
    try comprobar(CacheDeIconos.pedidas == [destino.path], "al restaurar se pide el icono claro y oscuro a iconservices")

    let limpia = try app("SinPrevia")
    try Aplicador.aplicar(icns: icns, a: limpia.path, variante: .claro)
    try Aplicador.restaurar(limpia.path)
    try comprobar(!fm.fileExists(atPath: Aplicador.iconoPersonalizado(limpia.path)), "sin icono previo se elimina Icon CR")
    try comprobar(atributo(limpia.path, "com.apple.FinderInfo") == nil, "sin FinderInfo previo se elimina atributo")

    let hostil = try app("IconoEnlace")
    try fm.createSymbolicLink(atPath: Aplicador.iconoPersonalizado(hostil.path), withDestinationPath: icono.path)
    try rechazar("Icon CR enlazado") { try Aplicador.aplicar(icns: icns, a: hostil.path, variante: .claro) }
    try comprobar(Data(contentsOf: icono) == bytes, "destino del enlace intacto")
    let dura = try app("IconoHardlink")
    try fm.linkItem(at: icono, to: URL(fileURLWithPath: Aplicador.iconoPersonalizado(dura.path)))
    try rechazar("Icon CR con hardlink") { try Aplicador.aplicar(icns: icns, a: dura.path, variante: .claro) }
    try fm.removeItem(atPath: Aplicador.iconoPersonalizado(dura.path))

    config = Configuracion(); config.apps = [Gestionada(ruta: destino.path, nombre: "Previa", bundleId: "otro.id")]
    try Almacen.guardar(config)
    try rechazar("aplicar sobre identidad distinta a la gestionada") { try Aplicador.aplicar(icns: icns, a: destino.path, variante: .claro) }
    try rechazar("restaurar sobre identidad distinta a la gestionada") { try Aplicador.restaurar(destino.path) }
    try comprobar(Data(contentsOf: icono) == bytes, "bundle incorrecto intacto")
    try Almacen.guardar(Configuracion())

    // Una importacion de otro bundle no puede crear datos ni invalidar su icono.
    let paquete = raiz.appendingPathComponent("Importacion")
    try fm.createDirectory(at: paquete, withIntermediateDirectories: true)
    var traida = Configuracion()
    traida.apps = [Gestionada(ruta: destino.path, nombre: "Previa", bundleId: "otra.identidad")]
    try JSONEncoder().encode(traida).write(to: paquete.appendingPathComponent("config.json"))
    let zip = raiz.appendingPathComponent("importacion.zip")
    try proceso("/usr/bin/ditto", ["-c", "-k", "--norsrc", paquete.path, zip.path])
    try rechazar("importar identidad ajena") { _ = try Almacen.importar(de: zip) }
    try comprobar(Almacen.cargar().apps.isEmpty && Data(contentsOf: icono) == bytes, "importación rechazada deja app y config intactas")

    let bloqueada = try app("Inmutable")
    guard chflags(bloqueada.path, UInt32(UF_IMMUTABLE)) == 0 else { throw ErrorIconos(texto: "No se pudo preparar la app ficticia inmutable.") }
    do {
        defer { chflags(bloqueada.path, 0) }
        do {
            try Aplicador.aplicar(icns: icns, a: bloqueada.path, variante: .claro)
            throw ErrorIconos(texto: "Se modificó una app inmutable.")
        } catch let error as ErrorIconos {
            try comprobar(error.codigo == .protegida, "inmutable se clasifica como protegida")
        }
    }

    let extras = raiz.appendingPathComponent("Extras")
    let directa = try app("Extra", en: extras)
    let anidada = try app("Fabricante", en: extras.appendingPathComponent("Marca"))
    _ = try app("DemasiadoProfunda", en: extras.appendingPathComponent("Marca/Submarca"))
    config = Configuracion(); config.carpetasExtra = [extras.path, extras.path]
    try Almacen.guardar(config)
    let encontradas = Set(Almacen.escanear().map(\.ruta))
    try comprobar(encontradas == Set([directa.path, anidada.path]), "carpetas extra y primer nivel sin duplicados")

    let aclApp = try app("ACLPrevia")
    try proceso("/bin/chmod", ["+a", "\(NSUserName()) allow \(Aplicador.permisosACL)", aclApp.path])
    try comprobar(Aplicador.tieneACL(aclApp.path), "ACL preexistente creada solo en fixture")
    try comprobar(Aplicador.conACL().isEmpty, "ACL preexistente no se considera propia")
    try Aplicador.quitarPermisoEnTerminal([aclApp.path])
    try comprobar(Aplicador.tieneACL(aclApp.path), "ACL preexistente no se retira")
    var st = stat(); stat(aclApp.path, &st)
    let solicitud: [[String: Any]] = [["ruta": aclApp.path, "dispositivo": Int(st.st_dev), "inodo": st.st_ino, "bundleId": "test.iconos"]]
    try Almacen.escribirSeguro(JSONSerialization.data(withJSONObject: solicitud), en: Almacen.base.appendingPathComponent("acl-solicitadas.json"))
    try Aplicador.confirmarPermisos()
    try comprobar(Aplicador.permisosRegistrados() == [aclApp.path], "simulación de solicitud confirmada persiste ACL")
    try comprobar(Data(contentsOf: Almacen.base.appendingPathComponent("acl-puestas.json")).count > 0, "registro ACL persistente")
    let guion = Aplicador.guionPermiso([aclApp.path])
    let guionURL = raiz.appendingPathComponent("permiso.command")
    try guion.write(to: guionURL, atomically: true, encoding: .utf8)
    try proceso("/bin/zsh", ["-n", guionURL.path])
    try comprobar(guion.contains("sudo -v") && guion.contains("Read-only file system") && guion.contains("Gestión de apps"), "guion separa sudo, volumen y Gestión de apps")
    // Simula el recibo de Terminal tras retirar la regla y una ACL nueva de otro origen.
    var registradas = try JSONSerialization.jsonObject(with: Data(contentsOf: Almacen.base.appendingPathComponent("acl-puestas.json"))) as! [[String: Any]]
    let retirada = UUID().uuidString
    registradas[0]["retirada"] = retirada
    try Almacen.escribirSeguro(JSONSerialization.data(withJSONObject: registradas), en: Almacen.base.appendingPathComponent("acl-puestas.json"))
    let quitar = Aplicador.guionACL([aclApp.path], quitar: true)
    try quitar.write(to: guionURL, atomically: true, encoding: .utf8)
    try proceso("/bin/zsh", ["-n", guionURL.path])
    try Almacen.escribirSeguro(Data(), en: Almacen.base.appendingPathComponent(".acl-retirada-" + retirada))
    try comprobar(Aplicador.permisosRegistrados().isEmpty && Aplicador.tieneACL(aclApp.path), "recibo impide reclamar una ACL posterior")
    try Almacen.escribirSeguro(Data("roto".utf8), en: Almacen.base.appendingPathComponent("acl-puestas.json"))
    try rechazar("registro ACL corrupto") { _ = try Aplicador.permisosRegistrados() }
    try comprobar(Aplicador.tieneACL(aclApp.path), "registro corrupto no toca ACL")
    // Apps web (PWA): Safari y la plantilla de Chromium (app_mode-Info.plist)
    try comprobar(Almacen.navegadorWeb(["CFBundleIdentifier": "com.apple.Safari.WebApp.AAAA"]) == "Safari", "detecta app web de Safari")
    try comprobar(Almacen.navegadorWeb(["CFBundleIdentifier": "com.google.Chrome.app.abc", "CrAppModeShortcutID": "abc",
                                        "CrBundleIdentifier": "test.navegador.inexistente"]) == "Chromium", "detecta app web de Chromium")
    try comprobar(Almacen.navegadorWeb(["CFBundleIdentifier": "com.google.Chrome"]) == nil, "app normal no es web")
    // Safari crea otra vez la app web: misma ruta, identificador nuevo
    let idViejo = "com.apple.Safari.WebApp.11111111-1111-1111-1111-111111111111"
    let idNuevo = "com.apple.Safari.WebApp.22222222-2222-2222-2222-222222222222"
    let web = try app("Web", id: idViejo)
    config = Configuracion(); config.apps = [Gestionada(ruta: web.path, nombre: "Web", bundleId: idViejo)]
    try Almacen.guardar(config)
    try Aplicador.aplicar(icns: icns, a: web.path, variante: .claro)
    try fm.removeItem(at: web)
    _ = try app("Web", id: idNuevo)
    try rechazar("aplicar sobre app web recreada sin reconocerla") { try Aplicador.aplicar(icns: icns, a: web.path, variante: .claro) }
    func encontrada(_ url: URL, _ id: String) -> AppEncontrada {
        AppEncontrada(ruta: url.path, nombre: "Web", escribible: true, personalizado: false, bundleId: id)
    }
    let ofrecidas = Almacen.reubicables([encontrada(web, idNuevo)], Almacen.cargar())
    try comprobar(ofrecidas.count == 1 && ofrecidas[0].vieja == web.path && ofrecidas[0].nueva == web.path, "ofrece recuperar app web recreada")
    try comprobar(Almacen.reubicables([encontrada(web, idViejo)], Almacen.cargar()).isEmpty, "app web intacta no se ofrece")
    try Almacen.reubicar(vieja: web.path, nueva: web.path)
    try comprobar(Almacen.cargar().apps.first?.bundleId == idNuevo, "app web recreada toma la identidad nueva")
    // Reintento tras un fallo entre el respaldo y la configuracion: no se queda bloqueada
    try Aplicador.readoptarRespaldo(web.path, de: idViejo, a: idNuevo)
    print("OK: readoptar el respaldo dos veces no falla")
    try Aplicador.aplicar(icns: icns, a: web.path, variante: .claro)
    try Aplicador.restaurar(web.path)
    try comprobar(!fm.fileExists(atPath: Aplicador.iconoPersonalizado(web.path)), "app web recuperada se aplica y restaura")
    // Una app normal con otro identificador en la misma ruta sigue rechazada
    let normal = try app("Normal", id: "test.normal.a")
    config = Configuracion(); config.apps = [Gestionada(ruta: normal.path, nombre: "Normal", bundleId: "test.normal.a")]
    try Almacen.guardar(config)
    try fm.removeItem(at: normal)
    _ = try app("Normal", id: "test.normal.b")
    try comprobar(Almacen.reubicables([encontrada(normal, "test.normal.b")], Almacen.cargar()).isEmpty, "app normal con otra identidad no se ofrece")
    try rechazar("reubicar en el sitio una app que no es web") { try Almacen.reubicar(vieja: normal.path, nueva: normal.path) }
    try comprobar(Almacen.cargar().apps.first?.bundleId == "test.normal.a", "identidad de app normal intacta")
    try Almacen.guardar(Configuracion())
    // Apps que ponen su propio icono en el Dock mientras estan abiertas
    let selectorDock = "setApplicationIconImage:\u{0}"
    func binario(_ url: URL, _ texto: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(texto.utf8)).write(to: url)
    }
    func texto(_ url: URL, _ contenido: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contenido.utf8).write(to: url)
    }
    func appDock(_ nombre: String, ejecutable: String, info extra: [String: Any] = [:]) throws -> URL {
        let url = raiz.appendingPathComponent("Dock/\(nombre).app")
        var info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.dock.\(nombre)",
                                   "CFBundleExecutable": nombre, "CFBundleVersion": "1"]
        info.merge(extra) { $1 }
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try binario(url.appendingPathComponent("Contents/MacOS/\(nombre)"), ejecutable)
        return url
    }
    let egui = try appDock("Egui", ejecutable: "eframe-0.36.2 objc2-app-kit-0.3.2 " + selectorDock)
    try comprobar(DetectorDock.analizar(egui.path) == .siempre, "eframe cambia el icono del Dock en cada arranque")
    let rust = try appDock("Rust", ejecutable: "objc2-app-kit-0.3.2 " + selectorDock)
    try comprobar(DetectorDock.analizar(rust.path) == .aVeces, "selector en el ejecutable: puede cambiarlo")
    let sinSelector = try appDock("SinSelector", ejecutable: "sharedApplication setActivationPolicy: applicationIconImage")
    try comprobar(DetectorDock.analizar(sinSelector.path) == nil, "sin el selector no se avisa")
    let tile = try appDock("Tile", ejecutable: "", info: ["NSDockTilePlugIn": "Tile.docktileplugin"])
    try comprobar(DetectorDock.analizar(tile.path) == .dibujaPropio, "NSDockTilePlugIn dibuja su icono")
    let marco = try appDock("Marco", ejecutable: "nada")
    try binario(marco.appendingPathComponent("Contents/Frameworks/UI.framework/Versions/A/UI"), selectorDock)
    try comprobar(DetectorDock.analizar(marco.path) == .aVeces, "framework cargado en el proceso cuenta")
    let otros = try appDock("Otros", ejecutable: "nada")
    try binario(otros.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"), selectorDock)
    try binario(otros.appendingPathComponent("Contents/PlugIns/Widget.appex/Contents/MacOS/Widget"), selectorDock)
    try binario(otros.appendingPathComponent("Contents/PlugIns/jdk-21.jdk/Contents/Home/lib/libawt_lwawt.dylib"), selectorDock)
    try texto(otros.appendingPathComponent("Contents/Frameworks/notas.txt"), selectorDock)
    try comprobar(DetectorDock.analizar(otros.path) == nil, "apps, extensiones, Java y archivos que no son Mach-O no cuentan")
    let electron = try appDock("Electron", ejecutable: "nada")
    try binario(electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"), selectorDock)
    try texto(electron.appendingPathComponent("Contents/Resources/app.asar"), "app.dock.setBadge('1');win.setIcon(i);tray.setIcon(i);x.dock.setIcons(i)")
    try comprobar(DetectorDock.analizar(electron.path) == nil, "Electron sin dock.setIcon no se avisa")
    let electronIcono = try appDock("ElectronIcono", ejecutable: "nada")
    try binario(electronIcono.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"), selectorDock)
    try texto(electronIcono.appendingPathComponent("Contents/Resources/app.asar"), "abc;e.app.dock?.setIcon (p);")
    try comprobar(DetectorDock.analizar(electronIcono.path) == .aVeces, "Electron con dock?.setIcon en app.asar")
    let electronCarpeta = try appDock("ElectronCarpeta", ejecutable: "nada")
    try binario(electronCarpeta.appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"), selectorDock)
    try texto(electronCarpeta.appendingPathComponent("Contents/Resources/app/main.js"), "const {app}=require('electron');app.dock.setIcon(ruta)")
    try comprobar(DetectorDock.analizar(electronCarpeta.path) == .aVeces, "Electron con dock.setIcon en Resources/app")
    try comprobar(DetectorDock.llamaDockSetIcon(Data("dock.setIcon\n(".utf8)) && !DetectorDock.llamaDockSetIcon(Data("dock .setIcon(".utf8))
                  && !DetectorDock.llamaDockSetIcon(Data(".setIcon(".utf8)), "patrón de dock.setIcon")
    // Electron con el framework renombrado y el JS sin empaquetar en Resources/app
    let renombrada = try appDock("Renombrada", ejecutable: "nada")
    try binario(renombrada.appendingPathComponent("Contents/Frameworks/Codex Framework.framework/Versions/A/Codex Framework"), selectorDock)
    try texto(renombrada.appendingPathComponent("Contents/Resources/app/package.json"), "{\"main\":\"main.js\"}")
    try texto(renombrada.appendingPathComponent("Contents/Resources/app/main.js"), "app.dock.setBadge('1')")
    try comprobar(DetectorDock.analizar(renombrada.path) == nil, "Electron renombrado con Resources/app sin dock.setIcon")
    // El selector partido entre dos bloques de lectura (4 MB) se encuentra igual
    let grande = try appDock("Grande", ejecutable: "")
    try (Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(count: (4 << 20) - 14) + Data(selectorDock.utf8))
        .write(to: grande.appendingPathComponent("Contents/MacOS/Grande"))
    try comprobar(DetectorDock.analizar(grande.path) == .aVeces, "selector en el borde de dos bloques")
    // Un analisis cancelado no deja nada en la cache
    let cancelable = try appDock("Cancelable", ejecutable: selectorDock)
    let cancelacion = Cancelacion()
    cancelacion.cancelar()
    try comprobar(DetectorDock.analizar(cancelable.path, cancelacion: cancelacion) == nil
                  && DetectorDock.analizar(cancelable.path) == .aVeces, "cancelado devuelve nil sin guardarlo")
    // Fixture de arte para probar el generador y el banco sin leer apps instaladas.
    let muestra = try app("Muestra", en: raiz.appendingPathComponent("Muestras"))
    try fm.createDirectory(at: muestra.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try fm.copyItem(at: icns, to: muestra.appendingPathComponent("Contents/Resources/AppIcon.icns"))
    let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.muestra", "CFBundleIconFile": "AppIcon.icns"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: muestra.appendingPathComponent("Contents/Info.plist"))
    print("TOTAL: \(pruebas) comprobaciones correctas")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
