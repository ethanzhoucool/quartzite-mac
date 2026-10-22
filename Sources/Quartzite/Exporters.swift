import Foundation

/// Writers for the Quartus Prime text formats: .bdf, .qsf, .qpf, .vwf (plus a Verilog backup).
enum QuartusExport {
    struct Bundle {
        var files: [(name: String, contents: String)]
        var notes: [String]
    }

    static func makeBundle(_ project: Project, conn: Connectivity, date: Date = Date()) throws -> Bundle {
        try SimulationResult.validateInputCount(project.inputPins.count)
        let errors = Compiler.compile(project).1.filter { $0.level == .error }
        guard errors.isEmpty else {
            throw NSError(domain: "Quartzite", code: 3, userInfo: [NSLocalizedDescriptionKey: errors.map(\.text).joined(separator: "; ")])
        }
        let routing = Routing(project: project, conn: conn)
        // A forced stub through another net changes the function in Quartus.
        // Refuse the export instead of emitting a short circuit with a warning.
        guard routing.warnings.isEmpty else {
            throw NSError(domain: "Quartzite", code: 4, userInfo: [NSLocalizedDescriptionKey:
                routing.warnings.joined(separator: "; ") + ". Move the symbols apart before exporting."])
        }
        let e = project.entityName
        var notes = routing.warnings
        if !routing.labeledWires.isEmpty {
            notes.append("\(routing.labeledWires.count) wire(s) are written as matching net labels instead of drawn lines (they could not be drawn without touching another wire). Quartus treats them as connected.")
        }
        return Bundle(files: [
            ("\(e).qpf", qpf(project, date: date)),
            ("\(e).qsf", qsf(project, date: date)),
            ("\(e).bdf", bdf(project, routing: routing)),
            ("Waveform.vwf", try vwf(project)),
            ("\(e)_pins.qsf", pinAssignments(project)),
            ("\(e)_backup.v", verilog(project, conn: conn)),
            ("README_LAB.txt", readme(project)),
        ], notes: notes)
    }

    // MARK: - Project files

    static func quartusDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss  MMMM dd, yyyy"
        return f.string(from: d)
    }

    static func qpf(_ p: Project, date: Date) -> String {
        """
        # Quartus Prime project file written by Quartzite for Mac.
        # Open this file with File > Open Project in Quartus Prime 18.0 or newer.

        QUARTUS_VERSION = "18.0"
        DATE = "\(quartusDate(date))"

        # Revisions

        PROJECT_REVISION = "\(p.entityName)"

        """
    }

    static func qsf(_ p: Project, date: Date) -> String {
        let e = p.entityName
        var s = """
        # Quartus Prime settings file written by Quartzite for Mac.
        # Device: DE10-Standard (Cyclone V SoC \(p.device))

        set_global_assignment -name FAMILY "Cyclone V"
        set_global_assignment -name DEVICE \(p.device)
        set_global_assignment -name TOP_LEVEL_ENTITY \(e)
        set_global_assignment -name ORIGINAL_QUARTUS_VERSION 18.0.0
        set_global_assignment -name PROJECT_CREATION_TIME_DATE "\(quartusDate(date).uppercased())"
        set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
        set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0
        set_global_assignment -name MAX_CORE_JUNCTION_TEMP 85
        set_global_assignment -name ERROR_CHECK_FREQUENCY_DIVISOR 256
        set_global_assignment -name EDA_SIMULATION_TOOL "ModelSim-Altera (Verilog)"
        set_global_assignment -name EDA_TIME_SCALE "1 ps" -section_id eda_simulation
        set_global_assignment -name EDA_OUTPUT_DATA_FORMAT "VERILOG HDL" -section_id eda_simulation
        set_global_assignment -name BDF_FILE \(e).bdf
        set_global_assignment -name VECTOR_WAVEFORM_FILE Waveform.vwf

        """
        s += locationLines(p)
        s += ioStandardLines(p)
        s += """

        set_global_assignment -name PARTITION_NETLIST_TYPE SOURCE -section_id Top
        set_global_assignment -name PARTITION_FITTER_PRESERVATION_LEVEL PLACEMENT_AND_ROUTING -section_id Top
        set_global_assignment -name PARTITION_COLOR 16764057 -section_id Top
        set_instance_assignment -name PARTITION_HIERARCHY root_partition -to | -section_id Top

        """
        return s
    }

    static func locationLines(_ p: Project) -> String {
        var s = ""
        for pin in p.inputPins + p.outputPins {
            guard let loc = pin.location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else { continue }
            // Tcl only treats # as a comment at the start of a command, so keep notes on their own line.
            if let board = BoardPin.lookup(loc) { s += "# \(pin.name) -> \(board.label)\n" }
            s += "set_location_assignment \(loc.uppercased()) -to \(pin.name)\n"
        }
        return s
    }

    /// Each board pin's I/O standard, after the locations as Quartus saves them. Without it
    /// Quartus compiles every pin as its 2.5 V default.
    static func ioStandardLines(_ p: Project) -> String {
        var s = ""
        for pin in p.inputPins + p.outputPins {
            guard let board = BoardPin.lookup(pin.location) else { continue }
            s += "set_instance_assignment -name IO_STANDARD \"\(board.ioStandard)\" -to \(pin.name)\n"
        }
        return s
    }

    /// Assignments-only file for Assignments > Import Assignments in the lab.
    static func pinAssignments(_ p: Project) -> String {
        "# Pin assignments for \(p.entityName) (DE10-Standard). Import with Assignments > Import Assignments...\n\n"
            + locationLines(p) + ioStandardLines(p)
    }

    // MARK: - Block diagram (.bdf)

    static func bdf(_ p: Project, routing: Routing) -> String {
        var out = """
        /*
        WARNING: Do NOT edit the input and output ports in this file in a text
        editor if you plan to continue editing the block that represents it in
        the Block Editor! File corruption is VERY likely to occur.
        */
        /*
        Block diagram for \(p.entityName), written by Quartzite for Mac.
        */
        (header "graphic" (version "1.4"))

        """
        for c in p.components where c.kind == .input { out += inputPin(c) }
        for c in p.components where c.kind == .output { out += outputPin(c) }
        for c in p.components where !c.kind.isPin { out += symbol(c) }
        for s in routing.segments {
            out += "(connector\n\t(pt \(i(s.a.x)) \(i(s.a.y)))\n\t(pt \(i(s.b.x)) \(i(s.b.y)))\n)\n"
        }
        for st in routing.stubs {
            let w = textWidth(st.name)
            let left = min(st.from.x, st.to.x)
            let rect = "(rect \(i(left + 2)) \(i(st.from.y - 15)) \(i(left + 2 + w)) \(i(st.from.y - 3)))"
            out += "(connector\n\t(text \"\(st.name)\" \(rect)(font \"Arial\" ))\n\t(pt \(i(st.from.x)) \(i(st.from.y)))\n\t(pt \(i(st.to.x)) \(i(st.to.y)))\n)\n"
        }
        for j in routing.junctions { out += "(junction (pt \(i(j.x)) \(i(j.y))))\n" }
        for n in p.notes ?? [] where !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += note(n) }
        return out
    }

    private static func i(_ v: CGFloat) -> Int { Int(v.rounded()) }
    private static func textWidth(_ s: String) -> CGFloat { CGFloat(max(12, s.count * 7)) }

    /// BDF strings can't hold double quotes or line breaks.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }

    private static func rect(_ c: Component) -> String {
        "(rect \(c.x) \(c.y) \(c.x + Int(c.size.width)) \(c.y + Int(c.size.height)))"
    }

    static func pt(_ p: CGPoint) -> String { "(pt \(i(p.x)) \(i(p.y)))" }
    static func rectText(_ r: CGRect) -> String { "(rect \(i(r.minX)) \(i(r.minY)) \(i(r.maxX)) \(i(r.maxY)))" }

    /// One (drawing ...) element, already in oriented local coordinates.
    static func shape(_ s: Shape) -> String {
        switch s {
        case .line(let a, let b): return "(line \(pt(a))\(pt(b)))"
        case .arc(let a, let b, let r): return "(arc \(pt(a))\(pt(b))\(rectText(r)))"
        case .circle(let r): return "(circle \(rectText(r)))"
        }
    }

    /// A caption whose rect follows the symbol's orientation; Quartus marks text on a
    /// quarter-turned symbol as (vertical).
    private static func caption(_ text: String, _ r: CGRect, _ c: Component, font: String, extra: String = "") -> String {
        let o = c.orient
        let vertical = o.swapsAxes ? "(vertical)" : ""
        return "(text \"\(escape(text))\" \(rectText(o.rect(r, in: c.kind.size)))(font \"Arial\" \(font))\(vertical)\(extra))"
    }

    private static func drawing(_ c: Component) -> String {
        var s = "\t(drawing\n"
        for d in c.kind.primitive.drawing { s += "\t\t\(shape(d.oriented(c.orient, in: c.kind.size)))\n" }
        s += "\t)\n"
        if let tag = c.orient.bdfTag { s += "\t(\(tag))\n" }
        return s
    }

    private static func inputPin(_ c: Component) -> String {
        let k = c.kind, port = k.primitive.ports[0]
        var s = "(pin\n\t(input)\n\t\(rect(c))\n"
        s += "\t\(caption("INPUT", Caption.pinDirectionRect(k), c, font: "(font_size 6)"))\n"
        s += "\t\(caption(c.name, Caption.pinNameRect(k, c.name), c, font: ""))\n"
        s += "\t\(pt(c.orient.point(port.pt, in: k.size)))\n"
        s += drawing(c)
        s += "\t\(caption(c.defaultValue ?? "VCC", Caption.pinDefaultRect, c, font: "(font_size 6)"))\n"
        return s + ")\n"
    }

    private static func outputPin(_ c: Component) -> String {
        let k = c.kind, port = k.primitive.ports[0]
        var s = "(pin\n\t(output)\n\t\(rect(c))\n"
        s += "\t\(caption("OUTPUT", Caption.pinDirectionRect(k), c, font: "(font_size 6)"))\n"
        s += "\t\(caption(c.name, Caption.pinNameRect(k, c.name), c, font: ""))\n"
        s += "\t\(pt(c.orient.point(port.pt, in: k.size)))\n"
        s += drawing(c)
        return s + ")\n"
    }

    /// A logic primitive. Like Quartus, rotated or flipped symbols are written with every
    /// coordinate already transformed plus the matching (rotate90)/(flipy)/... tag.
    private static func symbol(_ c: Component) -> String {
        let k = c.kind, o = c.orient
        var s = "(symbol\n\t\(rect(c))\n"
        s += "\t\(caption(k.bdfName, Caption.typeRect(k), c, font: "(font_size 6)"))\n"
        s += "\t\(caption(c.name, Caption.instanceRect(k, c.name), c, font: ""))\n"
        for port in k.primitive.ports {
            let r = Caption.portTextRect(port)
            let text = "(text \"\(port.name)\" \(rectText(r))(font \"Courier New\" (bold))(invisible))"
            let moved = "(text \"\(port.name)\" \(rectText(o.rect(r, in: k.size)))(font \"Courier New\" (bold))"
                + (o.swapsAxes ? "(vertical)" : "") + "(invisible))"
            s += "\t(port\n"
            s += "\t\t\(pt(o.point(port.pt, in: k.size)))\n"
            s += "\t\t(\(port.isOutput ? "output" : "input"))\n"
            s += "\t\t\(text)\n\t\t\(moved)\n"
            s += "\t\t(line \(pt(o.point(port.isOutput ? port.lineEnd : port.pt, in: k.size)))\(pt(o.point(port.isOutput ? port.pt : port.lineEnd, in: k.size))))\n"
            s += "\t)\n"
        }
        s += drawing(c)
        return s + ")\n"
    }

    /// Free text from the Text Tool.
    static func note(_ n: TextNote) -> String {
        "(text \"\(escape(n.text))\" \(rectText(n.frame))(font \"Arial\" (font_size 8)))\n"
    }

    // MARK: - Waveform (.vwf)

    static func vwfTiming(_ n: Int) -> (end: Double, step: Double) {
        let rows = pow(2.0, Double(n))
        let end = max(1000.0, rows * 10)
        return (end, end / rows)
    }

    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    static func vwf(_ p: Project) throws -> String {
        try SimulationResult.validateInputCount(p.inputPins.count)
        let inputs = p.inputPins, outputs = p.outputPins
        let n = inputs.count
        let (end, step) = vwfTiming(n)
        var s = """
        /*
        WARNING: Do NOT edit the input and output ports in this file in a text
        editor if you plan to continue editing the block that represents it in
        the Block Editor! File corruption is VERY likely to occur.
        */

        /*
        Test vectors for \(p.entityName): every input combination, counting up
        from 0 with \(inputs.first?.name ?? "the first input") as the MSB. Outputs are left unknown
        (X) - run Simulation > Run Functional Simulation in Quartus to fill them in.
        Written by Quartzite for Mac.
        */

        HEADER
        {
        \tVERSION = 1;
        \tTIME_UNIT = ns;
        \tDATA_OFFSET = 0.0;
        \tDATA_DURATION = \(fmt(end));
        \tSIMULATION_TIME = 0.0;
        \tGRID_PHASE = 0.0;
        \tGRID_PERIOD = \(fmt(step));
        \tGRID_DUTY_CYCLE = 50;
        }


        """
        for pin in inputs + outputs {
            s += """
            SIGNAL("\(pin.name)")
            {
            \tVALUE_TYPE = NINE_LEVEL_BIT;
            \tSIGNAL_TYPE = SINGLE_BIT;
            \tWIDTH = 1;
            \tLSB_INDEX = -1;
            \tDIRECTION = \(pin.kind == .input ? "INPUT" : "OUTPUT");
            \tPARENT = "";
            }


            """
        }
        for (k, pin) in inputs.enumerated() {
            let bit = n - 1 - k
            let half = step * Double(1 << bit)
            let periods = (1 << n) / (1 << (bit + 1))
            s += """
            TRANSITION_LIST("\(pin.name)")
            {
            \tNODE
            \t{
            \t\tREPEAT = 1;
            \t\tNODE
            \t\t{
            \t\t\tREPEAT = \(periods);
            \t\t\tLEVEL 0 FOR \(fmt(half));
            \t\t\tLEVEL 1 FOR \(fmt(half));
            \t\t}
            \t}
            }


            """
        }
        for pin in outputs {
            s += """
            TRANSITION_LIST("\(pin.name)")
            {
            \tNODE
            \t{
            \t\tREPEAT = 1;
            \t\tLEVEL X FOR \(fmt(end));
            \t}
            }


            """
        }
        for (idx, pin) in (inputs + outputs).enumerated() {
            s += """
            DISPLAY_LINE
            {
            \tCHANNEL = "\(pin.name)";
            \tEXPAND_STATUS = COLLAPSED;
            \tRADIX = Binary;
            \tTREE_INDEX = \(idx);
            \tTREE_LEVEL = 0;
            }


            """
        }
        s += "TIME_BAR\n{\n\tTIME = 0;\n\tMASTER = TRUE;\n}\n;\n"
        return s
    }

    // MARK: - Verilog backup

    static func verilog(_ p: Project, conn: Connectivity) -> String {
        let e = p.entityName
        let ins = p.inputPins, outs = p.outputPins
        var portList = ins.map { "\tinput  wire \($0.name)" } + outs.map { "\toutput wire \($0.name)" }
        if portList.isEmpty { portList = ["\t/* no pins */"] }
        var s = "// Structural Verilog equivalent of \(e).bdf, written by Quartzite for Mac.\n"
        s += "// Backup only: the project uses \(e).bdf. If the schematic ever fails to open,\n"
        s += "// add this file to the project instead and make it the top-level entity.\n\n"
        s += "module \(e) (\n" + portList.joined(separator: ",\n") + "\n);\n"
        var names: [Int: String] = [:]
        var used = Set(p.components.map { $0.name.lowercased() })
        func name(_ net: Int) -> String {
            if let n = names[net] { return n }
            var n = conn.netName(net, project: p)
            if conn.nets[net].ports.allSatisfy({ p.component($0.comp)?.kind.isPin == false }) {
                var base = n, k = 1
                while used.contains(base.lowercased()) { base = "\(n)_\(k)"; k += 1 }
                n = base
                used.insert(n.lowercased())
            }
            names[net] = n
            return n
        }
        var wires: [String] = []
        var body: [String] = []
        for g in p.components where !g.kind.isPin {
            let outNet = conn.netOf[PortRef(comp: g.id, port: g.kind.arity)]!
            let o = name(outNet)
            let ins = (0..<g.kind.arity).map { name(conn.netOf[PortRef(comp: g.id, port: $0)]!) }
            let prim: String
            switch g.kind.family {
            case .not: prim = "not"
            case .and: prim = "and"
            case .or: prim = "or"
            case .nand: prim = "nand"
            case .nor: prim = "nor"
            case .xor: prim = "xor"
            case .xnor: prim = "xnor"
            default: continue
            }
            let args = ([o] + ins).joined(separator: ", ")
            body.append("\t\(prim) \(g.name) (\(args));")
        }
        for net in conn.nets {
            let n = name(net.id)
            let isPin = net.ports.contains { p.component($0.comp)?.kind.isPin == true }
            if !isPin && !wires.contains(n) { wires.append(n) }
        }
        for o in outs {
            let net = conn.netOf[PortRef(comp: o.id, port: 0)]!
            let n = name(net)
            if n != o.name { body.append("\tassign \(o.name) = \(n);") }
        }
        if !wires.isEmpty { s += "\twire " + wires.joined(separator: ", ") + ";\n\n" }
        s += body.joined(separator: "\n") + "\nendmodule\n"
        return s
    }

    // MARK: - README

    static func readme(_ p: Project) -> String {
        let e = p.entityName
        let pins = (p.inputPins + p.outputPins).map { pin -> String in
            let loc = pin.location ?? "(not assigned)"
            let board = BoardPin.lookup(pin.location)?.label ?? ""
            return "  \(pin.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(loc.padding(toLength: 10, withPad: " ", startingAt: 0)) \(board)"
        }.joined(separator: "\n")
        return """
        \(e) - Quartus project exported from Quartzite for Mac
        ==========================================================

        Files
          \(e).qpf        Quartus project (open this)
          \(e).qsf        Settings: device \(p.device), top-level entity, pin assignments
          \(e).bdf        Block diagram schematic (the circuit)
          Waveform.vwf    Simulation test vectors (all input combinations)
          \(e)_pins.qsf   Pin assignments only, for Assignments > Import Assignments
          \(e)_backup.v   Same circuit as structural Verilog (fallback only)

        Pin assignments
        \(pins)

        In the lab (Quartus 18.0)
          1. Copy this whole folder to the lab computer (OneDrive / USB).
          2. File > Open Project... > \(e).qpf
             If Quartus complains about the project version, instead create a new
             project named \(e) with device \(p.device), copy \(e).bdf into it,
             add it (Project > Add/Remove Files) and import \(e)_pins.qsf
             (Assignments > Import Assignments...).
          3. Processing > Start Compilation (Ctrl+L). Expect 0 errors.
          4. File > Open > Waveform.vwf, then Simulation > Run Functional Simulation.
             Optional: select the input rows, Edit > Grouping > Group..., radix Hexadecimal.
          5. Tools > Programmer: DE-SoC [USB-1], add SOCVHPS before the FPGA if needed,
             add output_files/\(e).sof, tick Program/Configure, Start.

        """
    }
}
