import Foundation
import MLX

/// Points MLX at the Metal library SwiftPM copies into the test bundle.
///
/// Under `swift test` the test bundle is loaded without being registered as an `NSBundle`,
/// so MLX's automatic `mlx-swift_Cmlx.bundle` lookup fails ("Failed to load the default
/// metallib"). Call ``ensureConfigured()`` before the first MLX operation of a suite.
enum MetalLibrary {
    private final class Marker {}

    private static let configured: Void = {
        guard GPU.metallib == nil,
            let resources = Bundle(for: Marker.self).resourceURL
        else { return }
        let metallib = resources.appending(
            path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        if FileManager.default.fileExists(atPath: metallib.path) {
            GPU.metallib = metallib
        }
    }()

    static func ensureConfigured() { configured }
}
