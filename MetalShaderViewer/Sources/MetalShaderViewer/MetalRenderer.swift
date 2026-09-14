import AppKit
import Metal
import QuartzCore
import simd

/// An `NSView` backed by a `CAMetalLayer` that runs a fullscreen fragment shader.
///
/// The render loop is driven by a `CADisplayLink` so it is paced to the display
/// the window is actually on, and it stops completely whenever there is nothing
/// worth drawing (paused, occluded, zero-sized, or no compiled pipeline).
final class ShaderView: NSView {

    // MARK: Metal objects

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private let renderPass = MTLRenderPassDescriptor()

    // MARK: Loop state

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var shaderTime: Float = 0
    private var frameIndex: Float = 0
    private var mouse = SIMD2<Float>(0, 0)

    /// Smoothed frames-per-second, reported to the UI a few times a second.
    private var smoothedFrameTime: Double = 1.0 / 60.0
    private var lastFPSReport: CFTimeInterval = 0
    var onFPS: ((Double) -> Void)?

    // MARK: Tunables

    /// Fraction of native resolution to render at. The single biggest lever for
    /// expensive shaders: cost scales with pixel count, so 0.5 is ~4x cheaper.
    var resolutionScale: CGFloat = 1.0 {
        didSet { updateDrawableSize() }
    }

    var isPaused: Bool = false {
        didSet { syncLoopState() }
    }

    private var isOccluded: Bool = false {
        didSet { syncLoopState() }
    }

    // MARK: Init

    init(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else {
            fatalError("Metal device could not create a command queue.")
        }
        self.device = device
        self.commandQueue = queue
        self.commandQueue.label = "ShaderRenderQueue"
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        // The shader writes every pixel of the drawable, so the previous contents
        // never need loading back into tile memory.
        renderPass.colorAttachments[0].loadAction = .dontCare
        renderPass.colorAttachments[0].storeAction = .store
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = Self.pixelFormat
        // Nothing samples or reads back the drawable, which lets the driver pick
        // the cheapest texture configuration.
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Triple buffering: enough drawables to keep the GPU fed without adding
        // latency, and vsync so we never render frames the display will drop.
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.allowsNextDrawableTimeout = true
        layer.needsDisplayOnBoundsChange = true
        return layer
    }

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // MARK: Public control

    func setPipeline(_ pipeline: MTLRenderPipelineState) {
        self.pipeline = pipeline
        syncLoopState()
    }

    func resetTime() {
        shaderTime = 0
        frameIndex = 0
    }

    // MARK: View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopLoop()
        guard let window else { return }
        updateDrawableSize()
        observeOcclusion(of: window)
        syncLoopState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale

        let width = bounds.width * scale * resolutionScale
        let height = bounds.height * scale * resolutionScale
        let size = CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
        guard size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size
    }

    // MARK: Occlusion

    private func observeOcclusion(of window: NSWindow) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window)
        isOccluded = !window.occlusionState.contains(.visible)
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        // A fully hidden or minimised window keeps burning GPU otherwise.
        isOccluded = !window.occlusionState.contains(.visible)
    }

    // MARK: Loop

    private func syncLoopState() {
        let shouldRun = pipeline != nil && !isPaused && !isOccluded && window != nil
        shouldRun ? startLoop() : stopLoop()
    }

    private func startLoop() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        // .common keeps frames coming during live resize and menu tracking.
        link.add(to: .main, forMode: .common)
        lastTimestamp = 0
        displayLink = link
    }

    private func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Frame

    @objc private func step(_ link: CADisplayLink) {
        // One pool per frame: CAMetalDrawable is autoreleased and would otherwise
        // pile up until the run loop drains.
        autoreleasepool { render(link) }
    }

    private func render(_ link: CADisplayLink) {
        guard let pipeline else { return }

        let now = link.timestamp
        let delta = lastTimestamp == 0 ? (1.0 / 60.0) : max(0, now - lastTimestamp)
        lastTimestamp = now
        shaderTime += Float(delta)
        reportFPS(delta: delta, now: now)

        let size = metalLayer.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }

        // Acquired as late as possible: nextDrawable blocks when all drawables are
        // in flight, so everything that can be prepared first is prepared first.
        guard let drawable = metalLayer.nextDrawable() else { return }

        renderPass.colorAttachments[0].texture = drawable.texture

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return }

        var uniforms = Uniforms(
            resolution: SIMD2<Float>(Float(size.width), Float(size.height)),
            mouse: mouse * Float(resolutionScale),
            time: shaderTime,
            frame: frameIndex)

        encoder.setRenderPipelineState(pipeline)
        // Under 4 KB, so Metal inlines this into the command buffer. No uniform
        // buffer, no ring allocation, and no CPU/GPU synchronisation to manage.
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Deliberately no waitUntilCompleted: the CPU runs ahead and queues the
        // next frame while the GPU is still working on this one.

        frameIndex += 1
    }

    private func reportFPS(delta: CFTimeInterval, now: CFTimeInterval) {
        guard delta > 0 else { return }
        smoothedFrameTime += (delta - smoothedFrameTime) * 0.1
        guard now - lastFPSReport > 0.25 else { return }
        lastFPSReport = now
        onFPS?(1.0 / smoothedFrameTime)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateMouse(event) }
    override func mouseDragged(with event: NSEvent) { updateMouse(event) }

    private func updateMouse(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1
        // Reported in drawable pixels with a bottom-left origin, matching the
        // fragCoord the prelude hands the shader.
        mouse = SIMD2<Float>(Float(point.x * scale), Float(point.y * scale))
    }

    deinit {
        stopLoop()
        NotificationCenter.default.removeObserver(self)
    }
}
