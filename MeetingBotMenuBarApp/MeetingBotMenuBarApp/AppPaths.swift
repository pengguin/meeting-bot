import AppKit
import Foundation
import Security

enum SecureCredentialStore {
    static let service = "com.pgui.FeishuMeetingBotMenuBar.credentials"
    static let secretKeys = ["FEISHU_APP_SECRET", "HF_TOKEN", "LLM_API_KEY"]

    static func value(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func values() -> [String: String] {
        secretKeys.reduce(into: [:]) { result, key in
            if let value = value(for: key), !value.isEmpty {
                result[key] = value
            }
        }
    }

    static func replace(with values: [String: String]) throws {
        for key in secretKeys {
            try set(values[key] ?? "", for: key)
        }
    }

    private static func set(_ value: String, for key: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let deleteStatus = SecItemDelete(identity as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw keychainError(deleteStatus)
        }
        guard !value.isEmpty else {
            return
        }

        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus)
        }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey:
                    SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串操作失败"
            ]
        )
    }
}

enum AppPaths {
    private static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    static let defaultInstallRoot = homeDirectory
        .appendingPathComponent("Library/Application Support/meeting-bot", isDirectory: true)
    static let legacyInstallRoots = [
        homeDirectory.appendingPathComponent("Library/Application Support/meetin-bot", isDirectory: true),
        homeDirectory.appendingPathComponent("Library/Application Support/feishu-meeting-bot", isDirectory: true),
        homeDirectory.appendingPathComponent("meetin-bot", isDirectory: true),
        homeDirectory.appendingPathComponent("meeting-bot", isDirectory: true),
        homeDirectory.appendingPathComponent("feishu-meeting-bot", isDirectory: true),
    ]
    static let projectRoot = defaultInstallRoot
    static let defaultRecordingsDirectory = projectRoot.appendingPathComponent("downloads", isDirectory: true)
    static let defaultMeetingOutputsDirectory = projectRoot.appendingPathComponent("sessions", isDirectory: true)
    static var recordingsDirectory: URL {
        configuredDirectory(
            envKey: "RECORDINGS_DIR",
            defaultURL: defaultRecordingsDirectory
        )
    }
    static var sessionsDirectory: URL {
        configuredDirectory(
            envKey: "MEETING_OUTPUT_DIR",
            defaultURL: defaultMeetingOutputsDirectory
        )
    }
    static let logsDirectory = homeDirectory
        .appendingPathComponent("Library/Logs/meeting-bot", isDirectory: true)
    static let runtimeDirectory = projectRoot.appendingPathComponent("runtime", isDirectory: true)
    static let libraryDirectory = projectRoot.appendingPathComponent("library", isDirectory: true)
    static let eventsDirectory = runtimeDirectory.appendingPathComponent("events", isDirectory: true)
    static let statusFile = runtimeDirectory.appendingPathComponent("status.json")
    static let installedPayloadVersionFile = runtimeDirectory.appendingPathComponent("installed_payload_version.txt")
    static let installedAppVersionFile = runtimeDirectory.appendingPathComponent("installed_app_version.txt")
    static let legacyMigrationCompletedFile = runtimeDirectory.appendingPathComponent("legacy_migration_completed.txt")
    static let envFile = projectRoot.appendingPathComponent(".env")
    static let libraryMetadataFile = libraryDirectory.appendingPathComponent("meeting_library.json")
    static let templateCatalogFile = libraryDirectory.appendingPathComponent("meeting_templates.json")
    static let errorLog = logsDirectory.appendingPathComponent("bot_stderr.log")
    static let launchAgentPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist")

    static var legacyMigrationSource: URL? {
        guard !exists(legacyMigrationCompletedFile) else {
            return nil
        }
        return legacyInstallRoots.first(where: exists)
    }

    static func existingURL(path: String) -> URL? {
        guard !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return url
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func resolvedDirectory(path rawValue: String?, defaultURL: URL) -> URL {
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return defaultURL.standardizedFileURL
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        if NSString(string: expanded).isAbsolutePath {
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .standardizedFileURL
        }

        return projectRoot
            .appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
    }

    private static func configuredDirectory(envKey: String, defaultURL: URL) -> URL {
        resolvedDirectory(
            path: loadEnvValues(includeSecrets: false)[envKey],
            defaultURL: defaultURL
        )
    }

    static func loadEnvValues(includeSecrets: Bool = true) -> [String: String] {
        var values = [String: String]()
        if let contents = try? String(contentsOf: envFile, encoding: .utf8) {
            values = contents
                .split(separator: "\n")
                .reduce(into: [String: String]()) { result, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let separator = line.firstIndex(of: "=") else {
                    return
                }

                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result[key] = value
            }
        }
        if includeSecrets {
            values.merge(SecureCredentialStore.values()) { _, secureValue in secureValue }
        }
        return values
    }

    static func runtimeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(loadEnvValues()) { _, configuredValue in configuredValue }
        return environment
    }
}

enum AppVersion {
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "未知版本"
}

enum FileOpener {
    static func open(_ url: URL?) {
        guard let url else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL?) {
        guard let url else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func quickLook(_ url: URL?) {
        guard let url else {
            NSSound.beep()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        try? process.run()
    }

    static func openWithApplicationPicker(_ url: URL?) {
        guard let url else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择打开方式"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let appURL = panel.url else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }
}
