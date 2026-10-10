// swift-tools-version:5.9
// Cœur de l'app Sommeil : tout ce qui ne dépend pas du matériel de l'iPhone.
// Compilable et testable sur Mac, sur Linux et dans l'app iOS.
import PackageDescription

let package = Package(
    name: "SleepCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SleepCore", targets: ["SleepCore"])
    ],
    targets: [
        .target(name: "SleepCore"),
        .testTarget(name: "SleepCoreTests", dependencies: ["SleepCore"])
    ]
)
