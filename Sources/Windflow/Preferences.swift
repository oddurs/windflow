import Foundation
import ScreenSaver

/// Typed wrapper over the module's ScreenSaverDefaults domain.
final class Preferences {

    static let moduleName = "com.oddurs.Windflow"
    static let shared = Preferences()

    private let store: UserDefaults

    private init() {
        store = ScreenSaverDefaults(forModuleWithName: Preferences.moduleName)
            ?? UserDefaults.standard
        store.register(defaults: [
            Key.density: 1.0,
            Key.speed: 1.0,
            Key.trail: 1.0,
            Key.exposure: 1.0,
            Key.swirl: 0.55,
            Key.drift: 0.25,
            Key.saturation: 1.45,
            Key.bloom: 0.9,
            Key.secondsPerImage: 75.0,
            Key.shuffle: true,
        ])
    }

    enum Key {
        static let density = "density"
        static let speed = "speed"
        static let trail = "trail"
        static let exposure = "exposure"
        static let swirl = "swirl"
        static let drift = "drift"
        static let saturation = "saturation"
        static let bloom = "bloom"
        static let secondsPerImage = "secondsPerImage"
        static let shuffle = "shuffle"
    }

    /// Tracer count multiplier.
    var density: Double { get { store.double(forKey: Key.density) } set { set(Key.density, newValue) } }
    /// How fast the wind travels.
    var speed: Double { get { store.double(forKey: Key.speed) } set { set(Key.speed, newValue) } }
    /// Streak length — the glow half-life.
    var trail: Double { get { store.double(forKey: Key.trail) } set { set(Key.trail, newValue) } }
    /// Overall glyph coverage.
    var exposure: Double { get { store.double(forKey: Key.exposure) } set { set(Key.exposure, newValue) } }
    /// Time-varying wander, in radians.
    var swirl: Double { get { store.double(forKey: Key.swirl) } set { set(Key.swirl, newValue) } }
    /// 0 = hug the photo's structure exactly, 1 = let the open wind dominate.
    var drift: Double { get { store.double(forKey: Key.drift) } set { set(Key.drift, newValue) } }
    /// Colour depth.
    var saturation: Double { get { store.double(forKey: Key.saturation) } set { set(Key.saturation, newValue) } }
    /// Halo around the brightest lines.
    var bloom: Double { get { store.double(forKey: Key.bloom) } set { set(Key.bloom, newValue) } }
    var secondsPerImage: Double { get { store.double(forKey: Key.secondsPerImage) } set { set(Key.secondsPerImage, newValue) } }
    var shuffle: Bool { get { store.bool(forKey: Key.shuffle) } set { set(Key.shuffle, newValue) } }

    private func set(_ key: String, _ value: Any) {
        store.set(value, forKey: key)
        store.synchronize()
    }

    func synchronize() { store.synchronize() }
}
