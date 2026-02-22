@testable import Capacitor
import XCTest

final class ReadyChimeTests: XCTestCase {
    func testPlaySkipsPlaybackWhenEngineCannotRun() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: false)
        let readyChime = ReadyChime(backend: backend, runAsync: { work in work() })

        readyChime.play()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 1)
        XCTAssertEqual(backend.playDualToneCallCount, 0)
    }

    func testPlayPreservesSuccessfulPlaybackBehavior() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: true)
        let readyChime = ReadyChime(backend: backend, runAsync: { work in work() })

        readyChime.play()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 1)
        XCTAssertEqual(backend.playDualToneCallCount, 1)
    }

    func testPlayResetsStateWhenEngineCannotRun() {
        let backend = StubReadyChimeAudioBackend(engineCanRun: false)
        let readyChime = ReadyChime(backend: backend, runAsync: { work in work() })

        readyChime.play()
        readyChime.play()

        XCTAssertEqual(backend.ensureEngineRunningCallCount, 2)
        XCTAssertEqual(backend.playDualToneCallCount, 0)
    }
}

private final class StubReadyChimeAudioBackend: ReadyChime.AudioBackend {
    var ensureEngineRunningCallCount = 0
    var playDualToneCallCount = 0

    private let engineCanRun: Bool

    init(engineCanRun: Bool) {
        self.engineCanRun = engineCanRun
    }

    func ensureEngineRunning() -> Bool {
        ensureEngineRunningCallCount += 1
        return engineCanRun
    }

    func playDualTone() {
        playDualToneCallCount += 1
    }
}
