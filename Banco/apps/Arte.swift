import AppKit

// Lee el bundle y rasteriza en claro, igual que Almacen.mejor, sin sus archivos guardados.
func arteOriginal(_ ruta: String) -> CGImage? {
    let url = URL(fileURLWithPath: ruta), bundle = Bundle(path: ruta)
    let info = bundle?.infoDictionary ?? [:]
    var imagen: NSImage?
    if var nombre = info["CFBundleIconFile"] as? String, !nombre.isEmpty {
        if (nombre as NSString).pathExtension.isEmpty { nombre += ".icns" }
        imagen = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/\(nombre)"))
    }
    if imagen == nil, let nombre = info["CFBundleIconName"] as? String {
        imagen = bundle?.image(forResource: nombre)
    }
    if imagen == nil {
        // No confundir un icono aplicado en Finder con el original del fabricante.
        let personalizado = url.appendingPathComponent("Icon\r")
        guard !FileManager.default.fileExists(atPath: personalizado.path) else { return nil }
        imagen = NSWorkspace.shared.icon(forFile: ruta)
    }
    guard let imagen,
          let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                            space: Lienzo.espacio, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.interpolationQuality = .high
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        imagen.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    return c.makeImage()
}

