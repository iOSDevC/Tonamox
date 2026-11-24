import SwiftUI
import TerminalBridgeKit
import TonamoxCore

/// Terminal's consent sheet for a remote turn: destination, cost, what the turn contains, and the exact payload.
/// It renders the shared `UIConsentGate.Request`; the English `ConsentSheet` is not used in this app.
struct RemoteConsentSheet: View {
    let request: UIConsentGate.Request
    let gate: UIConsentGate

    var body: some View {
        NavigationStack {
            Form {
                Section("Destino") {
                    LabeledContent("Proveedor", value: request.target.provider.displayName)
                    LabeledContent("Modelo", value: request.target.modelID)
                    LabeledContent(
                        "Dónde",
                        value: request.target.isLocalNetwork ? "Tu red local (no comprobado que sea tuyo)" : "Nube"
                    )
                    Text(verbatim: Self.retentionText(request.target.provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Coste") {
                    LabeledContent("Previsto", value: projectedCostText)
                    if let offer = request.offer {
                        LabeledContent("Gastado en la sesión", value: Self.sessionSpendText(offer))
                        LabeledContent("Motivo", value: Self.reasonText(offer.reason))
                    }
                }
                if !request.disclosures.isEmpty {
                    Section("Qué se envía") {
                        ForEach(request.disclosures, id: \.self) { line in
                            Text(verbatim: line)
                                .font(.callout)
                        }
                    }
                    .accessibilityIdentifier("consent.disclosures")
                }
                if let payload = request.payload {
                    payloadSection(payload)
                }
            }
            .navigationTitle("¿Enviar fuera del iPhone?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("No enviar") { gate.resolve(false, requestID: request.id) }
                        .accessibilityIdentifier("consent.decline")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enviar") { gate.resolve(true, requestID: request.id) }
                        .accessibilityIdentifier("consent.send")
                }
            }
            .interactiveDismissDisabled()
            // Fail closed: a sheet that goes away without an answer declines.
            .onDisappear { gate.resolve(false, requestID: request.id) }
        }
    }

    private func payloadSection(_ payload: EscalationPayload) -> some View {
        Section {
            LabeledContent("Redacción", value: Self.redactionText(payload))
            LabeledContent("Salida máxima", value: "\(payload.maxTokens) tokens")
            if let system = payload.systemPrompt {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instrucciones del sistema").font(.caption.bold())
                    Text(verbatim: system)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Tu mensaje").font(.caption.bold())
                Text(verbatim: payload.userMessage)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("consent.userMessage")
        } header: {
            Text("Texto exacto")
        } footer: {
            Text(verbatim: "Se envía tal cual: \(Self.byteCount(payload)) bytes de texto. Si esta misma petición ya "
                + "se respondió en esta sesión, se reutiliza esa respuesta y no se envía nada.")
        }
    }

    /// The SDK's cloud notes are English, so a preset's Spanish note wins; the «Otro» server's is already Spanish.
    private static func retentionText(_ provider: any RemoteLLMProvider) -> String {
        ProviderPreset.preset(providerID: provider.id)?.retentionNote ?? provider.retentionNote
    }

    private static func redactionText(_ payload: EscalationPayload) -> String {
        guard payload.redactionEnabled else { return "Desactivada" }
        switch payload.redactedPIICount {
        case 0: return "Activada · nada encontrado"
        case 1: return "Activada · 1 elemento sustituido"
        default: return "Activada · \(payload.redactedPIICount) elementos sustituidos"
        }
    }

    private static func byteCount(_ payload: EscalationPayload) -> Int {
        (payload.systemPrompt?.utf8.count ?? 0) + payload.userMessage.utf8.count
    }

    private static func usd(_ value: Decimal, digits: Int) -> String {
        let amount = NSDecimalNumber(decimal: value).doubleValue
        return digits == 2 ? String(format: "$%.2f", amount) : String(format: "$%.4f", amount)
    }

    private static func sessionSpendText(_ offer: EscalationOffer) -> String {
        let unpriced = offer.unpricedRecordCount == 0 ? "" : " + \(offer.unpricedRecordCount) sin precio"
        return "\(usd(offer.sessionSpentUSD, digits: 4))\(unpriced) de \(usd(offer.costCapUSD, digits: 2))"
    }

    private static func reasonText(_ reason: EscalationReason) -> String {
        switch reason {
        case .costUnknown: "Coste desconocido: el límite no puede comprobarlo"
        default: "Lo pediste tú"
        }
    }

    private var projectedCostText: String {
        guard let cost = request.cost else { return "Coste desconocido" }
        if cost == 0 { return request.target.isLocalNetwork ? "Gratis (red local)" : "$0" }
        return Self.usd(cost, digits: 4)
    }
}
