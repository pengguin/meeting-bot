import CryptoKit
import Foundation

enum PayloadVerificationError: LocalizedError {
    case invalidSecurityMode
    case missingFile(String)
    case invalidManifest(String)
    case unsafePath(String)
    case unsupportedFile(String)
    case fileSetMismatch
    case checksumMismatch(String)
    case signatureRequired
    case signatureInvalid

    var errorDescription: String? {
        switch self {
        case .invalidSecurityMode:
            return "应用构建安全模式无效。"
        case .missingFile(let name):
            return "安装载荷缺少 \(name)。"
        case .invalidManifest(let reason):
            return "安装载荷清单无效：\(reason)"
        case .unsafePath(let path):
            return "安装载荷包含不安全路径：\(path)"
        case .unsupportedFile(let path):
            return "安装载荷包含不支持的文件类型：\(path)"
        case .fileSetMismatch:
            return "安装载荷文件集合与签名清单不一致。"
        case .checksumMismatch(let path):
            return "安装载荷文件校验失败：\(path)"
        case .signatureRequired:
            return "正式构建缺少有效的载荷签名或独立发布公钥。"
        case .signatureInvalid:
            return "安装载荷签名验证失败。"
        }
    }
}

struct PayloadVerifier {
    private struct Manifest: Decodable {
        struct Signature: Decodable {
            let status: String
        }

        let kind: String
        let securityMode: String
        let fileCount: Int
        let checksumFile: String
        let checksumFileSHA256: String
        let signature: Signature

        enum CodingKeys: String, CodingKey {
            case kind
            case securityMode = "security_mode"
            case fileCount = "file_count"
            case checksumFile = "checksum_file"
            case checksumFileSHA256 = "checksum_file_sha256"
            case signature
        }
    }

    private static let metadataFiles = Set([
        "release-manifest.json",
        "payload-files.sha256",
        "release-manifest.sig",
    ])

    static func verify(
        payloadRoot: URL,
        resourceRoot: URL,
        securityMode: String
    ) throws {
        guard securityMode == "development" || securityMode == "distribution" else {
            throw PayloadVerificationError.invalidSecurityMode
        }

        let manifestURL = payloadRoot.appendingPathComponent("release-manifest.json")
        let checksumsURL = payloadRoot.appendingPathComponent("payload-files.sha256")
        let signatureURL = payloadRoot.appendingPathComponent("release-manifest.sig")
        let publicKeyURL = resourceRoot.appendingPathComponent("release-public-key.pem")
        let embeddedKeyURL = payloadRoot.appendingPathComponent("release-public-key.pem")

        try requireRegularFile(manifestURL, name: "release-manifest.json")
        try requireRegularFile(checksumsURL, name: "payload-files.sha256")
        if FileManager.default.fileExists(atPath: embeddedKeyURL.path) {
            throw PayloadVerificationError.invalidManifest("发布公钥不能位于待验证载荷中")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw PayloadVerificationError.invalidManifest("无法解析 JSON")
        }

        guard manifest.kind == "meetingbot-payload",
              manifest.securityMode == securityMode,
              manifest.checksumFile == "payload-files.sha256",
              manifest.checksumFileSHA256.count == 64 else {
            throw PayloadVerificationError.invalidManifest("关键字段不匹配")
        }

        let checksumsData = try Data(contentsOf: checksumsURL)
        guard sha256(checksumsData) == manifest.checksumFileSHA256.lowercased() else {
            throw PayloadVerificationError.checksumMismatch("payload-files.sha256")
        }

        let expectedFiles = try parseChecksums(checksumsData)
        guard expectedFiles.count == manifest.fileCount else {
            throw PayloadVerificationError.invalidManifest("文件数量不匹配")
        }

        let actualFiles = try enumeratePayloadFiles(payloadRoot)
        guard Set(expectedFiles.keys) == actualFiles else {
            throw PayloadVerificationError.fileSetMismatch
        }

        for (relativePath, expectedHash) in expectedFiles {
            let fileURL = payloadRoot.appendingPathComponent(relativePath)
            guard try sha256(fileURL) == expectedHash else {
                throw PayloadVerificationError.checksumMismatch(relativePath)
            }
        }

        let signatureExists = FileManager.default.fileExists(atPath: signatureURL.path)
        let signedManifest = manifest.signature.status == "signed"
        if securityMode == "distribution" || signatureExists || signedManifest {
            guard signatureExists,
                  signedManifest,
                  FileManager.default.fileExists(atPath: publicKeyURL.path) else {
                throw PayloadVerificationError.signatureRequired
            }
            try verifySignature(
                manifestURL: manifestURL,
                signatureURL: signatureURL,
                publicKeyURL: publicKeyURL
            )
        }
    }

    private static func requireRegularFile(_ url: URL, name: String) throws {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw PayloadVerificationError.missingFile(name)
        }
    }

    private static func parseChecksums(_ data: Data) throws -> [String: String] {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw PayloadVerificationError.invalidManifest("校验清单不是 UTF-8")
        }

        var result = [String: String]()
        var normalizedPaths = Set<String>()
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.isEmpty {
                continue
            }
            let line = String(rawLine)
            guard line.count > 66 else {
                throw PayloadVerificationError.invalidManifest("校验清单行格式错误")
            }
            let hashEnd = line.index(line.startIndex, offsetBy: 64)
            let separatorEnd = line.index(hashEnd, offsetBy: 2)
            let hash = String(line[..<hashEnd]).lowercased()
            let separator = String(line[hashEnd..<separatorEnd])
            let path = String(line[separatorEnd...])
            guard hash.allSatisfy(\.isHexDigit), separator == "  " else {
                throw PayloadVerificationError.invalidManifest("校验清单行格式错误")
            }
            try validateRelativePath(path)
            let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
            guard result[path] == nil, normalizedPaths.insert(normalized).inserted else {
                throw PayloadVerificationError.invalidManifest("校验清单包含重复路径")
            }
            result[path] = hash
        }
        return result
    }

    private static func enumeratePayloadFiles(_ root: URL) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw PayloadVerificationError.invalidManifest("无法遍历载荷")
        }

        var files = Set<String>()
        var normalizedPaths = Set<String>()
        let rootPrefix = root.standardizedFileURL.path + "/"
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else {
                throw PayloadVerificationError.unsafePath(path)
            }
            let relativePath = String(path.dropFirst(rootPrefix.count))
            try validateRelativePath(relativePath)
            if values.isSymbolicLink == true {
                throw PayloadVerificationError.unsupportedFile(relativePath)
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw PayloadVerificationError.unsupportedFile(relativePath)
            }
            if metadataFiles.contains(relativePath) {
                continue
            }
            let normalized = relativePath.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(normalized).inserted else {
                throw PayloadVerificationError.invalidManifest("载荷包含冲突路径")
            }
            files.insert(relativePath)
        }
        return files
    }

    private static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PayloadVerificationError.unsafePath(path)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifySignature(
        manifestURL: URL,
        signatureURL: URL,
        publicKeyURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "dgst",
            "-sha256",
            "-verify",
            publicKeyURL.path,
            "-signature",
            signatureURL.path,
            manifestURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PayloadVerificationError.signatureInvalid
        }
        guard process.terminationStatus == 0 else {
            throw PayloadVerificationError.signatureInvalid
        }
    }
}
