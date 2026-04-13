import Foundation

@MainActor
class DailyStatsTracker: ObservableObject {
    @Published private(set) var todayWordCount: Int = 0
    @Published private(set) var todayTranscriptionCount: Int = 0

    private static let wordCountKey = "dailyStats.wordCount"
    private static let transcriptionCountKey = "dailyStats.transcriptionCount"
    private static let dateKey = "dailyStats.date"

    init() {
        loadTodayStats()
    }

    func recordTranscription(text: String) {
        rolloverIfNewDay()
        let words = text.split(whereSeparator: \.isWhitespace).count
        todayWordCount += words
        todayTranscriptionCount += 1
        save()
    }

    // MARK: - Private

    private func loadTodayStats() {
        let defaults = UserDefaults.standard
        let savedDate = defaults.string(forKey: Self.dateKey) ?? ""
        if savedDate == Self.todayString {
            todayWordCount = defaults.integer(forKey: Self.wordCountKey)
            todayTranscriptionCount = defaults.integer(forKey: Self.transcriptionCountKey)
        } else {
            todayWordCount = 0
            todayTranscriptionCount = 0
        }
    }

    private func rolloverIfNewDay() {
        let savedDate = UserDefaults.standard.string(forKey: Self.dateKey) ?? ""
        if savedDate != Self.todayString {
            todayWordCount = 0
            todayTranscriptionCount = 0
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(todayWordCount, forKey: Self.wordCountKey)
        defaults.set(todayTranscriptionCount, forKey: Self.transcriptionCountKey)
        defaults.set(Self.todayString, forKey: Self.dateKey)
    }

    private static var todayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
