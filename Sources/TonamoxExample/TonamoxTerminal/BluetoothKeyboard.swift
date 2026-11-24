import Combine
import CoreBluetooth
import Foundation
import os
import TerminalBridgeKit

/// One line of the diagnostics log. Never holds command text.
struct KeyboardLogEntry: Identifiable, Equatable {
    let id: Int
    let line: String
}

/// The diagnostics log, observed only by the keyboard screen so per-report entries do not re-render the chat.
@MainActor
final class KeyboardEventLog: ObservableObject {
    @Published private(set) var entries: [KeyboardLogEntry] = []
    private var nextID = 0

    func append(_ line: String, limit: Int) {
        entries.append(KeyboardLogEntry(id: nextID, line: line))
        nextID += 1
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    func copyableText() -> String {
        entries.map(\.line).joined(separator: "\n")
    }
}

/// How a typing job ended, as the caller sees it.
struct KeyboardJobOutcome {
    let end: KeyboardTransmissionEnd
    let sentReports: Int
    let totalReports: Int
}

/// Whether `BluetoothKeyboard.type` took the job.
enum KeyboardJobStart: Equatable {
    case started
    /// Spanish reason; nothing was sent.
    case refused(String)
}

/// Where the host OS and layout pickers are persisted.
enum KeyboardLayoutPreference {
    static let hostOSKey = "bluetoothKeyboard.hostOS"
    static let layoutKey = "bluetoothKeyboard.layout"
    static let defaultHostOS = HostOS.macOS.rawValue

    static func resolve(hostOSRaw: String, layoutRaw: String) -> HostKeyboardLayout {
        HostKeyboardLayout.resolve(rawID: layoutRaw, hostOS: HostOS(rawValue: hostOSRaw) ?? .macOS)
    }
}

/// This iPhone as a standard Bluetooth LE HID keyboard (HID over GATT). Types only `KeyboardTypingPlan`s, to
/// exactly one subscribed computer, and never sends Enter, Tab, Escape or a Ctrl/Cmd/Win chord.
@MainActor
final class BluetoothKeyboard: NSObject, ObservableObject {
    enum UUIDForm: String {
        case full
        case short

        var title: String {
            switch self {
            case .full: "UUID de 128 bits"
            case .short: "UUID de 16 bits"
            }
        }
    }

    enum ServiceKind: String, CaseIterable {
        case battery
        case deviceInformation
        case hid

        var title: String {
            switch self {
            case .battery: "Batería " + HIDGATTIdentifier.shortUUIDString(HIDGATTIdentifier.batteryService)
            case .deviceInformation:
                "Información del dispositivo "
                    + HIDGATTIdentifier.shortUUIDString(HIDGATTIdentifier.deviceInformationService)
            case .hid: "HID " + HIDGATTIdentifier.shortUUIDString(HIDGATTIdentifier.hidService)
            }
        }
    }

    /// The job being typed: one plan to one central on one characteristic.
    private struct TypingJob {
        let id: UUID
        let layoutID: HostKeyboardLayoutID
        let isProbe: Bool
        let permittedModifiers: HIDModifierSet
        let central: CBCentral
        let characteristic: CBMutableCharacteristic
        let origin: ContinuousClock.Instant
        var transmission: KeyboardTransmission
        let progress: (Int, Int) -> Void
        let completion: (KeyboardJobOutcome) -> Void
    }

    /// Started by the user in this app session; the command rows show the Bluetooth button only then.
    @Published private(set) var isActive = false
    @Published private(set) var managerState: CBManagerState = .unknown
    @Published private(set) var isAdvertising = false
    @Published private(set) var subscriberCount = 0
    /// Last LED byte the host wrote; nil until it writes one.
    @Published private(set) var hostLEDs: UInt8?
    @Published private(set) var acceptedUUIDForms: [ServiceKind: UUIDForm] = [:]
    @Published private(set) var failedServices: Set<ServiceKind> = []
    @Published private(set) var isTyping = false
    /// Bumped on every activation, so per-activation acknowledgements can be reset.
    @Published private(set) var activationCount = 0
    @Published private(set) var probeStatus: String?

    static let maxEvents = 500
    /// Row progress is published every this many reports: each publish re-renders the chat at the 12 ms pace.
    static let progressStride = 8
    static let probeAcknowledgements: [String] = []

    private static let logger = Logger(subsystem: "io.iosdevc.TonamoxTerminal", category: "BluetoothKeyboard")
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private static let advertisedServices = [CBUUID(string: HIDGATTIdentifier.shortUUIDString(HIDGATTIdentifier.hidService))]
    private static let emptyValue = Data()

    let eventLog = KeyboardEventLog()
    private let clock = ContinuousClock()
    private var manager: CBPeripheralManager?
    private var pendingServices: [ServiceKind] = []
    private var currentForm = UUIDForm.full
    private var addedServices: [ServiceKind: CBMutableService] = [:]
    private var databaseBuilt = false

    private var protocolModeValue: UInt8 = 1
    private let batteryLevelValue: UInt8 = 100
    private var lastInputReport = Data(count: HIDKeyboardDescriptor.inputReportLength)

    private var inputReport: CBMutableCharacteristic?
    private var outputReport: CBMutableCharacteristic?
    private var bootInput: CBMutableCharacteristic?
    private var bootOutput: CBMutableCharacteristic?
    private var protocolModeCharacteristic: CBMutableCharacteristic?
    private var controlPoint: CBMutableCharacteristic?
    private var batteryCharacteristic: CBMutableCharacteristic?

    private var activeJob: TypingJob?
    private var pumpTask: Task<Void, Never>?
    private var waitingForReady = false
    /// A job ended with a key possibly down and the release was not accepted: retried on the next ready.
    private var pendingRelease: (central: CBCentral, characteristic: CBMutableCharacteristic)?

    // MARK: - State for the UI

    var readiness: KeyboardReadiness {
        KeyboardReadiness.evaluate(
            isActive: isActive,
            bluetoothProblem: bluetoothProblem,
            subscriberCount: subscriberCount,
            leds: hostLEDs.map { HIDKeyboardLEDs(rawValue: $0) },
            isBusy: isTyping
        )
    }

    /// Spanish text when Bluetooth or the GATT database stops the keyboard; nil when it can work.
    var bluetoothProblem: String? {
        guard manager != nil else { return nil }
        switch managerState {
        case .poweredOn:
            return failedServices.contains(.hid) ? "iOS no aceptó el servicio de teclado (HID)." : nil
        case .poweredOff: return "Bluetooth está desactivado en el iPhone."
        case .unauthorized:
            return "Tonamox Terminal no tiene permiso para usar Bluetooth (Ajustes > Privacidad > Bluetooth)."
        case .unsupported: return "Este dispositivo no permite usar Bluetooth como teclado."
        case .resetting: return "Bluetooth se está reiniciando."
        case .unknown: return "Bluetooth aún no está listo."
        @unknown default: return "Estado de Bluetooth desconocido."
        }
    }

    var capsLockText: String {
        guard let hostLEDs else { return "desconocido (el ordenador aún no lo ha comunicado)" }
        return HIDKeyboardLEDs(rawValue: hostLEDs).contains(.capsLock) ? "activado" : "desactivado"
    }

    var connectionText: String {
        if subscriberCount == 1 { return "Ordenador conectado" }
        if subscriberCount > 1 { return "\(subscriberCount) ordenadores conectados" }
        if isAdvertising { return "Anunciando como «\(HIDKeyboardDescriptor.deviceName)». Esperando conexión" }
        return isActive ? "Esperando conexión" : "Desactivado"
    }

    var managerStateText: String {
        manager == nil ? "sin iniciar" : Self.describe(managerState)
    }

    func copyableLog() -> String {
        eventLog.copyableText()
    }

    // MARK: - Controls

    /// The CBPeripheralManager, and with it the permission prompt, is created only here.
    func start() {
        guard !isActive else { return }
        isActive = true
        activationCount += 1
        probeStatus = nil
        log("Teclado activado")
        retryPendingRelease()
        guard let manager else {
            log("Creando CBPeripheralManager en la cola principal")
            manager = CBPeripheralManager(delegate: self, queue: .main, options: nil)
            return
        }
        prepareOrAdvertise(manager)
    }

    func stop() {
        guard isActive else { return }
        cancelTyping(.cancelled)
        isActive = false
        manager?.stopAdvertising()
        isAdvertising = false
        log("Teclado detenido")
    }

    /// Called when the app becomes active again: iOS may have stopped advertising in the background.
    func resumeIfStarted() {
        // The release may have been refused just before the app left the foreground, when no ready callback follows.
        retryPendingRelease()
        guard isActive, let manager else { return }
        prepareOrAdvertise(manager)
    }

    func interruptForInactiveApp() {
        cancelTyping(.appInactive)
    }

    /// Ends the current job, if any. Never resumes it.
    func cancelTyping(_ reason: KeyboardTransmissionEnd = .cancelled) {
        guard var job = activeJob else { return }
        job.transmission.abort(reason)
        activeJob = job
        finishJob()
    }

    /// Types `plan` into the only subscribed computer. Refuses, sending nothing, unless the keyboard is ready.
    func type(
        _ plan: KeyboardTypingPlan,
        jobID: UUID,
        isProbe: Bool = false,
        progress: @escaping (Int, Int) -> Void,
        completion: @escaping (KeyboardJobOutcome) -> Void
    ) -> KeyboardJobStart {
        if let reason = readiness.message { return refuse(jobID, reason) }
        retryPendingRelease()
        guard pendingRelease == nil else {
            return refuse(jobID, "La última tecla aún no se ha liberado en el ordenador; espera un momento.")
        }
        guard manager != nil, let target = currentInputCharacteristic else {
            return refuse(jobID, "No hay informe de teclado: el servicio HID no está publicado.")
        }
        let centrals = target.subscribedCentrals ?? []
        guard centrals.count == 1, let central = centrals.first else {
            return refuse(jobID, "El ordenador no está suscrito al informe de teclado de este modo.")
        }
        activeJob = TypingJob(
            id: jobID,
            layoutID: plan.layoutID,
            isProbe: isProbe,
            permittedModifiers: plan.permittedModifiers,
            central: central,
            characteristic: target,
            origin: clock.now,
            transmission: KeyboardTransmission(plan: plan),
            progress: progress,
            completion: completion
        )
        isTyping = true
        waitingForReady = false
        log("Trabajo \(Self.shortID(jobID)) (\(plan.layoutID.rawValue)\(isProbe ? ", prueba" : "")): "
            + "\(plan.reports.count) informes por \(characteristicName(target)), mtu=\(central.maximumUpdateValueLength)")
        startPump()
        return .started
    }

    /// Types the layout's probe line; the result lands in `probeStatus`.
    func probe(_ layout: HostKeyboardLayout) {
        switch KeyboardTypingPlan.make(text: layout.probeLine, layout: layout, acknowledged: Self.probeAcknowledgements) {
        case .failure(let refusal):
            probeStatus = refusal.message
        case .success(let plan):
            probeStatus = "Tecleando la prueba…"
            let start = type(plan, jobID: UUID(), isProbe: true, progress: { [weak self] sent, total in
                self?.probeStatus = "Tecleando la prueba… \(sent)/\(total)"
            }, completion: { [weak self] outcome in
                self?.probeStatus = outcome.end == .completed
                    ? "Prueba tecleada (\(layout.title)). Compárala carácter por carácter; no pulses Enter."
                    : outcome.end.message(afterSending: outcome.sentReports)
            })
            if case .refused(let reason) = start {
                probeStatus = reason
            }
        }
    }

    // MARK: - GATT database

    private func prepareOrAdvertise(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn else {
            log("Bluetooth no está listo: \(Self.describe(manager.state))")
            return
        }
        if databaseBuilt {
            beginAdvertising()
        } else {
            buildDatabase()
        }
    }

    private func buildDatabase() {
        databaseBuilt = true
        addedServices = [:]
        acceptedUUIDForms = [:]
        failedServices = []
        pendingServices = ServiceKind.allCases
        currentForm = .full
        log("Construyendo base GATT: Batería, Información del dispositivo, HID")
        addNextService()
    }

    private func addNextService() {
        guard let manager else { return }
        guard let kind = pendingServices.first else {
            log("Base GATT terminada")
            if addedServices[.hid] == nil {
                log("El servicio HID no se pudo añadir en ninguna forma de UUID")
            }
            if isActive {
                beginAdvertising()
            }
            return
        }
        let service = makeService(kind, form: currentForm)
        log("add(\(kind.title)) con \(currentForm.title): \(service.uuid.uuidString)")
        manager.add(service)
    }

    private func makeService(_ kind: ServiceKind, form: UUIDForm) -> CBMutableService {
        switch kind {
        case .battery: makeBatteryService(form: form)
        case .deviceInformation: makeDeviceInformationService(form: form)
        case .hid: makeHIDService(form: form)
        }
    }

    private func makeBatteryService(form: UUIDForm) -> CBMutableService {
        let service = CBMutableService(type: Self.uuid(HIDGATTIdentifier.batteryService, form), primary: true)
        let level = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.batteryLevel, form),
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired]
        )
        batteryCharacteristic = level
        service.characteristics = [level]
        return service
    }

    private func makeDeviceInformationService(form: UUIDForm) -> CBMutableService {
        let service = CBMutableService(type: Self.uuid(HIDGATTIdentifier.deviceInformationService, form), primary: true)
        let manufacturer = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.manufacturerNameString, form),
            properties: [.read],
            value: Data(HIDKeyboardDescriptor.manufacturerName.utf8),
            permissions: [.readable]
        )
        let pnp = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.pnpIDCharacteristic, form),
            properties: [.read],
            value: Data(HIDKeyboardDescriptor.pnpID),
            permissions: [.readable]
        )
        service.characteristics = [manufacturer, pnp]
        return service
    }

    private func makeHIDService(form: UUIDForm) -> CBMutableService {
        let service = CBMutableService(type: Self.uuid(HIDGATTIdentifier.hidService, form), primary: true)
        if let battery = addedServices[.battery] {
            service.includedServices = [battery]
        }
        let information = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.hidInformationCharacteristic, form),
            properties: [.read],
            value: Data(HIDKeyboardDescriptor.hidInformation),
            permissions: [.readEncryptionRequired]
        )
        let reportMap = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.reportMapCharacteristic, form),
            properties: [.read],
            value: Data(HIDKeyboardDescriptor.reportMap),
            permissions: [.readEncryptionRequired]
        )
        let control = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.hidControlPoint, form),
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeEncryptionRequired]
        )
        let mode = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.protocolMode, form),
            properties: [.read, .writeWithoutResponse],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        let input = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.report, form),
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired]
        )
        let output = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.report, form),
            properties: [.read, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        input.descriptors = [makeReportReference(type: HIDKeyboardDescriptor.reportTypeInput, form: form)]
        output.descriptors = [makeReportReference(type: HIDKeyboardDescriptor.reportTypeOutput, form: form)]
        let bootIn = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.bootKeyboardInput, form),
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired]
        )
        let bootOut = CBMutableCharacteristic(
            type: Self.uuid(HIDGATTIdentifier.bootKeyboardOutput, form),
            properties: [.read, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readEncryptionRequired, .writeEncryptionRequired]
        )
        inputReport = input
        outputReport = output
        bootInput = bootIn
        bootOutput = bootOut
        protocolModeCharacteristic = mode
        controlPoint = control
        service.characteristics = [information, reportMap, control, mode, input, output, bootIn, bootOut]
        return service
    }

    private func makeReportReference(type reportType: UInt8, form: UUIDForm) -> CBMutableDescriptor {
        // CoreBluetooth documents only 0x2901/0x2904; the value goes in as raw bytes (report ID, report type).
        CBMutableDescriptor(
            type: Self.uuid(HIDGATTIdentifier.reportReference, form),
            value: Data([HIDKeyboardDescriptor.reportID, reportType])
        )
    }

    private static func uuid(_ short: UInt16, _ form: UUIDForm) -> CBUUID {
        switch form {
        case .full: CBUUID(string: HIDGATTIdentifier.fullUUIDString(short))
        case .short: CBUUID(string: HIDGATTIdentifier.shortUUIDString(short))
        }
    }

    private func beginAdvertising() {
        guard let manager else { return }
        guard addedServices[.hid] != nil else {
            log("No se anuncia: falta el servicio HID")
            return
        }
        if manager.isAdvertising {
            manager.stopAdvertising()
        }
        // The 16-bit HID UUID in the advertisement is what hosts filter on, whatever form the database used.
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: HIDKeyboardDescriptor.deviceName,
            CBAdvertisementDataServiceUUIDsKey: Self.advertisedServices,
        ])
        log("startAdvertising pedido (\(HIDKeyboardDescriptor.deviceName), servicio 1812)")
    }

    private func resetDatabase() {
        isAdvertising = false
        databaseBuilt = false
        addedServices = [:]
        pendingServices = []
        inputReport = nil
        outputReport = nil
        bootInput = nil
        bootOutput = nil
        protocolModeCharacteristic = nil
        controlPoint = nil
        batteryCharacteristic = nil
        refreshSubscribers()
    }

    // MARK: - Typing

    private var currentInputCharacteristic: CBMutableCharacteristic? {
        protocolModeValue == 0 ? bootInput : inputReport
    }

    private func refuse(_ jobID: UUID, _ reason: String) -> KeyboardJobStart {
        log("Trabajo \(Self.shortID(jobID)) rechazado: \(reason)")
        return .refused(reason + " No se ha enviado nada.")
    }

    private func elapsed(since origin: ContinuousClock.Instant) -> Duration {
        clock.now - origin
    }

    private func startPump() {
        guard pumpTask == nil, activeJob != nil else { return }
        pumpTask = Task { [weak self] in
            await self?.pump()
        }
    }

    private func pump() async {
        defer { pumpTask = nil }
        while activeJob != nil {
            sendNextReport()
            try? await Task.sleep(for: HIDKeyboardDescriptor.reportInterval)
        }
    }

    /// One tick: the key-hold watchdog, then at most one report.
    private func sendNextReport() {
        guard var job = activeJob, let manager else { return }
        job.transmission.check(at: elapsed(since: job.origin))
        guard job.transmission.end == nil, !waitingForReady else {
            activeJob = job
            if job.transmission.end != nil { finishJob() }
            return
        }
        guard let report = job.transmission.next() else {
            activeJob = job
            finishJob()
            return
        }
        // Last line of defence: the plan and the transmission already checked this report.
        guard report.isPermitted(within: job.permittedModifiers) else {
            job.transmission.abort(.unsafeReport)
            activeJob = job
            finishJob()
            return
        }
        let payload = Data(report.bytes)
        guard manager.updateValue(payload, for: job.characteristic, onSubscribedCentrals: [job.central]) else {
            waitingForReady = true
            activeJob = job
            return
        }
        lastInputReport = payload
        job.transmission.didSend(at: elapsed(since: job.origin))
        if job.isProbe {
            log("Prueba: enviado \(Self.hex(payload))")
        }
        if job.transmission.sentReports % Self.progressStride == 0 {
            job.progress(job.transmission.sentReports, job.transmission.totalReports)
        }
        activeJob = job
        if job.transmission.end != nil { finishJob() }
    }

    private func finishJob() {
        guard let job = activeJob, let end = job.transmission.end else { return }
        activeJob = nil
        isTyping = false
        waitingForReady = false
        if let cleanup = job.transmission.cleanupReport, let manager, manager.state == .poweredOn,
           job.characteristic.subscribedCentrals?.contains(where: { $0.identifier == job.central.identifier }) == true {
            let payload = Data(cleanup.bytes)
            let released = manager.updateValue(payload, for: job.characteristic, onSubscribedCentrals: [job.central])
            if released {
                lastInputReport = payload
            } else {
                pendingRelease = (job.central, job.characteristic)
            }
            log("Trabajo \(Self.shortID(job.id)): liberación final \(released ? "enviada" : "en espera")")
        }
        let outcome = KeyboardJobOutcome(
            end: end,
            sentReports: job.transmission.sentReports,
            totalReports: job.transmission.totalReports
        )
        log("Trabajo \(Self.shortID(job.id)) (\(job.layoutID.rawValue)) terminó: \(Self.describe(end)), "
            + "\(outcome.sentReports)/\(outcome.totalReports) informes")
        job.completion(outcome)
    }

    private func retryPendingRelease() {
        guard let pendingRelease, let manager, manager.state == .poweredOn else { return }
        sendPendingRelease(pendingRelease, manager)
    }

    private func sendPendingRelease(
        _ target: (central: CBCentral, characteristic: CBMutableCharacteristic),
        _ peripheral: CBPeripheralManager
    ) {
        let payload = Data(HIDKeyboardReport.released.bytes)
        guard peripheral.updateValue(payload, for: target.characteristic, onSubscribedCentrals: [target.central]) else {
            return
        }
        lastInputReport = payload
        pendingRelease = nil
        log("Liberación pendiente enviada")
    }

    private func abortJob(_ reason: KeyboardTransmissionEnd) {
        guard activeJob != nil else { return }
        cancelTyping(reason)
    }

    // MARK: - Subscriptions and writes

    private func refreshSubscribers() {
        let reportCentrals = inputReport?.subscribedCentrals ?? []
        let bootCentrals = bootInput?.subscribedCentrals ?? []
        subscriberCount = Set((reportCentrals + bootCentrals).map(\.identifier)).count
    }

    private func characteristicName(_ characteristic: CBCharacteristic) -> String {
        switch characteristic {
        case let item where item === inputReport: "Input Report 2A4D"
        case let item where item === outputReport: "Output Report 2A4D"
        case let item where item === bootInput: "Boot Input 2A22"
        case let item where item === bootOutput: "Boot Output 2A32"
        case let item where item === protocolModeCharacteristic: "Protocol Mode 2A4E"
        case let item where item === controlPoint: "Control Point 2A4C"
        case let item where item === batteryCharacteristic: "Battery Level 2A19"
        default: characteristic.uuid.uuidString
        }
    }

    private func dynamicValue(for characteristic: CBCharacteristic) -> Data? {
        switch characteristic {
        case let item where item === inputReport, let item where item === bootInput:
            lastInputReport
        case let item where item === outputReport, let item where item === bootOutput:
            Data([hostLEDs ?? 0])
        case let item where item === protocolModeCharacteristic:
            Data([protocolModeValue])
        case let item where item === batteryCharacteristic:
            Data([batteryLevelValue])
        default:
            characteristic.value
        }
    }

    private func applyWrite(_ value: Data, to characteristic: CBCharacteristic) {
        switch characteristic {
        case let item where item === outputReport, let item where item === bootOutput:
            applyLEDs(value)
        case let item where item === protocolModeCharacteristic:
            let previous = protocolModeValue
            protocolModeValue = value.first ?? 1
            log("Protocol Mode = \(protocolModeValue == 0 ? "boot" : "report")")
            if protocolModeValue != previous, activeJob != nil {
                // The job notifies the characteristic it started on; the host may now listen only to the other.
                log("Protocol Mode cambió durante el tecleo")
                abortJob(.cancelled)
            }
        case let item where item === controlPoint:
            log("Control Point = \(value.first.map { $0 == 0 ? "suspend" : "exit suspend" } ?? "vacío")")
        default:
            log("Escritura en \(characteristicName(characteristic)) ignorada")
        }
    }

    private func applyLEDs(_ value: Data) {
        guard let leds = HIDKeyboardLEDs.parse([UInt8](value)) else {
            log("LEDs del host: escritura vacía, estado sin cambios")
            return
        }
        hostLEDs = leds.rawValue
        log("LEDs del host: 0x\(Self.hex(Data([leds.rawValue]))) (Bloq Mayús \(capsLockText))")
        guard var job = activeJob else { return }
        job.transmission.hostLEDsChanged(leds)
        activeJob = job
        finishJob()
    }

    // MARK: - Log

    private func log(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        eventLog.append("\(stamp) \(message)", limit: Self.maxEvents)
        Self.logger.notice("\(message, privacy: .public)")
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "desconocido"
        case .resetting: "reiniciando"
        case .unsupported: "no compatible"
        case .unauthorized: "sin permiso"
        case .poweredOff: "apagado"
        case .poweredOn: "encendido"
        @unknown default: "valor \(state.rawValue)"
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
    }

    private static func describe(_ end: KeyboardTransmissionEnd) -> String {
        switch end {
        case .completed: "completado"
        case .cancelled: "cancelado"
        case .hostDisconnected: "ordenador desconectado"
        case .bluetoothOff: "Bluetooth no disponible"
        case .appInactive: "app inactiva"
        case .keyHeldTooLong: "tecla pulsada demasiado tiempo"
        case .capsLockTurnedOn: "Bloq Mayús activado"
        case .unsafeReport: "informe no permitido"
        }
    }
}

extension BluetoothKeyboard: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        managerState = peripheral.state
        log("Estado de Bluetooth: \(Self.describe(peripheral.state))")
        if peripheral.state == .poweredOn {
            if isActive { prepareOrAdvertise(peripheral) }
        } else {
            // Below poweredOn the system drops every published service; rebuild on the next poweredOn.
            abortJob(.bluetoothOff)
            pendingRelease = nil
            resetDatabase()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard let kind = pendingServices.first else { return }
        if let error {
            log("add(\(kind.title)) con \(currentForm.title) falló: \(Self.describe(error))")
            if currentForm == .full {
                currentForm = .short
                log("Reintentando \(kind.title) con UUID de 16 bits")
                addNextService()
                return
            }
            failedServices.insert(kind)
            log("\(kind.title) rechazado en las dos formas de UUID")
        } else if let mutable = service as? CBMutableService {
            addedServices[kind] = mutable
            acceptedUUIDForms[kind] = currentForm
            log("\(kind.title) aceptado con \(currentForm.title)")
        }
        pendingServices.removeFirst()
        currentForm = .full
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            isAdvertising = false
            log("startAdvertising falló: \(Self.describe(error))")
        } else {
            isAdvertising = true
            log("Anunciando como «\(HIDKeyboardDescriptor.deviceName)»")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        refreshSubscribers()
        log("Suscrito \(Self.shortID(central.identifier)) a \(characteristicName(characteristic)), "
            + "mtu=\(central.maximumUpdateValueLength)")
        if subscriberCount > 1, activeJob != nil {
            // Typing targets one central only, but a second host means the user may be looking at the wrong one.
            log("Otro ordenador se suscribió durante el tecleo")
            abortJob(.cancelled)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        log("Desuscrito \(Self.shortID(central.identifier)) de \(characteristicName(characteristic))")
        refreshSubscribers()
        if pendingRelease?.central.identifier == central.identifier {
            // Nothing more can reach it; hosts are expected to release keys on disconnect (unverified).
            pendingRelease = nil
        }
        if let job = activeJob, job.central.identifier == central.identifier, job.characteristic === characteristic {
            // isReadyToUpdateSubscribers may never come after a disconnect; never replay keys to a later host.
            abortJob(.hostDisconnected)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let name = characteristicName(request.characteristic)
        log("Lectura \(name) offset=\(request.offset) de \(Self.shortID(request.central.identifier))")
        guard let value = dynamicValue(for: request.characteristic) else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let value = request.value ?? Self.emptyValue
            log("Escritura \(characteristicName(request.characteristic)): [\(Self.hex(value))]")
            applyWrite(value, to: request.characteristic)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if let pendingRelease {
            sendPendingRelease(pendingRelease, peripheral)
        }
        // The next tick sends, so the verified pace holds after a full queue too.
        waitingForReady = false
    }
}
