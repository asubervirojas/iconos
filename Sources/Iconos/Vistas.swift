import AppKit
import SwiftUI

struct VistaPrincipal: View {
    @EnvironmentObject var e: Estudio
    @Environment(\.openWindow) private var abrirVentana

    var body: some View {
        NavigationSplitView {
            Lateral()
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
        } detail: {
            Group {
                if e.elegidas.count > 1 {
                    PanelVarias()
                } else if e.borrador != nil {
                    Editor()
                } else {
                    ContentUnavailableView {
                        Label("Elige una app", systemImage: "square.on.square")
                    } description: {
                        Text("Iconos saca el logo de su ficha y lo pone sobre una ficha clara u oscura con la forma de macOS. Elige varias con Cmd o Mayúsculas para cambiarlas juntas.")
                    } actions: {
                        // Lo que paso fuera del editor (Mover ajustes, Permitir cambios) tambien se ve
                        AvisoActual()
                            .buttonStyle(.glass)
                            .frame(maxWidth: 520)
                    }
                }
            }
            .safeAreaBar(edge: .top) {
                if e.configDanada { AvisoConfigDanada().padding(10) }
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .onAppear {
            if e.mostrarBienvenidaAlAbrir { abrirVentana(id: VistaBienvenida.id) }
        }
    }
}

/// config.json no se pudo leer: Iconos no escribe nada hasta que se revise
struct AvisoConfigDanada: View {
    @EnvironmentObject var e: Estudio

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("La configuración está dañada; se guardó una copia y no se borrará nada hasta que la revises")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Mostrar en Finder") { e.mostrarDatosEnFinder() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Lista de apps

struct Lateral: View {
    @EnvironmentObject var e: Estudio
    @Environment(\.colorScheme) private var esquema

    var body: some View {
        let repetidos = e.nombresRepetidos
        let gestionadas = e.gestionadas, resto = e.resto
        // La cabecera va encima de la lista: como barra flotante, con avisos crecia hacia arriba y se
        // metia debajo de los botones de la ventana
        VStack(spacing: 0) {
            CabeceraLista()
            List(selection: $e.elegidas) {
                if !gestionadas.isEmpty {
                    Section("Personalizadas") {
                        ForEach(gestionadas) { FilaApp(app: $0, repetido: repetidos.contains($0.nombre)) }
                    }
                }
                if !resto.isEmpty {
                    Section(gestionadas.isEmpty ? "Apps" : "Otras apps") {
                        ForEach(resto) { FilaApp(app: $0, repetido: repetidos.contains($0.nombre)) }
                    }
                }
            }
            .overlay {
                if gestionadas.isEmpty, resto.isEmpty, !e.escaneando {
                    ContentUnavailableView("Ninguna app", systemImage: "line.3.horizontal.decrease",
                                           description: Text(e.filtro == .todas ? "Nada coincide con la búsqueda." : "Ninguna app en «\(e.filtro.titulo)»."))
                }
            }
            .safeAreaBar(edge: .bottom) { PildoraAgente().padding(10) }
        }
        .searchable(text: $e.busqueda, placement: .sidebar, prompt: "Buscar")
        // El agente cambia la variante con la apariencia: la lista mira otra vez cuando ya lo hizo
        .onChange(of: esquema) { e.programarEscaneo(4) }
        .toolbar {
            ToolbarItem {
                Button("Volver a buscar apps", systemImage: "arrow.clockwise") { e.escanear() }
            }
        }
    }
}

struct FilaApp: View {
    @EnvironmentObject var e: Estudio
    let app: AppEncontrada
    let repetido: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: e.miniatura(app.ruta))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.nombre).lineLimit(1)
                if repetido {
                    Text(ubicacion).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let simbolo = estado.simbolo {
                Image(systemName: simbolo)
                    .font(estado == .puesto ? .caption : .caption2)
                    .foregroundStyle(estado.estilo)
                    .help(estado.ayuda(app, gestionada: e.gestionada(app.ruta) != nil))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(estado.palabras(app, gestionada: e.gestionada(app.ruta) != nil))
        .tag(app.ruta)
    }

    /// Lee la apariencia para volver a dibujar la fila cuando cambia (la variante que toca)
    @Environment(\.colorScheme) private var esquema
    private var estado: EstadoFila { _ = esquema; return e.estadoFila(app) }

    private var ubicacion: String {
        ((app.ruta as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}

extension EstadoFila {
    var simbolo: String? {
        switch self {
        case .noSePuede, .sinPermiso: "lock.fill"
        case .falta: "exclamationmark.triangle.fill"
        case .puesto: "checkmark.circle.fill"
        case .oscuroPropio: "circle.lefthalf.filled"
        case .normal: nil
        }
    }

    var estilo: AnyShapeStyle {
        switch self {
        case .noSePuede: AnyShapeStyle(.tertiary)
        case .sinPermiso, .falta: AnyShapeStyle(.orange)
        case .puesto: AnyShapeStyle(.tint)
        case .oscuroPropio, .normal: AnyShapeStyle(.secondary)
        }
    }

    func ayuda(_ app: AppEncontrada, gestionada: Bool) -> String {
        switch self {
        case .noSePuede: app.sistema ? String(localized: "App del sistema: no se puede cambiar") : String(localized: "Bloqueada por su fabricante: no se puede cambiar")
        case .sinPermiso: gestionada ? String(localized: "Perdió el permiso (quizá al actualizarse): pide tu contraseña otra vez")
            : String(localized: "Pide tu contraseña una vez para poder cambiarla")
        case .falta: String(localized: "Falta poner el icono: pendiente o sin permiso")
        case .puesto: String(localized: "Con icono de Iconos")
        case .oscuroPropio: String(localized: "Su icono ya tiene modo oscuro: macOS lo cambia solo")
        case .normal: ""
        }
    }

    /// Para VoiceOver
    func palabras(_ app: AppEncontrada, gestionada: Bool) -> String {
        switch self {
        case .noSePuede: app.sistema ? String(localized: "App del sistema, no se puede cambiar") : String(localized: "Bloqueada por su fabricante, no se puede cambiar")
        case .sinPermiso: gestionada ? String(localized: "Personalizada, perdió el permiso") : String(localized: "Necesita permiso")
        case .falta: String(localized: "Falta poner el icono")
        case .puesto: String(localized: "Con icono de Iconos")
        case .oscuroPropio: String(localized: "Con modo oscuro propio")
        case .normal: app.personalizado ? String(localized: "Con otro icono personalizado") : String(localized: "Sin personalizar")
        }
    }
}

/// Filtro por estado y avisos de lo que anoto el agente, arriba de la lista
struct CabeceraLista: View {
    @EnvironmentObject var e: Estudio
    @State private var altoAvisos: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mostrar", selection: $e.filtro) {
                ForEach(FiltroApps.allCases) { f in
                    Text("\(f.titulo) (\(e.cuantas(f)))").tag(f)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Mostrar apps")

            // Con muchos avisos se desplazan ellos: la lista de apps no se queda sin sitio
            ScrollView {
                avisos.onGeometryChange(for: CGFloat.self, of: \.size.height) { altoAvisos = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(altoAvisos, 300))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var avisos: some View {
        VStack(spacing: 8) {
            let sinPermiso = e.pendientesSinPermiso
            if !sinPermiso.isEmpty {
                Tarjeta(simbolo: "lock.fill", color: .orange,
                        titulo: sinPermiso.count == 1 ? String(localized: "1 app perdió el permiso al actualizarse")
                            : String(localized: "\(sinPermiso.count) apps perdieron el permiso al actualizarse"),
                        detalle: sinPermiso.map(\.nombre).joined(separator: ", ")) {
                    Button("Permitir cambios…") { e.permitirPendientes() }
                }
            }
            let nuevos = e.pendientesIconoNuevo
            if !nuevos.isEmpty {
                Tarjeta(simbolo: "sparkles", color: .accentColor,
                        titulo: nuevos.count == 1 ? String(localized: "\(nuevos[0].nombre) cambió de icono")
                            : String(localized: "\(nuevos.count) apps cambiaron de icono"),
                        detalle: (nuevos.count == 1 ? "" : nuevos.map(\.nombre).joined(separator: ", ") + ". ")
                            + String(localized: "Su fabricante trajo un icono nuevo e Iconos sacó el logo otra vez.")) {
                    Button("Entendido") { e.entendido(.iconoNuevo) }
                }
            }
            ForEach(e.pendientesRevisar) { p in
                Tarjeta(simbolo: "exclamationmark.triangle.fill", color: .orange,
                        titulo: String(localized: "Revisa el logo de \(p.nombre)"),
                        detalle: String(localized: "Cambió su icono y el logo nuevo no salió bien: se dejó el anterior.")) {
                    Button("Revisar") { e.revisar(p.ruta) }
                    Button("Ignorar") { e.descartarPendiente(p) }
                }
            }
            ForEach(e.reubicables) { r in
                Tarjeta(simbolo: "arrow.right.doc.on.clipboard", color: .accentColor,
                        titulo: String(localized: "\(e.nombreGestionada(r.vieja)) está en otra ubicación"),
                        detalle: String(localized: "Ahora está en \(((r.nueva as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath).")) {
                    Button("Mover ajustes") { e.moverAjustes(r) }
                        .disabled(e.trabajando)
                }
            }
        }
    }
}

/// Aviso compacto con sus botones (barra lateral)
struct Tarjeta<Botones: View>: View {
    let simbolo: String
    let color: Color
    let titulo: String
    let detalle: String
    @ViewBuilder let botones: Botones

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titulo).font(.callout.weight(.medium))
                    if !detalle.isEmpty {
                        Text(detalle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: simbolo).foregroundStyle(color)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                botones
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}

/// Estado del cambio automatico, al pie de la lista
struct PildoraAgente: View {
    @EnvironmentObject var e: Estudio

    var body: some View {
        // Activo pero macOS lo frena: no pone ningun icono hasta tener Gestion de apps
        let sinGestion = e.agenteConGestionDeApps == false
        HStack(spacing: 8) {
            PuntoAgente(estado: e.estadoAgente, aviso: sinGestion)
            VStack(alignment: .leading, spacing: 0) {
                Text("Cambio automático")
                    .font(.callout)
                Text(sinGestion ? String(localized: "Falta Gestión de apps") : e.estadoAgente.palabra)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            switch e.estadoAgente {
            case .apagado:
                Button("Activar") { e.activarAgente() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            case .sinRespuesta, .otraCopia, .otraVersion:
                Button("Reparar") { e.activarAgente() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            case .activo, .arrancando:
                if sinGestion {
                    Button("Arreglar") { abrirGestionDeApps() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .help("Activa Iconos Agente en Privacidad y seguridad > Gestión de apps")
                }
            }
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Ajustes de Iconos")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .help(sinGestion ? String(localized: "macOS no deja al agente cambiar iconos: activa Iconos Agente en Privacidad y seguridad > Gestión de apps.")
              : e.estadoAgente.detalle)
    }
}

struct PuntoAgente: View {
    let estado: EstadoDelAgente
    /// Activo pero con un problema (por ejemplo sin Gestion de apps)
    var aviso = false

    var body: some View {
        if estado == .arrancando {
            ProgressView().controlSize(.mini)
        } else {
            Circle()
                .fill(aviso ? Color.orange : estado.color)
                .frame(width: 7, height: 7)
        }
    }
}

extension EstadoDelAgente {
    var color: Color {
        switch self {
        case .activo, .arrancando: .green
        case .apagado: .secondary.opacity(0.5)
        case .sinRespuesta, .otraCopia, .otraVersion: .orange
        }
    }

    var palabra: String {
        switch self {
        case .activo: String(localized: "Activo")
        case .arrancando: String(localized: "Arrancando…")
        case .apagado: String(localized: "Apagado")
        case .sinRespuesta: String(localized: "No responde")
        case .otraCopia, .otraVersion: String(localized: "Hay que repararlo")
        }
    }

    var tituloCorto: String {
        switch self {
        case .activo: String(localized: "Cambio automático activo")
        case .arrancando: String(localized: "Arrancando…")
        case .apagado: String(localized: "Cambio automático apagado")
        case .sinRespuesta: String(localized: "El agente no responde")
        case .otraCopia: String(localized: "El agente usa otra copia")
        case .otraVersion: String(localized: "El agente es de otra versión")
        }
    }

    var detalle: String {
        switch self {
        case .sinRespuesta: String(localized: "Está cargado pero no da señales. Reparar lo vuelve a cargar; el registro está en ~/Library/Logs/Iconos-agente.log.")
        case .otraCopia: String(localized: "Apunta a una copia de Iconos que se movió o se recompiló. Reparar lo deja con esta.")
        case .otraVersion: String(localized: "Sigue corriendo el agente de la versión anterior de Iconos. Reparar lo vuelve a cargar con esta.")
        default: String(localized: "Cambia los iconos con el modo claro u oscuro y los vuelve a poner cuando una app se actualiza. Las apps de root necesitan el permiso otra vez si la actualización reemplaza la app.")
        }
    }
}

// MARK: Editor

struct Editor: View {
    @EnvironmentObject var e: Estudio
    @State private var verOriginal = false

    var body: some View {
        if let app = e.appSeleccionada, let g = e.borrador {
            Form {
                Section {
                    Picker("Apariencia", selection: borrador.modo) {
                        ForEach(Modo.allCases) { Text($0.titulo).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Escenario(g: g, verOriginal: verOriginal)
                        .padding(.bottom, 14)
                } footer: {
                    if g.modo == .automatico, !e.agenteActivo {
                        Text("El modo automático necesita el cambio automático activo (abajo a la izquierda).")
                            .foregroundStyle(.secondary)
                    }
                }

                if e.oscuroPropio.contains(app.ruta), e.gestionada(app.ruta) == nil {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Esta app ya tiene su propio modo oscuro")
                                Text("macOS cambia su icono solo. Aplica Iconos únicamente si quieres la ficha blanca y oscura de Iconos en su lugar.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "circle.lefthalf.filled")
                        }
                    }
                }

                if !app.escribible {
                    Section { avisoPermiso(app) }
                }

                if !g.propia {
                    Section("Logo") {
                        Picker("Estilo", selection: borrador.ajustes.estilo) {
                            ForEach(EstiloLogo.allCases) { Text($0.titulo).tag($0) }
                        }
                        LabeledContent("Tamaño") {
                            HStack(spacing: 10) {
                                Slider(value: borrador.ajustes.tamano, in: 0.6...1.4)
                                    .frame(maxWidth: 260)
                                    .accessibilityLabel("Tamaño del logo")
                                    .accessibilityValue("\(Int((g.ajustes.tamano * 100).rounded())) por ciento")
                                Text("\(Int((g.ajustes.tamano * 100).rounded())) %")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        if g.ajustes.estilo == .completo {
                            Picker("Quitar el blanco", selection: borrador.ajustes.quitarBlanco) {
                                ForEach(QuitarBlanco.allCases) { Text($0.titulo).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                if let d = e.diagnostico {
                    SeccionDiagnostico(d: d, faltaIcono: e.faltaIconoPropio)
                }

                Section {
                    LabeledContent("Imágenes propias") {
                        HStack(spacing: 8) {
                            Button("Clara…") { e.elegirPropia(.claro) }
                            Button("Oscura…") { e.elegirPropia(.oscuro) }
                            if e.tienePropias {
                                Button("Quitar", role: .destructive) { e.quitarPropias() }
                            }
                        }
                    }
                    if e.tienePropias {
                        Toggle("Usar las imágenes propias", isOn: borrador.propia)
                    }
                } footer: {
                    Text("Para usar un icono hecho a mano en lugar del generado (1024 × 1024).")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // Borde marcado bajo la barra de acciones: el formulario no se mezcla con los botones
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .disabled(e.trabajando)
            .navigationTitle(app.nombre)
            .navigationSubtitle(e.estado)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $verOriginal) {
                        Label("Ver original", systemImage: "eye")
                    }
                    .toggleStyle(.button)
                    .help("Comparar con el icono original")
                    Button("Mostrar en Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.ruta)])
                    }
                }
            }
            // Barra con el efecto de borde de macOS 26: el formulario se difumina al pasar por debajo
            .safeAreaBar(edge: .bottom) {
                BarraAcciones(app: app)
            }
            .onChange(of: e.seleccion) { verOriginal = false }
        }
    }

    private var borrador: Binding<Gestionada> {
        Binding(get: { e.borrador ?? Gestionada(ruta: "", nombre: "") }, set: { e.borrador = $0 })
    }

    @ViewBuilder private func avisoPermiso(_ app: AppEncontrada) -> some View {
        if app.sistema {
            Label("Es una app del sistema: macOS no deja cambiar su icono.", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        } else if app.bloqueada {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bloqueada por su fabricante")
                    Text("Tiene la marca de archivo inmutable para que nadie la modifique, ni siquiera root. Quitarla puede romper la protección de la app, así que Iconos no la toca.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield.fill")
            }
        } else {
            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Esta app es de root")
                        Text("Se abre Terminal y pide tu contraseña. Solo se da permiso en la carpeta de la app, no dentro de ella. Si una actualización reemplaza la app, hay que darlo otra vez. Si macOS lo bloquea, activa Terminal en Gestión de apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.fill")
                }
                Spacer()
                Button("Permitir cambios…") { e.permitir() }
            }
        }
    }
}

/// Claro y oscuro uno al lado del otro, sobre su propio fondo, con el Dock debajo
struct Escenario: View {
    @EnvironmentObject var e: Estudio
    @Environment(\.colorScheme) private var esquema
    let g: Gestionada
    let verOriginal: Bool

    var body: some View {
        let ahora = g.modo.variante(oscuroAhora: esquema == .dark)
        HStack(spacing: 0) {
            mitad(.claro, enUso: ahora == .claro)
            mitad(.oscuro, enUso: ahora == .oscuro)
        }
        .frame(height: 296)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .textCase(nil)
    }

    private func mitad(_ v: Variante, enUso: Bool) -> some View {
        let oscuro = v == .oscuro
        let imagen = verOriginal ? e.previaOriginal : (oscuro ? e.previaOscuro : e.previaClaro)
        return ZStack {
            LinearGradient(colors: oscuro ? [Color(white: 0.17), Color(white: 0.085)] : [Color(white: 0.985), Color(white: 0.885)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Spacer(minLength: 18)
                Group {
                    if let imagen {
                        Image(nsImage: imagen)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 150, height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(verOriginal ? "Original" : (oscuro ? "Icono oscuro" : "Icono claro"))
                .accessibilityValue(enUso && !verOriginal ? "En uso" : "")
                HStack(spacing: 6) {
                    Text(verOriginal ? "Original" : (oscuro ? "Oscuro" : "Claro"))
                        .fontWeight(.semibold)
                    if enUso, !verOriginal {
                        Text("En uso")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.09)))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                Spacer(minLength: 14)
                MiniDock(centro: imagen, vecinos: e.vecinos(de: g.ruta), oscuro: oscuro)
                    .padding(.bottom, 16)
            }
        }
        .environment(\.colorScheme, oscuro ? .dark : .light)
    }
}

/// Simulacion del Dock: el icono entre otras apps, al tamano en que se ve de verdad
struct MiniDock: View {
    let centro: NSImage?
    let vecinos: [NSImage]
    let oscuro: Bool

    var body: some View {
        let mitad = vecinos.count / 2
        HStack(spacing: 6) {
            ForEach(Array(vecinos.prefix(mitad).enumerated()), id: \.offset) { icono($0.element).opacity(0.9) }
            icono(centro)
            ForEach(Array(vecinos.dropFirst(mitad).enumerated()), id: \.offset) { icono($0.element).opacity(0.9) }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(oscuro ? Color.white.opacity(0.08) : Color.white.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(oscuro ? Color.white.opacity(0.12) : Color.black.opacity(0.06), lineWidth: 1)
        )
        .accessibilityLabel("Simulación del Dock")
    }

    @ViewBuilder private func icono(_ imagen: NSImage?) -> some View {
        if let imagen {
            Image(nsImage: imagen)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
        } else {
            Color.clear.frame(width: 38, height: 38)
        }
    }
}

/// Restaurar a la izquierda; estado, Descartar y Aplicar a la derecha. Siempre visible
struct BarraAcciones: View {
    @EnvironmentObject var e: Estudio
    let app: AppEncontrada

    var body: some View {
        let gestionada = e.gestionada(app.ruta) != nil
        GlassEffectContainer {
            HStack(spacing: 10) {
                Button("Restaurar original", systemImage: "arrow.uturn.backward") { e.restaurar() }
                    .buttonStyle(.glass)
                    .disabled(!e.puedeRestaurar)
                    .help("Quitar el icono personalizado y volver al de la app")
                Spacer(minLength: 12)
                AvisoActual(lineas: 2)
                    .buttonStyle(.glass)
                if e.trabajando { ProgressView().controlSize(.small) }
                if gestionada, e.cambiosSinAplicar {
                    Button("Descartar") { e.descartar() }
                        .buttonStyle(.glass)
                        .disabled(e.trabajando)
                }
                Button {
                    e.aplicar()
                } label: {
                    Text(!gestionada ? "Aplicar" : e.cambiosSinAplicar ? "Guardar cambios" : "Volver a poner")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                // Cmd+S y no Return: con Return al moverse por la lista se aplicaba sin querer
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!e.puedeAplicar)
                .help(e.faltaIconoPropio ? "Esta app no trae icono propio: elige tus imágenes" : "Aplicar (⌘S)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

/// Como salio el logo: metodo, confianza y motivos
struct SeccionDiagnostico: View {
    let d: Diagnostico
    let faltaIcono: Bool

    var body: some View {
        Section("Resultado") {
            if faltaIcono {
                Label("Esta app no trae icono propio: elige tus imágenes", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.orange)
            } else {
                LabeledContent("Confianza") {
                    Label(d.confianza.titulo, systemImage: d.confianza.simbolo)
                        .foregroundStyle(d.confianza.color)
                }
            }
            if !d.metodo.isEmpty {
                // metodo es la clave interna: se muestra traducido. Los motivos ya vienen traducidos
                let metodo = Diagnostico.titulo(metodo: d.metodo)
                LabeledContent("Cómo salió", value: metodo.prefix(1).uppercased() + metodo.dropFirst())
            }
            ForEach(d.motivos, id: \.self) { motivo in
                Text(motivo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Confianza {
    var color: Color {
        switch self {
        case .alta: .green
        case .media: .orange
        case .baja: .red
        }
    }

    var simbolo: String {
        switch self {
        case .alta: "checkmark.seal.fill"
        case .media: "exclamationmark.circle.fill"
        case .baja: "xmark.octagon.fill"
        }
    }
}

/// Error o mensaje de la ultima accion, con el boton que lo arregla cuando lo hay. Se ve en el editor,
/// en la vista vacia, en el panel de varias apps y en Ajustes
struct AvisoActual: View {
    @EnvironmentObject var e: Estudio
    var lineas: Int?

    var body: some View {
        if let error = e.error {
            HStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(lineas)
                    .help(error)
                // Por codigo y no por texto: el texto se traduce
                if e.codigoError == .sinGestionDeApps {
                    Button("Abrir Gestión de apps") { abrirGestionDeApps() }
                } else if e.codigoError == .sinPermisoRoot, e.appSeleccionada != nil {
                    Button("Permitir cambios…") { e.permitir() }
                }
            }
            .font(.callout)
        } else if let mensaje = e.mensaje {
            HStack(spacing: 8) {
                Label(mensaje, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(lineas)
                    .help(mensaje)
                if !e.permisoQueSobra.isEmpty {
                    Button("Quitar también el permiso") { e.quitarPermiso(e.permisoQueSobra) }
                        .help("La app sigue con el permiso que le dio Iconos; ya no hace falta")
                }
            }
            .font(.callout)
        }
    }
}

func abrirGestionDeApps() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: Varias apps

/// Varias apps elegidas: apariencia y estilo comunes, aplicar o restaurar todas juntas
struct PanelVarias: View {
    @EnvironmentObject var e: Estudio
    @State private var confirmarRestaurar = false

    var body: some View {
        let elegidas = e.appsElegidas
        let escribibles = e.elegidasEscribibles
        let restaurables = e.elegidasRestaurables
        Form {
            Section {
                Picker("Apariencia", selection: $e.modoVarias) {
                    ForEach(Modo.allCases) { Text($0.titulo).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Estilo", selection: $e.estiloVarias) {
                    ForEach(EstiloLogo.allCases) { Text($0.titulo).tag($0) }
                }
            } header: {
                HStack(spacing: -10) {
                    ForEach(elegidas.prefix(9)) { app in
                        Image(nsImage: e.miniatura(app.ruta))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 56, height: 56)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .accessibilityHidden(true)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if escribibles.count < elegidas.count {
                        Text("\(elegidas.count - escribibles.count) no se pueden cambiar ahora (del sistema, bloqueadas o sin permiso): se saltan.")
                    }
                    Text("Las que usan imágenes propias las conservan. El tamaño y lo demás de cada una no cambia.")
                }
                .foregroundStyle(.secondary)
            }

            Section("Apps elegidas") {
                ForEach(elegidas) { app in
                    let estado = e.estadoFila(app)
                    HStack(spacing: 9) {
                        Image(nsImage: e.miniatura(app.ruta))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 22, height: 22)
                        Text(app.nombre)
                        Spacer()
                        Text(estado.palabras(app, gestionada: e.gestionada(app.ruta) != nil))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .disabled(e.trabajando)
        .navigationTitle("\(elegidas.count) apps")
        .navigationSubtitle(escribibles.count == elegidas.count ? "Se pueden cambiar todas" : "Se pueden cambiar \(escribibles.count)")
        .safeAreaBar(edge: .bottom) {
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Button("Restaurar todas las elegidas", systemImage: "arrow.uturn.backward") { confirmarRestaurar = true }
                        .buttonStyle(.glass)
                        .disabled(e.trabajando || restaurables.isEmpty)
                    Spacer(minLength: 12)
                    AvisoActual(lineas: 2)
                        .buttonStyle(.glass)
                    if e.trabajando { ProgressView().controlSize(.small) }
                    Button {
                        e.aplicarVarias()
                    } label: {
                        Text("Aplicar a todas").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(e.trabajando || escribibles.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .confirmationDialog(restaurables.count == 1 ? "¿Restaurar el icono original de 1 app?"
                            : "¿Restaurar el icono original de \(restaurables.count) apps?",
                            isPresented: $confirmarRestaurar) {
            Button("Restaurar", role: .destructive) { e.restaurarVarias() }
        } message: {
            Text("Iconos deja de cuidarlas y borra sus ajustes e imágenes propias.")
        }
    }
}

// MARK: Ajustes

struct AjustesGenerales: View {
    @EnvironmentObject var e: Estudio
    @Environment(\.openWindow) private var abrirVentana
    @State private var confirmarRestaurarTodas = false
    @State private var confirmarDesinstalar = false

    var body: some View {
        Form {
            if e.error != nil || e.mensaje != nil {
                Section {
                    AvisoActual()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                LabeledContent {
                    Button("Abrir la guía…") { abrirVentana(id: VistaBienvenida.id) }
                } label: {
                    Text("Primeros pasos")
                    Text("Qué permisos necesita Iconos y si ya los tiene.")
                }
            } header: {
                Text("Permisos")
            }
            seccionAgente
            seccionRoot
            seccionCarpetas
            Section {
                Toggle(isOn: Binding(get: { e.reiniciarDock }, set: { e.reiniciarDock = $0 })) {
                    Text("Actualizar el Dock al cambiar un icono")
                    Text("macOS no deja refrescar un solo icono del Dock: hay que reiniciarlo y parpadea un segundo. Solo pasa si la app está en el Dock. Apagado, el cambio se ve la próxima vez que el Dock se reinicie.")
                }
            } header: {
                Text("Dock")
            }
            seccionMantenimiento
            seccionAcercaDe
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 660)
        .disabled(e.trabajando)
    }

    /// Estado del agente y lo que anoto en su ultima revision
    @ViewBuilder private var seccionAgente: some View {
        Section {
            HStack(spacing: 10) {
                PuntoAgente(estado: e.estadoAgente, aviso: e.agenteConGestionDeApps == false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.estadoAgente.tituloCorto)
                    Text(e.estadoAgente.detalle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch e.estadoAgente {
                case .activo, .arrancando:
                    Button("Apagar") { e.desactivarAgente() }
                case .apagado:
                    Button("Activar") { e.activarAgente() }
                case .sinRespuesta, .otraCopia, .otraVersion:
                    Button("Reparar") { e.activarAgente() }
                }
            }
            if let informe = e.informeAgente {
                if informe.gestionDeApps == false {
                    HStack(spacing: 12) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("macOS no deja al agente cambiar iconos")
                                Text("Activa Iconos Agente en Privacidad y seguridad > Gestión de apps. Hasta entonces no se cambia ningún icono solo.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Abrir Gestión de apps") { abrirGestionDeApps() }
                    }
                }
                LabeledContent("Última revisión", value: informe.fecha.formatted(.relative(presentation: .named)))
                if !informe.errores.isEmpty {
                    DisclosureGroup(informe.errores.count == 1 ? "1 app con error" : "\(informe.errores.count) apps con error") {
                        ForEach(informe.errores.sorted { $0.key < $1.key }, id: \.key) { ruta, texto in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.nombreGestionada(ruta))
                                Text(texto)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        } header: {
            Text("Cambio automático")
        }
    }

    /// Permiso solo para las gestionadas que lo necesitan; y quitar el que quedo en apps que ya no usa
    @ViewBuilder private var seccionRoot: some View {
        let sinPermiso = e.gestionadasSinPermiso
        let sobrantes = e.permisosSobrantes
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sinPermiso.isEmpty ? "Las apps personalizadas tienen permiso"
                         : sinPermiso.count == 1 ? "1 app personalizada sin permiso" : "\(sinPermiso.count) apps personalizadas sin permiso")
                    if !sinPermiso.isEmpty {
                        Text(sinPermiso.map(\.nombre).joined(separator: ", "))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Se abre Terminal y pide tu contraseña una sola vez para todas. Terminal necesita el permiso Gestión de apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Permitir todas…") { e.permitirTodas() }
                    .disabled(sinPermiso.isEmpty)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sobrantes.isEmpty ? "Ningún permiso de más"
                         : sobrantes.count == 1 ? "1 app tiene el permiso sin usarlo" : "\(sobrantes.count) apps tienen el permiso sin usarlo")
                    if !sobrantes.isEmpty {
                        Text(sobrantes.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.joined(separator: ", "))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Apps de root a las que Iconos dio permiso y que ya no personaliza.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // La hoja de Terminal ya dice que hace y para que apps: no hace falta confirmar antes
                Button("Quitar permisos que sobran…") { e.quitarPermisosSobrantes() }
                    .disabled(sobrantes.isEmpty)
            }
            Toggle(isOn: Binding(get: { e.explicarAntesDeTerminal }, set: { e.explicarAntesDeTerminal = $0 })) {
                Text("Explicar antes de abrir Terminal")
                Text("Muestra qué hace el comando y por qué pide tu contraseña.")
            }
            Button("Abrir Gestión de apps") { abrirGestionDeApps() }
        } header: {
            Text("Apps de root")
        }
    }

    /// Carpetas con apps ademas de Aplicaciones
    @ViewBuilder private var seccionCarpetas: some View {
        let carpetas = e.config.carpetasExtra
        Section {
            ForEach(carpetas, id: \.self) { carpeta in
                HStack(spacing: 8) {
                    Label((carpeta as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !FileManager.default.fileExists(atPath: carpeta) {
                        Text("No está")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("La carpeta no existe ahora (quizá es de un disco que no está conectado)")
                    }
                    Spacer()
                    Button("Quitar \((carpeta as NSString).lastPathComponent)", systemImage: "minus") { e.quitarCarpeta(carpeta) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Dejar de buscar apps en esta carpeta")
                }
            }
            HStack {
                Text(carpetas.isEmpty ? "Solo Aplicaciones y la carpeta Aplicaciones de tu usuario." : "Además de Aplicaciones y la de tu usuario.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Agregar carpeta…", systemImage: "plus") { e.agregarCarpetas() }
            }
        } header: {
            Text("Carpetas de apps")
        }
    }

    @ViewBuilder private var seccionMantenimiento: some View {
        let cuantas = e.config.apps.count
        Section {
            LabeledContent("Iconos personalizados") {
                Button("Restaurar todas…") { confirmarRestaurarTodas = true }
                    .disabled(cuantas == 0)
            }
            LabeledContent("Configuración") {
                HStack(spacing: 8) {
                    Button("Exportar configuración…") { e.exportar() }
                        .disabled(cuantas == 0)
                    Button("Importar…") { e.importar() }
                }
            }
            LabeledContent {
                Button("Desinstalar Iconos…", role: .destructive) { confirmarDesinstalar = true }
            } label: {
                Text("Desinstalar")
                Text("Deja el Mac como antes de Iconos.")
            }
        } header: {
            Text("Mantenimiento")
        }
        .confirmationDialog(cuantas == 1 ? "¿Restaurar el icono original de 1 app?" : "¿Restaurar el icono original de \(cuantas) apps?",
                            isPresented: $confirmarRestaurarTodas) {
            Button("Restaurar y conservar imágenes propias") { e.restaurarTodas(conservarPropias: true) }
            Button("Restaurar y borrar todo", role: .destructive) { e.restaurarTodas(conservarPropias: false) }
        } message: {
            Text("Iconos deja de cuidarlas. Puedes conservar tus imágenes propias para usarlas más adelante.")
        }
        .alert("¿Desinstalar Iconos?", isPresented: $confirmarDesinstalar) {
            Button("Desinstalar", role: .destructive) { e.desinstalar() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se restaura el icono original de todas las apps, se apaga el cambio automático, se abre Terminal para quitar los permisos que Iconos dio a las apps de root (pide tu contraseña), se borran los ajustes y las imágenes propias, e Iconos se mueve a la Papelera y se cierra.")
        }
        .alert("No se pudo desinstalar Iconos", isPresented: Binding(get: { e.erroresDesinstalar != nil },
                                                                      set: { if !$0 { e.erroresDesinstalar = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text((e.erroresDesinstalar ?? []).joined(separator: "\n")
                 + "\n\n" + String(localized: "Iconos sigue instalado con sus ajustes: puedes volver a intentarlo."))
        }
    }

    /// Version, repositorio y aviso de marcas
    @ViewBuilder private var seccionAcercaDe: some View {
        Section {
            LabeledContent("Versión", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? String(localized: "en desarrollo"))
            if let url = URL(string: Estudio.repositorio) {
                LabeledContent("Código fuente") {
                    Link(url.host().map { $0 + url.path() } ?? Estudio.repositorio, destination: url)
                }
            }
            Text("Las marcas e iconos pertenecen a sus dueños; Iconos no está afiliado a ellos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Acerca de")
        }
    }
}

// MARK: Primeros pasos

/// Como esta un paso de la guia
enum EstadoPaso {
    case hecho, falta, sinSaber, opcional

    var simbolo: String {
        switch self {
        case .hecho: "checkmark.circle.fill"
        case .falta: "exclamationmark.circle.fill"
        case .sinSaber: "questionmark.circle"
        case .opcional: "circle.dashed"
        }
    }

    var color: AnyShapeStyle {
        switch self {
        case .hecho: AnyShapeStyle(.green)
        case .falta: AnyShapeStyle(.orange)
        case .sinSaber, .opcional: AnyShapeStyle(.secondary)
        }
    }

    /// Para VoiceOver
    var palabra: String {
        switch self {
        case .hecho: String(localized: "Hecho")
        case .falta: String(localized: "Falta")
        case .sinSaber: String(localized: "Aún no se sabe")
        case .opcional: String(localized: "Opcional")
        }
    }
}

struct PasoGuia<Botones: View>: View {
    let numero: Int
    let titulo: String
    let detalle: String
    let estado: EstadoPaso
    @ViewBuilder let botones: Botones

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: estado.simbolo)
                .font(.title2)
                .foregroundStyle(estado.color)
                .frame(width: 28)
                .accessibilityLabel(estado.palabra)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(numero). \(titulo)")
                    .font(.headline)
                Text(detalle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { botones }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Guia de primeros pasos: los permisos que necesita Iconos, cada uno con su estado y el boton que lo
/// arregla. Se abre sola la primera vez y desde Ajustes o el menu Ayuda
struct VistaBienvenida: View {
    static let id = "bienvenida"
    @EnvironmentObject var e: Estudio
    @Environment(\.dismiss) private var cerrar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Primeros pasos con Iconos")
                        .font(.title2.bold())
                    Text("macOS protege las apps instaladas: para cambiar sus iconos, Iconos necesita unos permisos. Cada paso dice si ya está listo.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pasoAplicaciones
                    pasoGestionIconos
                    pasoAgente
                    pasoGestionAgente
                    pasoTerminal
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                AvisoActual(lineas: 2)
                Spacer()
                Button("Comprobar otra vez") {
                    e.comprobarAgente()
                    e.escanear()
                }
                Button("Listo") { cerrar() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding(16)
        }
        .frame(width: 580, height: 680)
        .onAppear {
            e.bienvenidaVista()
            e.revisarAgente()
        }
    }

    private var pasoAplicaciones: some View {
        let ubicacion = Estudio.ubicacion
        let estado: EstadoPaso, detalle: String
        switch ubicacion {
        case .aplicaciones:
            estado = .hecho
            detalle = String(localized: "Iconos está en Aplicaciones.")
        case .translocada:
            estado = .falta
            detalle = String(localized: "Abriste Iconos sin moverla de donde la descargaste y macOS la corre desde una copia temporal: el cambio automático dejaría de funcionar. Cierra Iconos, arrástrala a Aplicaciones en Finder y ábrela desde allí.")
        case .otra:
            estado = .falta
            let carpeta = ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            detalle = Estudio.seCopiaAAplicaciones
                ? String(localized: "Iconos está en \(carpeta), en otro disco. Cópiala a Aplicaciones para que el cambio automático la encuentre siempre: Iconos se copia, se abre desde allí y esta se cierra. La de \(carpeta) no se borra; puedes tirarla después.")
                : String(localized: "Iconos está en \(carpeta). Muévela a Aplicaciones para que el cambio automático la encuentre siempre: Iconos se mueve, se abre desde allí y esta copia se cierra.")
        case .sinPaquete:
            estado = .sinSaber
            detalle = String(localized: "Compilada sin .app (swift build): este paso no aplica.")
        }
        return PasoGuia(numero: 1, titulo: String(localized: "Iconos en Aplicaciones"), detalle: detalle, estado: estado) {
            switch ubicacion {
            case .translocada:
                Button("Abrir Aplicaciones") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
                Button("Cerrar Iconos") { NSApp.terminate(nil) }
            case .otra:
                Button(Estudio.seCopiaAAplicaciones ? "Copiar a Aplicaciones" : "Mover a Aplicaciones") { e.moverAAplicaciones() }
                    .disabled(e.trabajando)
            case .aplicaciones, .sinPaquete:
                EmptyView()
            }
        }
    }

    private var pasoGestionIconos: some View {
        let estado: EstadoPaso, detalle: String
        switch e.gestionDeApps {
        case true?:
            estado = .hecho
            detalle = String(localized: "macOS ya dejó a Iconos cambiar el icono de una app.")
        case false?:
            estado = .falta
            detalle = String(localized: "macOS frenó a Iconos al cambiar un icono. Activa Iconos en Privacidad y seguridad > Gestión de apps y vuelve a pulsar Aplicar.")
        case nil:
            estado = .sinSaber
            detalle = String(localized: "Se sabrá la primera vez que apliques un icono. Si macOS lo pide o lo frena, activa Iconos en Privacidad y seguridad > Gestión de apps.")
        }
        return PasoGuia(numero: 2, titulo: String(localized: "Gestión de apps para Iconos"), detalle: detalle, estado: estado) {
            if estado != .hecho {
                Button("Abrir Gestión de apps") { abrirGestionDeApps() }
            }
        }
    }

    private var pasoAgente: some View {
        let estado: EstadoPaso, detalle: String
        switch e.estadoAgente {
        case .activo:
            estado = .hecho
            detalle = String(localized: "Cambia los iconos con el modo claro u oscuro y los vuelve a poner cuando una app se actualiza.")
        case .arrancando:
            estado = .sinSaber
            detalle = String(localized: "Arrancando…")
        case .apagado:
            estado = .falta
            detalle = String(localized: "Un proceso pequeño que cambia los iconos con el modo claro u oscuro y los vuelve a poner cuando una app se actualiza.")
        case .sinRespuesta, .otraCopia, .otraVersion:
            estado = .falta
            detalle = e.estadoAgente.detalle
        }
        return PasoGuia(numero: 3, titulo: String(localized: "Activar el cambio automático"), detalle: detalle, estado: estado) {
            switch e.estadoAgente {
            case .apagado:
                Button("Activar el agente") { e.activarAgente() }
            case .sinRespuesta, .otraCopia, .otraVersion:
                Button("Reparar el agente") { e.activarAgente() }
            case .activo, .arrancando:
                EmptyView()
            }
        }
    }

    private var pasoGestionAgente: some View {
        let estado: EstadoPaso, detalle: String
        switch e.agenteConGestionDeApps {
        case true?:
            estado = .hecho
            detalle = String(localized: "macOS ya dejó a Iconos Agente cambiar el icono de una app.")
        case false?:
            estado = .falta
            detalle = String(localized: "macOS no deja a Iconos Agente cambiar iconos. Actívalo en Privacidad y seguridad > Gestión de apps; suele aparecer en la lista después de que macOS lo frene por primera vez.")
        case nil:
            estado = .sinSaber
            detalle = String(localized: "Se sabrá la primera vez que el agente cambie un icono (por ejemplo al pasar a modo oscuro). Es otro permiso, aparte del de Iconos, y se llama Iconos Agente.")
        }
        return PasoGuia(numero: 4, titulo: String(localized: "Gestión de apps para Iconos Agente"), detalle: detalle, estado: estado) {
            if estado != .hecho {
                Button("Abrir Gestión de apps") { abrirGestionDeApps() }
            }
        }
    }

    private var pasoTerminal: some View {
        let deRoot = e.apps.filter(\.necesitaPermiso).count
        let ahora = deRoot == 0 ? String(localized: "Ahora no hay ninguna sin permiso.")
            : deRoot == 1 ? String(localized: "Ahora hay 1 sin permiso.") : String(localized: "Ahora hay \(deRoot) sin permiso.")
        return PasoGuia(numero: 5, titulo: String(localized: "Opcional: Gestión de apps para Terminal"),
                        detalle: String(localized: "Solo para apps instaladas con un .pkg o desde App Store, que son de root. Iconos les da permiso con un comando en Terminal (pide tu contraseña) y macOS exige que Terminal tenga Gestión de apps. \(ahora)"),
                        estado: .opcional) {
            Button("Abrir Gestión de apps") { abrirGestionDeApps() }
        }
    }
}

/// Primeros pasos en el menu Ayuda
struct BotonPrimerosPasos: View {
    @Environment(\.openWindow) private var abrirVentana

    var body: some View {
        Button("Primeros pasos con Iconos") { abrirVentana(id: VistaBienvenida.id) }
    }
}

// MARK: Menu

/// Menu Icono de la barra de menus: lo mismo que la barra de acciones del editor
struct MenuIcono: View {
    @ObservedObject var e: Estudio

    var body: some View {
        if e.elegidas.count > 1 {
            Button("Aplicar a todas") { e.aplicarVarias() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(e.trabajando || e.elegidasEscribibles.isEmpty)
        } else {
            Button("Aplicar") { e.aplicar() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!e.puedeAplicar)
        }
        Button("Restaurar original") { e.restaurar() }
            .disabled(!e.puedeRestaurar)
        Button("Descartar cambios") { e.descartar() }
            .disabled(e.trabajando || !e.cambiosSinAplicar)
        Divider()
        Button("Volver a buscar apps") { e.escanear() }
            .keyboardShortcut("r", modifiers: .command)
    }
}
