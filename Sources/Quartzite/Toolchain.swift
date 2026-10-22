import Foundation

/// Finds the optional open-source Cyclone V toolchain (yosys, nextpnr-mistral, mistral-cv).
///
/// Nothing in Quartzite needs it: without it the compile flow runs the Quartzite-only
/// logical stages and the Assembler is skipped, exactly as before. With it, the Fitter runs
/// real synthesis + place and route and the Assembler writes an experimental .sof.
///
/// Search order for each tool: the environment variable (`QUARTZITE_YOSYS`,
/// `QUARTZITE_NEXTPNR`, `QUARTZITE_MISTRAL_CV`), then `~/.quartzite/toolchain/prefix/bin`
/// (or `$QUARTZITE_TOOLCHAIN/prefix/bin`), then `PATH`, then the usual Homebrew folders
/// (an app started from Finder gets a minimal PATH). `QUARTZITE_NO_TOOLCHAIN=1` hides the
/// toolchain, which is how the fallback is tested.
struct Toolchain {
    struct Tool {
        var name: String
        var url: URL
        /// How it was found ("QUARTZITE_YOSYS", "toolchain folder", "PATH", ...).
        var source: String
    }

    var yosys: Tool
    var nextpnr: Tool
    var mistralCV: Tool

    var tools: [Tool] { [yosys, nextpnr, mistralCV] }

    struct Search {
        var toolchain: Toolchain?
        /// Tools that were not found, with the places that were searched.
        var missing: [(name: String, searched: [String])]
        var disabled = false

        /// One line for the Messages pane / CLI.
        var summary: String {
            if let t = toolchain {
                return "Open-source Cyclone V toolchain found: " + t.tools.map { "\($0.name) (\($0.url.path))" }.joined(separator: ", ")
            }
            if disabled { return "The open-source Cyclone V toolchain is disabled (QUARTZITE_NO_TOOLCHAIN is set)" }
            return "The open-source Cyclone V toolchain was not found (missing: \(missing.map { $0.name }.joined(separator: ", ")))"
        }
    }

    static let names = (yosys: "yosys", nextpnr: "nextpnr-mistral", mistralCV: "mistral-cv")

    static func defaultPrefix(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let t = env["QUARTZITE_TOOLCHAIN"], !t.isEmpty { return URL(fileURLWithPath: t, isDirectory: true).appendingPathComponent("prefix/bin", isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".quartzite/toolchain/prefix/bin", isDirectory: true)
    }

    static func locate(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Search {
        if let v = env["QUARTZITE_NO_TOOLCHAIN"], !v.isEmpty, v != "0" {
            return Search(toolchain: nil, missing: [], disabled: true)
        }
        let fm = FileManager.default
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var missing: [(String, [String])] = []
        func find(_ name: String, _ variable: String) -> Tool? {
            var searched: [String] = []
            if let v = env[variable], !v.isEmpty {
                searched.append("$\(variable)=\(v)")
                if fm.isExecutableFile(atPath: v) { return Tool(name: name, url: URL(fileURLWithPath: v), source: variable) }
            }
            let prefix = defaultPrefix(env).appendingPathComponent(name)
            searched.append(prefix.path)
            if fm.isExecutableFile(atPath: prefix.path) { return Tool(name: name, url: prefix, source: "toolchain folder") }
            for d in pathDirs {
                let p = URL(fileURLWithPath: d, isDirectory: true).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: p.path) { return Tool(name: name, url: p, source: "PATH") }
            }
            searched.append("PATH")
            for d in extra where !pathDirs.contains(d) {
                let p = URL(fileURLWithPath: d, isDirectory: true).appendingPathComponent(name)
                searched.append(p.path)
                if fm.isExecutableFile(atPath: p.path) { return Tool(name: name, url: p, source: d) }
            }
            missing.append((name, searched))
            return nil
        }
        let y = find(names.yosys, "QUARTZITE_YOSYS")
        let n = find(names.nextpnr, "QUARTZITE_NEXTPNR")
        let m = find(names.mistralCV, "QUARTZITE_MISTRAL_CV")
        if let y, let n, let m {
            return Search(toolchain: Toolchain(yosys: y, nextpnr: n, mistralCV: m), missing: [])
        }
        return Search(toolchain: nil, missing: missing)
    }

    /// Cached result of `locate()` for the current process environment.
    static let shared: Search = locate()

    // MARK: Versions

    private static let versionLock = NSLock()
    private static var versionCache: [String: String] = [:]

    /// Version strings, e.g. "Yosys 0.69+post (git sha1 143eb14f...)". Cached per path.
    func versions() -> [(tool: String, version: String)] {
        tools.map { t in (t.name, Toolchain.version(of: t)) }
    }

    static func version(of t: Tool) -> String {
        versionLock.lock()
        if let v = versionCache[t.url.path] { versionLock.unlock(); return v }
        versionLock.unlock()
        var v = "unknown"
        switch t.name {
        case names.yosys:
            if let r = try? ToolProcess.run(t.url, ["-V"]), r.status == 0 { v = r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        case names.nextpnr:
            if let r = try? ToolProcess.run(t.url, ["--version"]) {
                // "nextpnr-mistral" -- Next Generation Place and Route (Version nextpnr-0.11.1-46-gf7455496)
                let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let a = s.range(of: "(Version "), let b = s.range(of: ")", range: a.upperBound..<s.endIndex) {
                    v = String(s[a.upperBound..<b.lowerBound])
                } else if !s.isEmpty { v = s }
            }
        default:
            // mistral-cv has no --version option; identify the binary instead.
            let attrs = try? FileManager.default.attributesOfItem(atPath: t.url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let date = (attrs?[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "?"
            v = "Mistral (no version option; binary \(CompileFlow.thousands(size)) bytes, built \(date))"
        }
        versionLock.lock(); versionCache[t.url.path] = v; versionLock.unlock()
        return v
    }
}

/// Lets Stop Processing terminate a running external tool. Thread safe.
final class ProcessCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Process?
    private var cancelled = false

    init() {}

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = running
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Registers a process about to run; false if cancellation already happened.
    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        running = p
        return true
    }

    func detach() { lock.lock(); running = nil; lock.unlock() }
}

/// Runs one external tool with Foundation `Process` (works on macOS and Linux), merging
/// stdout and stderr and handing each output line to `onLine` while it runs.
enum ToolProcess {
    struct Result {
        var status: Int32
        var output: String
        var cancelled: Bool
        var elapsed: TimeInterval
    }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, cancel: ProcessCancel? = nil,
                    keepOutput: Bool = true, onLine: ((String) -> Void)? = nil) throws -> Result {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let start = Date()
        if let cancel, !cancel.attach(p) {
            return Result(status: -1, output: "", cancelled: true, elapsed: 0)
        }
        defer { cancel?.detach() }
        do { try p.run() } catch {
            throw Failure(message: "could not start \(exe.path): \(error.localizedDescription)")
        }
        // The parent's copy of the write end must be closed, or reading never sees EOF.
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        var collected = Data()
        var pending = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if keepOutput { collected.append(chunk) }
            if let onLine {
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    onLine(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                }
            }
        }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        p.waitUntilExit()
        try? reader.close()
        return Result(status: p.terminationStatus, output: String(decoding: collected, as: UTF8.self),
                      cancelled: cancel?.isCancelled ?? false, elapsed: Date().timeIntervalSince(start))
    }
}
