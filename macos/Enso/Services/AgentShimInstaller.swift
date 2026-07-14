import CryptoKit
import Foundation

/// Rewrites <EnsoAppSupport.directory>/shims/bin/ from the bundled
/// wrapper scripts at every launch — skipped when the version stamp already
/// matches — so the installed shims always match the running app. Not under
/// TMPDIR: macOS purges /var/folders entries not accessed for a few days.
enum AgentShimInstaller {
    static var shimBinDirectory: URL {
        EnsoAppSupport.directory
            .appendingPathComponent("shims", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Installed name → bundled resource. Wrappers take the agent's own name
    /// so PATH lookup finds them; the relay keeps its unique name.
    private static var installedResources: [(name: String, resource: String)] {
        AgentSessionAdapterRegistry.all.map { ($0.agentID, $0.wrapperResourceName) }
            + [(AgentSessionAdapterRegistry.hookRelayResourceName, AgentSessionAdapterRegistry.hookRelayResourceName)]
    }

    static func installIfNeeded(bundle: Bundle = .main) {
        var payloads: [(name: String, data: Data)] = []
        for entry in installedResources {
            guard let url = bundle.url(forResource: entry.resource, withExtension: "sh", subdirectory: "agent-shims"),
                  let data = try? Data(contentsOf: url) else {
                NSLog("AgentShimInstaller: missing bundled wrapper %@", entry.resource)
                return
            }
            payloads.append((entry.name, data))
        }

        let fm = FileManager.default
        let directory = shimBinDirectory
        let stampURL = directory.appendingPathComponent(".version")

        var hasher = SHA256()
        for payload in payloads {
            hasher.update(data: Data(payload.name.utf8))
            hasher.update(data: payload.data)
        }
        let stamp = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let alreadyInstalled = payloads.allSatisfy {
            fm.isExecutableFile(atPath: directory.appendingPathComponent($0.name).path)
        }
        if alreadyInstalled, (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp {
            return
        }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for payload in payloads {
            let target = directory.appendingPathComponent(payload.name)
            try? fm.removeItem(at: target)
            if !fm.createFile(atPath: target.path, contents: payload.data, attributes: [.posixPermissions: 0o755]) {
                NSLog("AgentShimInstaller: failed to write %@", target.path)
                return
            }
        }
        try? Data(stamp.utf8).write(to: stampURL, options: .atomic)
    }
}
