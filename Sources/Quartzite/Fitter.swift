import Foundation

/// Quartzite Fitter: places I/O on the assigned package pins (validating every location
/// against the 5CSXFC6D6F31C6 package and the DE10-Standard board), and assigns the
/// synthesized LUTs to ALMs and LABs. Logic placement uses Quartzite's own logical LAB
/// numbering; it is deterministic but is not a Quartus floorplan coordinate. Routing and
/// delays are not modelled.
struct FitResult {
    struct IOPlacement {
        var name: String
        var isInput: Bool
        var location: String
        var bank: String?
        var pad: Int?
        var ioType: String
        var assignedByUser: Bool
        var board: BoardPin?
        var fanout: Int
        var component: UUID
    }

    struct LogicPlacement {
        var lut: Int
        var name: String
        var lab: Int
        var alm: Int
        var half: Int
        var location: String { "LAB \(lab), ALM \(alm)\(half == 0 ? "" : " (second LUT)")" }
    }

    var io: [IOPlacement] = []
    var logic: [LogicPlacement] = []
    var alms = 0
    var labs = 0
    var messages: [Message] = []
    var errors: Int { messages.filter { $0.level == .error }.count }

    /// User I/O pins per bank on this package (for the I/O Bank Usage table).
    static let bankCapacity: [String: Int] = {
        var d: [String: Int] = [:]
        for p in CycloneV.pins.values where p.isUserIO { if let b = p.bank { d[b, default: 0] += 1 } }
        return d
    }()
}

enum Fitter {
    static func run(project: Project, circuit: CompiledCircuit, synthesis: SynthesisResult) -> FitResult {
        var r = FitResult()
        func msg(_ level: Message.Level, _ text: String, _ comp: UUID? = nil, _ children: [Message] = []) {
            r.messages.append(Message(level: level, text: text, component: comp, children: children))
        }

        guard project.device == CycloneV.device else {
            msg(.error, "Quartzite Fitter supports only \(CycloneV.device); no package/resource database is available for \(project.device)")
            return r
        }
        if synthesis.resources.alms > CycloneV.totalALMs {
            msg(.error, "Design requires \(synthesis.resources.alms) ALMs, but \(CycloneV.device) has only \(CycloneV.totalALMs)")
        }

        // Fan-out of each input pin's buffer in the LUT netlist.
        var inputFanout = [Int](repeating: 0, count: circuit.inputs.count)
        for l in synthesis.network.luts { for s in l.inputs { if case .input(let k) = s { inputFanout[k] += 1 } } }
        for s in synthesis.network.outputs { if case .input(let k) = s { inputFanout[k] += 1 } }

        let pins: [(Component, Bool, Int)] = circuit.inputs.enumerated().map { ($0.element, true, inputFanout[$0.offset]) }
            + circuit.outputs.map { ($0, false, 0) }

        var taken: [String: [Component]] = [:]
        var unassigned: [(Component, Bool, Int)] = []
        var placed: [(Component, Bool, Int, String)] = []
        for (pin, isInput, fanout) in pins {
            guard let raw = pin.location, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                unassigned.append((pin, isInput, fanout)); continue
            }
            let loc = CycloneV.normalize(raw)
            guard let pkg = CycloneV.pins[loc] else {
                msg(.error, "Location \(loc) assigned to pin \"\(pin.name)\" does not exist in the \(CycloneV.package) package of \(CycloneV.device)", pin.id)
                continue
            }
            switch pkg.kind {
            case .power:
                msg(.error, "Can't place pin \"\(pin.name)\" at \(loc): that ball is \(pkg.function ?? "a power pin"), not an I/O pin", pin.id)
                continue
            case .dedicated:
                msg(.error, "Can't place pin \"\(pin.name)\" at \(loc): that ball is the dedicated pin \(pkg.function ?? "")", pin.id)
                continue
            case .dualPurpose:
                msg(.warning, "Pin \"\(pin.name)\" is assigned to \(loc), a dual-purpose configuration pin (\(pkg.function ?? "")). Quartus reserves it during configuration unless the Dual-Purpose Pins settings release it.", pin.id)
            case .userIO: break
            }
            taken[loc, default: []].append(pin)
            placed.append((pin, isInput, fanout, loc))
        }
        for (loc, owners) in taken.sorted(by: { $0.key < $1.key }) where owners.count > 1 {
            msg(.error, "Can't place multiple pins assigned to pin location \(loc)", owners[0].id,
                owners.map { Message(level: .info, text: "Pin \($0.name) is assigned to pin location \(loc)", component: $0.id) })
        }

        // Board-level checks.
        for (pin, isInput, _, loc) in placed {
            guard let board = BoardPin.lookup(loc) else {
                msg(.warning, "Pin \"\(pin.name)\" is assigned to \(loc), a valid I/O pin that is not wired to any DE10-Standard switch, push button, LED, 7-segment display, clock or GPIO header pin", pin.id)
                continue
            }
            if board.kind != .gpio && board.isInput != isInput {
                msg(.warning, "\(isInput ? "Input" : "Output") pin \"\(pin.name)\" is assigned to \(loc), which is \(board.label) (\(board.kind.rawValue.lowercased())), \(board.isInput ? "an input" : "an output") on the DE10-Standard", pin.id)
            }
            if board.activeLow && isInput {
                msg(.info, "Pin \"\(pin.name)\" is on \(board.label), which is active low: it reads 0 while the button is pressed", pin.id)
            } else if board.activeLow && !isInput {
                msg(.info, "Pin \"\(pin.name)\" drives \(board.longLabel); the segment lights when the output is 0", pin.id)
            }
        }

        // Pins without a location: Quartus places them itself.
        if !unassigned.isEmpty {
            let total = pins.count
            msg(.criticalWarning, "No exact pin location assignment(s) for \(unassigned.count) pins of \(total) total pins. For the list of pins please refer to the I/O Assignment Warnings table in the fitter report",
                unassigned.first?.0.id,
                unassigned.map { Message(level: .info, text: "Pin \($0.0.name) not assigned to an exact location on the device", component: $0.0.id) })
            let used = Set(taken.keys)
            let boardPins = Set(BoardPin.all.map { $0.pin })
            var free = CycloneV.pins.values.filter { $0.isUserIO && !used.contains($0.location) && !boardPins.contains($0.location) }
                .sorted { ($0.bank ?? "", $0.location) < ($1.bank ?? "", $1.location) }
            for (pin, isInput, fanout) in unassigned {
                guard !free.isEmpty else {
                    msg(.error, "No unused non-board I/O location is available for pin \"\(pin.name)\"; assign a free board I/O pin explicitly or reduce the number of pins", pin.id)
                    continue
                }
                let p = free.removeFirst()
                r.io.append(.init(name: pin.name, isInput: isInput, location: p.location, bank: p.bank, pad: p.pad, ioType: p.ioType,
                                  assignedByUser: false, board: nil, fanout: fanout, component: pin.id))
            }
            msg(.info, "The Quartzite Fitter placed the unassigned pins on unused I/O pins that no board resource uses. Quartus will choose its own locations, so assign them in the Pin Planner before going to the lab.")
        }
        for (pin, isInput, fanout, loc) in placed where (taken[loc]?.count ?? 0) == 1 {
            let pkg = CycloneV.pins[loc]!
            r.io.append(.init(name: pin.name, isInput: isInput, location: loc, bank: pkg.bank, pad: pkg.pad, ioType: pkg.ioType,
                              assignedByUser: true, board: BoardPin.lookup(loc), fanout: fanout, component: pin.id))
        }
        let order = Dictionary(uniqueKeysWithValues: pins.enumerated().map { ($0.element.0.id, $0.offset) })
        r.io.sort { (order[$0.component] ?? 0) < (order[$1.component] ?? 0) }

        // Logic placement: ALMs filled in order, ten ALMs per LAB.
        for (a, alm) in synthesis.resources.almPacking.enumerated() {
            for (h, lut) in alm.enumerated() {
                r.logic.append(.init(lut: lut, name: synthesis.network.luts[lut].name,
                                     lab: a / CycloneV.almsPerLAB, alm: a % CycloneV.almsPerLAB, half: h))
            }
        }
        r.logic.sort { $0.lut < $1.lut }
        r.alms = synthesis.resources.alms
        r.labs = (r.alms + CycloneV.almsPerLAB - 1) / CycloneV.almsPerLAB
        return r
    }
}

/// Logic depth report used by the Timing Analysis stage. Quartzite has no Cyclone V
/// delay model, so this is a structural estimate (LUT levels), not a timing analysis.
struct TimingEstimate {
    struct Path { var from: String; var to: String; var levels: Int }
    var paths: [Path]
    var maxLevels: Int

    static func run(_ s: SynthesisResult) -> TimingEstimate {
        let net = s.network
        // depth[lut][input] = longest LUT chain from that input pin through this LUT.
        var depth: [[Int: Int]] = []
        for l in net.luts {
            var d: [Int: Int] = [:]
            for sig in l.inputs {
                switch sig {
                case .input(let k): d[k] = max(d[k] ?? 0, 1)
                case .lut(let j): for (k, v) in depth[j] { d[k] = max(d[k] ?? 0, v + 1) }
                case .constant: break
                }
            }
            depth.append(d)
        }
        var paths: [Path] = []
        for (o, sig) in net.outputs.enumerated() {
            switch sig {
            case .input(let k): paths.append(Path(from: net.inputNames[k], to: net.outputNames[o], levels: 0))
            case .lut(let j):
                for (k, v) in depth[j].sorted(by: { $0.key < $1.key }) {
                    paths.append(Path(from: net.inputNames[k], to: net.outputNames[o], levels: v))
                }
            case .constant: break
            }
        }
        paths.sort { $0.levels != $1.levels ? $0.levels > $1.levels : ($0.to, $0.from) < ($1.to, $1.from) }
        return TimingEstimate(paths: paths, maxLevels: paths.map { $0.levels }.max() ?? 0)
    }
}
