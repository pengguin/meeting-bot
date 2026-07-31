import Foundation

struct EnvironmentCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isHealthy: Bool
}

enum ToolDiscovery {
    private static let fileManager = FileManager.default

    static func environmentWithToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var combined = searchDirectories()
        for path in existing where !combined.contains(path) {
            combined.append(path)
        }
        environment["PATH"] = combined.joined(separator: ":")
        return environment
    }

    static func resolveExecutable(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        guard trimmed.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        for directory in searchDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(trimmed).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return resolveFromLoginShell(trimmed)
    }

    static func libreOfficeExecutable() -> String? {
        if let resolved = resolveExecutable("soffice") ?? resolveExecutable("libreoffice") {
            return resolved
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice").path,
            home.appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
            "/opt/libreoffice/program/soffice",
        ]
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    private static func searchDirectories() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        var directories = [
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent("bin").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent("Library/pnpm").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        directories.append(contentsOf: childBinDirectories(
            under: home.appendingPathComponent(".nvm/versions/node")
        ))
        directories.append(contentsOf: npxBinDirectories(
            under: home.appendingPathComponent(".npm/_npx")
        ))
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    private static func childBinDirectories(under root: URL) -> [String] {
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin").path }
    }

    private static func npxBinDirectories(under root: URL) -> [String] {
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("node_modules/.bin").path }
    }

    private static func resolveFromLoginShell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v '\(command)' 2>/dev/null"]
        process.environment = environmentWithToolPaths()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard output.hasPrefix("/"), fileManager.isExecutableFile(atPath: output) else {
                return nil
            }
            return output
        } catch {
            return nil
        }
    }
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
                command: env["FFMPEG_BIN"] ?? "ffmpeg",
                fallbackCommand: "ffmpeg"
            ),
            libreOfficeCheck(),
            llmBackendCheck(env),
        ]
    }

    private static func llmBackendCheck(_ env: [String: String]) -> EnvironmentCheck {
        let provider = (env["LLM_PROVIDER"] ?? "codex")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if provider.isEmpty || provider == "codex" {
            return executableCheck(
                id: "codex",
                title: "Codex CLI",
                detail: env["CODEX_BIN"] ?? "codex",
                command: env["CODEX_BIN"] ?? "codex",
                fallbackCommand: "codex",
                validationArguments: ["login", "status"]
            )
        }

        // HTTP 后端：这里只校验配置完整性；网络连通性在首次配置向导中验证，
        // 避免每两分钟的健康检查产生网络请求。
        let apiKey = env["LLM_API_KEY"] ?? ""
        let model = env["LLM_MODEL"] ?? ""
        let needsKey = provider == "openai" || provider == "anthropic"
        let needsModel = provider == "openai"
        let missingKey = needsKey && apiKey.isEmpty
        let missingModel = needsModel && model.isEmpty

        var detail = "后端：\(provider)"
        if !model.isEmpty {
            detail += " / \(model)"
        }
        if missingKey {
            detail += "（缺少 LLM_API_KEY）"
        }
        if missingModel {
            detail += "（缺少 LLM_MODEL）"
        }

        return EnvironmentCheck(
            id: "llm",
            title: "纪要生成后端",
            detail: detail,
            isHealthy: !missingKey && !missingModel
        )
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
        fallbackCommand: String? = nil,
        validationArguments: [String] = []
    ) -> EnvironmentCheck {
        let resolved = ToolDiscovery.resolveExecutable(command)
            ?? fallbackCommand.flatMap(ToolDiscovery.resolveExecutable)
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
        let resolved = ToolDiscovery.libreOfficeExecutable()

        return EnvironmentCheck(
            id: "libreoffice",
            title: "LibreOffice",
            detail: resolved ?? "未找到 soffice",
            isHealthy: resolved != nil
        )
    }

    private static func validateExecutable(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ToolDiscovery.environmentWithToolPaths()

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
