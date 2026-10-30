// swift-tools-version:5.9
// Cœur de l'app Ciné : le rendu pellicule (même formule que les noyaux Metal), les formats,
// les réglages de l'appareil. Compilable et testable sur Mac, Linux et dans l'app iOS.
import PackageDescription

let package = Package(
    name: "FilmCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "FilmCore", targets: ["FilmCore"])],
    targets: [
        .target(name: "FilmCore"),
        .testTarget(name: "FilmCoreTests", dependencies: ["FilmCore"])
    ]
)
