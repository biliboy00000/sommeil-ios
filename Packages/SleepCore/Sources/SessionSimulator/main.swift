import Foundation
import SleepCore

// Simulateur de séance : écrit un dossier au même format que l'app, avec un pouls,
// une respiration, des arrêts de respiration et des positions CONNUS (voir SimulatedSession).
//
// Usage : sommeil-simulateur <dossier> [durée_s=600] [pouls=62] [graine=1]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage : sommeil-simulateur <dossier> [durée_s=600] [pouls=62] [graine=1]")
    exit(1)
}
var plan = SimulationPlan()
plan.duration = arguments.count > 2 ? Double(arguments[2]) ?? 600 : 600
plan.bpm = arguments.count > 3 ? Double(arguments[3]) ?? 62 : 62
plan.seed = arguments.count > 4 ? UInt64(arguments[4]) ?? 1 : 1
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let truth = try SimulatedSession.write(to: directory, plan: plan)
let beats = (truth["battements_s"] as? [Double])?.count ?? 0
print("Séance simulée écrite dans \(directory.path) : \(truth["mesures"] ?? 0) mesures, \(beats) battements")
