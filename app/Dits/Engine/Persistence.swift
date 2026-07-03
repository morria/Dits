// Simple JSON-in-UserDefaults persistence for settings and conversations.
// Deliberately not iCloud-backed: keeps signing/provisioning trivial and
// the data is small and device-local by nature.

import Foundation
import os

enum Persistence {
    private static let settingsKey = "dits.settings.v1"
    private static let conversationsKey = "dits.conversations.v1"
    private static let corruptBackupKey = "dits.conversations.corrupt-backup"
    private static var defaults: UserDefaults { .standard }
    private static let log = Logger(subsystem: "com.w2asm.dits", category: "persistence")

    static func loadSettings() -> StationSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(StationSettings.self, from: data) else {
            return StationSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: StationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    static func loadConversations() -> [Conversation] {
        guard let data = defaults.data(forKey: conversationsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Conversation].self, from: data)
        } catch {
            // Don't let the next save silently wipe the operator's QSO
            // history: stash the undecodable blob for post-mortem instead.
            log.error("Conversation store failed to decode (\(error.localizedDescription)); preserving blob under backup key")
            defaults.set(data, forKey: corruptBackupKey)
            return []
        }
    }

    static func saveConversations(_ conversations: [Conversation]) {
        do {
            let data = try JSONEncoder().encode(conversations)
            defaults.set(data, forKey: conversationsKey)
        } catch {
            log.error("Conversation store failed to encode: \(error.localizedDescription)")
        }
    }
}
