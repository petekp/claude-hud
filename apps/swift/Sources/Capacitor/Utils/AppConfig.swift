import Foundation

enum AppChannel: String, CaseIterable, Codable {
    case dev
    case alpha
    case beta
    case prod

    static func parse(_ rawValue: String?) -> AppChannel? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "dev", "development":
            return .dev
        case "alpha":
            return .alpha
        case "beta":
            return .beta
        case "prod", "production":
            return .prod
        default:
            return nil
        }
    }

    var label: String {
        rawValue.uppercased()
    }

    var isProduction: Bool {
        self == .prod
    }
}

struct FeatureFlags: Equatable, Codable {
    var ideaCapture: Bool
    var projectDetails: Bool

    static func defaults(for channel: AppChannel) -> FeatureFlags {
        switch channel {
        case .alpha:
            FeatureFlags(ideaCapture: false, projectDetails: false)
        case .dev, .beta, .prod:
            FeatureFlags(ideaCapture: true, projectDetails: true)
        }
    }

    fileprivate mutating func apply(_ overrides: FeatureOverrides) {
        for key in overrides.enabled {
            set(key, enabled: true)
        }
        for key in overrides.disabled {
            set(key, enabled: false)
        }
    }

    private mutating func set(_ key: FeatureKey, enabled: Bool) {
        switch key {
        case .ideaCapture:
            ideaCapture = enabled
        case .projectDetails:
            projectDetails = enabled
        }
    }
}

struct AppConfig: Equatable {
    let channel: AppChannel
    let featureFlags: FeatureFlags

    struct ConfigFile: Codable, Equatable {
        var channel: String?
        var featuresEnabled: [String]?
        var featuresDisabled: [String]?
        var featureFlags: [String: Bool]?

        static func load(url: URL = defaultURL) -> ConfigFile? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                return try decoder.decode(ConfigFile.self, from: data)
            } catch {
                return nil
            }
        }

        static var defaultURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".capacitor/config.json")
        }
    }

    static var defaultChannel: AppChannel {
        #if DEBUG
            return .dev
        #else
            return .prod
        #endif
    }

    static func current() -> AppConfig {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let configFile = ConfigFile.load()
        return resolve(
            environment: environment,
            info: info,
            configFile: configFile,
            defaultChannel: defaultChannel,
        )
    }

    static func resolve(
        environment: [String: String],
        info: [String: Any],
        configFile: ConfigFile?,
        defaultChannel: AppChannel,
    ) -> AppConfig {
        let channel = resolveChannel(
            environment: environment,
            info: info,
            configFile: configFile,
            defaultChannel: defaultChannel,
        )

        var flags = FeatureFlags.defaults(for: channel)
        flags.apply(overrides(from: configFile))
        flags.apply(overrides(fromInfo: info))
        flags.apply(overrides(fromEnvironment: environment))

        return AppConfig(channel: channel, featureFlags: flags)
    }

    private static func resolveChannel(
        environment: [String: String],
        info: [String: Any],
        configFile: ConfigFile?,
        defaultChannel: AppChannel,
    ) -> AppChannel {
        if let envChannel = AppChannel.parse(environment["CAPACITOR_CHANNEL"]) {
            return envChannel
        }
        if let infoChannel = AppChannel.parse(info["CapacitorChannel"] as? String) {
            return infoChannel
        }
        if let fileChannel = AppChannel.parse(configFile?.channel) {
            return fileChannel
        }
        return defaultChannel
    }

    private static func overrides(from configFile: ConfigFile?) -> FeatureOverrides {
        var overrides = FeatureOverrides()
        if let enabled = configFile?.featuresEnabled {
            overrides.enabled.formUnion(parseFeatureList(enabled))
        }
        if let disabled = configFile?.featuresDisabled {
            overrides.disabled.formUnion(parseFeatureList(disabled))
        }
        if let flagMap = configFile?.featureFlags {
            for (name, enabled) in flagMap {
                guard let key = FeatureKey.parse(name) else { continue }
                if enabled {
                    overrides.enabled.insert(key)
                } else {
                    overrides.disabled.insert(key)
                }
            }
        }
        return overrides
    }

    private static func overrides(fromInfo info: [String: Any]) -> FeatureOverrides {
        var overrides = FeatureOverrides()
        if let enabled = parseFeatureList(info["CapacitorFeaturesEnabled"]) {
            overrides.enabled.formUnion(enabled)
        }
        if let disabled = parseFeatureList(info["CapacitorFeaturesDisabled"]) {
            overrides.disabled.formUnion(disabled)
        }
        return overrides
    }

    private static func overrides(fromEnvironment environment: [String: String]) -> FeatureOverrides {
        var overrides = FeatureOverrides()
        if let enabled = parseFeatureList(environment["CAPACITOR_FEATURES_ENABLED"]) {
            overrides.enabled.formUnion(enabled)
        }
        if let disabled = parseFeatureList(environment["CAPACITOR_FEATURES_DISABLED"]) {
            overrides.disabled.formUnion(disabled)
        }
        return overrides
    }

    private static func parseFeatureList(_ raw: Any?) -> Set<FeatureKey>? {
        if let list = raw as? [String] {
            return parseFeatureList(list)
        }
        if let text = raw as? String {
            return parseFeatureList(text)
        }
        return nil
    }

    private static func parseFeatureList(_ raw: String?) -> Set<FeatureKey>? {
        guard let raw else { return nil }
        let tokens = raw
            .split { $0 == "," || $0.isWhitespace }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parseFeatureList(tokens.map { String($0) })
    }

    private static func parseFeatureList(_ raw: [String]) -> Set<FeatureKey> {
        var results = Set<FeatureKey>()
        for token in raw {
            if let key = FeatureKey.parse(token) {
                results.insert(key)
            }
        }
        return results
    }
}

private enum FeatureKey: String, CaseIterable {
    case ideaCapture = "ideacapture"
    case projectDetails = "projectdetails"

    static func parse(_ raw: String?) -> FeatureKey? {
        guard let raw else { return nil }
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return FeatureKey(rawValue: normalized)
    }
}

private struct FeatureOverrides {
    var enabled: Set<FeatureKey> = []
    var disabled: Set<FeatureKey> = []
}
