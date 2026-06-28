import XCTest
@testable import RAMWatcherCore

final class RAMWatcherCoreTests: XCTestCase {
    func testBlocklistProtectsCoreSystemProcesses() {
        XCTAssertTrue(KillBlocklist.isProtected(pid: 0, name: "kernel_task"))
        XCTAssertTrue(KillBlocklist.isProtected(pid: 1, name: "launchd"))
        XCTAssertTrue(KillBlocklist.isProtected(pid: 1234, name: "WindowServer"))
        XCTAssertFalse(KillBlocklist.isProtected(pid: 1234, name: "Google Chrome"))
    }

    func testGroupingSumsFootprintAcrossPPIDChildren() {
        let parent = ProcessInfo(pid: 100, ppid: 1, uid: 501, name: "MyApp",
                                  execPath: "/Applications/MyApp.app/Contents/MacOS/MyApp",
                                  physFootprintBytes: 1_000_000, isUserOwned: true)
        let helper = ProcessInfo(pid: 101, ppid: 100, uid: 501, name: "MyApp Helper",
                                  execPath: "/Applications/MyApp.app/Contents/Frameworks/Helper",
                                  physFootprintBytes: 500_000, isUserOwned: true)
        let groups = ProcessGrouper().group([parent, helper])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.totalFootprintBytes, 1_500_000)
        XCTAssertEqual(groups.first?.members.count, 2)
    }

    func testGroupingFallsBackToBundlePathForReparentedHelpers() {
        let parent = ProcessInfo(pid: 200, ppid: 1, uid: 501, name: "MyApp",
                                  execPath: "/Applications/MyApp.app/Contents/MacOS/MyApp",
                                  physFootprintBytes: 1_000_000, isUserOwned: true)
        // Reparented to launchd (ppid 1), not a PPID descendant of `parent`,
        // but shares the same .app bundle path.
        let xpcHelper = ProcessInfo(pid: 201, ppid: 1, uid: 501, name: "MyApp XPC",
                                     execPath: "/Applications/MyApp.app/Contents/XPCServices/Helper.xpc/Helper",
                                     physFootprintBytes: 250_000, isUserOwned: true)
        let groups = ProcessGrouper().group([parent, xpcHelper])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.totalFootprintBytes, 1_250_000)
    }

    func testGroupingViaResponsiblePID() {
        let cursor = ProcessInfo(pid: 300, ppid: 1, uid: 501, name: "Cursor",
                                  execPath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                                  physFootprintBytes: 2_000_000, isUserOwned: true)
        let python = ProcessInfo(pid: 301, ppid: 1, uid: 501, name: "python3.11",
                                  execPath: "/usr/local/bin/python3.11",
                                  physFootprintBytes: 500_000, isUserOwned: true,
                                  responsiblePID: 300, scriptPath: nil)
        let groups = ProcessGrouper().group([cursor, python])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.mainPID, 300)
        XCTAssertEqual(groups.first?.totalFootprintBytes, 2_500_000)
        XCTAssertEqual(groups.first?.members.count, 2)
    }

    func testGroupingViaScriptPathBundleFallback() {
        let cursor = ProcessInfo(pid: 400, ppid: 1, uid: 501, name: "Cursor",
                                  execPath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                                  physFootprintBytes: 2_000_000, isUserOwned: true)
        let python = ProcessInfo(pid: 401, ppid: 1, uid: 501, name: "python3.11",
                                  execPath: "/usr/local/bin/python3.11",
                                  physFootprintBytes: 500_000, isUserOwned: true,
                                  responsiblePID: nil,
                                  scriptPath: "/Applications/Cursor.app/Contents/Resources/app/extensions/some_script.py")
        let groups = ProcessGrouper().group([cursor, python])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.mainPID, 400)
        XCTAssertEqual(groups.first?.totalFootprintBytes, 2_500_000)
        XCTAssertEqual(groups.first?.members.count, 2)
    }
}
