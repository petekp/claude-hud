@testable import Capacitor
import XCTest

final class ProjectCardAnimationPolicyTests: XCTestCase {
    func testWaitingCardAnimatesWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: true,
            isWorking: false,
        )

        XCTAssertTrue(shouldAnimate)
    }

    func testIdleCardDoesNotAnimateWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: false,
            isWorking: false,
        )

        XCTAssertFalse(shouldAnimate)
    }

    func testWorkingCardAnimatesWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: false,
            isWorking: true,
        )

        XCTAssertTrue(shouldAnimate)
    }

    func testReadyChimeRespectsUserSetting() {
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: false,
            oldState: .working,
            newState: .ready,
            lastChimeTime: nil,
            now: Date(),
            chimeCooldown: 3.0,
        )

        XCTAssertFalse(shouldPlay)
    }

    func testReadyChimeRespectsCooldown() {
        let now = Date()
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: true,
            oldState: .working,
            newState: .ready,
            lastChimeTime: now.addingTimeInterval(-1.0),
            now: now,
            chimeCooldown: 3.0,
        )

        XCTAssertFalse(shouldPlay)
    }

    func testReadyChimePlaysWhenTransitioningToReady() {
        let shouldPlay = ReadyChimePolicy.shouldPlay(
            playReadyChime: true,
            oldState: .waiting,
            newState: .ready,
            lastChimeTime: nil,
            now: Date(),
            chimeCooldown: 3.0,
        )

        XCTAssertTrue(shouldPlay)
    }
}
