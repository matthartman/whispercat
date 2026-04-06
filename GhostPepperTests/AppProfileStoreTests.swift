import XCTest
@testable import GhostPepper

@MainActor
final class AppProfileStoreTests: XCTestCase {
    private let suiteName = "test-profiles"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBuiltInProfilesExist() throws {
        let store = AppProfileStore(defaults: try defaults())

        XCTAssertEqual(store.profiles.count, 3)
        XCTAssertEqual(Set(store.profiles.map(\.name)), Set(["Default", "Code", "Messaging"]))
    }

    func testProfileForBundleID() throws {
        let store = AppProfileStore(defaults: try defaults())

        XCTAssertEqual(store.profileFor(bundleID: "com.microsoft.VSCode").name, "Code")
    }

    func testProfileForUnknownBundleID() throws {
        let store = AppProfileStore(defaults: try defaults())

        XCTAssertEqual(store.profileFor(bundleID: "com.example.unknown").name, "Default")
    }

    func testAddCustomProfile() throws {
        let store = AppProfileStore(defaults: try defaults())
        let custom = AppProfile(
            name: "Docs",
            prompt: "Clean up for docs.",
            bundleIDs: ["com.example.docs"]
        )

        store.addProfile(custom)

        XCTAssertTrue(store.profiles.contains(custom))
    }

    func testCustomProfileTakesPriority() throws {
        let store = AppProfileStore(defaults: try defaults())
        let custom = AppProfile(
            name: "My Code",
            prompt: "Use my coding prompt.",
            bundleIDs: ["com.microsoft.VSCode"]
        )
        store.addProfile(custom)

        XCTAssertEqual(store.profileFor(bundleID: "com.microsoft.VSCode").name, "My Code")
    }

    func testDeleteProfile() throws {
        let store = AppProfileStore(defaults: try defaults())
        let custom = AppProfile(
            name: "Temp",
            prompt: "Temp prompt",
            bundleIDs: ["com.example.temp"]
        )
        store.addProfile(custom)

        XCTAssertTrue(store.deleteProfile(custom.id))
        XCTAssertFalse(store.profiles.contains(custom))
    }

    func testCannotDeleteBuiltIn() throws {
        let store = AppProfileStore(defaults: try defaults())
        let builtIn = try XCTUnwrap(store.profiles.first(where: { $0.name == "Default" }))

        XCTAssertFalse(store.deleteProfile(builtIn.id))
        XCTAssertTrue(store.profiles.contains(where: { $0.id == builtIn.id }))
    }

    private func defaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
