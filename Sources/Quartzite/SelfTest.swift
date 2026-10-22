import Foundation
#if canImport(SwiftUI)
import SwiftUI
import AppKit
#endif

/// `Quartzite --selftest [outdir]` builds a sample circuit, checks it, and writes the export bundle.
enum SelfTest {
    static func run(_ args: [String]) -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print(cond ? "  ok   \(what)" : "  FAIL \(what)")
            if !cond { ok = false }
        }

        // f = w'x + y z'   (wired), plus a labelled path to exercise net labels.
        var p = Project()
        p.name = "SelfTest"
        let names = ["w", "x", "y", "z"], locs = ["PIN_AC30", "PIN_AB28", "PIN_Y27", "PIN_AB30"]
        var pins: [Component] = []
        for (i, (n, l)) in zip(names, locs).enumerated() {
            pins.append(Component(kind: .input, name: n, x: 32, y: 64 + 64 * i, location: l))
        }
        let notW = Component(kind: .not, name: "inst", x: 256, y: 48)
        let notZ = Component(kind: .not, name: "inst1", x: 256, y: 240)
        let and1 = Component(kind: .and2, name: "inst2", x: 400, y: 64)
        let and2 = Component(kind: .and2, name: "inst3", x: 400, y: 192)
        let or1 = Component(kind: .or2, name: "inst4", x: 560, y: 128)
        let out = Component(kind: .output, name: "f", x: 720, y: 144, location: "PIN_AA24")
        p.components = pins + [notW, notZ, and1, and2, or1, out]
        p.inputOrder = pins.map { $0.id }
        func w(_ a: Component, _ ap: Int, _ b: Component, _ bp: Int) -> Wire {
            Wire(a: PortRef(comp: a.id, port: ap), b: PortRef(comp: b.id, port: bp))
        }
        p.wires = [
            w(pins[0], 0, notW, 0),
            w(notW, 1, and1, 0),
            w(pins[1], 0, and1, 1),
            w(pins[3], 0, notZ, 0),
            w(notZ, 1, and2, 1),
            w(and1, 2, or1, 0),
            w(and2, 2, or1, 1),
            w(or1, 2, out, 0),
        ]
        // y reaches and2.IN1 through a net label only.
        p.labels[PortRef(comp: and2.id, port: 0).key] = "y"
        p.expected[out.id.uuidString] = "4,5,6,7,2,10,14"   // w'x + yz'

        print("Compile")
        let (circuit, msgs) = Compiler.compile(p)
        for m in msgs { print("    [\(m.level)] \(m.text)") }
        check(circuit != nil, "design compiles")
        guard let circuit else { return false }
        check(circuit.stats.gates == 5 && circuit.stats.gateInputs == 8, "stats 5 gates / 8 inputs")

        print("Simulate")
        guard let sim = try? SimulationResult.run(circuit, project: p) else { print("simulation failed"); return false }
        check(sim.rows.count == 16, "16 rows")
        let want: Set<Int> = [2, 4, 5, 6, 7, 10, 14]
        let got = Set(sim.rows.indices.filter { sim.rows[$0].outputs[0] })
        check(got == want, "truth table = Σm(2,4,5,6,7,10,14) (got \(got.sorted()))")
        check(sim.matches(output: 0) == true, "matches expected")

        print("Errors are caught")
        var broken = p
        broken.wires.removeLast()
        let (bc, bm) = Compiler.compile(broken)
        check(bc == nil && bm.contains { $0.text.contains("not driven") }, "undriven output detected")
        var loop = p
        loop.wires.append(w(or1, 2, and1, 1))
        check(Compiler.compile(loop).0 == nil, "multiple drivers / loop detected")

        print("Routing")
        let conn = Connectivity(p)
        let routing = Routing(project: p, conn: conn)
        check(routing.routes.count == p.wires.count, "every wire has a route")
        var conflicts = 0
        let segs = routing.segments + routing.stubs.map { Routing.Segment(a: $0.from, b: $0.to, net: $0.net) }
        for s in segs {
            for o in segs where o.net != s.net {
                if Routing.collinearOverlap(s.a, s.b, o.a, o.b) || Routing.onSegment(s.a, o.a, o.b) || Routing.onSegment(s.b, o.a, o.b) {
                    conflicts += 1
                }
            }
        }
        check(conflicts == 0, "no segments of different nets touch")

        CompilerSelfTest.run(check)
        HierarchySelfTest.run(check)
        ImportSelfTest.run(check)
        SOFSelfTest.run(check)
        HardwareSelfTest.run(check)
        ProgrammerSelfTest.run(check)

        print("Export")
        guard let bundle = try? QuartusExport.makeBundle(p, conn: conn) else { print("export failed"); return false }
        let bdf = bundle.files.first { $0.name.hasSuffix(".bdf") }!.contents
        var depth = 0, minDepth = 0
        var inString = false
        for ch in bdf.split(separator: "*/", maxSplits: 2).last! {
            if ch == "\"" { inString.toggle() }
            if inString { continue }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1; minDepth = min(minDepth, depth) }
        }
        check(depth == 0 && minDepth == 0, "bdf parentheses balanced")
        check(bdf.components(separatedBy: "(symbol").count - 1 == 5, "5 symbols in bdf")
        check(bdf.contains("(text \"y\""), "label connector present")
        let qsf = bundle.files.first { $0.name == "SelfTest.qsf" }!.contents
        check(qsf.contains("set_location_assignment PIN_AC30 -to w"), "qsf pin w")
        check(qsf.contains("DEVICE 5CSXFC6D6F31C6"), "qsf device")
        let vwf = bundle.files.first { $0.name == "Waveform.vwf" }!.contents
        check(vwf.contains("LEVEL 0 FOR 500.0;") && vwf.contains("REPEAT = 8;"), "vwf counting pattern")
        for n in bundle.notes { print("    note: \(n)") }

        print("Rotate and flip (Quartus convention)")
        // Coordinates from a rotated NOT in a Quartus-saved file (gdevic/A-Z80 alu_mux_8.bdf):
        // (rect 216 80 248 128), IN at (pt 16 0), OUT at (pt 16 48), tagged (rotate270).
        var rn = Component(kind: .not, name: "not2", x: 216, y: 80)
        rn.orientation = .rotate270
        check(rn.frame == CGRect(x: 216, y: 80, width: 32, height: 48), "rotate270 NOT is 32 x 48")
        check(rn.portPoint(0) == CGPoint(x: 232, y: 80) && rn.portPoint(1) == CGPoint(x: 232, y: 128),
              "rotate270 NOT ports match Quartus")
        var fa = Component(kind: .and2, name: "inst8", x: 0, y: 0)
        fa.orientation = .flipy   // Quartus flipy AND2: inputs at (64,16)/(64,32), output (0,24)
        check(fa.portPoint(0) == CGPoint(x: 64, y: 16) && fa.portPoint(2) == CGPoint(x: 0, y: 24), "flipy AND2 ports match Quartus")
        check(Orientation.none.then(.rotate90)?.then(.rotate90) == .rotate180, "two left turns make 180")
        check(Orientation.flipy.then(.flipy) == Orientation.none, "flipping twice restores the symbol")
        check(Orientation.flipy.then(.rotate180) == .flipx, "flip horizontal + 180 = flip vertical")
        check(Orientation.rotate90.then(.flipy) == nil, "diagonal mirror is refused (Quartus has no tag for it)")
        var rp = p
        if let i = rp.index(of: notW.id) {
            rp.components[i].orientation = .rotate270
            rp.components[i].x = 288; rp.components[i].y = 48
        }
        let rb = QuartusExport.bdf(rp, routing: Routing(project: rp, conn: Connectivity(rp)))
        check(rb.contains("(rotate270)") && rb.contains("(vertical)"), "rotated symbol exported with (rotate270) and vertical text")
        let rsim = Compiler.compile(rp).0.flatMap { try? SimulationResult.run($0, project: rp) }
        check(rsim.map { r in Set(r.rows.indices.filter { r.rows[$0].outputs[0] }) } == want, "rotated NOT still computes the same function")

        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in bundle.files { try f.contents.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8) }
                print("Wrote \(bundle.files.count) files to \(dir.path)")
            } catch {
                print("Could not write self-test export: \(error.localizedDescription)")
                return false
            }
        }
        ok = RegressionTests.run() && ok
        #if canImport(SwiftUI)
        ok = MainActor.assumeIsolated { RegressionTests.runEditor() } && ok
        #endif
        print(ok ? "ALL PASSED" : "FAILURES")
        #if canImport(SwiftUI)
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated { render(p, sim: sim, to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
        }
        #endif
        return ok
    }

    #if canImport(SwiftUI)
    @MainActor
    static func render(_ p: Project, sim: SimulationResult, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(persist: false)
        store.project = p
        store.zoom = 1.25
        func save(_ name: String, _ v: some View) {
            let r = ImageRenderer(content: v)
            r.scale = 2
            guard let cg = r.cgImage else { print("render failed: \(name)"); return }
            let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            try? data.write(to: dir.appendingPathComponent(name))
            print("rendered \(name)")
        }
        save("schematic_export.png", SchematicSnapshot(store: store))
        save("canvas.png", SheetPreview(project: p, routing: store.routing))
        save("waveform.png", WaveformSnapshot(sim: sim, project: p.entityName))
        save("kmap.png", KMapView(sim: sim, output: 0).padding().background(Color.white).environment(\.colorScheme, .light))
        save("truth.png", TruthTableView(sim: sim).padding().background(Color.white).environment(\.colorScheme, .light))
        save("icons.png", HStack { ForEach(GateKind.placeable) { GateIcon(kind: $0).frame(width: 50, height: 30) } }
            .padding().background(Color.white).environment(\.colorScheme, .light))
    }
    /// Schematic and waveform images for a saved project's top-level sheet (used for lab hand-ins).
    @MainActor
    static func renderProject(_ d: DesignProject, to dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let p = d.top else { print("design has no top-level sheet"); return false }
        let store = Store(persist: false)
        store.loadDesign(d, from: nil, dirty: false)
        guard let circuit = Compiler.compile(d).0 else { print("design has errors"); return false }
        guard let sim = try? SimulationResult.run(circuit, project: p) else { print("simulation failed"); return false }
        func save(_ name: String, _ v: some View) -> Bool {
            let r = ImageRenderer(content: v)
            r.scale = 2
            guard let cg = r.cgImage,
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
            return (try? data.write(to: dir.appendingPathComponent(name))) != nil
        }
        let ok1 = save("\(p.entityName)_schematic.png", SchematicSnapshot(store: store))
        let ok2 = save("\(p.entityName)_waveform.png", WaveformSnapshot(sim: sim, project: p.entityName))
        // The Block Editor sheet as it looks on screen (grid, frames, Quartus colours).
        let ok3 = save("\(p.entityName)_canvas.png", SheetPreview(project: p, routing: store.routing))
        print("rendered schematic: \(ok1), waveform: \(ok2), canvas: \(ok3)")
        return ok1 && ok2 && ok3
    }
#endif
}
