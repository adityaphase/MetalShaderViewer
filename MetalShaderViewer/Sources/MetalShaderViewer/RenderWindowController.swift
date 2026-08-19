import AppKit
import Metal

/// The output window: nothing but a `ShaderView` filling the content area.
///
/// Defaults to a square canvas, which is the usual framing for shader art.
final class RenderWindowController: NSWindowController, NSWindowDelegate {

    static let defaultSize = NSSize(width: 800, height: 800)

    let shaderView: ShaderView
    var onClose: (() -> Void)?
    /// Fires when the user resizes the window, so the control panel's size
    /// fields stay in step with reality.
    var onResize: ((NSSize) -> Void)?

    init(device: MTLDevice) {
        shaderView = ShaderView(device: device)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Shader Output"
        window.contentView = shaderView
        window.contentMinSize = NSSize(width: 64, height: 64)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true

        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(title: String) {
        window?.title = title
        showWindow(nil)
    }

    /// Resizes the canvas while keeping the window's top-left corner planted, so
    /// the window does not appear to drift as the size is typed in.
    func setContentSize(_ size: NSSize) {
        guard let window else { return }
        guard window.contentView?.frame.size != size else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var origin = window.frame.origin
        origin.y += window.frame.height - frame.height
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: false)
    }

    /// Locks the window to a 1:1 canvas so dragging a corner keeps it square.
    /// `NSZeroSize` removes the constraint again.
    func setSquareLocked(_ locked: Bool) {
        window?.contentAspectRatio = locked ? NSSize(width: 1, height: 1) : .zero
    }

    func windowDidResize(_ notification: Notification) {
        guard let size = window?.contentView?.frame.size else { return }
        onResize?(size)
    }

    func windowWillClose(_ notification: Notification) {
        shaderView.isPaused = true
        onClose?()
    }
}
