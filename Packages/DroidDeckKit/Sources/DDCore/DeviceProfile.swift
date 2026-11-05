import Foundation

/// A hardware definition from the Android SDK device catalog (sdklib devices/*.xml).
/// These are Google's published definitions; DroidDeck does not invent device specs.
public struct DeviceProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: String               // e.g. "pixel_9_pro"
    public var name: String             // e.g. "Pixel 9 Pro"
    public var manufacturer: String
    public var formFactor: DeviceFormFactor
    public var screenWidth: Int
    public var screenHeight: Int
    public var diagonalInches: Double
    public var xdpi: Double
    public var ydpi: Double
    /// Density bucket from the definition ("xxhdpi", "420dpi").
    public var densityBucket: String
    public var ram: Megabytes?
    public var playStoreEnabled: Bool
    public var skinName: String?
    public var sensors: [String]
    public var hasFrontCamera: Bool
    public var hasBackCamera: Bool
    public var hasHardwareKeyboard: Bool
    public var minimumAPILevel: Int?
    public var maximumAPILevel: Int?
    /// Where the definition was loaded from ("Android Studio", "Command-line Tools", "User").
    public var source: String

    public init(id: String, name: String, manufacturer: String, formFactor: DeviceFormFactor,
                screenWidth: Int, screenHeight: Int, diagonalInches: Double, xdpi: Double, ydpi: Double,
                densityBucket: String, ram: Megabytes?, playStoreEnabled: Bool, skinName: String?,
                sensors: [String], hasFrontCamera: Bool, hasBackCamera: Bool, hasHardwareKeyboard: Bool,
                minimumAPILevel: Int?, maximumAPILevel: Int?, source: String) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.formFactor = formFactor
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.diagonalInches = diagonalInches
        self.xdpi = xdpi
        self.ydpi = ydpi
        self.densityBucket = densityBucket
        self.ram = ram
        self.playStoreEnabled = playStoreEnabled
        self.skinName = skinName
        self.sensors = sensors
        self.hasFrontCamera = hasFrontCamera
        self.hasBackCamera = hasBackCamera
        self.hasHardwareKeyboard = hasHardwareKeyboard
        self.minimumAPILevel = minimumAPILevel
        self.maximumAPILevel = maximumAPILevel
        self.source = source
    }

    /// The `hw.lcd.density` value Android Studio writes for this definition.
    /// Buckets map to their nominal dpi; explicit "NNNdpi" values are used as-is.
    public var lcdDensity: Int {
        DeviceProfile.density(forBucket: densityBucket) ?? Int((xdpi + ydpi) / 2)
    }

    public static func density(forBucket bucket: String) -> Int? {
        let named: [String: Int] = [
            "ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240,
            "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640,
        ]
        if let value = named[bucket] { return value }
        if bucket.hasSuffix("dpi"), let value = Int(bucket.dropLast(3)) { return value }
        return nil
    }

    public var resolutionDescription: String { "\(screenWidth) × \(screenHeight)" }
}
