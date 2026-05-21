import Darwin
import Foundation

struct LaunchAgentCommandResult {
    let exitCode: Int32
    let output: String

    var succeeded: Bool {
        exitCode == 0
    }

    static func success(_ output: String) -> LaunchAgentCommandResult {
        LaunchAgentCommandResult(exitCode: 0, output: output)
    }

    static func failure(_ output: String) -> LaunchAgentCommandResult {
        LaunchAgentCommandResult(exitCode: 1, output: output)
    }
}

final class LaunchAgentManager {
    private let label = "com.pgui.feishu-meeting-bot"

    private var guiDomain: String {
        "gui/\(getuid())"
    }

    private var serviceTarget: String {
        "\(guiDomain)/\(label)"
    }

    func status() -> LaunchAgentStatus {
        guard AppPaths.exists(AppPaths.launchAgentPlist) else {
            return .missing
        }

        let result = runLaunchctl(["print", serviceTarget])
        if !result.succeeded {
            return hasRunningBotProcess() ? .running : .stopped
        }

        let lines = result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        if lines.contains("state = running") {
            return .running
        }

        for line in lines where line.hasPrefix("pid =") {
            let rawPID = line.replacingOccurrences(of: "pid =", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int(rawPID), pid > 0 {
                return .running
            }
        }

        return .stopped
    }

    func isLaunchAtLoginEnabled() -> Bool {
        guard AppPaths.exists(AppPaths.launchAgentPlist) else {
            return false
        }

        let result = runLaunchctl(["print-disabled", guiDomain])
        guard result.succeeded else {
            return true
        }

        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("\"\(label)\"") else {
                continue
            }

            if trimmed.contains("=> disabled") {
                return false
            }

            if trimmed.contains("=> enabled") {
                return true
            }
        }

        return true
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) -> LaunchAgentCommandResult {
        guard AppPaths.exists(AppPaths.launchAgentPlist) else {
            return .failure("未找到 LaunchAgent 配置文件")
        }

        return runLaunchctl([
            enabled ? "enable" : "disable",
            serviceTarget,
        ])
    }

    func start() -> LaunchAgentCommandResult {
        guard AppPaths.exists(AppPaths.launchAgentPlist) else {
            return .failure("未找到 LaunchAgent 配置文件")
        }

        let wasEnabled = isLaunchAtLoginEnabled()
        var leading: [LaunchAgentCommandResult] = []
        if !wasEnabled {
            leading.append(runLaunchctl(["enable", serviceTarget]))
        }
        let bootstrap = runLaunchctl([
            "bootstrap",
            guiDomain,
            AppPaths.launchAgentPlist.path,
        ])
        let kickstart = runLaunchctl(["kickstart", "-k", serviceTarget])
        var trailing: [LaunchAgentCommandResult] = []
        if !wasEnabled {
            trailing.append(runLaunchctl(["disable", serviceTarget]))
        }

        return combinedResult(
            leading + [bootstrap, kickstart] + trailing,
            exitCode: kickstart.exitCode
        )
    }

    func stop() -> LaunchAgentCommandResult {
        guard AppPaths.exists(AppPaths.launchAgentPlist) else {
            return .failure("未找到 LaunchAgent 配置文件")
        }

        let result = runLaunchctl([
            "bootout",
            guiDomain,
            AppPaths.launchAgentPlist.path,
        ])

        if result.succeeded || status() == .stopped {
            return .success(result.output)
        }

        return result
    }

    func restart() -> LaunchAgentCommandResult {
        guard AppPaths.exists(AppPaths.launchAgentPlist) else {
            return .failure("未找到 LaunchAgent 配置文件")
        }

        let wasEnabled = isLaunchAtLoginEnabled()
        var leading: [LaunchAgentCommandResult] = []
        if !wasEnabled {
            leading.append(runLaunchctl(["enable", serviceTarget]))
        }

        let kickstart = runLaunchctl(["kickstart", "-k", serviceTarget])
        if kickstart.succeeded {
            var trailing: [LaunchAgentCommandResult] = []
            if !wasEnabled {
                trailing.append(runLaunchctl(["disable", serviceTarget]))
            }
            return combinedResult(leading + [kickstart] + trailing, exitCode: kickstart.exitCode)
        }

        let bootstrap = runLaunchctl([
            "bootstrap",
            guiDomain,
            AppPaths.launchAgentPlist.path,
        ])
        let secondKickstart = runLaunchctl(["kickstart", "-k", serviceTarget])
        var trailing: [LaunchAgentCommandResult] = []
        if !wasEnabled {
            trailing.append(runLaunchctl(["disable", serviceTarget]))
        }

        return combinedResult(
            leading + [kickstart, bootstrap, secondKickstart] + trailing,
            exitCode: secondKickstart.exitCode
        )
    }

    private func combinedResult(
        _ results: [LaunchAgentCommandResult],
        exitCode: Int32
    ) -> LaunchAgentCommandResult {
        let output = results
            .map(\.output)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return LaunchAgentCommandResult(exitCode: exitCode, output: output)
    }

    private func runLaunchctl(_ arguments: [String]) -> LaunchAgentCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return LaunchAgentCommandResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return LaunchAgentCommandResult(exitCode: -1, output: error.localizedDescription)
        }
    }

    private func hasRunningBotProcess() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", AppPaths.projectRoot.appendingPathComponent("bot.py").path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
