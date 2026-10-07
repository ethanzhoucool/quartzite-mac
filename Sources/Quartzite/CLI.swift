import Foundation

/// Command-line entry points (also used by CI on Linux, where there is no UI).
enum CLI {
    static let flags = ["--compile", "--selftest", "--export-suite", "--export-project", "--render-project", "--snapshot-window",
                        "--sof-info", "--sof-to-rbf", "--rbf-to-sof", "--sof-verify"]

    static func wants(_ args: [String]) -> Bool { args.contains { flags.contains($0) } }

    /// `--compile <file> --sof <out.sof>`: the full flow with real place and route and the
    /// experimental Assembler, printing each message as it is produced.
    static func compileToSOF(_ p: Project, sof: URL, args: [String], value: (String) -> String?) -> Int32 {
        let search = Toolchain.locate()
        print("Info: \(search.summary)")
        var hw: HardwareConfig? = nil
        if let tc = search.toolchain {
            var c = HardwareConfig(toolchain: tc, outputDirectory: sof.deletingLastPathComponent())
            c.sofURL = sof
            c.protectForeignSOF = false   // the user named the file
            if let w = value("--work") { c.workDirectory = URL(fileURLWithPath: w, isDirectory: true) }
            if let l = value("--layout"), let n = Int(l) { c.sofLayout = n }
            if let s = value("--seed"), let n = Int(s) { c.seed = n }
            hw = c
        } else {
            for m in search.missing { print("Info:     \(m.name) not found; searched \(m.searched.joined(separator: ", "))") }
        }
        let lock = NSLock()
        var printed = Set<UUID>()
        func show(_ m: Message) {
            lock.lock(); defer { lock.unlock() }
            guard printed.insert(m.id).inserted else { return }
            m.reportLines().forEach { print($0) }
        }
        hw?.onMessage = { show($0) }
        var state = FlowState(project: p, mainTask: "Compilation", hardware: hw)
        state.toolchainNote = hw == nil ? "Install the open-source toolchain (docs/TOOLCHAIN_NOTES.md) to generate the experimental .sof." : nil
        for stage in FlowStage.fullCompilation {
            let t = Date()
            let header = CompileFlow.header(stage, at: t)
            header.forEach(show)
            var run = CompileFlow.execute(stage, state: &state, started: t)
            run.messages.forEach(show)
            run.messages = header + run.messages
            state.runs.append(run)
            if run.status == .failed { break }
        }
        state.summary = CompileFlow.fullSummary(state)
        state.finished = Date()
        show(state.summary!)
        if args.contains("--report") { print(ReportText.render(CompileFlow.report(state))) }
        guard let a = state.assembly, a.passed else {
            print(hw == nil ? "No .sof was written: the open-source toolchain is not available." : "No .sof was written.")
            return 1
        }
        print("Wrote \(a.sofURL.path) (\(a.bytes) bytes, checksum \(a.checksumText)). \(HardwareFlow.shortNotice).")
        return state.failed ? 1 : 0
    }

    /// Returns the process exit code.
    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so progress shows up in CI logs and pipes
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        do {
            if let dir = value(after: "--export-suite") {
                try TestDesigns.exportSuite(to: URL(fileURLWithPath: dir, isDirectory: true))
                return 0
            }
            if let file = value(after: "--export-project"), let i = args.firstIndex(of: "--export-project"), i + 2 < args.count {
                let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
                let folder = args[i + 2]
                try TestDesigns.exportSuite(to: URL(fileURLWithPath: folder, isDirectory: true), designs: [(p.entityName, p)])
                return 0
            }
            #if canImport(SwiftUI)
            if let file = value(after: "--render-project"), let i = args.firstIndex(of: "--render-project"), i + 2 < args.count {
                let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
                let dir = URL(fileURLWithPath: args[i + 2], isDirectory: true)
                return MainActor.assumeIsolated { SelfTest.renderProject(p, to: dir) } ? 0 : 1
            }
            if let file = value(after: "--snapshot-window"), let i = args.firstIndex(of: "--snapshot-window"), i + 2 < args.count {
                let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
                let dir = URL(fileURLWithPath: args[i + 2], isDirectory: true)
                if args.contains("--hardware") { return MainActor.assumeIsolated { WindowSnapshot.runHardware(p, to: dir) } ? 0 : 1 }
                return MainActor.assumeIsolated { WindowSnapshot.run(p, to: dir) } ? 0 : 1
            }
            #endif
            if let file = value(after: "--compile") {
                // Quartzite --compile <file.qzproj> [--report] [--sof <out.sof> [--layout 16|17] [--work <dir>] [--seed n]]
                let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
                guard let sofPath = value(after: "--sof") else {
                    let state = CompileFlow.run(p)
                    for m in state.messages { m.reportLines().forEach { print($0) } }
                    if args.contains("--report") { print(ReportText.render(CompileFlow.report(state))) }
                    return state.failed ? 1 : 0
                }
                return compileToSOF(p, sof: URL(fileURLWithPath: sofPath), args: args, value: value)
            }
            if let dir = value(after: "--sof-verify") {
                // Quartzite --sof-verify <samples dir>: real-file SOF/RBF checks (see ci/sof_check.sh)
                return SOFSelfTest.verifySamples(dir) ? 0 : 1
            }
            if let file = value(after: "--sof-info") {
                // Quartzite --sof-info <file.sof>
                let sof = try SOFFile(contentsOf: URL(fileURLWithPath: file))
                sof.info().forEach { print($0) }
                return 0
            }
            if let i = args.firstIndex(of: "--sof-to-rbf"), i + 2 < args.count {
                // Quartzite --sof-to-rbf <in.sof> <out.rbf> [--compressed]
                let sof = try SOFFile(contentsOf: URL(fileURLWithPath: args[i + 1]))
                let rbf = try sof.extractRBF(compressed: args.contains("--compressed"))
                try rbf.write(to: URL(fileURLWithPath: args[i + 2]), options: .atomic)
                print("wrote \(args[i + 2]) (\(rbf.count) bytes)")
                return 0
            }
            if let i = args.firstIndex(of: "--rbf-to-sof"), i + 3 < args.count {
                // Quartzite --rbf-to-sof <in.rbf> <device> <out.sof> [--template <orig.sof>] [--layout 14|16|17] [--legacy (= --layout 14)] [--project <name>] [--compiler-version <string>]
                let rbf = try Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
                var opt = SOFFile.WrapOptions()
                if let t = value(after: "--template") { opt.template = try SOFFile(contentsOf: URL(fileURLWithPath: t)) }
                if let n = value(after: "--project") { opt.projectName = n }
                if let v = value(after: "--compiler-version") { opt.compilerVersion = v }
                if args.contains("--legacy") { opt.layout = 14 }
                for flag in ["--template", "--project", "--compiler-version", "--layout"] where args.contains(flag) {
                    guard let v = value(after: flag), !v.hasPrefix("--") else { throw SOFError.invalid("missing value for \(flag)") }
                }
                if let l = value(after: "--layout") {
                    guard let n = Int(l), [14, 16, 17].contains(n) else { throw SOFError.invalid("layout must be 14, 16 or 17") }
                    opt.layout = n
                }
                let sof = try SOFFile(wrapping: rbf, device: args[i + 2], options: opt)
                let out = sof.serialize()
                try out.write(to: URL(fileURLWithPath: args[i + 3]), options: .atomic)
                print("wrote \(args[i + 3]) (\(out.count) bytes)")
                return 0
            }
            if args.contains("--selftest") { return SelfTest.run(args) ? 0 : 1 }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print("usage: Quartzite --selftest [dir] | --sof-info <f.sof> | --sof-to-rbf <in.sof> <out.rbf> [--compressed] | --rbf-to-sof <in.rbf> <device> <out.sof> [--template f.sof] [--layout 14|16|17] [--project name] [--compiler-version s] | --compile <file.qzproj> [--report] [--sof <out.sof> [--layout 16|17] [--work dir] [--seed n]] | --export-suite <dir> | --export-project <file.qzproj> <dir>")
        return 2
    }
}

#if !canImport(SwiftUI)
@main
struct QuartziteCLI {
    static func main() { exit(CLI.run(CommandLine.arguments)) }
}
#endif
