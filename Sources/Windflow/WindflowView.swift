import Foundation
import AppKit
import ScreenSaver

@objc(WindflowView)
public final class WindflowView: ScreenSaverView {

    // Every layer is walked on the CPU each frame, and a full 5K frame also has
    // to reach the window server sixty times a second. Past this budget we
    // render under native and let the layer scale up — the lines are soft and
    // anti-aliased, so the difference is invisible where the power draw is not.
    private static let pixelBudget: Double = 2_600_000

    private var canvas: Canvas?
    private var simulation: Simulation?
    private var lastFrameTime: CFTimeInterval = 0
    private var configuredSize: NSSize = .zero
    private var configuredScale: CGFloat = 0

    private var playlist: [URL] = []
    private var playlistIndex = 0
    private let loadQueue = DispatchQueue(label: "com.oddurs.Windflow.load", qos: .utility)
    private var pending: CGImage?
    private var loading = false

    private var configController: ConfigSheetController?

    // MARK: - Lifecycle

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        layer?.backgroundColor = CGColor(red: 0.006, green: 0.008, blue: 0.016, alpha: 1)
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    public override func startAnimation() {
        super.startAnimation()
        lastFrameTime = CACurrentMediaTime()
    }

    public override func stopAnimation() {
        super.stopAnimation()
    }

    public override func draw(_ rect: NSRect) {
        // Everything is published through the layer's contents; this only paints
        // the ground colour before the first frame lands.
        NSColor(calibratedRed: 0.006, green: 0.008, blue: 0.016, alpha: 1).setFill()
        rect.fill()
    }

    // MARK: - Frame

    public override func animateOneFrame() {
        rebuildIfNeeded()
        guard let canvas, let simulation else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 1.0 / 240.0), 0.05))
        lastFrameTime = now

        simulation.step(dt: dt)
        if let image = canvas.present(fade: simulation.fadeFactor(dt: dt),
                                      bloomAmount: simulation.tuning.bloom,
                                      vignetteAmount: 0.12) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }

        if simulation.phase == .dissolving && pending == nil && !loading {
            prefetchNextImage()
        }
        if simulation.phase == .done {
            advanceImage()
        }
    }

    // MARK: - Sizing

    private func rebuildIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2.0
        let size = bounds.size
        guard size.width > 8, size.height > 8 else { return }
        if size == configuredSize && scale == configuredScale && canvas != nil { return }

        configuredSize = size
        configuredScale = scale

        let pointArea = Double(size.width * size.height)
        var renderScale = Double(scale)
        if pointArea * renderScale * renderScale > Self.pixelBudget {
            renderScale = (Self.pixelBudget / max(pointArea, 1)).squareRoot()
        }

        let pw = max(64, Int((Double(size.width) * renderScale).rounded()))
        let ph = max(64, Int((Double(size.height) * renderScale).rounded()))

        let c = Canvas(width: pw, height: ph)
        canvas = c
        layer?.contentsScale = CGFloat(renderScale)

        pending = nil
        let first = nextURL().flatMap { ImageLibrary.load($0) }
        simulation = makeSimulation(for: c, image: first)
    }

    // MARK: - Playlist

    /// Advance the playlist. Called on the main thread only — it owns the cursor.
    private func nextURL() -> URL? {
        if playlist.isEmpty || playlistIndex >= playlist.count {
            playlist = ImageLibrary.urls()
            if Preferences.shared.shuffle { playlist.shuffle() }
            playlistIndex = 0
        }
        guard playlistIndex < playlist.count else { return nil }
        let url = playlist[playlistIndex]
        playlistIndex += 1
        return url
    }

    private func makeSimulation(for canvas: Canvas, image: CGImage?) -> Simulation? {
        guard let image = image ?? ProceduralImage.make() else { return nil }
        return Simulation.make(image: image, canvas: canvas,
                               settings: SimulationSettings(prefs: Preferences.shared),
                               preview: isPreview)
    }

    /// Decoding a photograph takes long enough to drop frames, so it happens off
    /// the render thread while the current image is still dissolving. Only the
    /// decode is prefetched: the simulation itself writes into the shared canvas
    /// and has to be built on the main thread once the old one is finished with
    /// it.
    private func prefetchNextImage() {
        guard !loading else { return }
        loading = true
        let url = nextURL()
        loadQueue.async { [weak self] in
            let image = url.flatMap { ImageLibrary.load($0) } ?? ProceduralImage.make()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending = image
                self.loading = false
            }
        }
    }

    /// Cut to the next photograph immediately. Used by the preview harness; the
    /// screensaver itself only ever advances on the timer.
    public func advanceImage() {
        guard let canvas else { return }
        let image = pending ?? nextURL().flatMap { ImageLibrary.load($0) }
        pending = nil
        loading = false
        simulation = makeSimulation(for: canvas, image: image)
    }

    /// Re-read the preferences and restart the current photograph with them.
    public func reloadSettings() {
        configuredSize = .zero
        canvas = nil
    }

    // MARK: - Configuration

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if configController == nil {
            configController = ConfigSheetController()
        }
        return configController?.window
    }
}
