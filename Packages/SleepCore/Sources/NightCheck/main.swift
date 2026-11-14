import Foundation
import SleepCore

// Analyse une séance sur ordinateur (Mac ou Linux), pour vérifier l'analyse de l'app sur de vraies nuits.
// Usage : NightCheck <dossier de la séance> <dossier de sortie> [son.s16 [début du son en s depuis l'origine]]
// son.s16 : son de la nuit décodé en 16 kHz mono, entiers 16 bits, sans en-tête.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage : NightCheck <séance> <sortie> [son.s16 [début]]")
    exit(1)
}
let session = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let started = Date()
let analyzer = try NightAnalyzer(directory: session)
try analyzer.analyzeSensors()
print(String(format: "capteurs : %.1f s", Date().timeIntervalSince(started)))
if args.count >= 4 {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    let offset = args.count >= 5 ? Double(args[4]) ?? 0 : 0
    let total = data.count / 2
    let chunk = 16_000 * 60
    data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        var i = 0
        while i < total {
            let n = min(chunk, total - i)
            let samples = (0..<n).map { Float(p[i + $0]) / 32768 }
            analyzer.addSound(startUptime: analyzer.origin + offset + Double(i) / 16_000, samples: samples)
            i += n
        }
    }
    print(String(format: "son : %.1f s", Date().timeIntervalSince(started)))
}
let report = analyzer.finish()
print(String(format: "bilan : %.1f s", Date().timeIntervalSince(started)))
try report.write(to: output)

func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
if let h = analyzer.lastHeartTrack {
    try json(["t": h.times, "bpm": h.bpm, "height": h.height, "hlong": h.heightLong,
              "valid": h.valid, "conf": h.confident]).write(to: output.appendingPathComponent("pouls.json"))
}
if let b = analyzer.lastBreathTracks {
    for (name, t) in [("gyro", b.gyro), ("son", b.sound)] {
        try json(["t": t.times, "rate": t.rate, "height": t.height, "hlong": t.heightLong, "valid": t.valid,
                  "conf": t.confident, "confs": t.confidentShort]).write(to: output.appendingPathComponent("resp_\(name).json"))
    }
}
try json(analyzer.lastPauses.map { ["start": $0.start, "end": $0.end, "source": $0.source, "ratio": $0.ratio.isNaN ? -1 : $0.ratio,
                                     "snr": $0.signalToNoise.isNaN ? -1 : $0.signalToNoise, "hidden": $0.hiddenBreaths.isNaN ? -99 : $0.hiddenBreaths,
                                     "verdict": $0.verdict.rawValue] }).write(to: output.appendingPathComponent("pauses.json"))
let s = report.summary
print("note", report.score?.value ?? -1, report.score?.verdict ?? "")
for p in report.score?.parts ?? [] { print("  ", p.name, "|", p.measure, "|", Int(p.points.rounded())) }
print("sommeil", s.sleepSeconds ?? 0, "fourchette", s.sleepLowSeconds ?? 0, s.sleepHighSeconds ?? 0, "latence", s.onsetLatency ?? -1,
      "éveil", s.wakeAfterOnset ?? -1, "éveils", s.awakenings)
print("pouls fenêtres fiables", s.heartWindowShare ?? 0, "éveillé", s.heartAwake ?? 0, "endormi", s.heartAsleep ?? 0)
print("respiration accord", s.breathAgreement ?? -1, "médiane", s.breathMedian ?? 0, "couverture", s.breathCoverage)
print("pauses réduites", s.pauses, "non vérifiables", s.pausesUnverifiable ?? 0, "écartées", s.silencesDismissed ?? 0,
      "amplitude", s.breathingAmplitude ?? 0, "emplacement", report.placement)
for n in report.notes { print("note:", n) }
