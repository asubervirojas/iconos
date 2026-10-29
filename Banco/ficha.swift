// Hoja por app: original (sobre cuadricula), resultado claro y oscuro, a 420 px
import AppKit
let a = CommandLine.arguments
let dir = a[1], salida = a[2], titulo = a[3]
let c: CGFloat = 420, pie: CGFloat = 34
let img = NSImage(size: NSSize(width: c * 3, height: c + pie))
img.lockFocus()
NSColor(white: 0.55, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: c * 3, height: c + pie).fill()
// cuadricula para ver la transparencia del original
for i in 0..<21 { for j in 0..<21 where (i + j) % 2 == 0 {
    NSColor(white: 0.75, alpha: 1).setFill(); NSRect(x: CGFloat(i) * 20, y: CGFloat(j) * 20, width: 20, height: 20).fill() } }
for (k, n) in ["original", "claro", "oscuro"].enumerated() {
    NSImage(contentsOfFile: "\(dir)/\(n).png")?.draw(in: NSRect(x: CGFloat(k) * c + 10, y: 10, width: c - 20, height: c - 20))
}
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
("\(titulo)   |   original   |   claro   |   oscuro" as NSString).draw(at: NSPoint(x: 10, y: c + 7), withAttributes: attrs)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: salida))
