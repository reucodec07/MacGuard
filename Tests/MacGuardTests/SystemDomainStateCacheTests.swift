import XCTest
@testable import MacGuard

final class SystemDomainStateCacheTests: XCTestCase {
    
    func testParsingValidBlocks() {
        let output = """
        services = {
            0   -   com.apple.metadata.mds
            500  78  com.apple.WindowServer
            100  -   com.thirdparty.daemon
        }
        """
        let labels = SystemDomainStateCache.parse(output: output)
        XCTAssertEqual(labels.count, 3)
        XCTAssertTrue(labels.contains("com.apple.metadata.mds"))
        XCTAssertTrue(labels.contains("com.apple.WindowServer"))
        XCTAssertTrue(labels.contains("com.thirdparty.daemon"))
    }
    
    func testParsingLabelFormat() {
        let output = """
        label = "com.apple.example.daemon"
        state = running
        """
        let labels = SystemDomainStateCache.parse(output: output)
        XCTAssertEqual(labels.count, 1)
        XCTAssertTrue(labels.contains("com.apple.example.daemon"))
    }
    
    func testParsingEmptyAndMalformed() {
        let output = """
        services = {
        }
        some other garbage
        """
        let labels = SystemDomainStateCache.parse(output: output)
        XCTAssertTrue(labels.isEmpty)
    }

    func testRobustParsing() {
        let fixture = """
        system domain:
            label = "com.apple.xpc.launchd.domain.system"
            services = {
                0x0  (0)   [ ]  com.apple.taskgated
                0x1  (1)   [X]  "com.apple.syslogd"
                0x2  (2)   [ ]  quoted.label.with.spaces
            }
        """
        let labels = SystemDomainStateCache.parse(output: fixture)
        XCTAssertTrue(labels.contains("com.apple.taskgated"))
        XCTAssertTrue(labels.contains("com.apple.syslogd"))
        XCTAssertTrue(labels.contains("quoted.label.with.spaces"))
        XCTAssertTrue(labels.contains("com.apple.xpc.launchd.domain.system"))
    }
}
