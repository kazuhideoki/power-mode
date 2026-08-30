import AppKit
import CoreGraphics
import Darwin

private let pseudoScreenSaverBrightness: Float = 0.01
private let externalDisplayDimBrightness = 1
private let externalDisplayActiveBrightness = 50

private final class DisplayBrightnessController {
    private typealias DisplayServicesGetBrightness = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias DisplayServicesSetBrightness = @convention(c) (
        CGDirectDisplayID,
        Float
    ) -> Int32

    private enum SavedBrightness {
        case displayServices(Float)
        case m1ddc(selector: String, brightness: Int)
    }

    private let stateFile: String?
    private let displayServicesHandle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )
    private lazy var displayServicesGetBrightness: DisplayServicesGetBrightness? =
        loadSymbol(
            "DisplayServicesGetBrightness",
            from: displayServicesHandle,
            as: DisplayServicesGetBrightness.self
        )
    private lazy var displayServicesSetBrightness: DisplayServicesSetBrightness? =
        loadSymbol(
            "DisplayServicesSetBrightness",
            from: displayServicesHandle,
            as: DisplayServicesSetBrightness.self
        )
    private lazy var m1ddcPath: String? = {
        let override = ProcessInfo.processInfo.environment["POWER_MODE_M1DDC"]
        return [
            override,
            "/opt/homebrew/bin/m1ddc",
            "/usr/local/bin/m1ddc",
        ].compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()
    private var savedBrightness: [CGDirectDisplayID: SavedBrightness] = [:]

    init(stateFile: String?) {
        self.stateFile = stateFile
    }

    deinit {
        if let displayServicesHandle {
            dlclose(displayServicesHandle)
        }
    }

    func dim(_ screens: [NSScreen]) {
        restore()

        for screen in screens {
            guard let displayID = displayID(for: screen) else { continue }

            if CGDisplayIsBuiltin(displayID) != 0 {
                if let brightness = captureAndDimBuiltinDisplay(displayID) {
                    savedBrightness[displayID] = brightness
                }
                continue
            }

            guard let selector = m1ddcSelector(for: displayID) else { continue }
            savedBrightness[displayID] = .m1ddc(
                selector: selector,
                brightness: externalDisplayActiveBrightness
            )
            persistExternalRestoreState()
            if !setM1ddcBrightness(
                externalDisplayDimBrightness,
                selector: selector
            ) {
                savedBrightness.removeValue(forKey: displayID)
                persistExternalRestoreState()
            }
        }
    }

    func restore() {
        var remaining: [CGDirectDisplayID: SavedBrightness] = [:]

        for (displayID, brightness) in savedBrightness {
            if !restore(brightness, for: displayID) {
                remaining[displayID] = brightness
            }
        }

        savedBrightness = remaining
        persistExternalRestoreState()
    }

    private func captureAndDimBuiltinDisplay(
        _ displayID: CGDirectDisplayID
    ) -> SavedBrightness? {
        if let getBrightness = displayServicesGetBrightness,
           let setBrightness = displayServicesSetBrightness
        {
            var currentBrightness: Float = 0
            if getBrightness(displayID, &currentBrightness) == 0,
               isValid(currentBrightness),
               setBrightness(
                   displayID,
                   min(currentBrightness, pseudoScreenSaverBrightness)
               ) == 0
            {
                return .displayServices(currentBrightness)
            }
        }

        return nil
    }

    private func restore(
        _ brightness: SavedBrightness,
        for displayID: CGDirectDisplayID
    ) -> Bool {
        switch brightness {
        case let .displayServices(value):
            return displayServicesSetBrightness?(displayID, value) == 0
        case let .m1ddc(selector, value):
            return setM1ddcBrightness(value, selector: selector)
        }
    }

    private func setM1ddcBrightness(
        _ brightness: Int,
        selector: String
    ) -> Bool {
        runM1ddc(
            selector: selector,
            arguments: ["set", "luminance", String(brightness)]
        )
    }

    private func runM1ddc(
        selector: String,
        arguments: [String]
    ) -> Bool {
        guard let m1ddcPath else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: m1ddcPath)
        process.arguments = ["display", selector] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        return process.terminationStatus == 0
    }

    private func persistExternalRestoreState() {
        guard let stateFile else { return }

        let lines = savedBrightness.compactMap { _, brightness -> String? in
            guard case let .m1ddc(selector, value) = brightness else {
                return nil
            }
            return "\(selector) \(value)"
        }.sorted()

        if lines.isEmpty {
            try? FileManager.default.removeItem(atPath: stateFile)
            return
        }

        try? (lines.joined(separator: "\n") + "\n").write(
            toFile: stateFile,
            atomically: true,
            encoding: .utf8
        )
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func m1ddcSelector(for displayID: CGDirectDisplayID) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        let uuidString = CFUUIDCreateString(nil, uuid) as String
        return "uuid=\(uuidString)"
    }

    private func isValid(_ brightness: Float) -> Bool {
        brightness.isFinite && (0 ... 1).contains(brightness)
    }

    private func loadSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type
    ) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

private struct Configuration {
    let idleSeconds: TimeInterval
    let stopFile: String?
    let brightnessStateFile: String?

    init(arguments: [String]) {
        var idleSeconds: TimeInterval = 300
        var stopFile: String?
        var brightnessStateFile: String?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--idle-seconds" where index + 1 < arguments.count:
                if let value = TimeInterval(arguments[index + 1]), value > 0 {
                    idleSeconds = value
                }
                index += 2
            case "--stop-file" where index + 1 < arguments.count:
                stopFile = arguments[index + 1]
                index += 2
            case "--brightness-state-file" where index + 1 < arguments.count:
                brightnessStateFile = arguments[index + 1]
                index += 2
            default:
                index += 1
            }
        }

        self.idleSeconds = idleSeconds
        self.stopFile = stopFile
        self.brightnessStateFile = brightnessStateFile
    }
}

@MainActor
private final class BouncingClockView: NSView {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var position = CGPoint(x: 80, y: 80)
    private var velocity = CGVector(dx: 92, dy: 67)
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var animationTimer: Timer?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        chooseInitialPosition()
        startAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: backgroundWhiteLevel(), alpha: 1).setFill()
        dirtyRect.fill()
        clockString().draw(at: position, withAttributes: textAttributes)
    }

    private func backgroundWhiteLevel() -> CGFloat {
        let cycle = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 300)
        guard cycle < 12 else { return 0 }
        return CGFloat(sin(.pi * cycle / 12) * 0.008)
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .light),
            .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1),
        ]
    }

    private func clockString() -> NSString {
        formatter.string(from: Date()) as NSString
    }

    private func clockSize() -> CGSize {
        clockString().size(withAttributes: textAttributes)
    }

    private func chooseInitialPosition() {
        let size = clockSize()
        let maximumX = max(0, bounds.width - size.width)
        let maximumY = max(0, bounds.height - size.height)
        position = CGPoint(
            x: CGFloat.random(in: 0 ... maximumX),
            y: CGFloat.random(in: 0 ... maximumY)
        )
    }

    private func startAnimation() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func advanceFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(now - lastFrameTime, 0.1)
        lastFrameTime = now

        position.x += velocity.dx * elapsed
        position.y += velocity.dy * elapsed

        let size = clockSize()
        let maximumX = max(0, bounds.width - size.width)
        let maximumY = max(0, bounds.height - size.height)
        var bounced = false

        if position.x <= 0 || position.x >= maximumX {
            position.x = min(max(0, position.x), maximumX)
            velocity.dx *= -1
            bounced = true
        }
        if position.y <= 0 || position.y >= maximumY {
            position.y = min(max(0, position.y), maximumY)
            velocity.dy *= -1
            bounced = true
        }

        if bounced {
            varyDirectionSlightly()
        }

        needsDisplay = true
    }

    private func varyDirectionSlightly() {
        let speed = max(80, hypot(velocity.dx, velocity.dy))
        let jitter = CGFloat.random(in: -0.16 ... 0.16)
        let cosine = cos(jitter)
        let sine = sin(jitter)
        let rotatedX = velocity.dx * cosine - velocity.dy * sine
        let rotatedY = velocity.dx * sine + velocity.dy * cosine
        let rotatedSpeed = max(1, hypot(rotatedX, rotatedY))

        velocity = CGVector(
            dx: rotatedX / rotatedSpeed * speed,
            dy: rotatedY / rotatedSpeed * speed
        )
    }
}

@MainActor
private final class PseudoScreenSaverDelegate: NSObject, NSApplicationDelegate {
    private let configuration: Configuration
    private var windows: [NSWindow] = []
    private var idleTimer: Timer?
    private var stopTimer: DispatchSourceTimer?
    private var isVisible = false
    private var isCursorHidden = false
    private let brightnessController: DisplayBrightnessController

    init(configuration: Configuration) {
        self.configuration = configuration
        brightnessController = DisplayBrightnessController(
            stateFile: configuration.brightnessStateFile
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateVisibility()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        startStopMonitor()
        updateVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleTimer?.invalidate()
        stopTimer?.cancel()
        brightnessController.restore()
        showCursor()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenParametersChanged() {
        guard isVisible else { return }
        hideOverlay()
        showOverlay()
    }

    private func startStopMonitor() {
        guard let stopFile = configuration.stopFile else { return }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler {
            if FileManager.default.fileExists(atPath: stopFile) {
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
        timer.resume()
        stopTimer = timer
    }

    private func updateVisibility() {
        if let stopFile = configuration.stopFile,
           FileManager.default.fileExists(atPath: stopFile)
        {
            NSApp.terminate(nil)
            return
        }

        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )

        if isVisible {
            if idleSeconds < 1.5 {
                hideOverlay()
            }
        } else if idleSeconds >= configuration.idleSeconds {
            showOverlay()
        }
    }

    private func showOverlay() {
        guard !isVisible else { return }

        windows = NSScreen.screens.map { screen in
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.becomesKeyOnlyIfNeeded = true
            window.isFloatingPanel = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary,
            ]
            window.contentView = BouncingClockView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            window.orderFrontRegardless()
            return window
        }

        brightnessController.dim(NSScreen.screens)
        isVisible = true
        hideCursor()
    }

    private func hideOverlay() {
        brightnessController.restore()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        showCursor()
        isVisible = false
    }

    private func hideCursor() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    private func showCursor() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }
}

@main
private struct PseudoScreenSaverMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = PseudoScreenSaverDelegate(
            configuration: Configuration(arguments: CommandLine.arguments)
        )
        app.delegate = delegate
        app.run()
    }
}
