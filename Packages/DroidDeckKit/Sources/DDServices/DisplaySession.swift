import Foundation
import CoreGraphics
import DDCore
import DDPlatform
import DDEmulatorGRPC

/// One decoded frame of the device display, upright as the user sees it.
public struct DisplayFrame: @unchecked Sendable {
    public var image: CGImage
    public var rotation: EmulatorSkinRotation
    public var sequence: UInt32
}

/// Maps points between the displayed (rotated) image and the device's natural
/// touchscreen coordinates, which do not rotate with the UI.
public struct DisplayGeometry: Equatable, Sendable {
    /// Natural (portrait) panel size from hw.lcd.width/height.
    public var deviceWidth: Int
    public var deviceHeight: Int
    public var rotation: EmulatorSkinRotation

    public init(deviceWidth: Int, deviceHeight: Int, rotation: EmulatorSkinRotation) {
        self.deviceWidth = deviceWidth
        self.deviceHeight = deviceHeight
        self.rotation = rotation
    }

    /// Size of the upright image in device pixels.
    public var displayedSize: CGSize {
        rotation.quarterTurns % 2 == 0
            ? CGSize(width: deviceWidth, height: deviceHeight)
            : CGSize(width: deviceHeight, height: deviceWidth)
    }

    /// Converts a point normalized to the displayed image (0...1, origin top-left) to panel coordinates.
    /// Rotation follows Android's convention: ROTATION_90 means the device was turned counter-clockwise.
    public func devicePoint(normalizedX u: Double, normalizedY v: Double) -> (x: Int32, y: Int32) {
        let w = Double(deviceWidth), h = Double(deviceHeight)
        let u = min(max(u, 0), 1), v = min(max(v, 0), 1)
        let x: Double, y: Double
        switch rotation {
        case .portrait: (x, y) = (u * w, v * h)
        case .landscape: (x, y) = ((1 - v) * w, u * h)
        case .reversePortrait: (x, y) = ((1 - u) * w, (1 - v) * h)
        case .reverseLandscape: (x, y) = (v * w, (1 - u) * h)
        }
        return (Int32(min(max(x, 0), w - 1)), Int32(min(max(y, 0), h - 1)))
    }
}

/// Streams frames from the emulator's gRPC endpoint and decodes them into CGImages.
public actor DisplaySession {
    public enum State: Equatable, Sendable {
        case connecting
        case streaming
        case failed(String)
    }

    private let controller: EmulatorControllerClient
    private var streamTask: Task<Void, Never>?

    public init(controller: EmulatorControllerClient) {
        self.controller = controller
    }

    /// Starts streaming at most `maxWidth × maxHeight` pixels; the emulator scales preserving aspect ratio.
    /// Reconnects automatically after transient failures.
    public func frames(maxWidth: Int, maxHeight: Int, sharedMemory: Bool = true) -> AsyncStream<Result<DisplayFrame, DroidDeckError>> {
        streamTask?.cancel()
        let (stream, continuation) = AsyncStream<Result<DisplayFrame, DroidDeckError>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let controller = self.controller
        streamTask = Task.detached(priority: .userInitiated) {
            var attempts = 0
            var useSharedMemory = sharedMemory
            while !Task.isCancelled {
                // The emulator writes each frame into memory shared with DroidDeck (gRPC MMAP transport),
                // so only a small notice crosses the socket instead of megabytes of pixels per frame.
                let shared = useSharedMemory ? SharedFrameBuffer(capacity: max(1, maxWidth) * max(1, maxHeight) * 4) : nil
                var delivered = 0, unreadable = 0
                do {
                    let request = EmulatorImageRequest(format: .rgba8888, width: UInt32(max(1, maxWidth)), height: UInt32(max(1, maxHeight)),
                                                       mmapHandle: shared?.handle)
                    let images = try await controller.streamScreenshots(request)
                    for try await image in images {
                        attempts = 0
                        guard image.width > 0, image.height > 0 else { continue }
                        guard let cg = Self.makeImage(image, shared: shared) else {
                            unreadable += 1
                            // The emulator isn't filling the shared buffer: switch to in-band frames.
                            if shared != nil && delivered == 0 && unreadable >= 3 { useSharedMemory = false; break }
                            continue
                        }
                        delivered += 1
                        continuation.yield(.success(DisplayFrame(image: cg, rotation: image.rotation, sequence: image.sequence)))
                    }
                    if !useSharedMemory && shared != nil { continue }
                } catch {
                    if Task.isCancelled { break }
                    if shared != nil && delivered == 0 { useSharedMemory = false }
                    attempts += 1
                    let message = Redactor.redact(String(describing: error))
                    continuation.yield(.failure(DroidDeckError(.toolFailed, "The display stream was interrupted.", detail: message)))
                    if attempts > 20 { break }
                }
                try? await Task.sleep(for: .milliseconds(min(250 * attempts, 3000)))
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel() }
        }
        return stream
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    static func makeImage(_ image: EmulatorImage, shared: SharedFrameBuffer? = nil) -> CGImage? {
        let expected = image.width * image.height * 4
        let pixels: Data
        if image.pixels.count >= expected {
            pixels = Data(image.pixels.prefix(expected))
        } else if let shared, let copy = shared.copy(count: expected) {
            pixels = copy
        } else {
            return nil
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// Serializes input to one device so events arrive in order. Pointer moves are coalesced
/// while a previous event is in flight to keep latency low.
public actor InputPipeline {
    private let controller: EmulatorControllerClient
    private var queue: [EmulatorInputEvent] = []
    private var draining = false
    public private(set) var lastError: String?

    public init(controller: EmulatorControllerClient) {
        self.controller = controller
    }

    public func send(_ event: EmulatorInputEvent) {
        // Replace a queued move for the same pointers with the newer position.
        if case .touch(let touches, _) = event, touches.allSatisfy({ $0.pressure > 0 }),
           let last = queue.last, case .touch(let previous, _) = last, previous.allSatisfy({ $0.pressure > 0 }),
           Set(previous.map(\.identifier)) == Set(touches.map(\.identifier)) {
            queue[queue.count - 1] = event
        } else {
            queue.append(event)
        }
        if !draining {
            draining = true
            Task { await drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let event = queue.removeFirst()
            do {
                try await controller.send(event)
                lastError = nil
            } catch {
                lastError = Redactor.redact(String(describing: error))
            }
        }
        draining = false
    }
}

/// Places the official skin around the display for any rotation. The skin artwork is portrait;
/// in landscape the frame is rotated and the display opening moves with it.
public struct DeviceFrameGeometry: Equatable, Sendable {
    public var frameSize: CGSize
    /// Display opening inside the portrait frame.
    public var display: CGRect
    public var rotation: EmulatorSkinRotation

    public init(frameSize: CGSize, display: CGRect, rotation: EmulatorSkinRotation) {
        self.frameSize = frameSize
        self.display = display
        self.rotation = rotation
    }

    /// Size of the rotated frame.
    public var containerSize: CGSize {
        rotation.quarterTurns % 2 == 0 ? frameSize : CGSize(width: frameSize.height, height: frameSize.width)
    }

    /// Clockwise rotation applied to the portrait artwork, in degrees. ROTATION_90 (landscape)
    /// means the device was turned counter-clockwise, so the artwork turns -90°.
    public var artworkRotationDegrees: Double {
        switch rotation {
        case .portrait: return 0
        case .landscape: return -90
        case .reversePortrait: return 180
        case .reverseLandscape: return 90
        }
    }

    /// The display opening in the rotated container.
    public var rotatedDisplay: CGRect {
        let w = frameSize.width, h = frameSize.height, d = display
        switch rotation {
        case .portrait:
            return d
        case .landscape:        // (x, y) → (y, w − x)
            return CGRect(x: d.minY, y: w - d.maxX, width: d.height, height: d.width)
        case .reversePortrait:  // (x, y) → (w − x, h − y)
            return CGRect(x: w - d.maxX, y: h - d.maxY, width: d.width, height: d.height)
        case .reverseLandscape: // (x, y) → (h − y, x)
            return CGRect(x: h - d.maxY, y: d.minX, width: d.height, height: d.width)
        }
    }

    /// Uniform scale that fits the rotated frame into `available`.
    public func scale(toFit available: CGSize) -> CGFloat {
        let c = containerSize
        guard c.width > 0, c.height > 0 else { return 1 }
        return min(available.width / c.width, available.height / c.height)
    }
}

/// A private file mapped into memory that the emulator writes frames into (gRPC `ImageTransport.MMAP`).
final class SharedFrameBuffer: @unchecked Sendable {
    let handle: String
    private let path: String
    private let fd: Int32
    private let capacity: Int
    private let base: UnsafeMutableRawPointer

    init?(capacity: Int) {
        let url = FileManager.default.temporaryDirectory.appending(path: "droiddeck-frame-\(UUID().uuidString).rgba")
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return nil }
        guard ftruncate(fd, off_t(capacity)) == 0,
              let base = mmap(nil, capacity, PROT_READ, MAP_SHARED, fd, 0),
              base != UnsafeMutableRawPointer(bitPattern: -1) else {
            close(fd)
            unlink(url.path)
            return nil
        }
        self.fd = fd
        self.base = base
        self.capacity = capacity
        self.path = url.path
        self.handle = url.absoluteString
    }

    /// The first `count` bytes, or nil if the file is smaller (reading a mapping past the end of its file
    /// would crash with SIGBUS).
    func copy(count: Int) -> Data? {
        var info = stat()
        guard count <= capacity, fstat(fd, &info) == 0, Int(info.st_size) >= count else { return nil }
        return Data(bytes: base, count: count)
    }

    deinit {
        munmap(base, capacity)
        close(fd)
        unlink(path)
    }
}
