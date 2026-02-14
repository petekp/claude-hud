@testable import Capacitor
import XCTest

final class AppConfigTests: XCTestCase {
    func testAlphaChannelDefaultsDisableOutOfScopeFeatures() {
        let config = AppConfig.resolve(
            environment: ["CAPACITOR_CHANNEL": "alpha"],
            info: [:],
            configFile: nil,
            defaultChannel: .prod,
        )

        XCTAssertEqual(config.channel, .alpha)
        XCTAssertFalse(config.featureFlags.ideaCapture)
        XCTAssertFalse(config.featureFlags.projectDetails)
        XCTAssertFalse(config.featureFlags.workstreams)
        XCTAssertFalse(config.featureFlags.projectCreation)
        XCTAssertFalse(config.featureFlags.llmFeatures)
    }

    func testEnvironmentOverridesInfoAndConfigChannel() {
        let configFile = AppConfig.ConfigFile(channel: "dev", featuresEnabled: nil, featuresDisabled: nil, featureFlags: nil)
        let config = AppConfig.resolve(
            environment: ["CAPACITOR_CHANNEL": "beta"],
            info: ["CapacitorChannel": "alpha"],
            configFile: configFile,
            defaultChannel: .prod,
        )

        XCTAssertEqual(config.channel, .beta)
    }

    func testEnvironmentFeatureOverridesApplyAfterDefaults() {
        let config = AppConfig.resolve(
            environment: [
                "CAPACITOR_CHANNEL": "alpha",
                "CAPACITOR_FEATURES_ENABLED": "ideaCapture",
                "CAPACITOR_FEATURES_DISABLED": "projectDetails,workstreams",
            ],
            info: [:],
            configFile: nil,
            defaultChannel: .prod,
        )

        XCTAssertTrue(config.featureFlags.ideaCapture)
        XCTAssertFalse(config.featureFlags.projectDetails)
        XCTAssertFalse(config.featureFlags.workstreams)
    }

    func testConfigFileFeatureFlagsOverrideDefaults() {
        let configFile = AppConfig.ConfigFile(
            channel: nil,
            featuresEnabled: nil,
            featuresDisabled: nil,
            featureFlags: [
                "ideaCapture": true,
                "projectDetails": false,
                "projectCreation": false,
                "llmFeatures": true,
            ],
        )

        let config = AppConfig.resolve(
            environment: [:],
            info: [:],
            configFile: configFile,
            defaultChannel: .prod,
        )

        XCTAssertTrue(config.featureFlags.ideaCapture)
        XCTAssertFalse(config.featureFlags.projectDetails)
        XCTAssertFalse(config.featureFlags.projectCreation)
        XCTAssertTrue(config.featureFlags.llmFeatures)
    }

    func testAreFeatureFlagsDefaultOffAndCanBeEnabled() {
        let baseline = AppConfig.resolve(
            environment: [:],
            info: [:],
            configFile: nil,
            defaultChannel: .prod,
        )
        XCTAssertFalse(baseline.featureFlags.areStatusRow)
        XCTAssertFalse(baseline.featureFlags.areLauncher)
        XCTAssertFalse(baseline.featureFlags.areShadowCompare)

        let overridden = AppConfig.resolve(
            environment: [
                "CAPACITOR_FEATURES_ENABLED": "areStatusRow,areLauncher,areShadowCompare",
            ],
            info: [:],
            configFile: nil,
            defaultChannel: .prod,
        )
        XCTAssertTrue(overridden.featureFlags.areStatusRow)
        XCTAssertTrue(overridden.featureFlags.areLauncher)
        XCTAssertTrue(overridden.featureFlags.areShadowCompare)
    }
}
