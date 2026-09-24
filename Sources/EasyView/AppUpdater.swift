import AppKit
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var currentTag: String
    @Published private(set) var availableTag: String?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var statusMessage: String?

    private var latestRelease: ReleaseMetadata?
    private var latestAsset: ReleaseAsset?

    init() {
        currentTag = Bundle.main.infoDictionary?["EasyViewGitTag"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "未标记"
    }

    func checkForUpdates() async {
        guard !isInstalling else { return }
        isChecking = true
        statusMessage = nil
        availableTag = nil
        latestRelease = nil
        latestAsset = nil
        defer { isChecking = false }

        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/qeekey/EasyView/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("EasyView-macOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw UpdateError.message("无法获取 GitHub 最新版本信息。")
            }

            let release = try JSONDecoder().decode(ReleaseMetadata.self, from: data)
            guard let current = ParsedVersion(currentTag),
                  let latest = ParsedVersion(release.tagName) else {
                throw UpdateError.message("无法比较当前版本与 GitHub 版本号。")
            }
            guard latest > current else { return }

            guard let asset = release.assets.first(where: { $0.name == "EasyView.dmg" }),
                  let digest = asset.digest,
                  digest.lowercased().hasPrefix("sha256:") else {
                throw UpdateError.message("最新版本暂未提供可校验的 EasyView.dmg。")
            }
            guard let downloadURL = URL(string: asset.browserDownloadURL),
                  downloadURL.scheme == "https",
                  downloadURL.host == "github.com",
                  downloadURL.path.hasPrefix("/qeekey/EasyView/releases/download/") else {
                throw UpdateError.message("最新版本的下载地址无效。")
            }

            latestRelease = release
            latestAsset = asset
            availableTag = release.tagName
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installLatest() async {
        guard let release = latestRelease,
              let asset = latestAsset,
              let downloadURL = URL(string: asset.browserDownloadURL),
              let digest = asset.digest,
              !isInstalling else { return }
        isInstalling = true
        statusMessage = "正在下载最新版…"
        var handedOffToInstaller = false
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyViewUpdate-\(UUID().uuidString)", isDirectory: true)

        defer {
            isInstalling = false
            if !handedOffToInstaller {
                try? FileManager.default.removeItem(at: workDirectory)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var request = URLRequest(url: downloadURL)
            request.setValue("EasyView-macOS", forHTTPHeaderField: "User-Agent")
            let (downloadedFile, response) = try await URLSession.shared.download(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw UpdateError.message("下载 EasyView.dmg 失败。")
            }

            let dmgURL = workDirectory.appendingPathComponent("EasyView.dmg")
            try FileManager.default.moveItem(at: downloadedFile, to: dmgURL)
            statusMessage = "正在校验下载文件…"
            let actualDigest = SHA256.hash(data: try Data(contentsOf: dmgURL))
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest.lowercased() == "sha256:\(actualDigest)" else {
                throw UpdateError.message("下载文件校验失败，未安装更新。")
            }

            statusMessage = "正在准备安装…"
            let mountPoint = workDirectory.appendingPathComponent("Mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try Self.runProcess(
                "/usr/bin/hdiutil",
                ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmgURL.path]
            )
            var isMounted = true
            defer {
                if isMounted {
                    try? Self.runProcess("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path])
                }
            }

            guard let appInDiskImage = try Self.applicationBundle(in: mountPoint, expectedTag: release.tagName) else {
                throw UpdateError.message("磁盘映像中没有与此应用匹配的新版简图。")
            }

            let stagedApp = workDirectory.appendingPathComponent("简图.app", isDirectory: true)
            try FileManager.default.copyItem(at: appInDiskImage, to: stagedApp)
            try Self.runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
            try Self.runProcess("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path])
            isMounted = false

            let installScript = workDirectory.appendingPathComponent("install-update.sh")
            try Self.installScript.write(to: installScript, atomically: true, encoding: .utf8)
            try Self.launchInstaller(
                script: installScript,
                processID: ProcessInfo.processInfo.processIdentifier,
                stagedApp: stagedApp,
                destination: Bundle.main.bundleURL.standardizedFileURL,
                workDirectory: workDirectory
            )
            handedOffToInstaller = true
            statusMessage = "安装已准备，应用即将关闭并重启。"
            NSApp.terminate(nil)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static func applicationBundle(in mountPoint: URL, expectedTag: String) throws -> URL? {
        var candidates: [URL] = []
        let rootInfo = mountPoint.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: rootInfo.path) {
            // `hdiutil -srcfolder Some.app` copies the bundle's contents to the
            // image root, rather than preserving the outer .app directory.
            // Treat that root as the app bundle for compatibility with releases
            // produced by the previous workflow.
            candidates.append(mountPoint)
        }

        if let enumerator = FileManager.default.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let entry as URL in enumerator where entry.pathExtension == "app" {
                candidates.append(entry)
            }
        }

        let expectedVersion = expectedTag.hasPrefix("v") ? String(expectedTag.dropFirst()) : expectedTag
        var foundThisAppWithDifferentVersion: String?
        for entry in candidates {
            let infoURL = entry.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == "com.qeekey.easyview" else { continue }
            let embeddedTag = info["EasyViewGitTag"] as? String
            let embeddedVersion = info["CFBundleShortVersionString"] as? String
            if embeddedTag == expectedTag || embeddedVersion == expectedVersion {
                return entry
            }
            foundThisAppWithDifferentVersion = embeddedTag ?? embeddedVersion ?? "未知"
        }
        if let foundThisAppWithDifferentVersion {
            throw UpdateError.message(
                "GitHub \(expectedTag) 的 EasyView.dmg 内含简图 \(foundThisAppWithDifferentVersion)，与发布版本不一致。为避免覆盖当前应用，已取消更新；请重新发布正确的 DMG。"
            )
        }
        return nil
    }

    private static func runProcess(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.message(detail?.isEmpty == false ? detail! : "更新操作失败（\(path)）。")
        }
    }

    private static func launchInstaller(
        script: URL,
        processID: pid_t,
        stagedApp: URL,
        destination: URL,
        workDirectory: URL
    ) throws {
        let arguments = [
            String(processID), stagedApp.path, destination.path, workDirectory.path
        ]
        let parentDirectory = destination.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parentDirectory.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return
        }

        let shellCommand = ([script.path] + arguments).map(shellQuoted).joined(separator: " ")
        let detachedCommand = "nohup /bin/sh \(shellCommand) >/dev/null 2>&1 &"
        let appleScriptSource = "do shell script \(appleScriptQuoted(detachedCommand)) with administrator privileges"
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            throw UpdateError.message("无法启动需要管理员授权的安装步骤。")
        }
        var error: NSDictionary?
        _ = appleScript.executeAndReturnError(&error)
        if error != nil {
            throw UpdateError.message("管理员授权已取消，更新未安装。")
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static let installScript = """
    #!/bin/sh
    set -eu
    WAIT_PID="$1"
    SOURCE_APP="$2"
    DEST_APP="$3"
    WORK_DIR="$4"
    STAGED_APP="${DEST_APP}.updating-${WAIT_PID}"
    BACKUP_APP="${DEST_APP}.backup-${WAIT_PID}"

    while /bin/kill -0 "$WAIT_PID" 2>/dev/null; do /bin/sleep 1; done
    /usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
    if [ -e "$DEST_APP" ]; then /bin/mv "$DEST_APP" "$BACKUP_APP"; fi
    if ! /bin/mv "$STAGED_APP" "$DEST_APP"; then
        if [ -e "$BACKUP_APP" ]; then /bin/mv "$BACKUP_APP" "$DEST_APP"; fi
        exit 1
    fi
    if ! /usr/bin/codesign --verify --deep --strict "$DEST_APP"; then
        /bin/mv "$DEST_APP" "$STAGED_APP"
        if [ -e "$BACKUP_APP" ]; then /bin/mv "$BACKUP_APP" "$DEST_APP"; fi
        exit 1
    fi
    /bin/rm -rf "$BACKUP_APP"
    /usr/bin/open "$DEST_APP"
    /bin/rm -rf "$WORK_DIR"
    """
}

private struct ReleaseMetadata: Decodable {
    let tagName: String
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

}

private struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

private enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

private struct ParsedVersion: Comparable {
    let components: [Int]
    let prerelease: [String]?

    init?(_ tag: String) {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let versionParts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count else { return nil }
        self.components = numbers
        if versionParts.count > 1 {
            let parts = versionParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = parts
        } else {
            prerelease = nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, .some): return false
        case (.some, nil): return true
        case let (.some(left), .some(right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] { continue }
                let leftNumber = Int(left[index])
                let rightNumber = Int(right[index])
                if let leftNumber, let rightNumber { return leftNumber < rightNumber }
                if leftNumber != nil { return true }
                if rightNumber != nil { return false }
                return left[index] < right[index]
            }
            return left.count < right.count
        }
    }
}

struct AboutPanelView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
            Text("简图")
                .font(.title2.weight(.semibold))
            Text("版本 \(updater.currentTag)")
                .font(.body)

            if let latestTag = updater.availableTag {
                Button(updater.isInstalling ? "正在更新…" : "立即更新到最新版") {
                    Task { await updater.installLatest() }
                }
                .disabled(updater.isInstalling)
                .help("下载并安装版本 \(latestTag)")
            } else if updater.isChecking {
                ProgressView().controlSize(.small)
            }

            if let message = updater.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            Text("版权所有 © 2026 qeekey")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360, height: 292)
    }
}
