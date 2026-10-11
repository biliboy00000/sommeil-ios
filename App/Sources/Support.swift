import Foundation
import UIKit
import CoreMotion
import SleepCore

/// Réglages de l'app, gardés dans UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Adresse du récepteur sur le PC, par exemple « 192.168.1.23:8010 ».
    @Published var pcAddress: String { didSet { defaults.set(pcAddress, forKey: "pcAddress") } }
    /// Enregistrer aussi l'accéléromètre et le gyroscope bruts.
    @Published var rawSensors: Bool { didSet { defaults.set(rawSensors, forKey: "rawSensors") } }
    /// Consignes dites à voix haute.
    @Published var voicePrompts: Bool { didSet { defaults.set(voicePrompts, forKey: "voicePrompts") } }
    /// Envoyer au PC dès l'arrêt de l'enregistrement.
    @Published var autoUpload: Bool { didSet { defaults.set(autoUpload, forKey: "autoUpload") } }
    /// Heure du réveil, en minutes depuis minuit.
    @Published var wakeMinutes: Int { didSet { defaults.set(wakeMinutes, forKey: "wakeMinutes") } }
    /// Code affiché par le récepteur du PC (protège la commande du micro).
    @Published var pcCode: String { didSet { defaults.set(pcCode, forKey: "pcCode") } }
    /// Démarrer et arrêter le Blue Yeti du PC avec chaque enregistrement.
    @Published var controlYeti: Bool { didSet { defaults.set(controlYeti, forKey: "controlYeti") } }

    init() {
        defaults.register(defaults: ["pcAddress": "", "rawSensors": true, "voicePrompts": true,
                                     "autoUpload": true, "wakeMinutes": 7 * 60 + 30, "pcCode": "",
                                     "controlYeti": true])
        pcAddress = defaults.string(forKey: "pcAddress") ?? ""
        rawSensors = defaults.bool(forKey: "rawSensors")
        voicePrompts = defaults.bool(forKey: "voicePrompts")
        autoUpload = defaults.bool(forKey: "autoUpload")
        wakeMinutes = defaults.integer(forKey: "wakeMinutes")
        pcCode = defaults.string(forKey: "pcCode") ?? ""
        controlYeti = defaults.bool(forKey: "controlYeti")
    }

    /// Le Blue Yeti doit-il être commandé ? (option activée et adresse du PC connue)
    var wantsYeti: Bool { controlYeti && !pcAddress.trimmingCharacters(in: .whitespaces).isEmpty }

    var wakeDate: Date {
        get {
            Calendar.current.date(bySettingHour: wakeMinutes / 60, minute: wakeMinutes % 60, second: 0, of: Date()) ?? Date()
        }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            wakeMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 30)
        }
    }

    /// Prochaine occurrence de l'heure du réveil.
    func nextWake(after now: Date = Date()) -> Date {
        let today = wakeDate
        return today > now ? today : Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
    }
}

/// Horloges : celle des capteurs (temps depuis le démarrage) et l'heure réelle.
enum Clock {
    static var uptime: Double { ProcessInfo.processInfo.systemUptime }
    static var unix: Double { Date().timeIntervalSince1970 }
    static var now: (uptime: Double, unix: Double) { (uptime, unix) }

    /// Horloge qui continue pendant la veille de l'iPhone (en secondes).
    static var continuous: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    /// Convertit un instant de l'horloge des capteurs en heure réelle.
    static func unix(fromUptime value: Double) -> Double {
        unix - (uptime - value)
    }
}

/// Informations sur l'iPhone.
enum DeviceInfo {
    static var model: String {
        var system = utsname()
        uname(&system)
        let mirror = Mirror(reflecting: system.machine)
        return mirror.children.reduce("") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return result }
            return result + String(UnicodeScalar(UInt8(value)))
        }
    }

    static var systemVersion: String { UIDevice.current.systemVersion }

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var freeDiskMB: Double? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_000_000
    }

    /// À appeler depuis le fil principal.
    static func batteryLevel() -> Double? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    static func batteryState() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .unplugged: return "debranche"
        case .charging: return "en_charge"
        case .full: return "pleine"
        default: return "inconnu"
        }
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "eleve"
        case .serious: return "serieux"
        case .critical: return "critique"
        @unknown default: return "inconnu"
        }
    }

    static var installation: ProvisioningInfo? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return ProvisioningInfo.parse(data)
    }

    /// Teste si l'API « haute fréquence » d'Apple (CMBatchedSensorManager) est utilisable ici.
    /// Elle est prévue pour l'Apple Watch ; on vérifie sans l'appeler directement.
    static func highRateAPISupport() -> [String: Bool] {
        guard let cls = NSClassFromString("CMBatchedSensorManager") else { return ["classe_presente": false] }
        let object = cls as AnyObject
        var result = ["classe_presente": true]
        for (key, selector) in [("accelerometre", "isAccelerometerSupported"), ("mouvement", "isDeviceMotionSupported")] {
            if object.responds(to: NSSelectorFromString(selector)),
               let value = object.value(forKey: selector) as? Bool {
                result[key] = value
            }
        }
        return result
    }
}

/// Journal de diagnostic de l'app (indépendant des séances), à exporter et à m'envoyer.
final class Diagnostics {
    static let shared = Diagnostics()

    let directory: URL
    private let queue = DispatchQueue(label: "sommeil.diagnostic")
    private let formatter: DateFormatter

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("diagnostic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    var logURL: URL { directory.appendingPathComponent("app.log") }

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async { [logURL] in
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
        #if DEBUG
        print(message)
        #endif
    }

    /// Garde un rapport Apple (MetricKit) : raisons des fermetures, plantages…
    func saveReport(_ data: Data, prefix: String) {
        let name = "\(prefix)_\(Int(Date().timeIntervalSince1970)).json"
        queue.async { [directory] in
            try? data.write(to: directory.appendingPathComponent(name))
        }
    }

    /// Réduit le journal s'il devient trop gros (on garde la fin).
    func trimIfNeeded(maxBytes: Int = 5_000_000) {
        queue.async { [logURL] in
            guard let data = try? Data(contentsOf: logURL), data.count > maxBytes else { return }
            try? data.suffix(maxBytes / 2).write(to: logURL)
        }
    }
}
