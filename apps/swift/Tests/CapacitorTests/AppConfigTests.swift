@testable import Capacitor
import XCTest

final class AppConfigTests: XCTestCase {
    func testAlphaChannelDefaultsDisableIdeaAndDetails() {
        let config = AppConfig.resolve(
            environment: ["CAPACITOR_CHANNEL": "alpha"],
            info: [:],
            configFile: nil,
            defaultChannel: .prod,
        )

        XCTAssertEqual(config.channel, .alpha)
        XCTAssertFalse(config.featureFlags.ideaCapture)
        XCTAssertFalse(config.featureFlags.projectDetails)
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
                "CAPACITOR_FEATURES_DISABLED": "projectDetails",
            ],
            info: [:],
            configFile: nil,
            defaultChannel: .prod,
        )

        XCTAssertTrue(config.featureFlags.ideaCapture)
        XCTAssertFalse(config.featureFlags.projectDetails)
    }

    func testConfigFileFeatureFlagsOverrideDefaults() {
        let configFile = AppConfig.ConfigFile(
            channel: nil,
            featuresEnabled: nil,
            featuresDisabled: nil,
            featureFlags: [
                "ideaCapture": true,
                "projectDetails": false,
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
    }
}
