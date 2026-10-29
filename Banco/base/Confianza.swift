// Contrato minimo del banco; evita depender de Almacen y del resto de la app.
enum Confianza: String, Codable, CaseIterable, Comparable {
    case baja, media, alta

    private var orden: Int { switch self { case .baja: 0; case .media: 1; case .alta: 2 } }
    static func < (a: Confianza, b: Confianza) -> Bool { a.orden < b.orden }
}
