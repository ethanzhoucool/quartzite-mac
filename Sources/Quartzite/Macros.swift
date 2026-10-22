import Foundation

// MARK: - VCC and GND

/// The constant primitives in Quartus' primitives > other library.
enum BuiltinSymbols {
    /// From a .bdf that Quartus Prime 18.0 compiled (ci/fixtures/quartus18/lab2/vcc_symbol.txt).
    static let vccText = """
    (symbol
    \t(rect 304 208 336 224)
    \t(text "VCC" (rect 7 0 27 10)(font "Arial" (font_size 6)))
    \t(text "inst" (rect 3 5 26 17)(font "Arial" )(invisible))
    \t(port
    \t\t(pt 16 16)
    \t\t(output)
    \t\t(text "1" (rect 19 7 27 19)(font "Courier New" (bold))(invisible))
    \t\t(text "1" (rect 19 7 27 19)(font "Courier New" (bold))(invisible))
    \t\t(line (pt 16 16)(pt 16 8))
    \t)
    \t(drawing
    \t\t(line (pt 8 8)(pt 24 8))
    \t)
    )
    """

    // PROVISIONAL until CT-0b P1-4: the GND primitive as it appears in older Quartus-saved
    // .bdf files (32 x 32, output at the top, a triangle below the bar).
    static let gndText = """
    (symbol
    \t(rect 304 240 336 272)
    \t(text "GND" (rect 8 16 29 26)(font "Arial" (font_size 6)))
    \t(text "inst" (rect 3 21 26 33)(font "Arial" )(invisible))
    \t(port
    \t\t(pt 16 0)
    \t\t(output)
    \t\t(text "1" (rect 18 0 26 12)(font "Courier New" (bold))(invisible))
    \t\t(text "1" (rect 18 0 26 12)(font "Courier New" (bold))(invisible))
    \t\t(line (pt 16 8)(pt 16 0))
    \t)
    \t(drawing
    \t\t(line (pt 8 8)(pt 16 16))
    \t\t(line (pt 16 16)(pt 24 8))
    \t\t(line (pt 8 8)(pt 24 8))
    \t)
    )
    """

    static let vcc: SymbolDef = try! SymbolDef(parsing: vccText, source: .library, libraryPath: ["primitives", "other"])
    static let gnd: SymbolDef = try! SymbolDef(parsing: gndText, source: .library, libraryPath: ["primitives", "other"])
    static let vccPrimitive = vcc.primitive
    static let gndPrimitive = gnd.primitive
}
