import AppKit
import ObjectiveC

/// Iconos de macOS 26 hechos con Icon Composer: el catalogo de la app guarda el fondo y las capas del
/// logo por separado, y la version oscura que hizo el fabricante. Si la app los tiene, el logo sale de
/// ahi tal cual, sin adivinar donde termina la ficha. El lienzo (1024) es el cuerpo de la ficha.
///
/// Las capas vectoriales solo las sabe leer CoreUI (privado): todo va con responds(to:) y, si algo no
/// cuadra, devuelve nil y se usa la extraccion por imagen
enum Capas {
    struct Logo {
        let claro: CGImage
        let oscuro: CGImage
        let detalle: String
        let ocupacion: Double
    }

    private static var cache: [String: (fecha: Date, logo: Logo?, uso: UInt64)] = [:]
    private static let candado = NSLock()
    private static var reloj: UInt64 = 0
    private static let limiteCache = 24

    static func logo(_ app: String) -> Logo? {
        let car = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/Assets.car")
        guard let fecha = (try? FileManager.default.attributesOfItem(atPath: car.path))?[.modificationDate] as? Date else { return nil }
        candado.lock()
        if let hecho = cache[app], hecho.fecha == fecha {
            reloj &+= 1
            cache[app]?.uso = reloj
            candado.unlock()
            return hecho.logo
        }
        candado.unlock()
        let logo = leer(app, car)
        candado.lock()
        reloj &+= 1
        cache[app] = (fecha, logo, reloj)
        while cache.count > limiteCache, let vieja = cache.min(by: { $0.value.uso < $1.value.uso })?.key {
            cache.removeValue(forKey: vieja)
        }
        candado.unlock()
        return logo
    }

    private static func leer(_ app: String, _ car: URL) -> Logo? {
        guard let nombre = Bundle(path: app)?.infoDictionary?["CFBundleIconName"] as? String,
              let catalogo = CoreUI.catalogo(car) else { return nil }
        let rellenos = Rellenos(car)
        guard var claro = componer(catalogo, nombre, oscuro: false, rellenos) else { return nil }
        var oscuro = componer(catalogo, nombre, oscuro: true, rellenos) ?? claro
        // Si la capa del logo ya trae su propio fondo no hay nada que separar: mejor la extraccion normal
        let ocupacion = cobertura(claro.imagen)
        guard ocupacion > 0.004, ocupacion < 0.80 else { return nil }
        // Un logo pensado para su fondo de color (la chispa blanca de Claude) se pierde en la ficha
        // nueva: se pinta con el color del fondo original, con contraste suficiente
        var recoloreadas: [String] = []
        if let nuevo = conContraste(claro, oscuro: false, rellenos) { claro.imagen = nuevo; recoloreadas.append("claro") }
        if let nuevo = conContraste(oscuro, oscuro: true, rellenos) { oscuro.imagen = nuevo; recoloreadas.append("oscuro") }
        return Logo(claro: claro.imagen, oscuro: oscuro.imagen,
                    detalle: String(format: "capas=%d; ocupacion=%.3f", claro.capas, ocupacion)
                        + (recoloreadas.isEmpty ? "" : "; color de marca en " + recoloreadas.joined(separator: " y ")),
                    ocupacion: ocupacion)
    }

    /// Luminancia de las fichas de Lienzo (claro ~#F6F6F8, oscuro ~#1F1F21)
    private static let luminanciaFicha = (claro: 0.92, oscuro: 0.014)

    private static func conContraste(_ c: Compuesto, oscuro: Bool, _ rellenos: Rellenos) -> CGImage? {
        guard let media = luminanciaMedia(c.imagen) else { return nil }
        let ficha = oscuro ? luminanciaFicha.oscuro : luminanciaFicha.claro
        let contraste = (max(media, ficha) + 0.05) / (min(media, ficha) + 0.05)
        guard contraste < 1.8, let fondo = c.fondo,
              let colores = rellenos.colores(de: fondo, oscuro: oscuro), !colores.isEmpty else { return nil }
        // Los colores del fondo, ajustados en luminosidad hasta 3:1 con la ficha
        let marca: [CGColor] = colores.compactMap { color in
            guard let s = color.converted(to: Lienzo.espacio, intent: .defaultIntent, options: nil)?.components, s.count >= 3 else { return nil }
            let v = Extractor.brandColor(Extractor.V(Float(s[0]), Float(s[1]), Float(s[2])), dark: oscuro)
            return CGColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
        }
        let lado = c.imagen.width
        guard !marca.isEmpty,
              let ctx = CGContext(data: nil, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: lado * 4,
                                  space: Lienzo.espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: lado, height: lado)
        ctx.clip(to: rect, mask: c.imagen)
        if marca.count == 1, let unico = marca.first {
            ctx.setFillColor(unico)
            ctx.fill(rect)
        } else if let g = CGGradient(colorsSpace: Lienzo.espacio, colors: marca as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        return ctx.makeImage()
    }

    /// Luminancia relativa media del logo, ponderada por alfa
    private static func luminanciaMedia(_ imagen: CGImage) -> Double? {
        let lado = 128
        var px = [UInt8](repeating: 0, count: lado * lado * 4)
        guard let ctx = CGContext(data: &px, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: lado * 4,
                                  space: Lienzo.espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(imagen, in: CGRect(x: 0, y: 0, width: lado, height: lado))
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var suma = 0.0, peso = 0.0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            let a = Double(px[i + 3])
            let r = Double(px[i]) / a, g = Double(px[i + 1]) / a, b = Double(px[i + 2]) / a
            suma += (0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)) * a
            peso += a
        }
        return peso > 0 ? suma / peso : nil
    }

    struct Compuesto {
        var imagen: CGImage
        let capas: Int
        /// Nombre del relleno del fondo original (degradado o color)
        let fondo: String?
    }

    /// Las capas del logo, de abajo arriba, sin el relleno de fondo. Las muy transparentes son siluetas
    /// para la sombra, y las que cruzan todo el lienzo con poca tinta son texturas del fondo (la
    /// cuadricula de Xcode): ninguna es logo
    private static func componer(_ catalogo: AnyObject, _ nombre: String, oscuro: Bool,
                                 _ rellenos: Rellenos) -> Compuesto? {
        let apariencia = oscuro ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua"
        let aparienciaUI = oscuro ? "UIAppearanceDark" : "UIAppearanceLight"
        // Catalyst y algunas apps universales guardan la pila con las apariencias de UIKit.
        guard let pila = CoreUI.pila(catalogo, nombre, apariencia) ?? CoreUI.pila(catalogo, nombre, aparienciaUI),
              let grupos = CoreUI.objeto(pila, "layers") as? [AnyObject] else { return nil }
        let lienzo = CoreUI.tamano(pila).flatMap { $0.width > 1 ? $0.width : nil } ?? 1024
        let lado = 1024
        let k = CGFloat(lado) / lienzo
        guard let ctx = CGContext(data: nil, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: lado * 4,
                                  space: Lienzo.espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var dibujadas = 0
        var fondo: String?
        for grupo in grupos {
            // El fondo (degradado o color) no tiene capas
            guard let capas = CoreUI.objeto(grupo, "layers") as? [AnyObject] else {
                if fondo == nil { fondo = CoreUI.objeto(grupo, "name") as? String }
                continue
            }
            let opacidadGrupo = CoreUI.real(grupo, "opacity") ?? 1
            let rellenoGrupo = CoreUI.objeto(grupo, "gradientOrColorName") as? String
            for capa in capas {
                let opacidad = opacidadGrupo * (CoreUI.real(capa, "opacity") ?? 1)
                guard opacidad >= 0.3, let marco = CoreUI.marco(capa), marco.width > 0, marco.height > 0 else { continue }
                let destino = CGRect(x: marco.minX * k, y: CGFloat(lado) - marco.maxY * k, width: marco.width * k, height: marco.height * k)
                guard let imagen = CoreUI.rasterizar(capa, destino.size), !esTextura(imagen, destino, lado: CGFloat(lado)) else { continue }
                ctx.saveGState()
                ctx.setAlpha(opacidad)
                let relleno = (CoreUI.objeto(capa, "gradientOrColorName") as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? rellenoGrupo.flatMap { $0.isEmpty ? nil : $0 }
                if let relleno, rellenos.pintar(relleno, oscuro: oscuro, en: ctx, rect: destino, mascara: imagen) {
                    // La forma de la capa con el color que le dio el disenador
                } else {
                    ctx.draw(imagen, in: destino)
                }
                ctx.restoreGState()
                dibujadas += 1
            }
        }
        guard dibujadas > 0, let imagen = ctx.makeImage() else { return nil }
        return Compuesto(imagen: imagen, capas: dibujadas, fondo: fondo)
    }

    /// Lineas finas de borde a borde del lienzo: tinta en casi todo el ancho y alto, pero poca
    private static func esTextura(_ imagen: CGImage, _ destino: CGRect, lado: CGFloat) -> Bool {
        guard destino.width >= lado * 0.95, destino.height >= lado * 0.95 else { return false }
        let n = 128
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: Lienzo.espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(imagen, in: CGRect(x: 0, y: 0, width: n, height: n))
        var x0 = n, x1 = -1, y0 = n, y1 = -1, tinta = 0
        for y in 0..<n { for x in 0..<n where px[(y * n + x) * 4 + 3] > 20 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); tinta += 1
        }}
        guard x1 >= 0 else { return false }
        let ancho = Double(x1 - x0 + 1) / Double(n), alto = Double(y1 - y0 + 1) / Double(n)
        return ancho > 0.9 && alto > 0.9 && Double(tinta) / Double(n * n) < 0.25
    }

    /// Fraccion del lienzo cubierta por el logo (alfa ponderado)
    private static func cobertura(_ imagen: CGImage) -> Double {
        let lado = 128
        var px = [UInt8](repeating: 0, count: lado * lado * 4)
        guard let ctx = CGContext(data: &px, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: lado * 4,
                                  space: Lienzo.espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(imagen, in: CGRect(x: 0, y: 0, width: lado, height: lado))
        var suma = 0
        for i in stride(from: 3, to: px.count, by: 4) { suma += Int(px[i]) }
        return Double(suma) / Double(255 * lado * lado)
    }

    // MARK: Rellenos

    /// Colores y degradados con nombre del catalogo (assetutil los describe; CoreUI no los da facil)
    struct Rellenos {
        private var colores: [String: [(apariencia: String, color: CGColor)]] = [:]
        private var degradados: [String: [(apariencia: String, colores: [String], paradas: [CGFloat], inicio: CGPoint, fin: CGPoint)]] = [:]

        init(_ car: URL) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/assetutil")
            p.arguments = ["--info", car.path]
            let tubo = Pipe()
            p.standardOutput = tubo
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let datos = tubo.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let entradas = try? JSONSerialization.jsonObject(with: datos) as? [[String: Any]] else { return }
            for e in entradas {
                guard let nombre = e["Name"] as? String else { continue }
                let apariencia = e["Appearance"] as? String ?? ""
                switch e["AssetType"] as? String {
                case "Color":
                    if let c = Rellenos.color(e) { colores[nombre, default: []].append((apariencia, c)) }
                case "Named Gradient":
                    guard let nombres = e["Gradient Colors"] as? [String] else { continue }
                    let paradas = (e["Gradient Stops"] as? [NSNumber])?.map { CGFloat(truncating: $0) }
                        ?? nombres.indices.map { CGFloat($0) / CGFloat(max(1, nombres.count - 1)) }
                    let puntos = (e["Gradient Start/Stop"] as? String ?? "0.5,0 - 0.5,1").components(separatedBy: " - ").map { parte -> CGPoint in
                        let n = parte.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : .zero
                    }
                    degradados[nombre, default: []].append((apariencia, nombres, paradas,
                                                            puntos.first ?? CGPoint(x: 0.5, y: 0), puntos.count > 1 ? puntos[1] : CGPoint(x: 0.5, y: 1)))
                default:
                    break
                }
            }
        }

        private static func color(_ e: [String: Any]) -> CGColor? {
            guard let comp = (e["Color components"] as? [NSNumber])?.map({ CGFloat(truncating: $0) }) else { return nil }
            let espacio = (e["Colorspace"] as? String ?? "srgb").lowercased()
            if comp.count == 2 {
                return CGColor(genericGrayGamma2_2Gray: comp[0], alpha: comp[1])
            }
            guard comp.count >= 3 else { return nil }
            let nombre: CFString = espacio.contains("p3") ? CGColorSpace.displayP3
                : espacio.contains("extended") ? CGColorSpace.extendedSRGB : CGColorSpace.sRGB
            guard let cs = CGColorSpace(name: nombre) else { return nil }
            return CGColor(colorSpace: cs, components: comp.count >= 4 ? comp : comp + [1])
        }

        private func elegir<T>(_ lista: [(apariencia: String, T)], oscuro: Bool) -> T? {
            let propia = oscuro ? ["NSAppearanceNameDarkAqua", "UIAppearanceDark"] : ["NSAppearanceNameAqua", "UIAppearanceLight"]
            // La apariencia explicita prevalece sobre Any, independientemente del orden del JSON.
            return (lista.first { propia.contains($0.apariencia) }
                    ?? lista.first { $0.apariencia == "UIAppearanceAny" || $0.apariencia.isEmpty }
                    ?? lista.first { ["NSAppearanceNameAqua", "UIAppearanceLight"].contains($0.apariencia) } ?? lista.first)?.1
        }

        private func colorNombrado(_ nombre: String, oscuro: Bool) -> CGColor? {
            elegir((colores[nombre] ?? []).map { ($0.apariencia, $0.color) }, oscuro: oscuro)
        }

        /// Los colores de un relleno (uno si es color, los del degradado si es degradado)
        func colores(de nombre: String, oscuro: Bool) -> [CGColor]? {
            if let c = colorNombrado(nombre, oscuro: oscuro) { return [c] }
            guard let d = elegir((degradados[nombre] ?? []).map { ($0.apariencia, $0) }, oscuro: oscuro) else { return nil }
            let cs = d.colores.compactMap { colorNombrado($0, oscuro: oscuro) }
            return cs.isEmpty ? nil : cs
        }

        /// Pinta el color o degradado dentro de la forma de la capa
        func pintar(_ nombre: String, oscuro: Bool, en ctx: CGContext, rect: CGRect, mascara: CGImage) -> Bool {
            if let c = colorNombrado(nombre, oscuro: oscuro) {
                ctx.clip(to: rect, mask: mascara)
                ctx.setFillColor(c)
                ctx.fill(rect)
                return true
            }
            guard let d = elegir((degradados[nombre] ?? []).map { ($0.apariencia, $0) }, oscuro: oscuro) else { return false }
            let cs = d.colores.compactMap { colorNombrado($0, oscuro: oscuro) }
            guard cs.count == d.colores.count, cs.count >= 2,
                  let degradado = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.extendedSRGB), colors: cs as CFArray,
                                             locations: d.paradas.count == cs.count ? d.paradas : nil) else { return false }
            // Coordenadas del degradado: unidad del marco de la capa, origen arriba
            func punto(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height) }
            ctx.clip(to: rect, mask: mascara)
            ctx.drawLinearGradient(degradado, start: punto(d.inicio), end: punto(d.fin), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            return true
        }
    }
}

/// Llamadas a CoreUI por el runtime de Objective-C
private enum CoreUI {
    static let cargado: Bool = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW) != nil

    static func catalogo(_ car: URL) -> AnyObject? {
        guard cargado, let cls = NSClassFromString("CUICatalog") as? NSObject.Type else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let sel = NSSelectorFromString("initWithURL:error:")
        guard cls.instancesRespond(to: sel), let nuevo = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        let f = unsafeBitCast(class_getMethodImplementation(cls, sel), to: Init.self)
        return f(nuevo, sel, car as NSURL, nil)
    }

    static func pila(_ catalogo: AnyObject, _ nombre: String, _ apariencia: String) -> AnyObject? {
        typealias F = @convention(c) (AnyObject, Selector, NSString, Double, Int, UInt, UInt, NSString?, NSString?) -> AnyObject?
        let sel = NSSelectorFromString("iconLayerStackWithName:scaleFactor:deviceIdiom:deviceSubtype:displayGamut:appearanceName:locale:")
        guard catalogo.responds(to: sel), let cls = object_getClass(catalogo) else { return nil }
        return unsafeBitCast(class_getMethodImplementation(cls, sel), to: F.self)(catalogo, sel, nombre as NSString, 1, 0, 0, 0, apariencia as NSString, nil)
    }

    static func objeto(_ o: AnyObject, _ nombre: String) -> AnyObject? {
        let sel = NSSelectorFromString(nombre)
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue()
    }

    static func real(_ o: AnyObject, _ nombre: String) -> CGFloat? {
        typealias F = @convention(c) (AnyObject, Selector) -> Double
        let sel = NSSelectorFromString(nombre)
        guard o.responds(to: sel), let cls = object_getClass(o) else { return nil }
        return CGFloat(unsafeBitCast(class_getMethodImplementation(cls, sel), to: F.self)(o, sel))
    }

    static func marco(_ o: AnyObject) -> CGRect? {
        typealias F = @convention(c) (AnyObject, Selector) -> CGRect
        let sel = NSSelectorFromString("frame")
        guard o.responds(to: sel), let cls = object_getClass(o) else { return nil }
        return unsafeBitCast(class_getMethodImplementation(cls, sel), to: F.self)(o, sel)
    }

    static func tamano(_ o: AnyObject) -> CGSize? {
        typealias F = @convention(c) (AnyObject, Selector) -> CGSize
        let sel = NSSelectorFromString("size")
        guard o.responds(to: sel), let cls = object_getClass(o) else { return nil }
        return unsafeBitCast(class_getMethodImplementation(cls, sel), to: F.self)(o, sel)
    }

    /// Vector (SVG/PDF) al tamano pedido, o la imagen tal cual si es un mapa de bits
    static func rasterizar(_ capa: AnyObject, _ tam: CGSize) -> CGImage? {
        let sel = NSSelectorFromString("rasterizeImageUsingScaleFactor:forTargetSize:")
        if capa.responds(to: sel), let cls = object_getClass(capa) {
            typealias F = @convention(c) (AnyObject, Selector, Double, CGSize) -> Unmanaged<CGImage>?
            return unsafeBitCast(class_getMethodImplementation(cls, sel), to: F.self)(capa, sel, 1, tam)?.takeUnretainedValue()
        }
        let selImagen = NSSelectorFromString("image")
        guard capa.responds(to: selImagen), let cls = object_getClass(capa) else { return nil }
        typealias G = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
        return unsafeBitCast(class_getMethodImplementation(cls, selImagen), to: G.self)(capa, selImagen)?.takeUnretainedValue()
    }
}
