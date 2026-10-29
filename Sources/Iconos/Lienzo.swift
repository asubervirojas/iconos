import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum Variante: String, Codable, CaseIterable {
    case claro, oscuro

    /// Para mostrar (rawValue es el nombre de los archivos y del atributo de Icon\r)
    var nombre: String {
        switch self {
        case .claro: String(localized: "claro")
        case .oscuro: String(localized: "oscuro")
        }
    }
}

/// Dibuja iconos con la silueta de macOS sobre fondo claro u oscuro, sin brillo en el logo.
enum Lienzo {
    static let lado: CGFloat = 1024
    static let espacio = CGColorSpace(name: CGColorSpace.sRGB)!

    // Silueta de los iconos del sistema: esquina continua de radio 213.5 sobre un cuerpo de 824
    // (medida sobre iconos de macOS 27)
    static let cuerpo = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let silueta = RoundedRectangle(cornerRadius: 213.5, style: .continuous).path(in: cuerpo).cgPath

    struct Estilo {
        let arriba, abajo: CGColor
        let filoArriba, filoAbajo, filoLados: CGFloat
        let sombraLogo: (color: CGColor, desenfoque: CGFloat, dy: CGFloat)
        let sombraFicha: CGFloat
    }

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    static func estilo(_ v: Variante) -> Estilo {
        switch v {
        case .claro:
            return Estilo(arriba: rgb(0xFFFFFF), abajo: rgb(0xEDEDF0), filoArriba: 1, filoAbajo: 1, filoLados: 0.05,
                          sombraLogo: (rgb(0x000000, 0.18), 14, -8), sombraFicha: 0.28)
        case .oscuro:
            return Estilo(arriba: rgb(0x2A2A2C), abajo: rgb(0x141415), filoArriba: 1, filoAbajo: 0.66, filoLados: 0.30,
                          sombraLogo: (rgb(0x000000, 0.45), 16, -8), sombraFicha: 0.28)
        }
    }

    // MARK: Logo

    /// Pasa la imagen a RGBA de 1024, opcionalmente vuelve transparente el blanco (placas y halos
    /// blancos que en fondo oscuro se ven como un recuadro) y la recorta a lo que tiene contenido.
    static func preparar(_ arte: CGImage, quitarBlanco: Bool) -> CGImage? {
        let n = Int(lado)
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: espacio,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let escala = min(lado / CGFloat(arte.width), lado / CGFloat(arte.height))
        let w = CGFloat(arte.width) * escala, h = CGFloat(arte.height) * escala
        c.interpolationQuality = .high
        c.draw(arte, in: CGRect(x: (lado - w) / 2, y: (lado - h) / 2, width: w, height: h))
        guard let datos = c.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }

        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 4
                var a = Double(datos[i + 3])
                if a == 0 { continue }
                if quitarBlanco {
                    // Sin premultiplicar: blanco = canales altos y casi sin saturacion
                    let r = Double(datos[i]) / a, g = Double(datos[i + 1]) / a, b = Double(datos[i + 2]) / a
                    let menor = min(r, g, b), mayor = max(r, g, b)
                    let blancura = suave(0.80, 0.96, menor) * (1 - suave(0.05, 0.16, mayor - menor))
                    if blancura > 0 {
                        let factor = 1 - blancura
                        a *= factor
                        for k in 0..<4 { datos[i + k] = UInt8((Double(datos[i + k]) * factor).rounded()) }
                    }
                }
                if a > 12 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY, let completa = c.makeImage() else { return nil }
        // En la memoria del contexto la fila 0 es la de arriba, igual que en CGImage.cropping
        return completa.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    private static func suave(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Icono completo

    /// Ficha de macOS con el logo. Con `destino` el logo va en ese rectangulo (el extractor lo da para
    /// conservar la proporcion del diseno original); sin el, centrado con lado maximo `escala` del lienzo.
    static func renderizar(logo: CGImage?, variante: Variante, escala: Double, destino: CGRect? = nil) -> CGImage? {
        let st = estilo(variante)
        let n = Int(lado)
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: espacio,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high

        // Sombra como la del sistema: ~0.16 pegada al borde inferior, nula a ~50 px
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -5.5), blur: 28, color: rgb(0x000000, st.sombraFicha))
        c.addPath(silueta)
        c.setFillColor(st.abajo)
        c.fillPath()
        c.restoreGState()

        c.saveGState()
        c.addPath(silueta)
        c.clip()
        let fondo = CGGradient(colorsSpace: espacio, colors: [st.arriba, st.abajo] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(fondo, start: CGPoint(x: 512, y: cuerpo.maxY), end: CGPoint(x: 512, y: cuerpo.minY), options: [])
        if let logo {
            let maximo = lado * CGFloat(escala)
            let f = min(maximo / CGFloat(logo.width), maximo / CGFloat(logo.height))
            let w = CGFloat(logo.width) * f, h = CGFloat(logo.height) * f
            c.setShadow(offset: CGSize(width: 0, height: st.sombraLogo.dy), blur: st.sombraLogo.desenfoque, color: st.sombraLogo.color)
            c.draw(logo, in: destino ?? CGRect(x: 512 - w / 2, y: 506 - h / 2, width: w, height: h))
        }
        c.restoreGState()
        dibujarFilo(c, st)
        return c.makeImage()
    }

    /// Borde de cristal de los iconos del sistema: brillo arriba y abajo que se desvanece hacia dentro
    /// y un filo algo mas oscuro en los lados
    private static func dibujarFilo(_ c: CGContext, _ st: Estilo) {
        func bandas(_ color: UInt32, _ lista: [(ancho: CGFloat, alfa: CGFloat)]) {
            for b in lista {
                c.addPath(silueta)
                c.setLineWidth(b.ancho * 2)
                c.setStrokeColor(rgb(color, b.alfa))
                c.strokePath()
            }
        }
        func mascaraVertical(_ paradas: [(CGFloat, CGFloat)]) {
            c.setBlendMode(.destinationIn)
            let g = CGGradient(colorsSpace: espacio, colors: paradas.map { rgb(0xFFFFFF, $0.1) } as CFArray,
                               locations: paradas.map { $0.0 })!
            c.drawLinearGradient(g, start: CGPoint(x: 512, y: cuerpo.maxY), end: CGPoint(x: 512, y: cuerpo.minY), options: [])
        }
        c.saveGState()
        c.addPath(silueta)
        c.clip()
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        bandas(0xFFFFFF, [(12, 0.05), (7, 0.19), (5, 0.13), (3, 0.25), (1.5, 0.42)])
        mascaraVertical([(0, st.filoArriba), (0.28, 0), (0.72, 0), (1, st.filoAbajo)])
        c.endTransparencyLayer()
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        bandas(0x000000, [(6, st.filoLados)])
        bandas(0xFFFFFF, [(1.5, 0.06)])
        mascaraVertical([(0, 0), (0.3, 1), (0.7, 1), (1, 0)])
        c.endTransparencyLayer()
        c.restoreGState()
    }

    // MARK: Archivos

    static func escalar(_ imagen: CGImage, a n: Int) -> CGImage? {
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: espacio,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(imagen, in: CGRect(x: 0, y: 0, width: n, height: n))
        return c.makeImage()
    }

    static func escribirPNG(_ imagen: CGImage, en url: URL) throws {
        guard let destino = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ErrorIconos("No se pudo crear \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destino, imagen, nil)
        guard CGImageDestinationFinalize(destino) else { throw ErrorIconos("No se pudo escribir \(url.lastPathComponent)") }
    }

    static func leerImagen(_ url: URL) -> CGImage? {
        guard let fuente = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(fuente, 0, nil)
    }

    /// icns con todos los tamanos del sistema, armado con iconutil desde un iconset
    static func escribirICNS(_ imagen: CGImage, en url: URL) throws {
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent("iconos-\(UUID().uuidString).iconset")
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: set) }
        for base in [16, 32, 128, 256, 512] {
            for (sufijo, factor) in [("", 1), ("@2x", 2)] {
                guard let img = escalar(imagen, a: base * factor) else { throw ErrorIconos("No se pudo escalar el icono") }
                try escribirPNG(img, en: set.appendingPathComponent("icon_\(base)x\(base)\(sufijo).png"))
            }
        }
        // Se escribe al lado y se renombra: el agente nunca lee un icns a medias
        let temporal = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).icns")
        defer { try? fm.removeItem(at: temporal) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", "-o", temporal.path, set.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ErrorIconos("iconutil fallo (\(p.terminationStatus))") }
        guard rename(temporal.path, url.path) == 0 else { throw ErrorIconos("No se pudo guardar \(url.lastPathComponent)") }
    }
}

struct ErrorIconos: LocalizedError {
    /// Para decidir que boton ofrecer sin mirar el texto (el texto se traduce)
    enum Codigo: String, Codable {
        /// macOS frena la escritura: falta Gestion de apps (para Iconos, el agente o Terminal)
        case sinGestionDeApps
        /// App de root sin la ACL de Iconos: se arregla con Permitir cambios
        case sinPermisoRoot
        /// Del sistema o con marca inmutable del fabricante: no se puede
        case protegida
        /// sudo fallo: contrasena incorrecta o cuenta sin permisos de administrador
        case sudo
    }

    let errorDescription: String?
    /// La app se estaba actualizando (desaparecio o cambio el bundle): se reintenta pronto
    let transitorio: Bool
    let codigo: Codigo?
    /// El mensaje se traduce al crearlo: los literales son claves de Recursos/Localizable.xcstrings
    init(_ mensaje: String.LocalizationValue, transitorio: Bool = false, codigo: Codigo? = nil) {
        self.init(texto: String(localized: mensaje), transitorio: transitorio, codigo: codigo)
    }

    /// Un texto ya traducido (o armado con textos traducidos). No hay init(_: String) a proposito: un
    /// String pasado sin etiqueta no compila en vez de quedar sin traducir
    init(texto: String, transitorio: Bool = false, codigo: Codigo? = nil) {
        errorDescription = texto
        self.transitorio = transitorio
        self.codigo = codigo
    }
}
