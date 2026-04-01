import XCTest
import ServiceManagement
@testable import MacGuard

final class MockURLOpener: URLOpening, @unchecked Sendable {
    var openedURLs: [URL] = []
    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

final class LoginItemManagerTests: XCTestCase {

    @MainActor
    private func makeIsolatedManager(fake: FakeSMServiceController) -> LoginItemManager {
        let manager = LoginItemManager(controller: fake, urlOpener: MockURLOpener())
        return manager
    }

    @MainActor
    func testToggleTransitions() async throws {
        let fake = FakeSMServiceController()
        let manager = makeIsolatedManager(fake: fake)
        
        XCTAssertEqual(manager.status, .notRegistered)
        await manager.enable()
        XCTAssertEqual(manager.status, .enabled)
        await manager.disable()
        XCTAssertEqual(manager.status, .notRegistered)
    }

    @MainActor
    func testRequiresApprovalTransitions() async throws {
        let fake = FakeSMServiceController()
        fake.mockedStatus = .requiresApproval
        let manager = makeIsolatedManager(fake: fake)
        
        XCTAssertEqual(manager.status, .requiresApproval)
    }
}
