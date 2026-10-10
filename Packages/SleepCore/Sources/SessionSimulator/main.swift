import Foundation
import SleepCore

// Simulateur de séance : écrit un dossier au même format que l'app, avec un pouls,
// une respiration, des arrêts de respiration et des positions CONNUS. Sert à tester
// la lecture sur le PC et, en phase 2, les algorithmes.
//
// Usage : sommeil-simulateur <dossier> [durée_s=600] [pouls=62] [graine=1]
// Sans son (le son est ajouté par les tests Python si besoin).

struct Random {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage : sommeil-simulateur <dossier> [durée_s=600] [pouls=62] [graine=1]")
    exit(1)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let duration = arguments.count > 2 ? Double(arguments[2]) ?? 600 : 600
let bpm = arguments.count > 3 ? Double(arguments[3]) ?? 62 : 62
var random = Random(seed: arguments.count > 4 ? UInt64(arguments[4]) ?? 1 : 1)

let fs = 100.0
let startUnix = 1_760_120_000.0      // date fixe : résultats reproductibles
let startUptime = 50_000.0
let breathRate = 14.0 / 60            // Hz
var truth: [String: Any] = ["pouls_bpm": bpm, "respiration_par_min": 14.0, "frequence_hz": fs]

try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var clockUptime = startUptime
let clock: ChunkedStreamWriter.Clock = { (clockUptime, startUnix + clockUptime - startUptime) }
let dm = ChunkedStreamWriter(stream: .deviceMotion, directory: directory.appendingPathComponent("capteurs"),
                             nominalRate: fs, chunkDuration: 600, clock: clock)
let acc = ChunkedStreamWriter(stream: .accelerometer, directory: directory.appendingPathComponent("capteurs"),
                              nominalRate: fs, chunkDuration: 600, clock: clock)
let gyr = ChunkedStreamWriter(stream: .gyroscope, directory: directory.appendingPathComponent("capteurs"),
                              nominalRate: fs, chunkDuration: 600, clock: clock)
let journal = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.journal))
let clockLog = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.clock))
let stateLog = try JSONLinesWriter(url: directory.appendingPathComponent(SessionFiles.state))

func unix(_ uptime: Double) -> Double { startUnix + uptime - startUptime }

// Déroulé : celui du test guidé (positions, arrêts de respiration, mouvements).
func position(at t: Double) -> (Double, Double, Double) {
    if t >= 510 { return (-0.97, 0.05, -0.2) }       // côté droit
    if t >= 300 { return (0.97, 0.05, -0.2) }        // côté gauche
    return (0.0, 0.1, -0.995)                        // sur le dos, écran vers le haut
}
func holdingBreath(_ t: Double) -> Bool { (155..<175).contains(t) || (425..<445).contains(t) }
func moving(_ t: Double) -> Bool { (240..<260).contains(t) || (295..<302).contains(t) || (505..<512).contains(t) }

journal.write(JournalEvent(unix: unix(startUptime), uptime: startUptime, type: EventType.sessionStart,
                           message: "Début : séance simulée"))
for step in GuidedTest.steps where step.at <= duration {
    journal.write(JournalEvent(unix: unix(startUptime + step.at), uptime: startUptime + step.at,
                               type: EventType.marker, message: step.display,
                               values: ["t_test_s": step.at], info: ["marqueur": step.marker]))
}

// Battements : intervalles autour de la période moyenne, avec une variabilité respiratoire.
var beats: [Double] = []
var nextBeat = 0.4
while nextBeat < duration {
    beats.append(nextBeat)
    let rsa = 0.04 * sin(2 * Double.pi * breathRate * nextBeat)
    nextBeat += 60 / bpm + rsa + 0.015 * random.gaussian()
}
truth["battements_s"] = beats
var beatIndex = 0
var breathPhase = 0.0
var calibration = CalibrationAccumulator()
var gravity = position(at: 0)
let n = Int(duration * fs)
var samples = 0

for i in 0..<n {
    let t = Double(i) / fs
    // Petite irrégularité d'horodatage (±0,3 ms), comme sur un vrai iPhone.
    let timestamp = startUptime + t + 0.0003 * (random.next() - 0.5)
    clockUptime = timestamp

    // Gravité : rejoint doucement la position, plus la respiration (inclinaison de ±0,6°).
    let target = position(at: t)
    gravity = (gravity.0 + (target.0 - gravity.0) * 0.02, gravity.1 + (target.1 - gravity.1) * 0.02,
               gravity.2 + (target.2 - gravity.2) * 0.02)
    if !holdingBreath(t) { breathPhase += 2 * Double.pi * breathRate / fs }
    let tiltAmplitude = 0.6 * Double.pi / 180
    let tilt = holdingBreath(t) ? 0 : tiltAmplitude * sin(breathPhase)
    // Vitesse de rotation correspondante, vue par le gyroscope (axe x de l'iPhone).
    let tiltRate = holdingBreath(t) ? 0 : tiltAmplitude * 2 * Double.pi * breathRate * cos(breathPhase)
    var g = (gravity.0, gravity.1 * cos(tilt) - gravity.2 * sin(tilt), gravity.1 * sin(tilt) + gravity.2 * cos(tilt))
    let norm = (g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot()
    g = (g.0 / norm, g.1 / norm, g.2 / norm)

    // Battement : vibration amortie (sismocardiographie) sur z, et rotation (gyrocardiographie) sur x et y.
    while beatIndex + 1 < beats.count && beats[beatIndex + 1] <= t { beatIndex += 1 }
    var scg = 0.0, gcg = 0.0
    for k in [beatIndex, beatIndex + 1] where k < beats.count {
        let dt = t - beats[k]
        if dt >= 0 && dt < 0.15 { scg += 0.006 * exp(-dt / 0.035) * sin(2 * Double.pi * 16 * dt) }
        let dt2 = dt - 0.3
        if dt2 >= 0 && dt2 < 0.12 { scg += 0.003 * exp(-dt2 / 0.03) * sin(2 * Double.pi * 22 * dt2) }
        if dt >= 0 && dt < 0.15 { gcg += 0.012 * exp(-dt / 0.04) * sin(2 * Double.pi * 13 * dt) }
    }
    var user = (0.0012 * random.gaussian(), 0.0012 * random.gaussian(), scg + 0.0012 * random.gaussian())
    var rotation = (gcg + tiltRate + 0.003 * random.gaussian(), 0.5 * gcg + 0.003 * random.gaussian(),
                    0.003 * random.gaussian())
    if moving(t) {
        user = (user.0 + 0.15 * random.gaussian(), user.1 + 0.15 * random.gaussian(), user.2 + 0.15 * random.gaussian())
        rotation = (rotation.0 + 0.5 * random.gaussian(), rotation.1 + 0.5 * random.gaussian(), rotation.2 + 0.5 * random.gaussian())
    }
    if t < 30 { calibration.add(gravity: g, userAcceleration: user) }

    dm.append(timestamp: timestamp, values: [user.0, user.1, user.2, g.0, g.1, g.2,
                                             rotation.0, rotation.1, rotation.2, 0, 0, 0, 1].map { Float($0) })
    acc.append(timestamp: timestamp, values: [user.0 + g.0, user.1 + g.1, user.2 + g.2].map { Float($0) })
    gyr.append(timestamp: timestamp, values: [rotation.0 + 0.004, rotation.1 - 0.002, rotation.2 + 0.001].map { Float($0) })
    samples += 1

    if i % 100 == 0 {
        dm.flush(); acc.flush(); gyr.flush()
    }
    if i % 1000 == 0 {
        clockLog.write(ClockPoint(uptime: timestamp, unix: unix(timestamp), continuous: timestamp + 3600))
    }
    if i % 1500 == 0 {
        stateLog.write(DeviceStateSample(unix: unix(timestamp), uptime: timestamp, battery: 0.9 - 0.06 * t / 3600,
                                         batteryState: "debranche", thermal: "normal", lowPowerMode: false,
                                         freeDiskMB: 50_000, samples: ["dm": samples, "acc": samples, "gyr": samples],
                                         audioSeconds: t, audioRunning: true))
    }
}
dm.close(); acc.close(); gyr.close()

let end = startUptime + duration
journal.write(JournalEvent(unix: unix(end), uptime: end, type: EventType.sessionEnd, message: "Fin de la séance simulée"))
journal.close(); clockLog.close(); stateLog.close()

var info = SessionInfo(id: directory.lastPathComponent, kind: "test_guide", appVersion: "simulateur",
                       device: "simulation", systemVersion: "-", startUnix: startUnix, startUptime: startUptime,
                       nominalRate: fs, streams: ["dm", "acc", "gyr"])
info.endUnix = unix(end)
info.endUptime = end
info.endedNormally = true
info.calibration = calibration.result(startUnix: startUnix, endUnix: startUnix + 30)
info.notes = ["séance simulée : pouls \(bpm) bpm, respiration 14/min, arrêts de respiration 155-175 s et 425-445 s"]
try info.write(to: directory)
let truthData = try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted, .sortedKeys])
try truthData.write(to: directory.appendingPathComponent("verite_simulation.json"))
if let summary = try? SessionSummary.compute(directory: directory, now: unix(end)) {
    try summary.write(to: directory)
}
print("Séance simulée écrite dans \(directory.path) : \(samples) mesures, \(beats.count) battements")
