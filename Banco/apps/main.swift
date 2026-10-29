import AppKit

let args = CommandLine.arguments
guard args.count > 2 else {
    fputs("Uso: diagnostico <salida> <ruta.app>...\n", stderr)
    exit(1)
}
let salida = URL(fileURLWithPath: args[1])
for ruta in args.dropFirst(2) {
    guard FileManager.default.fileExists(atPath: ruta), let arte = arteOriginal(ruta) else {
        fputs("Sin icono original: \(ruta)\n", stderr)
        exit(1)
    }
    let nombre = URL(fileURLWithPath: ruta).deletingPathExtension().lastPathComponent
    let x = Extractor.extraer(arte, app: ruta)
    let dir = salida.appendingPathComponent(nombre)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Lienzo.escribirPNG(arte, en: dir.appendingPathComponent("original.png"))
    for v in Variante.allCases {
        if let img = Lienzo.renderizar(logo: v == .claro ? x.light : x.dark, variante: v, escala: 0.62, destino: x.destino) {
            try Lienzo.escribirPNG(img, en: dir.appendingPathComponent("\(v.rawValue).png"))
        }
    }
    print("\(nombre)\t\(x.mode)\t\(x.plate)\t\(x.details)\t\(x.confianza.rawValue)\t\(x.motivos.joined(separator: "; "))")
}
