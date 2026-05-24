import Foundation

struct EnvironmentCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isHealthy: Bool
}

enum EnvironmentHealthChecker {
    static func run() -> [EnvironmentCheck] {
        let env = AppPaths.loadEnvValues()

        return [
            configCheck(env),
            executableCheck(
                id: "python",
                title: "Python 环境",
                detail: AppPaths.projectRoot
                    .appendingPathComponent(".venv/bin/python")
                    .path,
                command: AppPaths.projectRoot
                    .appendingPathComponent(".venv/bin/python")
                    .path
            ),
            executableCheck(
                id: "ffmpeg",
                title: "ffmpeg",
                detail: env["FFMPEG_BIN"] ?? "ffmpeg",
                command: env["FFMPEG_BIN"] ?? "ffmpeg"
            ),
            libreOfficeCheck(),
            executableCheck(
                id: "codex",
                title: "Codex CLI",
                detail: env["CODEX_BIN"] ?? "codex",
                command: env["CODEX_BIN"] ?? "codex",
                validationArguments: ["login", "status"]
            ),
        ]
    }

    private static func configCheck(_ env: [String: String]) -> EnvironmentCheck {
        let requiredKeys = [
            "FEISHU_APP_ID",
            "FEISHU_APP_SECRET",
            "HF_TOKEN",
        ]
        let placeholderPrefixes = [
            "cli_xxxxxxxxxxxxxxxx",
            "replace_with_",
            "hf_replace_",
        ]

        let hasAllValues = requiredKeys.allSatisfy { key in
            guard let value = env[key], !value.isEmpty else {
                return false
            }

            return !placeholderPrefixes.contains(where: value.hasPrefix)
        }

        return EnvironmentCheck(
            id: "env",
            title: "核心配置",
            detail: hasAllValues ? ".env 已配置" : ".env 未填完整",
            isHealthy: hasAllValues
        )
    }

    private static func executableCheck(
        id: String,
        title: String,
        detail: String,
        command: String,
        validationArguments: [String] = []
    ) -> EnvironmentCheck {
        let resolved = resolveExecutable(command)
        guard let resolved else {
            return EnvironmentCheck(
                id: id,
                title: title,
                detail: detail,
                isHealthy: false
            )
        }

        if !validationArguments.isEmpty {
            let validation = validateExecutable(resolved, arguments: validationArguments)
            return EnvironmentCheck(
                id: id,
                title: title,
                detail: validation ? resolved : "\(resolved)（未登录或校验失败）",
                isHealthy: validation
            )
        }

        return EnvironmentCheck(
            id: id,
            title: title,
            detail: resolved,
            isHealthy: true
        )
    }

    private static func libreOfficeCheck() -> EnvironmentCheck {
        let knownPath = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        let resolved = resolveExecutable("soffice")
            ?? (FileManager.default.isExecutableFile(atPath: knownPath) ? knownPath : nil)

        return EnvironmentCheck(
            id: "libreoffice",
            title: "LibreOffice",
            detail: resolved ?? "未找到 soffice",
            isHealthy: resolved != nil
        )
    }

    private static func environmentWithToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var combined = toolDirectories
        for path in existing where !combined.contains(path) {
            combined.append(path)
        }
        environment["PATH"] = combined.joined(separator: ":")
        return environment
    }

    private static func resolveExecutable(_ command: String) -> String? {
        guard !command.isEmpty else {
            return nil
        }

        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }

        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.environment = environmentWithToolPaths()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    private static func validateExecutable(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environmentWithToolPaths()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(6)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
