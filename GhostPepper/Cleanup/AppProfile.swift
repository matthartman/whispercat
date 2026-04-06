import Foundation

struct AppProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var bundleIDs: [String]
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        bundleIDs: [String] = [],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.bundleIDs = bundleIDs
        self.isBuiltIn = isBuiltIn
    }
}
