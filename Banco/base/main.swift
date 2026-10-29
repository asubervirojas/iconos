import AppKit
// Banco de pruebas: banco <muestras> <salida>. Para cada carpeta con original.png escribe claro.png y
// oscuro.png igual que Iconos (Almacen.imagen, estilo automatico, tamano 1) y una linea de log.
let args = CommandLine.arguments
let entrada = URL(fileURLWithPath: args[1]), salida = URL(fileURLWithPath: args[2])
let nombres = ((try? FileManager.default.contentsOfDirectory(atPath: entrada.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
for n in nombres where args.count < 4 || args[3...].contains(n) {
    guard let arte = Lienzo.leerImagen(entrada.appendingPathComponent("\(n)/original.png")) else { continue }
    let t0 = Date()
    let x = Extractor.extract(arte)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let dir = salida.appendingPathComponent(n)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Lienzo.escribirPNG(arte, en: dir.appendingPathComponent("original.png"))
    for v in Variante.allCases {
        if let img = Lienzo.renderizar(logo: v == .claro ? x.light : x.dark, variante: v, escala: 0.62, destino: x.destino) {
            try? Lienzo.escribirPNG(img, en: dir.appendingPathComponent("\(v.rawValue).png"))
        }
    }
    print("\(n)\t\(x.mode)\t\(ms) ms\t\(x.details)\t\(x.confianza.rawValue)\t\(x.motivos.joined(separator: "; "))")
}
