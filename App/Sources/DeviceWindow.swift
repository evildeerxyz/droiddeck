import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DroidDeckKit

/// The live device window: the real emulator display streamed over gRPC, with controls.
struct DeviceWindowView: View {
    @Environment(AppModel.self) private var model
    let deviceID: String
    @State private var editingKeymap = false
    @State private var installing: [URL] = []
    @State private var flash = false
    @State private var uploadBanner: UploadBanner?
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let device = model.devices.device(named: deviceID) {
                content(device)
                    .navigationTitle(device.displayName)
                    .navigationSubtitle(device.state.label)
            } else {
                EmptyStateView(title: "Device Not Found", systemImage: "iphone.slash", message: "\(deviceID) is no longer in the device library.")
            }
        }
        .errorAlert(model)
    }

    @ViewBuilder
    private func content(_ device: ManagedDevice) -> some View {
        if device.state.isRunning, device.capabilities.supports(.embeddedDisplay), let instance = device.instance, instance.displayMode != .externalWindow {
            HStack(spacing: 0) {
                LiveDisplay(device: device, editingKeymap: $editingKeymap)
                    .padding(16)
                    .overlay { if flash { Color.white.opacity(0.6).allowsHitTesting(false) } }
                    .overlay { if dropTargeted { dropHint(device) } }
                    .overlay(alignment: .bottom) { if let uploadBanner { banner(uploadBanner) } }
                    .dropDestination(for: URL.self) { urls, _ in
                        handleDrop(urls, device: device)
                    } isTargeted: { dropTargeted = $0 }
                Divider()
                ControlRail(device: device, onScreenshot: screenshot,
                            onAddFiles: { _ = handleDrop($0, device: device) })
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: Binding(get: { !installing.isEmpty }, set: { if !$0 { installing = [] } })) {
                if let serial = device.instance?.adbSerial {
                    InstallAPKSheet(serial: serial, files: installing) { installing = [] }.environment(model)
                }
            }
        } else if device.state.isRunning, let instance = device.instance {
            VStack(spacing: 16) {
                EmptyStateView(title: instance.displayMode == .externalWindow ? "Shown in the Emulator Window" : "No Display",
                               systemImage: "macwindow",
                               message: instance.hasControlChannel
                                ? "This device was started in \(instance.displayMode.displayName.lowercased()) mode. Restart it with \"In DroidDeck\" display to show it here."
                                : device.capabilities.reason(.embeddedDisplay) ?? "")
                if instance.displayMode == .externalWindow {
                    Button("Bring Emulator Window to Front") { NSRunningApplication(processIdentifier: instance.pid)?.activate() }
                }
            }
        } else if device.state.isBusy {
            VStack(spacing: 12) {
                ProgressView()
                Text(device.state.label).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(title: "\(device.displayName) Is Stopped", systemImage: "power",
                           message: device.capabilities.supports(.startDevice) ? "Start the device to see its screen." : (device.capabilities.reason(.startDevice) ?? ""),
                           action: device.capabilities.supports(.startDevice) ? ("Start", { model.devices.start(device.id) }) : nil)
        }
    }

    /// APKs are offered for installation; everything else (files and folders) is copied to the device.
    private func handleDrop(_ urls: [URL], device: ManagedDevice) -> Bool {
        let isAPK: (URL) -> Bool = { ["apk", "xapk"].contains($0.pathExtension.lowercased()) }
        let apks = urls.filter(isAPK)
        let files = urls.filter { !isAPK($0) }
        if !apks.isEmpty, device.capabilities.supports(.apkInstall) { installing = apks }
        if !files.isEmpty, device.capabilities.supports(.fileTransfer) { upload(files, device: device) }
        return !urls.isEmpty
    }

    /// Copies files from the Mac and says where they landed, without leaving the window.
    private func upload(_ urls: [URL], device: ManagedDevice) {
        let started = UploadBanner(text: "Uploading to \(device.displayName)…", state: .working)
        withAnimation(.easeOut(duration: 0.2)) { uploadBanner = started }
        Task {
            var done = started
            do {
                done.text = try await model.devices.uploadFiles(urls, to: device.id).summary
                done.state = .succeeded
            } catch {
                done.text = (error as? DroidDeckError)?.message ?? error.localizedDescription
                done.state = .failed
            }
            if uploadBanner == nil || uploadBanner?.id == started.id {
                withAnimation(.easeOut(duration: 0.2)) { uploadBanner = done }
            }
            try? await Task.sleep(for: .seconds(done.state == .failed ? 8 : 6))
            if uploadBanner?.id == done.id { withAnimation(.easeIn(duration: 0.3)) { uploadBanner = nil } }
        }
    }

    private func banner(_ banner: UploadBanner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch banner.state {
            case .working: ProgressView().controlSize(.small)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .frame(maxWidth: 380)
        .padding(.bottom, 28)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func dropHint(_ device: ManagedDevice) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Drop to copy to \(device.displayName)", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    private func screenshot() {
        guard let device = model.devices.device(named: deviceID), let adb = model.devices.adb, let serial = device.instance?.adbSerial else { return }
        let folder = model.devices.preferences.screenshotDirectory
        let name = "\(device.displayName) \(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "."))).png"
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeIn(duration: 0.25)) { flash = false }
        }
        model.attempt {
            let png = try await adb.screenshotPNG(serial)
            let url = folder.appending(path: name)
            try SafeFileOperations.writeAtomically(png, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// The display area: the SDK's official skin (artwork + display mask, rotated with the device)
/// when available, a drawn bezel otherwise.
struct LiveDisplay: View {
    @Environment(AppModel.self) private var model
    let device: ManagedDevice
    @Binding var editingKeymap: Bool
    @State private var rotation: EmulatorSkinRotation = .portrait
    @State private var skin: SkinLayout?
    @State private var skinImage: NSImage?
    @State private var maskImage: NSImage?
    @State private var status = "Connecting to display…"
    @State private var connected = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if device.metadata.showFrame, let skin, let skinImage {
                    skinned(skin: skin, back: skinImage, mask: maskImage, in: geo.size)
                } else if device.metadata.showFrame {
                    bezel(in: geo.size)
                } else {
                    screen.aspectRatio(aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if !connected {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.25), value: rotation)
        }
        .frame(minWidth: 260, minHeight: 300)
        .task(id: device.id) { loadSkin() }
    }

    private var aspect: CGFloat {
        let c = device.device.configuration
        let w = CGFloat(c.screenWidth), h = CGFloat(c.screenHeight)
        return rotation.quarterTurns % 2 == 0 ? w / h : h / w
    }

    private var screen: some View {
        EmulatorScreen(device: device, editingKeymap: editingKeymap,
                       onRotation: { rotation = $0 },
                       onStatus: { text, ok in status = text; connected = ok })
            .accessibilityLabel("\(device.displayName) screen")
    }

    private func skinned(skin: SkinLayout, back: NSImage, mask: NSImage?, in size: CGSize) -> some View {
        SkinnedFrame(skin: skin, back: back, mask: mask, rotation: rotation, available: size) { screen }
    }

    /// Bezel drawn when the SDK has no skin for this profile.
    private func bezel(in size: CGSize) -> some View {
        let inset: CGFloat = 12
        let screenAspect = aspect
        let maxW = size.width - inset * 2, maxH = size.height - inset * 2
        let screenW = min(maxW, maxH * screenAspect), screenH = screenW / screenAspect
        let radius = min(screenW, screenH) * 0.07
        return ZStack {
            RoundedRectangle(cornerRadius: radius + inset, style: .continuous)
                .fill(Color(white: 0.08))
                .overlay(RoundedRectangle(cornerRadius: radius + inset, style: .continuous).strokeBorder(Color(white: 0.3), lineWidth: 1.5))
                .frame(width: screenW + inset * 2, height: screenH + inset * 2)
            screen
                .frame(width: screenW, height: screenH)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private func loadSkin() {
        guard let sdk = model.devices.sdk else { return }
        let name = device.device.configuration.skinName ?? device.device.configuration.profileID
        guard let name, let dir = SkinLayout.directory(named: name, sdkRoot: sdk.root, systemImagePath: device.device.image?.installPath),
              let layout = SkinLayout.load(directory: dir), let back = layout.backgroundImage else { return }
        skin = layout
        skinImage = NSImage(contentsOf: back)
        maskImage = layout.maskImage.flatMap { NSImage(contentsOf: $0) }
    }
}

/// The official skin around any screen content, for every rotation. Shared by the live window
/// and the offscreen render check used in UI tests.
struct SkinnedFrame<Screen: View>: View {
    let skin: SkinLayout
    let back: NSImage
    let mask: NSImage?
    let rotation: EmulatorSkinRotation
    let available: CGSize
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        let g = DeviceFrameGeometry(
            frameSize: CGSize(width: skin.frameWidth, height: skin.frameHeight),
            display: CGRect(x: skin.displayX, y: skin.displayY, width: skin.displayWidth, height: skin.displayHeight),
            rotation: rotation)
        let s = g.scale(toFit: available)
        let c = g.containerSize
        let r = g.rotatedDisplay
        let angle = Angle.degrees(g.artworkRotationDegrees)
        // Composited like the emulator: the display at the bottom, hidden wherever the skin mask
        // is opaque (rounded corners, camera cut-out), with the frame artwork drawn on top.
        // back.webp is transparent over the screen and draws the bezel and camera lens.
        ZStack(alignment: .topLeading) {
            screen()
                .frame(width: r.width * s, height: r.height * s)
                .mask {
                    if let mask {
                        ZStack {
                            Rectangle().fill(.black)
                            Image(nsImage: mask).resizable().interpolation(.high)
                                .frame(width: g.display.width * s, height: g.display.height * s)
                                .rotationEffect(angle)
                                .frame(width: r.width * s, height: r.height * s)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    } else {
                        RoundedRectangle(cornerRadius: CGFloat(skin.displayCornerRadius) * s, style: .continuous)
                    }
                }
                // The layout's corner_radius clips the display too; the mask alone leaves the
                // extreme corner pixels uncovered (visible as small squares outside the body).
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(skin.displayCornerRadius) * s, style: .continuous))
                .offset(x: r.minX * s, y: r.minY * s)
            Image(nsImage: back).resizable().interpolation(.high)
                .frame(width: g.frameSize.width * s, height: g.frameSize.height * s)
                .rotationEffect(angle)
                .frame(width: c.width * s, height: c.height * s)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: c.width * s, height: c.height * s)
    }
}

// MARK: - Screen view

struct EmulatorScreen: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let device: ManagedDevice
    let editingKeymap: Bool
    let onRotation: (EmulatorSkinRotation) -> Void
    let onStatus: (String, Bool) -> Void

    func makeNSView(context: Context) -> EmulatorScreenNSView {
        let view = EmulatorScreenNSView()
        view.deviceSize = (device.device.configuration.screenWidth, device.device.configuration.screenHeight)
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ view: EmulatorScreenNSView, context: Context) {
        view.keyBindings = device.metadata.keyBindings
        view.keyMappingEnabled = device.metadata.keyMappingEnabled
        view.editingKeymap = editingKeymap
        view.onAddBinding = { x, y, key in
            model.devices.updateMetadata(device.id) { $0.keyBindings.append(KeyBinding(key: key, kind: .tap, x: x, y: y)) }
        }
        context.coordinator.onRotation = onRotation
        context.coordinator.onStatus = onStatus
    }

    static func dismantleNSView(_ view: EmulatorScreenNSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, deviceID: device.id) }

    @MainActor
    final class Coordinator {
        let model: AppModel
        let deviceID: String
        weak var view: EmulatorScreenNSView?
        var onRotation: ((EmulatorSkinRotation) -> Void)?
        var onStatus: ((String, Bool) -> Void)?
        private var session: DisplaySession?
        private var streamTask: Task<Void, Never>?
        private var requestedSize: CGSize = .zero
        private var shownBefore = false

        init(model: AppModel, deviceID: String) {
            self.model = model
            self.deviceID = deviceID
        }

        func attach(view: EmulatorScreenNSView) {
            self.view = view
            view.onPixelSizeChange = { [weak self] size in self?.restart(for: size) }
            // Stop pulling frames while the window is hidden, minimized or fully covered, and tell the
            // device manager so a device nobody is looking at can sleep its display.
            view.onVisibilityChange = { [weak self] visible in
                guard let self else { return }
                self.model.devices.setOnScreen(self.deviceID, visible, justOpened: visible && !self.shownBefore)
                if visible { self.shownBefore = true }
                if visible {
                    self.restart(for: view.pixelSize, force: true)
                } else {
                    self.pauseStream()
                }
            }
            Task {
                guard let controller = await model.devices.controller(for: deviceID) else {
                    onStatus?("The display channel is unavailable.", false)
                    return
                }
                session = DisplaySession(controller: controller)
                view.input = InputPipeline(controller: controller)
                restart(for: view.pixelSize)
            }
        }

        /// Restarts the stream when the view's pixel size changes noticeably.
        func restart(for size: CGSize, force: Bool = false) {
            guard let session, size.width > 10, size.height > 10 else { return }
            guard view?.isVisibleOnScreen ?? true else { return }
            if !force && abs(size.width - requestedSize.width) < 24 && abs(size.height - requestedSize.height) < 24 && streamTask != nil { return }
            requestedSize = size
            streamTask?.cancel()
            streamTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150)) // debounce live resizing
                guard !Task.isCancelled else { return }
                let frames = await session.frames(maxWidth: Int(size.width), maxHeight: Int(size.height))
                var lastRotation: EmulatorSkinRotation?
                for await result in frames {
                    guard let self, !Task.isCancelled else { break }
                    switch result {
                    case .success(let frame):
                        self.view?.show(frame)
                        if frame.rotation != lastRotation {
                            lastRotation = frame.rotation
                            self.onRotation?(frame.rotation)
                        }
                        self.onStatus?("", true)
                    case .failure(let error):
                        self.onStatus?(error.message, false)
                    }
                }
            }
        }

        func pauseStream() {
            streamTask?.cancel()
            streamTask = nil
            if let session { Task { await session.cancel() } }
        }

        func stop() {
            pauseStream()
            model.devices.setOnScreen(deviceID, false)
        }
    }
}

/// Draws frames in a CALayer and turns mouse, trackpad and keyboard input into device input.
final class EmulatorScreenNSView: NSView {
    var input: InputPipeline?
    var deviceSize: (Int, Int) = (1080, 2400)
    var rotation: EmulatorSkinRotation = .portrait
    var keyBindings: [KeyBinding] = []
    var keyMappingEnabled = false
    var editingKeymap = false { didSet { needsDisplay = true; updateMarkers() } }
    var onAddBinding: ((Double, Double, String) -> Void)?
    var onPixelSizeChange: ((CGSize) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var occlusionObserver: NSObjectProtocol?

    var isVisibleOnScreen: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private let imageLayer = CALayer()
    private var markerLayers: [CALayer] = []
    private var imageAspect: CGFloat = 1080.0 / 2400.0
    private var pendingBindingPoint: (Double, Double)?
    private var pressedMappedKeys = Set<String>()
    private var scrollAnchor: CGPoint?
    private var scrollOffset: CGSize = .zero
    private var scrollEndWork: DispatchWorkItem?
    private var secondFingerDown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var pixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        updateMarkers()
        onPixelSizeChange?(pixelSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            onVisibilityChange?(false)
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onVisibilityChange?(self.isVisibleOnScreen)
            }
        }
        // No occlusion change is posted when the view appears inside an already-visible window
        // (e.g. the device finishes booting while its window is open), so report the current state.
        onVisibilityChange?(isVisibleOnScreen)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        onPixelSizeChange?(pixelSize)
    }

    func show(_ frame: DisplayFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame.image
        CATransaction.commit()
        imageAspect = CGFloat(frame.image.width) / CGFloat(max(1, frame.image.height))
        rotation = frame.rotation
    }

    /// The rectangle the aspect-fit image occupies.
    private var imageRect: CGRect {
        let viewAspect = bounds.width / max(1, bounds.height)
        if viewAspect > imageAspect {
            let w = bounds.height * imageAspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
        let h = bounds.width / imageAspect
        return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    private func normalized(_ point: CGPoint) -> (Double, Double) {
        let rect = imageRect
        return (Double((point.x - rect.minX) / rect.width), Double((point.y - rect.minY) / rect.height))
    }

    private func devicePoint(_ normalized: (Double, Double)) -> (x: Int32, y: Int32) {
        DisplayGeometry(deviceWidth: deviceSize.0, deviceHeight: deviceSize.1, rotation: rotation)
            .devicePoint(normalizedX: normalized.0, normalizedY: normalized.1)
    }

    private func touches(for event: NSEvent, pressure: Int32) -> [EmulatorTouch] {
        let location = convert(event.locationInWindow, from: nil)
        let n = normalized(location)
        let p = devicePoint(n)
        var touches = [EmulatorTouch(x: p.x, y: p.y, identifier: 1, pressure: pressure)]
        // Option-drag adds a second finger mirrored around the screen center (pinch/rotate).
        // A finger that went down is always lifted, even if Option was released mid-gesture.
        let wantsSecond = event.modifierFlags.contains(.option) && pressure > 0
        if wantsSecond || (secondFingerDown && pressure == 0) || (secondFingerDown && !wantsSecond) {
            let m = devicePoint((1 - n.0, 1 - n.1))
            let down = wantsSecond
            touches.append(EmulatorTouch(x: m.x, y: m.y, identifier: 2, pressure: down ? pressure : 0))
            secondFingerDown = down
        }
        return touches
    }

    private func send(_ event: EmulatorInputEvent) {
        guard let input else { return }
        Task { await input.send(event) }
    }

    // MARK: Mouse and trackpad

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if editingKeymap {
            pendingBindingPoint = normalized(convert(event.locationInWindow, from: nil))
            updateMarkers()
            return
        }
        send(.touch(touches(for: event, pressure: 1)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !editingKeymap else { return }
        send(.touch(touches(for: event, pressure: 1)))
    }

    override func mouseUp(with event: NSEvent) {
        guard !editingKeymap else { return }
        send(.touch(touches(for: event, pressure: 0)))
    }

    /// Scrolling becomes a one-finger drag that ends shortly after the wheel stops.
    override func scrollWheel(with event: NSEvent) {
        guard !editingKeymap else { return }
        var location = convert(event.locationInWindow, from: nil)
        if scrollAnchor == nil {
            // Android treats drags that start near the left/right edge as the Back gesture.
            // Start synthesized scroll drags well inside the screen so scrolling never navigates back.
            let rect = imageRect
            let margin = rect.width * 0.12
            location.x = min(max(location.x, rect.minX + margin), rect.maxX - margin)
            location.y = min(max(location.y, rect.minY + rect.height * 0.08), rect.maxY - rect.height * 0.08)
            scrollAnchor = location
            scrollOffset = .zero
            let p = devicePoint(normalized(location))
            send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: 7, pressure: 1)]))
        }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        scrollOffset.width += event.scrollingDeltaX * factor
        scrollOffset.height += event.scrollingDeltaY * factor
        let limit = imageRect.width * 0.3
        scrollOffset.width = min(max(scrollOffset.width, -limit), limit)
        let anchor = scrollAnchor!
        let current = CGPoint(x: anchor.x + scrollOffset.width, y: anchor.y + scrollOffset.height)
        let p = devicePoint(normalized(current))
        send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: 7, pressure: 1)]))
        scrollEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: 7, pressure: 0)]))
            self.scrollAnchor = nil
        }
        scrollEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Keyboard

    private static let specialKeys: [UInt16: String] = [
        36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "Escape",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if editingKeymap, let point = pendingBindingPoint, !key.isEmpty {
            onAddBinding?(point.0, point.1, key)
            pendingBindingPoint = nil
            updateMarkers()
            return
        }
        if keyMappingEnabled, handleMappedKey(key, down: true, isRepeat: event.isARepeat) { return }
        if let special = Self.specialKeys[event.keyCode] {
            send(.key(special, .keyPress))
        } else if let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            send(.text(text))
        }
    }

    override func keyUp(with event: NSEvent) {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if keyMappingEnabled { _ = handleMappedKey(key, down: false, isRepeat: false) }
    }

    /// Mapped keys become touches: taps press/release at a point; WASD drives a virtual joystick.
    private func handleMappedKey(_ key: String, down: Bool, isRepeat: Bool) -> Bool {
        let matches = keyBindings.filter { $0.key == key }
        guard !matches.isEmpty else { return false }
        if isRepeat { return true }
        if down { pressedMappedKeys.insert(key) } else { pressedMappedKeys.remove(key) }
        for binding in matches where binding.kind == .tap {
            let p = devicePoint((binding.x, binding.y))
            let id = Int32(20 + abs(binding.key.hashValue % 8))
            send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: id, pressure: down ? 1 : 0)]))
        }
        let stick = keyBindings.filter { $0.kind != .tap }
        if let center = stick.first, matches.contains(where: { $0.kind != .tap }) {
            var dx = 0.0, dy = 0.0
            for b in stick where pressedMappedKeys.contains(b.key) {
                switch b.kind {
                case .joystickUp: dy -= 1
                case .joystickDown: dy += 1
                case .joystickLeft: dx -= 1
                case .joystickRight: dx += 1
                case .tap: break
                }
            }
            let active = dx != 0 || dy != 0
            let length = max(1, sqrt(dx * dx + dy * dy))
            let aspect = Double(imageAspect)
            let p = devicePoint((center.x + dx / length * center.radius, center.y + dy / length * center.radius * aspect))
            send(.touch([EmulatorTouch(x: p.x, y: p.y, identifier: 30, pressure: active ? 1 : 0)]))
        }
        return true
    }

    // MARK: Key-map editing overlay

    private func updateMarkers() {
        markerLayers.forEach { $0.removeFromSuperlayer() }
        markerLayers = []
        guard editingKeymap || (keyMappingEnabled && false) else { return }
        let rect = imageRect
        var points: [(Double, Double, String)] = keyBindings.map { ($0.x, $0.y, $0.key == " " ? "␣" : $0.key.uppercased()) }
        if let pending = pendingBindingPoint { points.append((pending.0, pending.1, "?")) }
        for (x, y, label) in points {
            let marker = CATextLayer()
            marker.string = label
            marker.fontSize = 13
            marker.alignmentMode = .center
            marker.foregroundColor = NSColor.white.cgColor
            marker.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            marker.cornerRadius = 13
            marker.contentsScale = window?.backingScaleFactor ?? 2
            marker.frame = CGRect(x: rect.minX + CGFloat(x) * rect.width - 13, y: rect.minY + CGFloat(y) * rect.height - 13, width: 26, height: 26)
            layer?.addSublayer(marker)
            markerLayers.append(marker)
        }
    }
}

// MARK: - Control rail

/// The buttons beside the screen: Android's own keys, then a few things from your Mac.
struct ControlRail: View {
    @Environment(AppModel.self) private var model
    let device: ManagedDevice
    let onScreenshot: () -> Void
    /// Files and folders from the Mac: APKs are installed, everything else is copied to the device.
    let onAddFiles: ([URL]) -> Void

    var body: some View {
        let caps = device.capabilities
        VStack(spacing: 4) {
            railButton("Back", "arrow.uturn.backward", keycode: 4)
            railButton("Home", "circle", keycode: 3)
            railButton("Recent apps", "square.on.square", keycode: 187)
            Divider().padding(.vertical, 4)
            railButton("Volume up", "speaker.plus", keycode: 24)
            railButton("Volume down", "speaker.minus", keycode: 25)
            railButton("Power", "power", keycode: 26)
            iconButton("Rotate", "rotate.right", enabled: caps.supports(.rotation)) { rotate() }
            Divider().padding(.vertical, 4)
            iconButton("Screenshot", "camera", enabled: caps.supports(.screenshot), action: onScreenshot)
            iconButton("Add files from your Mac: photos and videos go to the Gallery, apps (APK) are installed, other files go to Downloads. You can also drag files onto the screen.",
                       "plus.rectangle.on.folder", enabled: caps.supports(.fileTransfer) || caps.supports(.apkInstall)) { chooseFiles() }
            iconButton("Paste text from your Mac into the focused field", "doc.on.clipboard", enabled: caps.supports(.clipboard)) { pasteClipboard() }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 52)
    }

    private func railButton(_ title: String, _ symbol: String, keycode: Int) -> some View {
        iconButton(title, symbol, enabled: device.capabilities.supports(.hardwareButtons)) {
            guard let adb = model.devices.adb, let serial = device.instance?.adbSerial else { return }
            Task { try? await adb.keyevent(serial, keycode) }
        }
    }

    private func iconButton(_ title: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private func rotate() {
        guard let adb = model.devices.adb, let serial = device.instance?.adbSerial else { return }
        model.attempt { _ = try await adb.emu(serial, ["rotate"]) }
    }

    private func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        model.devices.pasteToDevice(device.id, text: text)
    }

    /// A native open panel: it can pick whole folders as well as files.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders for \(device.displayName). Photos and videos appear in the Gallery, apps (APK) are installed, other files go to Files › Downloads."
        let add = onAddFiles
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, !panel.urls.isEmpty { add(panel.urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

private struct UploadBanner: Equatable {
    enum State { case working, succeeded, failed }
    let id = UUID()
    var text: String
    var state: State
}
