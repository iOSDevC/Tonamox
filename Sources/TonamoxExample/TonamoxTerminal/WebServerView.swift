import SwiftUI
import TerminalBridgeKit
import TonamoxServer

/// "Servidor web": start and stop, where it listens, port, features, browser pairing, API keys, received outputs
/// and recent activity.
struct WebServerView: View {
    @Bindable var controller: WebServerController
    @ObservedObject var chat: TerminalChatViewModel
    @State private var interfaces: [ServerInterface] = []
    @State private var keyLabel = ""
    @State private var keyMessage: String?
    @State private var ticketLabel = ""
    @State private var ticketMessage: String?
    @State private var confirmsNetworkStart = false
    @State private var confirmsRevokeAll = false
    @Environment(\.scenePhase) private var scenePhase

    static let loopbackTitle = "Solo este iPhone y cable USB (127.0.0.1)"
    static let loopbackDetail = "Nada de la red puede conectarse. Desde un ordenador por cable hace falta un reenvío "
        + "a 127.0.0.1 (por ejemplo iproxy)."
    static let apiFootnote = "La API compatible con OpenAI siempre está activa y pide una clave. El servidor solo "
        + "funciona con la app abierta: en segundo plano cierra el puerto."

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            statusSection
            if controller.canStart {
                listenSection
                portSection
                featureSection
            }
            // Outside the options: turning it off while serving lets the screen lock again.
            screenSection
            if let endpoint = controller.endpoint, let server = controller.server {
                if server.configuration.features.contains(.browserPage) {
                    browserSection(server)
                }
                if server.configuration.features.contains(.ingest) {
                    ingestSection(endpoint: endpoint)
                }
            }
            keySection
            if !controller.arrivals.waiting.isEmpty {
                receivedSection
            }
            if let server = controller.server {
                activitySection(server)
            }
        }
        .navigationTitle("Servidor web")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshInterfaces()
            controller.reloadStoredKeys()
        }
        // Shown once means once: leaving the screen drops the key, so it is not on screen on the next visit.
        .onDisappear(perform: controller.forgetIssuedKey)
        .confirmationDialog("¿Iniciar sin cifrado en esta red?", isPresented: $confirmsNetworkStart,
                            titleVisibility: .visible) {
            Button("Iniciar sin cifrado", role: .destructive) {
                Task { await controller.start() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            if case .network(let interface) = controller.listenChoice {
                Text(verbatim: WebServerInterfaceKind(interface.kind).networkWarning)
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        let status = controller.status
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(verbatim: status.title).font(.headline)
                } icon: {
                    Circle().fill(Self.tint(for: status)).frame(width: 10, height: 10)
                }
                if case .listening(let url, _) = status {
                    Text(verbatim: url)
                        .font(.title2.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                        .accessibilityIdentifier("webServer.url")
                }
                Text(verbatim: controller.isPreparing ? controller.preparingText : status.detail)
                    .font(.callout)
                    .foregroundStyle(status.isProblem ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .listening(_, true) = status, case .interface(let interface)? = controller.endpoint?.exposure {
                    Text(verbatim: "Conexión sin cifrar en " + WebServerInterfaceKind(interface.kind).title + ". "
                        + WebServerInterfaceKind(interface.kind).networkWarning)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("webServer.unencryptedBanner")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("webServer.status")
            modelRow
            if let error = controller.startError {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            startStopButton
        } footer: {
            Text(verbatim: Self.apiFootnote)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if let title = controller.servedTitle, !controller.canStart {
            LabeledContent("Modelo servido", value: title)
        } else if let problem = controller.modelProblem {
            Text(verbatim: problem)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("webServer.modelProblem")
        } else if let choice = chat.selectedChoice {
            LabeledContent("Modelo que se servirá", value: choice.title)
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if controller.canStart {
            Button {
                if case .network = controller.listenChoice {
                    confirmsNetworkStart = true
                } else {
                    Task { await controller.start() }
                }
            } label: {
                Label("Iniciar", systemImage: "play.fill")
            }
            .disabled(controller.modelProblem != nil || (try? controller.portValidation.get()) == nil)
            .accessibilityIdentifier("webServer.start")
        } else {
            Button(role: .destructive) {
                Task { await controller.stop() }
            } label: {
                Label("Detener", systemImage: "stop.fill")
            }
            .disabled(controller.isPreparing)
            .accessibilityIdentifier("webServer.stop")
        }
    }

    private static func tint(for status: WebServerStatus) -> Color {
        switch status {
        case .listening: .green
        case .starting: .yellow
        case .suspended, .failed: .orange
        case .stopped: .gray
        }
    }

    // MARK: Options (only while stopped)

    private var listenSection: some View {
        Section {
            Picker("Dónde escucha", selection: $controller.listenChoice) {
                Text(verbatim: Self.loopbackTitle).tag(ListenChoice.loopback)
                ForEach(interfaces) { interface in
                    Text(verbatim: WebServerInterfaceKind(interface.kind)
                        .rowTitle(address: interface.ipv4, interfaceName: interface.name))
                        .tag(ListenChoice.network(interface))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("webServer.listenPicker")
            Button("Buscar redes otra vez", action: refreshInterfaces)
        } header: {
            Text("Dónde escucha")
        } footer: {
            switch controller.listenChoice {
            case .loopback:
                Text(verbatim: Self.loopbackDetail)
            case .network(let interface):
                Text(verbatim: WebServerInterfaceKind(interface.kind).networkWarning + " "
                    + WebServerInterfaceKind.peerLockExplanation + " Esta elección no se guarda.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var portSection: some View {
        Section {
            TextField("Puerto", text: $controller.portText)
                .keyboardType(.numberPad)
                .font(.body.monospaced())
                .accessibilityIdentifier("webServer.port")
        } header: {
            Text("Puerto")
        } footer: {
            if case .failure(let refusal) = controller.portValidation {
                Text(verbatim: refusal.message).foregroundStyle(.red)
            } else {
                Text(verbatim: "Por defecto \(WebServerPort.defaultPort).")
            }
        }
    }

    private var featureSection: some View {
        Section("Funciones") {
            Toggle(isOn: $controller.servesBrowserPage) {
                featureLabel("Página web con chat y guía",
                             "Un navegador puede chatear con el modelo tras escribir un código que ves aquí.")
            }
            Toggle(isOn: $controller.acceptsIngest) {
                featureLabel("Recepción de salida",
                             "Un ordenador te envía la salida de una orden con un enlace de un solo uso. Solo llega "
                                + "al modelo si tú la revisas y la envías.")
            }
            Toggle(isOn: $controller.servesScripts) {
                featureLabel("Scripts",
                             "Sirve tnx-run.sh, un script público que se comprueba con su huella SHA-256 y envía "
                                + "la salida de una orden.")
            }
        }
    }

    private var screenSection: some View {
        Section {
            Toggle(WebServerScreenAwake.toggleTitle, isOn: $controller.keepsScreenAwake)
                .accessibilityIdentifier("webServer.keepsScreenAwake")
        } footer: {
            Text(verbatim: WebServerScreenAwake.footer)
        }
    }

    private func featureLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshInterfaces() {
        interfaces = ServerInterface.available()
        if case .network(let chosen) = controller.listenChoice, !interfaces.contains(chosen) {
            controller.listenChoice = .loopback
        }
    }

    // MARK: Browsers

    private func browserSection(_ server: TonamoxServer) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                pairingRow(server, now: context.date)
            }
            ForEach(server.pairedBrowsers) { browser in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: browser.label)
                        Text(verbatim: "\(browser.peer) · emparejado a las "
                            + Self.timeFormatter.string(from: browser.pairedAt) + " · caduca "
                            + Self.dateTimeFormatter.string(from: browser.expiresAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revocar", role: .destructive) { server.revoke(browser.id) }
                        .buttonStyle(.borderless)
                }
            }
            if !server.lockedPeers.isEmpty {
                LabeledContent("Equipo permitido", value: server.lockedPeers.joined(separator: ", "))
                Button("Permitir otro equipo", action: server.allowAnotherComputer)
                    .accessibilityIdentifier("webServer.allowAnother")
            }
        } header: {
            Text("Navegadores")
        } footer: {
            Text("El código solo aparece en este iPhone; el navegador nunca lo recibe. Lo escribes tú en la página.")
        }
    }

    @ViewBuilder
    private func pairingRow(_ server: TonamoxServer, now: Date) -> some View {
        if let until = controller.pairingWindowUntil, server.isPairingWindowOpen, until > now {
            let left = WebServerCountdown.secondsLeft(until: until, now: now)
            Text(verbatim: "Esperando a un navegador: abre la dirección y toca «Emparejar» en la página. Quedan "
                + WebServerCountdown.format(secondsLeft: left) + ".")
                .font(.callout)
                .accessibilityIdentifier("webServer.pairingCountdown")
        } else {
            Button("Emparejar un navegador", action: controller.openPairingWindow)
                .accessibilityIdentifier("webServer.pair")
        }
    }

    // MARK: Keys

    private var keySection: some View {
        let rows = controller.keyRows
        return Section {
            if let warning = controller.keyStorage.warning {
                Text(verbatim: warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("webServer.keyStorageWarning")
            }
            if let endpoint = controller.endpoint {
                keyIssueRows(endpoint: endpoint)
            } else {
                Text(verbatim: APIKeyStorageText.issueNeedsServer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = controller.keyProblem {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("webServer.keyProblem")
            }
            if rows.isEmpty {
                Text(verbatim: APIKeyStorageText.noKeys).foregroundStyle(.secondary)
            }
            ForEach(rows) { client in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: client.label)
                        Text(verbatim: Self.keyDetail(client))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revocar", role: .destructive) { controller.revokeKey(client.id) }
                        .buttonStyle(.borderless)
                }
            }
            if !rows.isEmpty || controller.keyProblem != nil {
                Button("Revocar todas", role: .destructive) { confirmsRevokeAll = true }
                    .accessibilityIdentifier("webServer.revokeAllKeys")
            }
        } header: {
            Text("Claves API")
        } footer: {
            Text(verbatim: controller.keyStorage.footer)
        }
        .confirmationDialog(APIKeyStorageText.revokeAllTitle(count: max(rows.count, 1)),
                            isPresented: $confirmsRevokeAll, titleVisibility: .visible) {
            Button("Revocar todas", role: .destructive, action: controller.revokeAllKeys)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(verbatim: APIKeyStorageText.revokeAllMessage)
        }
    }

    @ViewBuilder
    private func keyIssueRows(endpoint: ServerEndpoint) -> some View {
        if let issued = controller.issuedKey {
            issuedKeyPanel(issued, endpoint: endpoint)
        } else {
            HStack {
                TextField("Nombre (por ejemplo editor)", text: $keyLabel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Crear") {
                    keyMessage = controller.issueKey(label: keyLabel)
                    if keyMessage == nil { keyLabel = "" }
                }
                .accessibilityIdentifier("webServer.createKey")
            }
            if let keyMessage {
                Text(verbatim: keyMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func issuedKeyPanel(_ issued: IssuedAPIKey, endpoint: ServerEndpoint) -> some View {
        let lines = APIKeyInstructions(baseURL: endpoint.baseURL.absoluteString)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Clave «\(issued.client.label)»: se muestra solo esta vez.")
                .font(.callout.weight(.semibold))
            // No text selection: a selected copy would skip the pasteboard expiry. Hidden while the app is not
            // active, so the app switcher's snapshot does not keep it.
            Text(verbatim: scenePhase == .active ? issued.secret : "••••••••")
                .font(.caption.monospaced())
                .accessibilityIdentifier("webServer.issuedSecret")
            Button("Copiar la línea de cabecera", action: controller.copyIssuedKeyHeader)
            Text(verbatim: "1. Copia la línea (dura 2 minutos en el portapapeles). En la Mac, guárdala en un archivo "
                + "que solo tú puedes leer:")
                .font(.caption)
            commandText(lines.saveLine)
            Text(verbatim: "2. Pruébala sin escribir la clave en la orden (así no aparece en «ps» ni en el historial):")
                .font(.caption)
            commandText(lines.testLine)
            Text(verbatim: "3. En un cliente compatible con OpenAI: URL base")
                .font(.caption)
            commandText(lines.openAIBaseURL)
            Button("Ya la guardé", action: controller.forgetIssuedKey)
        }
    }

    private func commandText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func keyDetail(_ client: ClientInfo) -> String {
        let formatted = client.expiresAt.map(dateTimeFormatter.string(from:)) ?? ""
        let expiry = APIKeyStorageText.expiry(expiresAt: client.expiresAt, now: Date(), formatted: formatted)
        let use = client.lastUsed.map { "último uso " + dateTimeFormatter.string(from: $0) } ?? "sin usar"
        return expiry + " · " + use
    }

    // MARK: Ingest

    private func ingestSection(endpoint: ServerEndpoint) -> some View {
        Section {
            HStack {
                TextField("Nombre (por ejemplo build)", text: $ticketLabel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Crear enlace") {
                    Task {
                        ticketMessage = await controller.makeTicket(label: ticketLabel)
                        if ticketMessage == nil { ticketLabel = "" }
                    }
                }
            }
            if let ticketMessage {
                Text(verbatim: ticketMessage).font(.caption).foregroundStyle(.red)
            }
            if let port = controller.loopbackIngestPort {
                let hint = NetworkOutputLine.loopbackForwardHint(port: port)
                Text(verbatim: hint.explanation)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                commandText(hint.command)
            }
            ForEach(controller.tickets) { ticket in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "«\(ticket.label)» · caduca " + Self.timeFormatter.string(from: ticket.expiresAt))
                        .font(.callout)
                    commandText("<tu orden>" + ticket.curlSuffix(on: endpoint))
                    Button("Cancelar enlace", role: .destructive) {
                        Task { await controller.cancel(ticket) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Recibir una salida")
        } footer: {
            Text("Escribe tú en la Mac la orden seguida de este final, o usa «Enviar salida al iPhone por red» en el "
                + "menú «Más» de una orden del chat. Cada enlace sirve una sola vez. Lo que llegue abre la revisión "
                + "de «Pegar salida» y no va al modelo hasta que lo envíes.")
        }
    }

    private var receivedSection: some View {
        Section {
            ForEach(controller.arrivals.waiting.reversed()) { output in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "«\(output.label)» · \(output.byteCount) bytes · \(output.peer) · "
                        + Self.timeFormatter.string(from: output.receivedAt)
                        + (output.exitStatus.map { " · salida \($0)" } ?? ""))
                        .font(.callout)
                    if !output.peerMatchesLock {
                        Text("Llegó de un equipo que no es el emparejado: puede no ser lo que esperas.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Revisar") {
                            let presenting = chat.isPresentingPasteOrDialog || controller.livePairingRequest != nil
                            if let taken = controller.takeArrival(output.id, isPresenting: presenting) {
                                chat.prepareNetworkPaste(taken)
                            }
                        }
                        .disabled(chat.isPresentingPasteOrDialog)
                        Spacer()
                        Button("Descartar", role: .destructive) { controller.discard(output) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text(verbatim: controller.arrivals.badgeText ?? "Salidas recibidas")
        } footer: {
            Text("Es texto del ordenador: cualquier programa pudo escribirlo. Se revisa igual que «Pegar salida»; la "
                + "respuesta aparece en el chat.")
        }
    }

    // MARK: Activity

    private func activitySection(_ server: TonamoxServer) -> some View {
        Section {
            LabeledContent("Navegadores emparejados", value: "\(server.pairedBrowsers.count)")
            LabeledContent("Claves", value: "\(server.clients.count)")
            if server.activity.isEmpty {
                Text("Todavía no hay peticiones.").foregroundStyle(.secondary)
            }
            ForEach(server.activity.suffix(20).reversed()) { entry in
                Text(verbatim: Self.timeFormatter.string(from: entry.answeredAt) + " · \(entry.route) · \(entry.status)"
                    + (entry.clientLabel.map { " · " + $0 } ?? ""))
                    .font(.caption.monospaced())
            }
        } header: {
            Text("Actividad reciente")
        } footer: {
            Text("Solo la ruta, el código y quién: nunca el contenido de las peticiones.")
        }
    }
}

/// A browser asks to pair: the code it must type, who asks, and a way to refuse.
struct BrowserPairingSheet: View {
    let request: PairingRequest
    let onDeny: () -> Void
    let onExpire: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Escribe este código en la página del navegador:")
                Text(verbatim: request.displayCode)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityValue(Text(verbatim: request.displayCode).speechSpellsOutCharacters())
                    .accessibilityIdentifier("webServer.pairingCode")
                LabeledContent("Pide desde", value: request.peer)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nombre que envió la página (no verificado)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: request.untrustedLabel.isEmpty ? "(sin nombre)" : request.untrustedLabel)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = WebServerCountdown.secondsLeft(until: request.expiresAt, now: context.date)
                    Text(verbatim: "Caduca en " + WebServerCountdown.format(secondsLeft: left) + ".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Si no esperabas esta petición, recházala.")
                    .font(.callout)
                Button("Rechazar", role: .destructive, action: onDeny)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("webServer.denyPairing")
                Spacer()
            }
            .padding()
            .navigationTitle("Emparejar navegador")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: request.id) {
            let left = max(0, request.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(left))
            if !Task.isCancelled { onExpire() }
        }
    }
}
