import Combine
import Foundation

final class AppProfileStore: ObservableObject {
    @Published var profiles: [AppProfile]

    private static let defaultsKey = "appProfiles"
    private static let builtInProfiles: [AppProfile] = [
        AppProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Default",
            prompt: TextCleaner.defaultPrompt,
            bundleIDs: [],
            isBuiltIn: true
        ),
        AppProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Code",
            prompt: """
            Clean up this transcription with minimal changes. Preserve technical terms, code identifiers, filenames, commands, APIs, and version numbers exactly as spoken unless there is an obvious recognition error. Remove filler words, keep the original structure and meaning, and only fix punctuation and clear transcription mistakes.
            """,
            bundleIDs: [
                "com.microsoft.VSCode",
                "com.apple.dt.Xcode",
                "com.github.atom",
                "com.jetbrains.intellij"
            ],
            isBuiltIn: true
        ),
        AppProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Messaging",
            prompt: """
            Clean up this transcription for chat apps. Keep the meaning the same, use a casual tone, shorten long run-on phrasing into shorter sentences, and keep punctuation light and natural. Remove filler words and obvious recognition mistakes.
            """,
            bundleIDs: [
                "com.tinyspeck.slackmacgap",
                "com.apple.MobileSMS",
                "com.hnc.Discord"
            ],
            isBuiltIn: true
        )
    ]

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let customProfiles = Self.loadCustomProfiles(from: defaults)
        self.profiles = Self.builtInProfiles + customProfiles
    }

    func profileFor(bundleID: String) -> AppProfile {
        if let customProfile = profiles.first(where: { !$0.isBuiltIn && $0.bundleIDs.contains(bundleID) }) {
            return customProfile
        }

        if let builtInProfile = profiles.first(where: { $0.isBuiltIn && $0.bundleIDs.contains(bundleID) }) {
            return builtInProfile
        }

        return profiles.first(where: { $0.isBuiltIn && $0.name == "Default" }) ?? Self.builtInProfiles[0]
    }

    func addProfile(_ profile: AppProfile) {
        var profile = profile
        profile.isBuiltIn = false
        profiles.append(profile)
        persistCustomProfiles()
    }

    func updateProfile(_ profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
              !profiles[index].isBuiltIn else {
            return
        }

        var profile = profile
        profile.isBuiltIn = false
        profiles[index] = profile
        persistCustomProfiles()
    }

    @discardableResult
    func deleteProfile(_ id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isBuiltIn else {
            return false
        }

        profiles.remove(at: index)
        persistCustomProfiles()
        return true
    }

    private func persistCustomProfiles() {
        let customProfiles = profiles.filter { !$0.isBuiltIn }
        guard let data = try? encoder.encode(customProfiles) else {
            return
        }

        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func loadCustomProfiles(from defaults: UserDefaults) -> [AppProfile] {
        let decoder = JSONDecoder()
        guard let data = defaults.data(forKey: defaultsKey),
              let decodedProfiles = try? decoder.decode([AppProfile].self, from: data) else {
            return []
        }

        return decodedProfiles.filter { !$0.isBuiltIn }
    }
}
