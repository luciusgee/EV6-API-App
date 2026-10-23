import CoreMotion
import Foundation

/// Watches the phone's accelerometer while a standing-start run waits, and notes the moment the car
/// pulls away. The car only reports whole km/h a few times a second; the phone feels the launch
/// within a hundredth of a second.
@MainActor
final class MotionLaunch {
    private let manager = CMMotionManager()
    /// When the latest push began. A later push replaces it, so jolts while waiting don't count.
    private(set) var launchedAt: Date?
    private var above = 0

    /// A shove harder than this, in g, held for a few samples, is a launch. Hard EV launches pull
    /// 0.5–1 g; bumps and handling the phone don't last.
    static let threshold = 0.18
    static let samples = 4

    var available: Bool { manager.isDeviceMotionAvailable }

    func start() {
        launchedAt = nil
        above = 0
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated { self.feel(motion) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Ready for the next launch.
    func rearm() {
        launchedAt = nil
        above = 0
    }

    private func feel(_ motion: CMDeviceMotion) {
        let a = motion.userAcceleration
        let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        if g > Self.threshold {
            above += 1
            if above == Self.samples {
                // Back to the first sample over the line.
                let seconds = motion.timestamp - Double(Self.samples - 1) * manager.deviceMotionUpdateInterval
                launchedAt = Date(timeIntervalSinceNow: seconds - ProcessInfo.processInfo.systemUptime)
            }
        } else {
            above = 0
        }
    }
}
