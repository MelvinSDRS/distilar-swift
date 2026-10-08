import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What a report says about where it came from. It is read when the report
/// is written, not when it is sent: the app may update in between.
@MainActor
enum DeviceInfo {
    /// The app's version and build, such as 2.4 (318).
    static func appVersion(_ bundle: Bundle = .main) -> String? {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?) where version != build: return clip("\(version) (\(build))", 64)
        case let (version?, _): return clip(version, 64)
        case let (nil, build?): return clip(build, 64)
        case (nil, nil): return nil
        }
    }

    /// The system and its version, such as iOS 26.1.
    static func osVersion() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return clip("\(device.systemName) \(device.systemVersion)", 64)
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }

    /// The model identifier, such as iPhone17,1, which names the exact model
    /// where a marketing name would not.
    static func model() -> String? {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return clip(simulated, 64)
        }
        #endif
        #if os(macOS)
        return sysctl("hw.model").map { clip($0, 64) }
        #else
        return sysctl("hw.machine").map { clip($0, 64) }
        #endif
    }

    /// The app's language and region, such as fr_CA.
    static func locale(_ locale: Locale = .current) -> String? {
        guard let language = locale.language.languageCode?.identifier else { return nil }
        guard let region = locale.region?.identifier else { return clip(language, 35) }
        return clip("\(language)_\(region)", 35)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.nilIfEmpty
    }

    /// Cuts text to the server's limit, which counts Unicode scalars.
    private static func clip(_ text: String, _ limit: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }
}
