import AppKit
import Metal
import UniformTypeIdentifiers

/// The control panel: pick a shader, size the canvas, tune the render settings.
final class ControlWindowController: NSWindowController, NSTextFieldDelegate {

    private let device: MTLDevice
    private let compiler: ShaderCompiler
    private var renderWindow: RenderWindowController?

    private var shaderURL: URL?
    private var fileWatcher: FileWatcher?

    /// Desired canvas size, remembered even while the output window is closed.
    private var canvasSize = RenderWindowController.defaultSize
    private var isSquareLocked = true

    // MARK: Controls

    private let nameLabel = NSTextField(labelWithString: "No shader loaded")
    private let pathLabel = NSTextField(labelWithString: "Choose a .metal file to begin")
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let squareToggle = NSButton(checkboxWithTitle: "Keep square", target: nil, action: nil)
    private let drawableLabel = NSTextField(labelWithString: "—")
    private let scalePopup = NSPopUpButton()
    private let fpsLabel = NSTextField(labelWithString: "—")
    private let pauseButton = NSButton()
    private let reloadButton = NSButton()
    private let autoReloadToggle = NSButton(checkboxWithTitle: "Auto-reload on save", target: nil, action: nil)
    private let statusDot = StatusDot()
    private let statusLabel = NSTextField(labelWithString: "Idle")
    private let logView = NSTextView()

    private static let scales: [(String, CGFloat)] = [
        ("100% — native", 1.0),
        ("75%", 0.75),
        ("50%", 0.5),
        ("33%", 1.0 / 3.0),
        ("25%", 0.25)
    ]

    private static let contentWidth: CGFloat = 396

    // MARK: Init

    init(device: MTLDevice) {
        self.device = device
        self.compiler = ShaderCompiler(device: device, pixelFormat: ShaderView.pixelFormat)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Metal Shader Viewer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true

        super.init(window: window)

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        let stack = makeStack()
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        window.contentView = background
        window.setContentSize(background.fittingSize)
        window.center()

        syncSizeFields()
        showFPSPlaceholder()
        updateDrawableLabel()
        updateEnabledState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    private func makeStack() -> NSStackView {
        let stack = NSStackView(views: [
            header(),
            sectionTitle("Shader"),
            shaderSection(),
            separator(),
            sectionTitle("Output"),
            outputSection(),
            separator(),
            sectionTitle("Playback"),
            playbackSection(),
            separator(),
            sectionTitle("Log"),
            logSection(),
            statusRow()
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 42, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: stack.views[0])
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 44).isActive = true
        return stack
    }

    private func header() -> NSView {
        let glyph = NSImageView(image: NSImage(
            systemSymbolName: "cube.transparent",
            accessibilityDescription: nil) ?? NSImage())
        glyph.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glyph.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Metal Shader Viewer")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let row = NSStackView(views: [glyph, title])
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func shaderSection() -> NSView {
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        for label in [nameLabel, pathLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }

        let choose = button("Choose Shader…", symbol: "folder", action: #selector(chooseShader))
        choose.keyEquivalent = "\r"
        configure(reloadButton, "Reload", symbol: "arrow.clockwise", action: #selector(reload))

        autoReloadToggle.target = self
        autoReloadToggle.action = #selector(toggleAutoReload)
        autoReloadToggle.state = .on
        autoReloadToggle.font = .systemFont(ofSize: 12)
        autoReloadToggle.toolTip = "Recompile automatically whenever the shader file is written."


        let buttons = NSStackView(views: [choose, reloadButton])
        buttons.spacing = 8

        let column = NSStackView(views: [nameLabel, pathLabel, buttons, autoReloadToggle])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(2, after: nameLabel)
        return column
    }

    private func outputSection() -> NSView {
        for field in [widthField, heightField] {
            field.formatter = Self.pixelFormatter()
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            field.target = self
            field.action = #selector(sizeFieldCommitted)
            field.widthAnchor.constraint(equalToConstant: 62).isActive = true
        }

        squareToggle.target = self
        squareToggle.action = #selector(toggleSquare)
        squareToggle.state = .on
        squareToggle.font = .systemFont(ofSize: 12)
        squareToggle.toolTip = "Lock the output window to a 1:1 canvas."
        widthField.toolTip = "Canvas size in points. Multiply by the display scale for pixels."
        scalePopup.toolTip = "Render below the canvas size and upscale. The cheapest way to buy frame rate."


        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let px = NSTextField(labelWithString: "pt")
        px.textColor = .secondaryLabelColor
        px.font = .systemFont(ofSize: 11)

        let sizeRow = NSStackView(views: [
            fieldLabel("Canvas"), widthField, times, heightField, px, squareToggle
        ])
        sizeRow.spacing = 6
        sizeRow.alignment = .centerY

        scalePopup.addItems(withTitles: Self.scales.map(\.0))
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged)
        scalePopup.font = .systemFont(ofSize: 12)

        let scaleRow = NSStackView(views: [fieldLabel("Render at"), scalePopup])
        scaleRow.spacing = 6
        scaleRow.alignment = .centerY

        drawableLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        drawableLabel.textColor = .secondaryLabelColor

        let column = NSStackView(views: [sizeRow, scaleRow, drawableLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        return column
    }

    private func playbackSection() -> NSView {
        configure(pauseButton, "Pause", symbol: "pause.fill", action: #selector(togglePause))

        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        let fpsUnit = NSTextField(labelWithString: "fps")
        fpsUnit.font = .systemFont(ofSize: 11)
        fpsUnit.textColor = .secondaryLabelColor

        let fpsGroup = NSStackView(views: [fpsLabel, fpsUnit])
        fpsGroup.spacing = 4
        fpsGroup.alignment = .firstBaseline

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [pauseButton, spacer, fpsGroup])
        row.spacing = 10
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func logSection() -> NSView {
        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 100),
            scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        return scroll
    }

    private func statusRow() -> NSView {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [statusDot, statusLabel])
        row.spacing = 7
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    // MARK: Small builders

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return box
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, title, symbol: symbol, action: action)
        return button
    }

    private func configure(_ button: NSButton, _ title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = action
    }

    private static func pixelFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 64
        formatter.maximum = 8192
        return formatter
    }

    // MARK: Actions

    @objc func chooseShader() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Metal shader file"
        if let metal = UTType(filenameExtension: "metal") {
            panel.allowedContentTypes = [metal, .plainText, .sourceCode]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    @objc private func reload() {
        guard let shaderURL else { return }
        load(url: shaderURL, resetTime: false)
    }

    @objc private func togglePause() {
        guard let view = renderWindow?.shaderView else { return }
        view.isPaused.toggle()
        configure(pauseButton,
                  view.isPaused ? "Resume" : "Pause",
                  symbol: view.isPaused ? "play.fill" : "pause.fill",
                  action: #selector(togglePause))
        if view.isPaused {
            status("Paused.", .idle)
            showFPSPlaceholder()
        } else {
            status("Running \(shaderURL?.lastPathComponent ?? "shader").", .running)
        }
    }

    @objc private func toggleAutoReload() {
        autoReloadToggle.state == .on ? startWatching() : fileWatcher?.stop()
    }

    @objc private func scaleChanged() {
        renderWindow?.shaderView.resolutionScale = currentScale
        updateDrawableLabel()
    }

    @objc private func toggleSquare() {
        isSquareLocked = squareToggle.state == .on
        renderWindow?.setSquareLocked(isSquareLocked)
        if isSquareLocked {
            canvasSize.height = canvasSize.width
            applyCanvasSize()
        }
    }

    @objc private func sizeFieldCommitted() {
        commitSizeFields()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitSizeFields()
    }

    private func commitSizeFields() {
        // The height field is disabled while square is locked, so width drives both.
        let width = clampPixels(widthField.doubleValue)
        let height = isSquareLocked ? width : clampPixels(heightField.doubleValue)
        canvasSize = NSSize(width: width, height: height)
        syncSizeFields()
        applyCanvasSize()
    }

    private func clampPixels(_ value: Double) -> Double {
        value.isFinite ? min(8192, max(64, value.rounded())) : 800
    }

    private func applyCanvasSize() {
        renderWindow?.setContentSize(canvasSize)
        updateDrawableLabel()
    }

    private func syncSizeFields() {
        widthField.stringValue = String(Int(canvasSize.width))
        heightField.stringValue = String(Int(canvasSize.height))
        heightField.isEnabled = !isSquareLocked
    }

    private var currentScale: CGFloat {
        Self.scales[scalePopup.indexOfSelectedItem].1
    }

    private func updateDrawableLabel() {
        let backing = renderWindow?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((canvasSize.width * backing * currentScale).rounded())
        let height = Int((canvasSize.height * backing * currentScale).rounded())
        drawableLabel.stringValue =
            "Drawable \(width) × \(height) px  ·  @\(Int(backing))x display"
    }

    // MARK: Loading

    func load(url: URL, resetTime: Bool = true) {
        shaderURL = url
        nameLabel.stringValue = url.lastPathComponent
        pathLabel.stringValue = url.deletingLastPathComponent().path
        status("Compiling \(url.lastPathComponent)…", .working)

        let source: String
        do {
            source = try compiler.loadSource(at: url)
        } catch {
            report(error)
            return
        }

        compiler.makePipeline(source: source) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pipeline):
                self.present(pipeline: pipeline, url: url, resetTime: resetTime)
            case .failure(let error):
                self.report(error)
            }
        }

        if autoReloadToggle.state == .on { startWatching() }
        updateEnabledState()
    }

    private func present(pipeline: MTLRenderPipelineState, url: URL, resetTime: Bool) {
        let controller = renderWindow ?? makeRenderWindow()
        if resetTime { controller.shaderView.resetTime() }
        controller.shaderView.resolutionScale = currentScale
        controller.shaderView.setPipeline(pipeline)
        controller.shaderView.isPaused = false
        configure(pauseButton, "Pause", symbol: "pause.fill", action: #selector(togglePause))
        controller.setSquareLocked(isSquareLocked)
        controller.setContentSize(canvasSize)
        controller.show(title: url.lastPathComponent)
        status("Running \(url.lastPathComponent).", .running)
        log("Compiled \(url.lastPathComponent) successfully.")
        updateDrawableLabel()
        updateEnabledState()
    }

    private func makeRenderWindow() -> RenderWindowController {
        let controller = RenderWindowController(device: device)
        controller.shaderView.onFPS = { [weak self] fps in
            self?.fpsLabel.textColor = .labelColor
            self?.fpsLabel.stringValue = String(format: "%.0f", fps)
        }
        controller.onResize = { [weak self] size in
            guard let self else { return }
            self.canvasSize = NSSize(width: size.width.rounded(), height: size.height.rounded())
            self.syncSizeFields()
            self.updateDrawableLabel()
        }
        controller.onClose = { [weak self] in
            self?.renderWindow = nil
            self?.showFPSPlaceholder()
            self?.status("Output window closed.", .idle)
            self?.updateEnabledState()
        }
        renderWindow = controller
        return controller
    }

    // MARK: File watching

    private func startWatching() {
        fileWatcher?.stop()
        guard let shaderURL else { return }
        fileWatcher = FileWatcher(url: shaderURL) { [weak self] in
            self?.reload()
        }
    }

    // MARK: Status

    private func updateEnabledState() {
        reloadButton.isEnabled = shaderURL != nil
        pauseButton.isEnabled = renderWindow != nil
    }

    private func showFPSPlaceholder() {
        fpsLabel.textColor = .tertiaryLabelColor
        fpsLabel.stringValue = "—"
    }

    private func status(_ message: String, _ state: StatusDot.State) {
        statusLabel.stringValue = message
        statusDot.state = state
    }

    private func report(_ error: Error) {
        status("Compilation failed.", .error)
        log(error.localizedDescription, isError: true)
        NSSound.beep()
    }

    private func log(_ message: String, isError: Bool = false) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logView.textColor = isError ? .systemRed : .secondaryLabelColor
        logView.string = "\(stamp)\n\(message)\n"
        logView.scrollToEndOfDocument(nil)
    }
}

/// A small coloured dot summarising what the app is doing.
final class StatusDot: NSView {
    enum State { case idle, working, running, error }

    var state: State = .idle { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch state {
        case .idle:    color = .tertiaryLabelColor
        case .working: color = .systemOrange
        case .running: color = .systemGreen
        case .error:   color = .systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Watches a single file and fires when it changes on disk.
///
/// Many editors save by writing a new file and renaming it over the old one, which
/// invalidates the descriptor, so the watcher re-arms itself after those events.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let handler: () -> Void

    init(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        arm()
    }

    private func arm() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.rename) || events.contains(.delete) {
                source.cancel()
                // Give the editor a moment to finish putting the new file in place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.arm()
                    self.handler()
                }
            } else {
                self.handler()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
