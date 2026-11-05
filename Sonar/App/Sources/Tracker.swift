import ARKit
import CoreMotion
import simd

/// Position et orientation du téléphone : ARKit (caméra + capteurs), et en option le maillage LiDAR comme référence.
final class Tracker: NSObject, ARSessionDelegate {
    let session = ARSession()
    private(set) var lidarActive = false
    private var poses: LineWriter?
    private let lock = NSLock()
    private var lastStateText = ""

    /// (texte, suivi normal ?) — appelé sur le fil principal quand l'état change.
    var onState: ((String, Bool) -> Void)?

    static var lidarSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func run(lidar: Bool) {
        lidarActive = lidar && Self.lidarSupported
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if lidarActive {
            config.sceneReconstruction = .mesh
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { session.pause() }

    func beginLogging(to folder: URL) {
        lock.lock()
        poses = LineWriter(url: folder.appendingPathComponent("poses.csv"),
                           header: "t,tx,ty,tz,qx,qy,qz,qw,suivi")
        lock.unlock()
    }

    func endLogging() {
        lock.lock()
        poses?.close()
        poses = nil
        lock.unlock()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let cam = frame.camera
        let m = cam.transform
        let q = simd_quatf(m)
        let state: String
        switch cam.trackingState {
        case .normal: state = "normal"
        case .notAvailable: state = "indisponible"
        case .limited(let reason):
            switch reason {
            case .initializing: state = "initialisation"
            case .excessiveMotion: state = "trop_rapide"
            case .insufficientFeatures: state = "pas_assez_de_details"
            case .relocalizing: state = "relocalisation"
            @unknown default: state = "limite"
            }
        }
        lock.lock()
        poses?.write(String(format: "%.6f,%.5f,%.5f,%.5f,%.6f,%.6f,%.6f,%.6f,%@",
                            frame.timestamp, m.columns.3.x, m.columns.3.y, m.columns.3.z,
                            q.imag.x, q.imag.y, q.imag.z, q.real, state))
        lock.unlock()

        if state != lastStateText {
            lastStateText = state
            onState?(Self.humanText(state), state == "normal")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onState?("Erreur ARKit : \(error.localizedDescription)", false)
    }

    private static func humanText(_ s: String) -> String {
        switch s {
        case "normal": return "Suivi OK"
        case "initialisation": return "Initialisation… bouge un peu le téléphone"
        case "trop_rapide": return "Trop rapide, ralentis"
        case "pas_assez_de_details": return "Pas assez de détails visibles (éclaire la pièce)"
        case "relocalisation": return "Relocalisation…"
        default: return "Suivi indisponible"
        }
    }

    // MARK: Maillage LiDAR

    /// Écrit le maillage LiDAR en OBJ, dans le repère du monde ARKit (mètres). Renvoie le nombre de sommets.
    @discardableResult
    func exportMesh(to url: URL) -> Int {
        guard lidarActive, let anchors = session.currentFrame?.anchors else { return 0 }
        var text = "# Maillage LiDAR (repère monde ARKit, mètres, Y vers le haut)\n"
        var base = 1
        var total = 0
        for case let anchor as ARMeshAnchor in anchors {
            let g = anchor.geometry
            let t = anchor.transform
            let v = g.vertices
            let vptr = v.buffer.contents()
            for i in 0..<v.count {
                let p = vptr.advanced(by: v.offset + v.stride * i).assumingMemoryBound(to: Float.self)
                let w = t * SIMD4<Float>(p[0], p[1], p[2], 1)
                text += String(format: "v %.4f %.4f %.4f\n", w.x, w.y, w.z)
            }
            let f = g.faces
            let fptr = f.buffer.contents()
            let per = f.indexCountPerPrimitive
            for i in 0..<f.count {
                var idx: [Int] = []
                for j in 0..<per {
                    let o = (i * per + j) * f.bytesPerIndex
                    let value: Int = f.bytesPerIndex == 4
                        ? Int(fptr.advanced(by: o).assumingMemoryBound(to: UInt32.self).pointee)
                        : Int(fptr.advanced(by: o).assumingMemoryBound(to: UInt16.self).pointee)
                    idx.append(value + base)
                }
                text += "f " + idx.map(String.init).joined(separator: " ") + "\n"
            }
            base += v.count
            total += v.count
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return total
    }
}

/// Capteurs de mouvement bruts à 100 Hz (orientation, accélération, gravité, rotation).
final class MotionLogger {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var writer: LineWriter?

    func start(folder: URL) {
        guard manager.isDeviceMotionAvailable else { return }
        writer = LineWriter(url: folder.appendingPathComponent("mouvement.csv"),
                            header: "t,qx,qy,qz,qw,ax,ay,az,gx,gy,gz,rx,ry,rz")
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let m, let w = self?.writer else { return }
            let q = m.attitude.quaternion
            let a = m.userAcceleration, g = m.gravity, r = m.rotationRate
            w.write(String(format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f",
                           m.timestamp, q.x, q.y, q.z, q.w, a.x, a.y, a.z, g.x, g.y, g.z, r.x, r.y, r.z))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        queue.waitUntilAllOperationsAreFinished()
        writer?.close()
        writer = nil
    }
}
