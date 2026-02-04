@testable import Capacitor
import XCTest

final class ProjectCardAnimationPolicyTests: XCTestCase {
    func testWaitingCardAnimatesWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: true,
            isWorking: false
        )

        XCTAssertTrue(shouldAnimate)
    }

    func testIdleCardDoesNotAnimateWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: false,
            isWorking: false
        )

        XCTAssertFalse(shouldAnimate)
    }

    func testWorkingCardAnimatesWhenNotHoveredOrActive() {
        let shouldAnimate = CardEffectAnimationPolicy.shouldAnimate(
            isActive: false,
            isHovered: false,
            isWaiting: false,
            isWorking: true
        )

        XCTAssertTrue(shouldAnimate)
    }
}
