import Foundation

/// Un événement du journal d'une séance (journal.jsonl), une ligne JSON par événement.
public struct JournalEvent: Codable, Equatable, Sendable {
    /// Heure réelle (secondes depuis 1970, UTC).
    public var unix: Double
    /// Horloge des capteurs (secondes depuis le démarrage de l'iPhone).
    public var uptime: Double
    /// Type d'événement, voir `EventType`.
    public var type: String
    /// Phrase lisible, en français.
    public var message: String
    public var values: [String: Double]?
    public var info: [String: String]?

    public init(unix: Double, uptime: Double, type: String, message: String,
                values: [String: Double]? = nil, info: [String: String]? = nil) {
        self.unix = unix
        self.uptime = uptime
        self.type = type
        self.message = message
        self.values = values
        self.info = info
    }
}

/// Types d'événements du journal.
public enum EventType {
    public static let sessionStart = "session_debut"
    public static let sessionEnd = "session_fin"
    public static let calibrationStart = "calibration_debut"
    public static let calibrationEnd = "calibration_fin"
    public static let interruptionStart = "interruption_debut"
    public static let interruptionEnd = "interruption_fin"
    public static let resumeFailed = "reprise_echec"
    public static let resumeOK = "reprise_ok"
    public static let audioRoute = "route_audio"
    public static let mediaReset = "reset_services_media"
    public static let memoryWarning = "alerte_memoire"
    public static let background = "arriere_plan"
    public static let foreground = "premier_plan"
    public static let willTerminate = "app_fermee"
    public static let sensorGap = "capteur_trou"
    public static let audioGap = "audio_trou"
    public static let marker = "marqueur"
    public static let error = "erreur"
    public static let info = "info"
    public static let thermal = "thermique"
    public static let battery = "batterie"
    public static let stats = "stats_capteurs"
    public static let previousSessionLost = "seance_precedente_interrompue"
    /// Commande et état du Blue Yeti branché au PC.
    public static let yeti = "yeti_pc"
}

/// Correspondance entre l'horloge des capteurs et l'heure réelle (horloge.jsonl).
public struct ClockPoint: Codable, Equatable, Sendable {
    public var uptime: Double
    public var unix: Double
    /// Horloge « continue » (compte aussi le temps de veille), en secondes.
    public var continuous: Double?

    public init(uptime: Double, unix: Double, continuous: Double? = nil) {
        self.uptime = uptime
        self.unix = unix
        self.continuous = continuous
    }
}

/// État de l'iPhone, noté régulièrement (etat.jsonl). Sert aussi de « battement de cœur » :
/// la dernière ligne indique jusqu'à quand l'app tournait.
public struct DeviceStateSample: Codable, Equatable, Sendable {
    public var unix: Double
    public var uptime: Double
    /// Niveau de batterie entre 0 et 1, nil si inconnu.
    public var battery: Double?
    /// "debranche", "en_charge", "pleine" ou "inconnu".
    public var batteryState: String
    /// "normal", "eleve", "serieux", "critique".
    public var thermal: String
    public var lowPowerMode: Bool
    public var freeDiskMB: Double?
    /// Nombre de mesures écrites depuis le début, par flux (dm, acc, gyr).
    public var samples: [String: Int]
    /// Secondes d'audio écrites depuis le début.
    public var audioSeconds: Double
    /// L'audio était-il en train d'enregistrer à ce moment ?
    public var audioRunning: Bool

    public init(unix: Double, uptime: Double, battery: Double?, batteryState: String, thermal: String,
                lowPowerMode: Bool, freeDiskMB: Double?, samples: [String: Int], audioSeconds: Double,
                audioRunning: Bool) {
        self.unix = unix
        self.uptime = uptime
        self.battery = battery
        self.batteryState = batteryState
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.freeDiskMB = freeDiskMB
        self.samples = samples
        self.audioSeconds = audioSeconds
        self.audioRunning = audioRunning
    }
}

/// Un fichier audio de la séance (audio/index.jsonl). Une ligne à l'ouverture du fichier
/// (`complete` = false), une autre à sa fermeture (`complete` = true, `frames` connu).
public struct AudioSegmentInfo: Codable, Equatable, Sendable {
    public var file: String
    /// Horloge des capteurs au premier échantillon.
    public var startUptime: Double
    public var startUnix: Double
    public var frames: Int
    public var sampleRate: Double
    public var complete: Bool

    public init(file: String, startUptime: Double, startUnix: Double, frames: Int,
                sampleRate: Double, complete: Bool) {
        self.file = file
        self.startUptime = startUptime
        self.startUnix = startUnix
        self.frames = frames
        self.sampleRate = sampleRate
        self.complete = complete
    }

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
}

/// Calibration au coucher : gravité moyenne mesurée allongé sur le dos.
public struct Calibration: Codable, Equatable, Sendable {
    public var startUnix: Double
    public var endUnix: Double
    public var gravity: [Double]
    /// Agitation pendant la calibration (écart-type de l'accélération, en g).
    public var movement: Double
    public var samples: Int

    public init(startUnix: Double, endUnix: Double, gravity: [Double], movement: Double, samples: Int) {
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.gravity = gravity
        self.movement = movement
        self.samples = samples
    }

    /// Inclinaison du téléphone par rapport à « à plat » (écran vers le haut ou vers le bas), en degrés.
    /// Sur le dos, téléphone posé sur le sternum, elle reste faible.
    public var tiltDegrees: Double {
        guard gravity.count == 3 else { return 0 }
        let norm = (gravity[0] * gravity[0] + gravity[1] * gravity[1] + gravity[2] * gravity[2]).squareRoot()
        guard norm > 0 else { return 0 }
        return acos(min(1, abs(gravity[2]) / norm)) * 180 / Double.pi
    }

    /// Au-delà, on doute que la personne soit vraiment sur le dos pendant la calibration.
    public static let maxPlausibleTilt = 35.0
    /// Au-delà de cette agitation (g), la calibration est jugée perturbée.
    public static let maxStillMovement = 0.02

    public var isPlausible: Bool { tiltDegrees <= Self.maxPlausibleTilt && movement < Self.maxStillMovement }
}

/// Description d'une séance (session.json).
public struct SessionInfo: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var id: String
    /// "nuit", "test_guide" ou "placement".
    public var kind: String
    public var appVersion: String
    public var device: String
    public var systemVersion: String
    public var startUnix: Double
    public var startUptime: Double
    public var endUnix: Double?
    public var endUptime: Double?
    /// true si l'enregistrement a été arrêté normalement (bouton « Arrêter »).
    public var endedNormally: Bool
    public var nominalRate: Double
    public var streams: [String]
    public var audioFormat: String?
    public var audioSampleRate: Double?
    public var audioSegmentSeconds: Double?
    public var calibration: Calibration?
    /// Résultat du test de l'API haute fréquence d'Apple (CMBatchedSensorManager).
    public var highRateAPI: [String: Bool]?
    /// Date d'expiration de l'installation de l'app (profil Apple), si connue.
    public var installExpiryUnix: Double?
    /// Présent si la nuit a été lancée avec un délai (« Oui, dans 45 min »).
    public var delayedStart: DelayedStart?
    /// "guidee" (30 s sur le dos au début) ou "automatique" (cherchée pendant la nuit).
    public var calibrationMode: String?
    /// Réglage du micro : "mesure" (son brut, sans traitement d'iOS) ou "normal" (compatible avec une vidéo
    /// ou un podcast qui joue en même temps). Absent avant la version 0.2.13 : "mesure".
    public var audioMode: String?
    public var notes: [String]

    public init(id: String, kind: String, appVersion: String, device: String, systemVersion: String,
                startUnix: Double, startUptime: Double, nominalRate: Double, streams: [String]) {
        self.formatVersion = Self.formatVersion
        self.id = id
        self.kind = kind
        self.appVersion = appVersion
        self.device = device
        self.systemVersion = systemVersion
        self.startUnix = startUnix
        self.startUptime = startUptime
        self.endedNormally = false
        self.nominalRate = nominalRate
        self.streams = streams
        self.notes = []
    }

    /// Identifiant lisible à partir de la date de début, par exemple "2026-10-10_23h14m05".
    public static func makeID(startUnix: Double, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: Date(timeIntervalSince1970: startUnix))
        return String(format: "%04d-%02d-%02d_%02dh%02dm%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

public enum SessionFiles {
    public static let info = "session.json"
    public static let journal = "journal.jsonl"
    public static let clock = "horloge.jsonl"
    public static let state = "etat.jsonl"
    public static let summary = "resume.json"
    public static let sensorsDir = "capteurs"
    public static let audioDir = "audio"
    public static let audioIndex = "audio/index.jsonl"
}

extension SessionInfo {
    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent(SessionFiles.info), options: .atomic)
    }

    public static func read(from directory: URL) throws -> SessionInfo {
        let data = try Data(contentsOf: directory.appendingPathComponent(SessionFiles.info))
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }
}
