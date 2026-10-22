import Foundation

// Boolean function representation and two-level minimization used by Quartzite's
// Analysis & Synthesis stage.
//
// Convention: a function of n variables is indexed by minterm number m in 0..<2^n.
// Variable "bit position" p is the bit (m >> p) & 1. The first input pin (the MSB of
// the minterm number, as in Σm notation) is bit position n - 1.

/// Truth table of an n-variable function (n <= 16), stored as a bitset.
struct TruthTable: Hashable {
    let n: Int
    private(set) var words: [UInt64]

    static let maxInputs = 16

    init(n: Int) {
        precondition(n >= 0 && n <= TruthTable.maxInputs)
        self.n = n
        words = Array(repeating: 0, count: max(1, (1 << n + 63) / 64))
    }

    init(n: Int, minterms: [Int]) {
        self.init(n: n)
        for m in minterms { self[m] = true }
    }

    init(n: Int, _ f: (Int) -> Bool) {
        self.init(n: n)
        for m in 0..<(1 << n) where f(m) { self[m] = true }
    }

    var size: Int { 1 << n }

    subscript(m: Int) -> Bool {
        get { (words[m >> 6] >> UInt64(m & 63)) & 1 == 1 }
        set {
            if newValue { words[m >> 6] |= 1 << UInt64(m & 63) } else { words[m >> 6] &= ~(1 << UInt64(m & 63)) }
        }
    }

    /// The function that equals variable `bit`.
    static func variable(_ bit: Int, n: Int) -> TruthTable { TruthTable(n: n) { ($0 >> bit) & 1 == 1 } }

    static func constant(_ v: Bool, n: Int) -> TruthTable { TruthTable(n: n) { _ in v } }

    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }
    var isZero: Bool { words.allSatisfy { $0 == 0 } }
    var isOne: Bool { count == size }
    var constantValue: Bool? { isZero ? false : (isOne ? true : nil) }
    var minterms: [Int] { (0..<size).filter { self[$0] } }

    /// Valid bits of word 0 when n < 6.
    private var lastMask: UInt64 { n >= 6 ? ~0 : (UInt64(1) << UInt64(1 << n)) - 1 }

    static prefix func ! (a: TruthTable) -> TruthTable {
        var r = a
        for i in r.words.indices { r.words[i] = ~r.words[i] }
        r.words[0] &= a.lastMask
        return r
    }

    static func & (a: TruthTable, b: TruthTable) -> TruthTable {
        var r = a
        for i in r.words.indices { r.words[i] &= b.words[i] }
        return r
    }

    static func | (a: TruthTable, b: TruthTable) -> TruthTable {
        var r = a
        for i in r.words.indices { r.words[i] |= b.words[i] }
        return r
    }

    /// Low-half masks for bit positions 0...5 inside a 64-bit word (positions where the bit is 0).
    private static let halfMasks: [UInt64] = [0x5555555555555555, 0x3333333333333333, 0x0F0F0F0F0F0F0F0F,
                                              0x00FF00FF00FF00FF, 0x0000FFFF0000FFFF, 0x00000000FFFFFFFF]

    /// Whether the function changes with variable `bit` somewhere.
    func depends(on bit: Int) -> Bool {
        guard bit < n else { return false }
        if bit < 6 {
            let m = TruthTable.halfMasks[bit], s = UInt64(1 << bit)
            return words.contains { ($0 & m) != (($0 >> s) & m) }
        }
        let stride = 1 << (bit - 6)
        for i in words.indices where (i / stride) % 2 == 0 {
            if words[i] != words[i + stride] { return true }
        }
        return false
    }

    /// Bit positions the function depends on, highest (first input) first.
    var support: [Int] { (0..<n).reversed().filter { depends(on: $0) } }

    /// f with variable `bit` fixed; the result no longer depends on `bit`.
    func cofactor(_ bit: Int, _ value: Bool) -> TruthTable {
        guard bit < n else { return self }
        var r = self
        if bit < 6 {
            let m = TruthTable.halfMasks[bit], s = UInt64(1 << bit)
            for i in r.words.indices {
                let half = value ? (words[i] >> s) & m : words[i] & m
                r.words[i] = half | (half << s)
            }
            r.words[0] &= lastMask
        } else {
            let stride = 1 << (bit - 6)
            for i in words.indices where (i / stride) % 2 == 0 {
                let v = value ? words[i + stride] : words[i]
                r.words[i] = v
                r.words[i + stride] = v
            }
        }
        return r
    }
}

/// A product term over bit positions: literal p is present when `care` has bit p,
/// positive when `value` has bit p.
struct Cube: Hashable, Comparable {
    var value: UInt32
    var care: UInt32

    var literalCount: Int { care.nonzeroBitCount }
    func covers(_ m: Int) -> Bool { UInt32(truncatingIfNeeded: m) & care == value }

    /// Deterministic order: fewer literals first, then by literals from the MSB down
    /// (positive before complemented).
    static func < (a: Cube, b: Cube) -> Bool {
        if a.literalCount != b.literalCount { return a.literalCount < b.literalCount }
        for p in stride(from: 31, through: 0, by: -1) {
            let bit = UInt32(1) << UInt32(p)
            let ca = a.care & bit != 0, cb = b.care & bit != 0
            if ca != cb { return ca }
            if ca {
                let va = a.value & bit != 0, vb = b.value & bit != 0
                if va != vb { return va }
            }
        }
        return false
    }
}

/// Exact two-level minimizer: Quine-McCluskey prime implicants, essential primes,
/// then Petrick's method on the remaining cover problem. If Petrick's expansion grows
/// beyond `petrickLimit` products it switches to an exact branch-and-bound cover; if that
/// exceeds its node budget the best cover found so far is returned with `exact == false`.
/// Cost: fewest product terms, then fewest literals.
enum Minimizer {
    struct Result {
        var cubes: [Cube]
        var primeCount: Int
        var essentialCount: Int
        var exact: Bool
        var method: String
    }

    static let petrickLimit = 4096
    static let branchNodeLimit = 400_000

    static func primeImplicants(on: TruthTable, dc: TruthTable? = nil) -> [Cube] {
        let full = UInt32((1 << on.n) - 1)
        let care = dc.map { on | $0 } ?? on
        var current = Set(care.minterms.map { Cube(value: UInt32($0), care: full) })
        var primes: [Cube] = []
        while !current.isEmpty {
            var next = Set<Cube>()
            var used = Set<Cube>()
            for c in current {
                var b = c.care
                while b != 0 {
                    let bit = b & (~b &+ 1)
                    b &= b &- 1
                    guard c.value & bit == 0 else { continue }
                    let partner = Cube(value: c.value | bit, care: c.care)
                    if current.contains(partner) {
                        next.insert(Cube(value: c.value, care: c.care & ~bit))
                        used.insert(c)
                        used.insert(partner)
                    }
                }
            }
            primes += current.filter { !used.contains($0) }
            current = next
        }
        // Keep only primes that cover at least one ON minterm.
        let ons = on.minterms
        return primes.filter { p in ons.contains { p.covers($0) } }.sorted()
    }

    /// Search limits for functions of many inputs. Above `greedyAbovePrimes` prime implicants
    /// the cover is chosen greedily; otherwise branch and bound stops after `nodeLimit` nodes.
    struct Limits {
        var nodeLimit: Int
        var greedyAbovePrimes: Int
    }

    /// Limits for outputs that depend on 9 to 12 inputs (deterministic: node counts, no clock).
    static let wideLimits = Limits(nodeLimit: 20_000, greedyAbovePrimes: 1500)

    static func minimize(on: TruthTable, dc: TruthTable? = nil, limits: Limits? = nil) -> Result {
        if on.isZero { return Result(cubes: [], primeCount: 0, essentialCount: 0, exact: true, method: "constant") }
        let careSet = dc.map { on | $0 } ?? on
        if careSet.isOne { return Result(cubes: [Cube(value: 0, care: 0)], primeCount: 1, essentialCount: 1, exact: true, method: "constant") }
        let primes = primeImplicants(on: on, dc: dc)
        let ons = on.minterms
        let words = (ons.count + 63) / 64
        // cover[p] = bitset of ON-minterm rows prime p covers.
        var cover = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: primes.count)
        for (r, m) in ons.enumerated() {
            for (p, c) in primes.enumerated() where c.covers(m) { cover[p][r >> 6] |= 1 << UInt64(r & 63) }
        }
        let lits = primes.map { $0.literalCount }
        if let limits, primes.count > limits.greedyAbovePrimes {
            let pick = greedyCover(rows: ons.count, cover: cover, literals: lits)
            return Result(cubes: pick.map { primes[$0] }.sorted(), primeCount: primes.count, essentialCount: 0, exact: false,
                          method: "best cover found (search limit)")
        }
        var solver = CoverSolver(rows: ons.count, cover: cover, literals: lits)
        if let limits { solver.nodeLimit = limits.nodeLimit }
        let sol = solver.solve()
        let method: String
        switch sol.method {
        case .reduction: method = "Quine-McCluskey (essential and dominating prime implicants)"
        case .petrick: method = "Quine-McCluskey + Petrick's method"
        case .branchAndBound: method = sol.exact ? "Quine-McCluskey + exact branch-and-bound cover" : "Quine-McCluskey + bounded search (best cover found, may not be minimal)"
        }
        return Result(cubes: sol.chosen.map { primes[$0] }.sorted(), primeCount: primes.count,
                      essentialCount: sol.essentials, exact: sol.exact, method: method)
    }

    /// Repeatedly takes the prime covering the most uncovered rows (fewer literals, then the
    /// lower index, on ties).
    static func greedyCover(rows: Int, cover: [[UInt64]], literals: [Int]) -> [Int] {
        var open = [UInt64](repeating: 0, count: (rows + 63) / 64)
        for r in 0..<rows { open[r >> 6] |= 1 << UInt64(r & 63) }
        var chosen: [Int] = []
        while open.contains(where: { $0 != 0 }) {
            var best = -1, bestGain = 0
            for (p, c) in cover.enumerated() {
                var gain = 0
                for i in c.indices { gain += (c[i] & open[i]).nonzeroBitCount }
                if gain > bestGain || (gain == bestGain && gain > 0 && best >= 0 && literals[p] < literals[best]) { best = p; bestGain = gain }
            }
            guard best >= 0 else { break }
            chosen.append(best)
            for i in open.indices { open[i] &= ~cover[best][i] }
        }
        return chosen
    }

    /// Petrick's method: multiply out the product of sums (one sum per uncovered minterm),
    /// absorbing superset products as we go. Returns nil if it grows too large.
    static func petrick(_ clausesIn: [[Int]], literals: [Int]) -> Set<Int>? {
        // Drop duplicate clauses and clauses implied by smaller ones (a ⊆ b means b is redundant).
        var clauses = Array(Set(clausesIn.map { Set($0) }))
        clauses.sort { $0.count != $1.count ? $0.count < $1.count : $0.sorted().lexicographicallyPrecedes($1.sorted()) }
        var reduced: [Set<Int>] = []
        for c in clauses where !reduced.contains(where: { $0.isSubset(of: c) }) { reduced.append(c) }

        var products: [Set<Int>] = [[]]
        for clause in reduced {
            var next: [Set<Int>] = []
            for p in products {
                if !p.isDisjoint(with: clause) { next.append(p); continue }
                for c in clause.sorted() { next.append(p.union([c])) }
            }
            next = Array(Set(next)).sorted { $0.count != $1.count ? $0.count < $1.count : $0.sorted().lexicographicallyPrecedes($1.sorted()) }
            var kept: [Set<Int>] = []
            for p in next where !kept.contains(where: { $0.isSubset(of: p) }) {
                kept.append(p)
                if kept.count > petrickLimit { return nil }
            }
            products = kept
        }
        func cost(_ s: Set<Int>) -> (Int, Int) { (s.count, s.reduce(0) { $0 + literals[$1] }) }
        var best: Set<Int>?
        for p in products {
            if let b = best {
                let cp = cost(p), cb = cost(b)
                if !(cp.0 < cb.0 || (cp.0 == cb.0 && cp.1 < cb.1)) { continue }
            }
            best = p
        }
        return best
    }
}

/// Minimum-cost cover of the prime implicant chart: repeated essential-prime selection
/// with row and column dominance, then Petrick's method on the cyclic core, or an exact
/// bitset branch and bound when Petrick's expansion would be too large.
struct CoverSolver {
    enum Method { case reduction, petrick, branchAndBound }
    struct Solution { var chosen: [Int]; var essentials: Int; var exact: Bool; var method: Method }

    let rows: Int
    let cover: [[UInt64]]
    let literals: [Int]
    var nodeLimit = 60_000

    private var words: Int { (rows + 63) / 64 }

    private static func isSubset(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for i in a.indices where a[i] & ~b[i] != 0 { return false }
        return true
    }
    private static func and(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] { zip(a, b).map { $0 & $1 } }
    private static func isZero(_ a: [UInt64]) -> Bool { a.allSatisfy { $0 == 0 } }
    private static func count(_ a: [UInt64]) -> Int { a.reduce(0) { $0 + $1.nonzeroBitCount } }
    private static func has(_ a: [UInt64], _ i: Int) -> Bool { (a[i >> 6] >> UInt64(i & 63)) & 1 == 1 }
    private static func clear(_ a: inout [UInt64], _ i: Int) { a[i >> 6] &= ~(1 << UInt64(i & 63)) }

    func solve() -> Solution {
        var active = [UInt64](repeating: 0, count: words)
        for r in 0..<rows { active[r >> 6] |= 1 << UInt64(r & 63) }
        var primes = Set(cover.indices)
        var chosen: [Int] = []
        var essentials = -1

        func coverers(_ r: Int) -> [Int] { primes.filter { CoverSolver.has(cover[$0], r) }.sorted() }

        var changed = true
        while changed && !CoverSolver.isZero(active) {
            changed = false
            // Essential primes.
            var picked = 0
            for r in 0..<rows where CoverSolver.has(active, r) {
                let c = coverers(r)
                if c.count == 1 {
                    let p = c[0]
                    chosen.append(p)
                    primes.remove(p)
                    for i in active.indices { active[i] &= ~cover[p][i] }
                    picked += 1
                    changed = true
                }
            }
            if essentials < 0 { essentials = picked }
            // Column dominance: drop a prime whose remaining rows another prime covers at no greater cost.
            let ordered = primes.sorted()
            var restricted: [Int: [UInt64]] = [:]
            for p in ordered { restricted[p] = CoverSolver.and(cover[p], active) }
            for p in ordered {
                let rp = restricted[p]!
                if CoverSolver.isZero(rp) { primes.remove(p); changed = true; continue }
                for q in ordered where q != p && primes.contains(q) {
                    let rq = restricted[q]!
                    guard CoverSolver.isSubset(rp, rq), literals[p] >= literals[q] else { continue }
                    if rp == rq && literals[p] == literals[q] && p < q { continue }   // keep one of two equals
                    primes.remove(p); changed = true; break
                }
            }
            // Row dominance: a row whose coverers include another row's coverers is implied.
            let activeRows = (0..<rows).filter { CoverSolver.has(active, $0) }
            let cov = activeRows.map { Set(coverers($0)) }
            for (i, r) in activeRows.enumerated() {
                for (j, _) in activeRows.enumerated() where j != i && CoverSolver.has(active, activeRows[j]) {
                    if cov[j].isSubset(of: cov[i]) && (cov[j] != cov[i] || j < i) {
                        CoverSolver.clear(&active, r); changed = true; break
                    }
                }
            }
        }
        if essentials < 0 { essentials = 0 }
        if CoverSolver.isZero(active) {
            return Solution(chosen: chosen, essentials: essentials, exact: true, method: .reduction)
        }
        // Cyclic core.
        let coreRows = (0..<rows).filter { CoverSolver.has(active, $0) }
        let clauses = coreRows.map { coverers($0) }
        if let pick = Minimizer.petrick(clauses, literals: literals) {
            return Solution(chosen: chosen + pick.sorted(), essentials: essentials, exact: true, method: .petrick)
        }
        let (pick, exact) = branchAndBound(active: active, primes: primes.sorted())
        return Solution(chosen: chosen + pick, essentials: essentials, exact: exact, method: .branchAndBound)
    }

    /// Branch on the uncovered row with the fewest allowed primes; branch i takes option i
    /// and excludes options 0..<i, so rows left with one allowed prime are forced.
    private func branchAndBound(active start: [UInt64], primes: [Int]) -> ([Int], Bool) {
        let P = primes.count
        let pw = (P + 63) / 64
        let rowList = (0..<rows).filter { CoverSolver.has(start, $0) }
        var rowCov: [[UInt64]] = []          // per row in rowList: allowed-prime bitset over k
        for r in rowList {
            var b = [UInt64](repeating: 0, count: pw)
            for k in 0..<P where CoverSolver.has(cover[primes[k]], r) { b[k >> 6] |= 1 << UInt64(k & 63) }
            rowCov.append(b)
        }
        // Rows as positions in rowList; prime k covers these positions.
        let rw = (rowList.count + 63) / 64
        var primeRows = [[UInt64]](repeating: [UInt64](repeating: 0, count: rw), count: P)
        for (i, b) in rowCov.enumerated() {
            for k in 0..<P where CoverSolver.has(b, k) { primeRows[k][i >> 6] |= 1 << UInt64(i & 63) }
        }
        func bits(_ b: [UInt64]) -> [Int] {
            var out: [Int] = []
            for (w, word) in b.enumerated() {
                var x = word
                while x != 0 { let t = x.trailingZeroBitCount; out.append(w * 64 + t); x &= x - 1 }
            }
            return out
        }
        var all = [UInt64](repeating: 0, count: rw)
        for i in 0..<rowList.count { all[i >> 6] |= 1 << UInt64(i & 63) }

        // Greedy cover for the initial bound.
        var greedy: [Int] = []
        var open = all
        while !CoverSolver.isZero(open) {
            var best = -1, bestGain = -1
            for k in 0..<P {
                let g = CoverSolver.count(CoverSolver.and(primeRows[k], open))
                if g > bestGain || (g == bestGain && best >= 0 && literals[primes[k]] < literals[primes[best]]) { best = k; bestGain = g }
            }
            greedy.append(best)
            for i in open.indices { open[i] &= ~primeRows[best][i] }
        }
        var bestSet = greedy
        var bestCost = (greedy.count, greedy.reduce(0) { $0 + literals[primes[$1]] })
        var nodes = 0
        var complete = true

        func search(_ actIn: [UInt64], _ excl: [UInt64], _ chosenIn: [Int], _ litsIn: Int) {
            nodes += 1
            if nodes > nodeLimit { complete = false; return }
            var act = actIn, chosen = chosenIn, lits = litsIn
            var minRow = -1, minCount = Int.max
            // Forced picks: rows with a single allowed prime.
            var forcing = true
            while forcing {
                forcing = false
                minRow = -1; minCount = Int.max
                for i in bits(act) {
                    var allowed = 0
                    var only = -1
                    for w in 0..<pw {
                        let x = rowCov[i][w] & ~excl[w]
                        allowed += x.nonzeroBitCount
                        if x != 0 && only < 0 { only = w * 64 + x.trailingZeroBitCount }
                    }
                    if allowed == 0 { return }
                    if allowed == 1 {
                        chosen.append(only); lits += literals[primes[only]]
                        for w in act.indices { act[w] &= ~primeRows[only][w] }
                        forcing = true
                        break
                    }
                    if allowed < minCount { minCount = allowed; minRow = i }
                }
            }
            if CoverSolver.isZero(act) {
                if chosen.count < bestCost.0 || (chosen.count == bestCost.0 && lits < bestCost.1) {
                    bestSet = chosen; bestCost = (chosen.count, lits)
                }
                return
            }
            // Lower bound: rows with pairwise disjoint allowed-prime sets.
            var used = [UInt64](repeating: 0, count: pw)
            var lb = 0
            for i in bits(act) {
                var disjoint = true
                for w in 0..<pw where rowCov[i][w] & ~excl[w] & used[w] != 0 { disjoint = false; break }
                if disjoint { lb += 1; for w in 0..<pw { used[w] |= rowCov[i][w] & ~excl[w] } }
            }
            if chosen.count + lb > bestCost.0 { return }
            if chosen.count + lb == bestCost.0 && lits + lb >= bestCost.1 { return }
            var allowedMin = rowCov[minRow]
            for w in 0..<pw { allowedMin[w] &= ~excl[w] }
            let options = bits(allowedMin).sorted { a, b in
                let ga = CoverSolver.count(CoverSolver.and(primeRows[a], act)), gb = CoverSolver.count(CoverSolver.and(primeRows[b], act))
                return ga != gb ? ga > gb : literals[primes[a]] < literals[primes[b]]
            }
            var ex = excl
            for k in options {
                var next = act
                for w in next.indices { next[w] &= ~primeRows[k][w] }
                search(next, ex, chosen + [k], lits + literals[primes[k]])
                if !complete { return }
                ex[k >> 6] |= 1 << UInt64(k & 63)
            }
        }
        search(all, [UInt64](repeating: 0, count: pw), [], 0)
        return (bestSet.map { primes[$0] }, complete)
    }
}

/// Text forms of minimized functions.
enum Equation {
    /// Literal names for each bit position: names[p] for position p.
    typealias Names = [String]

    /// Quartus equation notation, e.g. `(x & z) # (!x & y & !z)`. Constants are GND / VCC.
    static func sop(_ cubes: [Cube], names: Names) -> String {
        if cubes.isEmpty { return "GND" }
        if cubes.contains(where: { $0.care == 0 }) { return "VCC" }
        let terms = cubes.map { c -> [String] in literals(c, names: names, positive: true) }
        if terms.count == 1 { return terms[0].joined(separator: " & ") }
        return terms.map { $0.count == 1 ? $0[0] : "(" + $0.joined(separator: " & ") + ")" }.joined(separator: " # ")
    }

    /// POS in Quartus notation from cubes of the OFF-set (each cube becomes one sum).
    static func pos(offCubes: [Cube], names: Names) -> String {
        if offCubes.isEmpty { return "VCC" }
        if offCubes.contains(where: { $0.care == 0 }) { return "GND" }
        let sums = offCubes.map { c -> [String] in literals(c, names: names, positive: false) }
        if sums.count == 1 { return sums[0].joined(separator: " # ") }
        return sums.map { $0.count == 1 ? $0[0] : "(" + $0.joined(separator: " # ") + ")" }.joined(separator: " & ")
    }

    /// Textbook notation, e.g. `w'y + wy'z + xyz'` and `(w + y)(y + z)`.
    static func textbookSOP(_ cubes: [Cube], names: Names) -> String {
        if cubes.isEmpty { return "0" }
        if cubes.contains(where: { $0.care == 0 }) { return "1" }
        let sep = names.contains { $0.count > 1 } ? "·" : ""
        return cubes.map { c in textbookLiterals(c, names: names, complementWhen: false).joined(separator: sep) }.joined(separator: " + ")
    }

    static func textbookPOS(offCubes: [Cube], names: Names) -> String {
        if offCubes.isEmpty { return "1" }
        if offCubes.contains(where: { $0.care == 0 }) { return "0" }
        let sums = offCubes.map { c in textbookLiterals(c, names: names, complementWhen: true) }
        if sums.count == 1 && sums[0].count == 1 { return sums[0][0] }
        return sums.map { "(" + $0.joined(separator: " + ") + ")" }.joined()
    }

    private static func positions(_ c: Cube, count: Int) -> [Int] {
        (0..<count).reversed().filter { c.care & (1 << UInt32($0)) != 0 }
    }

    private static func literals(_ c: Cube, names: Names, positive: Bool) -> [String] {
        positions(c, count: names.count).map { p in
            let one = c.value & (1 << UInt32(p)) != 0
            return (one == positive) ? names[p] : "!" + names[p]
        }
    }

    private static func textbookLiterals(_ c: Cube, names: Names, complementWhen: Bool) -> [String] {
        positions(c, count: names.count).map { p in
            let one = c.value & (1 << UInt32(p)) != 0
            return one == complementWhen ? names[p] + "'" : names[p]
        }
    }

    /// Lab cost of a two-level realisation: gates and gate inputs, counting one NOT per
    /// complemented variable, a gate per multi-literal term and the final OR/AND.
    static func cost(_ cubes: [Cube], pos: Bool, bits: Int) -> (gates: Int, inputs: Int) {
        if cubes.isEmpty || cubes.contains(where: { $0.care == 0 }) { return (0, 0) }
        var complemented = Set<Int>()
        var gates = 0, inputs = 0
        for c in cubes {
            for p in 0..<bits where c.care & (1 << UInt32(p)) != 0 {
                let one = c.value & (1 << UInt32(p)) != 0
                // SOP uses x' where the cube has 0; POS sums use x' where the off-cube has 1.
                if one == pos { complemented.insert(p) }
            }
            if c.literalCount > 1 { gates += 1; inputs += c.literalCount }
        }
        if cubes.count > 1 { gates += 1; inputs += cubes.count }
        return (gates + complemented.count, inputs + complemented.count)
    }
}

/// Cyclone V LUT masks, encoded the way Quartus writes `lut_mask` on `cyclonev_lcell_comb`:
/// bit index = dataf*32 + datae*16 + datad*8 + datac*4 + datab*2 + dataa, and inputs that
/// are not connected simply repeat the pattern.
enum LUTMask {
    struct Port {
        /// Index of the variable that drives this port.
        var variable: Int
        /// The port sees the complement of the variable (Quartus writes `.dataa(!\y~input_o )`).
        var inverted = false
    }

    /// `ports` lists dataa...dataf (nil = unconnected). `function` takes a bitmask of
    /// variable values (bit v = value of variable v).
    static func mask(ports: [Port?], function: (UInt32) -> Bool) -> UInt64 {
        precondition(ports.count <= 6)
        var mask: UInt64 = 0
        for idx in 0..<64 {
            var assignment: UInt32 = 0
            for (k, port) in ports.enumerated() {
                guard let port else { continue }
                let portValue = (idx >> k) & 1 == 1
                if portValue != port.inverted { assignment |= 1 << UInt32(port.variable) }
            }
            if function(assignment) { mask |= 1 << UInt64(idx) }
        }
        return mask
    }

    /// Mask for a LUT whose first k ports carry its k inputs directly: the local
    /// 2^k-entry table repeated across the unused high ports.
    static func replicate(_ local: UInt64, inputs k: Int) -> UInt64 {
        if k >= 6 { return local }
        let width = 1 << k
        let pattern = local & (width == 64 ? ~0 : (UInt64(1) << UInt64(width)) - 1)
        var m: UInt64 = 0
        var shift = 0
        while shift < 64 { m |= pattern << UInt64(shift); shift += width }
        return m
    }

    static func hex(_ m: UInt64) -> String {
        let s = String(m, radix: 16, uppercase: true)
        return "64'h" + String(repeating: "0", count: 16 - s.count) + s
    }
}
