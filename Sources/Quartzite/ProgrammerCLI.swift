import Foundation

/// `--program` and `--detect`: the Programmer from the command line.
extension CLI {
    static let programmerUsage = "--program <file.sof> [--cable usb-blasterII|usb-blaster] [--firmware <blaster_6810.hex>] [--tool <openFPGALoader>] [--dry-run] | --detect [--cable ...] [--firmware ...] [--tool ...] [--bsdl <5CSXFC6D6F31.bsd>]"

    /// Options from the command line, the environment and the usual install places.
    /// Throws when a value is missing or the cable is unknown; `requireTool` false lets
    /// `--dry-run` print commands with a bare `openFPGALoader` when it is not installed.
    static func programmerOptions(_ args: [String], requireTool: Bool,
                                  environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> (options: ProgrammerOptions, notes: [String]) {
        func value(_ flag: String) throws -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw ProgrammerError.badFile("missing value for \(flag)") }
            return args[i + 1]
        }
        var notes: [String] = []
        var cable = ProgrammerCable.usbBlasterII
        if let c = try value("--cable") {
            guard let k = ProgrammerCable(rawValue: c) else {
                throw ProgrammerError.badFile("--cable must be \(ProgrammerCable.allCases.map(\.rawValue).joined(separator: " or ")) (got \"\(c)\")")
            }
            cable = k
        }
        let search = Programmer.locateTool(setting: try value("--tool"), environment: env)
        let tool: URL
        if let u = search.url { tool = u } else if requireTool {
            throw ProgrammerError.toolMissing(Programmer.toolMissingHelp + " (" + search.summary + ")")
        } else {
            tool = URL(fileURLWithPath: Programmer.toolName)
            notes.append("Note: \(search.summary)")
        }
        var o = ProgrammerOptions(tool: tool, cable: cable)
        if cable.needsFirmware {
            o.firmware = BlasterFirmware.locate(setting: try value("--firmware"), environment: env)
            if o.firmware == nil {
                if requireTool { throw ProgrammerError.firmwareMissing(BlasterFirmware.missingHelp) }
                o.firmware = URL(fileURLWithPath: BlasterFirmware.fileName)
                notes.append("Note: the USB-Blaster II firmware was not found; pass --firmware <path to \(BlasterFirmware.fileName)>")
            }
        }
        return (o, notes)
    }

    static func runProgrammer(_ args: [String]) -> Int32 {
        let dry = args.contains("--dry-run")
        do {
            if let i = args.firstIndex(of: "--program") {
                guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw ProgrammerError.badFile("usage: Quartzite \(programmerUsage)") }
                let file = URL(fileURLWithPath: args[i + 1])
                let (o, notes) = try programmerOptions(args, requireTool: !dry)
                notes.forEach { print($0) }
                if dry {
                    let plan = try ProgrammerService.dryRun(file: file, options: o, workDirectory: ProgrammerService.workDirectory)
                    plan.notes.forEach { print("Info: \($0)") }
                    print("Info: dry run; these commands would run (the FPGA is index \(Programmer.defaultFPGAIndex) on a DE10-Standard; Start uses the index Auto Detect finds):")
                    plan.commands.forEach { print($0) }
                    return 0
                }
                var svc = ProgrammerService(options: o)
                svc.log = { print($0) }
                var last = -1
                try svc.program(file: file, chain: nil, workDirectory: ProgrammerService.workDirectory) { p in
                    let pct = Int(p * 100)
                    if pct != last, pct % 10 == 0 { last = pct; print("Progress: \(pct)%") }
                }
                print("Progress: 100% (Successful)")
                return 0
            }
            // --detect
            let (o, notes) = try programmerOptions(args, requireTool: true)
            notes.forEach { print($0) }
            var svc = ProgrammerService(options: o)
            svc.log = { print($0) }
            let probes = (try? svc.scan()) ?? []
            print("Hardware: " + (probes.isEmpty ? "No Hardware" : probes.enumerated().map { $0.element.displayName(port: $0.offset + 1) }.joined(separator: ", ")))
            let chain = try svc.detect()
            for d in chain {
                print("Device \(d.index + 1): \(d.name)  IDCODE \(d.idcodeText)" + (d.detail.isEmpty ? "" : "  (\(d.detail))"))
            }
            if let i = args.firstIndex(of: "--bsdl"), i + 1 < args.count {
                let map = try BoardScanMap(bsdl: BSDLFile(text: String(contentsOf: URL(fileURLWithPath: args[i + 1]), encoding: .utf8)))
                let fpga = try ProgrammerService.fpga(in: chain)
                let s = try svc.sampleBoard(map: map, index: fpga.index, workDirectory: ProgrammerService.workDirectory)
                print(BoardScanMap.describe(s))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

extension BoardScanMap {
    /// "SW 9..0: 0000000101  KEY 3..0: ....  LEDR 9..0: ..." for the CLI.
    static func describe(_ s: BoardState) -> String {
        func bits(_ b: [Bool]) -> String { String(b.reversed().map { $0 ? "1" : "0" }) }
        let hex = (0..<6).reversed().map { d in "HEX\(d)=" + String(zip("abcdefg", s.segments[d]).compactMap { $0.1 ? $0.0 : nil }) }
        return "SW 9..0: \(bits(s.switches))  KEY 3..0 pressed: \(bits(s.keysPressed))  LEDR 9..0: \(bits(s.leds))\n" + hex.joined(separator: " ")
    }
}
