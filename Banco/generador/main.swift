import AppKit
import CryptoKit

// Lee bundles locales; la salida contiene arte ajeno y no se distribuye.
let fm = FileManager.default
let args = CommandLine.arguments
guard args.count >= 3 else { fputs("Uso: muestras <salida> <carpeta de apps>...\n", stderr); exit(1) }
let salida = URL(fileURLWithPath: args[1])
try fm.createDirectory(at: salida, withIntermediateDirectories: true)
var vistas = Set<String>()
var total = 0
func extraer(_ app: URL) {
    guard app.pathExtension == "app", vistas.insert(app.standardizedFileURL.path).inserted,
          let valores = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          valores.isDirectory == true, valores.isSymbolicLink != true,
          fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else { return }
    autoreleasepool {
        guard let arte = arteOriginal(app.path) else { fputs("Sin arte original: \(app.path)\n", stderr); return }
        let nombre = app.deletingPathExtension().lastPathComponent
        let resumen = SHA256.hash(data: Data(app.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let destino = salida.appendingPathComponent("\(nombre)-\(resumen)")
        do {
            try fm.createDirectory(at: destino, withIntermediateDirectories: true)
            try Lienzo.escribirPNG(arte, en: destino.appendingPathComponent("original.png"))
            total += 1
            print(destino.lastPathComponent)
        } catch { fputs("\(app.path): \(error.localizedDescription)\n", stderr) }
    }
}
for raiz in args.dropFirst(2) {
    guard let entradas = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: raiz),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
    for entrada in entradas {
        if entrada.pathExtension == "app" { extraer(entrada) }
        else if let valores = try? entrada.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                valores.isDirectory == true, valores.isSymbolicLink != true,
                let dentro = try? fm.contentsOfDirectory(at: entrada, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for app in dentro { extraer(app) }
        }
    }
}
print("Muestras generadas: \(total)")
if total == 0 { exit(1) }
