#!/usr/bin/env python3
"""Random designs through the export, the independent checks and the import.

Builds seeded random gate-level designs with `Quartzite --build-design`: one sheet, or a
child sheet placed as blocks, sometimes with a 7447, VCC and GND. It exports each with
`--export-project` and checks the folder:

  * `bdf_check.check_folder` re-reads the .bdf files and simulates them;
  * the structural Verilog backup (`<entity>_backup.v`) and the LUT netlist
    (`simulation/quartzite/<entity>_quartzite.vo`) are simulated here, row by row;
  * the export is imported with `--import`, exported again, and its truth table compared.

A design that Quartzite refuses to compile or export (overlapping symbols, a route it can't
draw) is skipped and counted: refusing is allowed, writing a wrong file is not.

    random_designs.py <path to Quartzite> [--count N] [--seed S] [--work DIR] [--keep]

Exit status 1 if any exported design fails a check. The same seed gives the same designs.
"""
import argparse, json, pathlib, random, re, shutil, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bdf_check  # noqa: E402

GATES = ['not', 'and2', 'and3', 'and4', 'or2', 'or3', 'or4', 'nand2', 'nand3', 'nand4',
         'nor2', 'nor3', 'nor4', 'xor2', 'xnor2']


def arity(kind):
    return 1 if kind == 'not' else int(kind[-1])


def in_port(kind, i):
    return 'IN' if kind == 'not' else f'IN{i + 1}'


class Sheet:
    """One sheet of a DesignSpec, with helpers that keep one name per labelled endpoint."""

    def __init__(self, name):
        self.spec = {'name': name, 'inputs': [], 'outputs': [], 'parts': [], 'wires': [], 'labels': []}
        self.names = {}

    def connect(self, rng, src, dst, label_chance):
        if rng.random() < label_chance:
            name = self.names.setdefault(src, 'n_' + src.replace('.', '_'))
            if not any(l[0] == src for l in self.spec['labels']): self.spec['labels'].append([src, name])
            self.spec['labels'].append([dst, name])
        else:
            self.spec['wires'].append([src, dst])


def gate_sheet(rng, name, inputs, outputs, gates, label_chance, constants=False, dense=False):
    """Inputs on the left, gates in up to three columns, outputs on the right. `dense` lets
    symbols overlap, so more wires have to be exported as labels (or the export refused)."""
    s = Sheet(name)
    s.spec['inputs'] = [{'name': f'i{k}', 'y': 64 + 64 * k} for k in range(inputs)]
    signals = [f'i{k}' for k in range(inputs)]
    if constants:
        s.spec['parts'] += [{'id': 'kv', 'kind': 'vcc', 'x': 120, 'y': 8},
                            {'id': 'kg', 'kind': 'gnd', 'x': 120, 'y': 40 + 64 * inputs}]
        signals += ['kv.1', 'kg.1']
    taken, made = [], []
    for g in range(gates):
        for _ in range(100):
            x, y = 240 + 176 * rng.randrange(3) + 8 * rng.randint(0, 4), 32 + 8 * rng.randint(0, 60)
            if dense or all(abs(x - a) > 72 or abs(y - b) > 88 for a, b in taken): break
        else:
            break
        taken.append((x, y))
        kind = rng.choice(GATES)
        s.spec['parts'].append({'id': f'g{g}', 'kind': kind, 'x': x, 'y': y})
        for i in range(arity(kind)):
            src = rng.choice(signals)
            # Constants and labels on the same endpoint must keep one name, so constants
            # always connect by label.
            s.connect(rng, src, f'g{g}.{in_port(kind, i)}', 1.0 if src.startswith('k') else label_chance)
        signals.append(f'g{g}.OUT')
        made.append(f'g{g}.OUT')
    for k, src in enumerate(rng.sample(made, min(outputs, len(made)))):
        s.spec['outputs'].append({'name': f'o{k}', 'x': 880, 'y': 48 + 96 * k})
        s.spec['wires'].append([src, f'o{k}'])
    return s


def flat_design(rng, t):
    s = gate_sheet(rng, f'R{t}', rng.randint(2, 8), rng.randint(1, 3), rng.randint(1, 12),
                   rng.choice([0.0, 0.25, 0.5]), constants=rng.random() < 0.3, dense=rng.random() < 0.3)
    return {'name': f'R{t}', 'sheets': [s.spec]}


def block_design(rng, t):
    child = gate_sheet(rng, f'C{t}', rng.randint(2, 3), rng.randint(1, 2), rng.randint(1, 4), 0.3)
    child.spec['symbol'] = True
    top = Sheet(f'H{t}')
    n = rng.randint(2, 4)
    top.spec['inputs'] = [{'name': f'x{k}', 'y': 64 + 64 * k} for k in range(n)]
    signals, outs = [f'x{k}' for k in range(n)], []
    for b in range(rng.randint(1, 3)):
        top.spec['parts'].append({'id': f'b{b}', 'kind': 'block', 'of': f'C{t}', 'x': 280, 'y': 48 + 224 * b})
        for p in child.spec['inputs']:
            if rng.random() < 0.15: continue          # left open: driven by the pin's default (VCC)
            top.connect(rng, rng.choice(signals), f"b{b}.{p['name']}", 0.4)
        for p in child.spec['outputs']:
            signals.append(f"b{b}.{p['name']}"); outs.append(f"b{b}.{p['name']}")
    if rng.random() < 0.3:
        top.spec['parts'] += [{'id': 'v', 'kind': 'vcc', 'x': 480, 'y': 760}, {'id': 'd', 'kind': 'macro', 'of': '7447', 'x': 600, 'y': 640}]
        for c in ['LTN', 'RBIN', 'BIN']: top.spec['wires'].append(['v.1', f'd.{c}'])
        for c in 'ABCD': top.connect(rng, rng.choice(signals), f'd.{c}', 1.0)
        for k, seg in enumerate(['OA', 'OB', 'OC']):
            top.spec['outputs'].append({'name': f'seg{k}', 'x': 900, 'y': 640 + 32 * k})
            top.spec['labels'].append([f'd.{seg}', f'seg{k}'])
    for k, src in enumerate(rng.sample(outs, min(len(outs), 3))):
        top.spec['outputs'].append({'name': f'y{k}', 'x': 900, 'y': 48 + 96 * k})
        top.connect(rng, src, f'y{k}', 0.5)
    return {'name': f'H{t}', 'top': f'H{t}', 'sheets': [child.spec, top.spec]}


# --- Independent simulation of the two Verilog files ------------------------------------

PRIMS = {'and': all, 'or': any, 'nand': lambda v: not all(v), 'nor': lambda v: not any(v),
         'xor': lambda v: sum(v) % 2 == 1, 'xnor': lambda v: sum(v) % 2 == 0, 'not': lambda v: not v[0]}


def const(text):
    return {"1'b1": True, "1'b0": False}.get(text.strip())


def simulate_backup(text, values):
    """`<entity>_backup.v`: gate primitives and assigns, evaluated until nothing changes."""
    v = dict(values)
    stmts = [(m[1], m[2], [a.strip() for a in m[3].split(',')[1:]], m[3].split(',')[0].strip())
             for m in re.finditer(r'(?m)^\t(and|or|nand|nor|xor|xnor|not) (\w+) \(([^)]*)\);', text)]
    stmts += [('assign', None, [m[2].strip()], m[1]) for m in re.finditer(r'(?m)^\tassign (\w+) = ([^;]+);', text)]
    for _ in range(len(stmts) + 1):
        for prim, _, args, out in stmts:
            xs = [const(a) if const(a) is not None else v.get(a) for a in args]
            if None not in xs: v[out] = xs[0] if prim == 'assign' else PRIMS[prim](xs)
    return v


def simulate_vo(text, values):
    """`<entity>_quartzite.vo`: qz_lcell_comb LUTs (written in topological order) and assigns."""
    v = dict(values)
    def val(a):
        c = const(a)
        return c if c is not None else v[a.strip()]
    for m in re.finditer(r"qz_lcell_comb #\(\.lut_mask\(64'h([0-9A-F]{16})\)\) \w+ \(([^;]*)\);", text):
        ports = dict(re.findall(r'\.(\w+)\(([^)]*)\)', m[2]))
        idx = sum(1 << k for k, p in enumerate(['dataa', 'datab', 'datac', 'datad', 'datae', 'dataf']) if val(ports[p]))
        v[ports['combout']] = bool((int(m[1], 16) >> idx) & 1)
    return {m[1]: val(m[2]) for m in re.finditer(r'(?m)^assign (\w+) = ([^;]+);', text)}


def netlist_problems(folder, exp):
    backup = next(folder.glob('*_backup.v')).read_text()
    vo = next((folder / 'simulation' / 'quartzite').glob('*.vo')).read_text()
    n, problems = len(exp['inputs']), []
    for i, want in enumerate(exp['rows']):
        ins = {name: bool((i >> (n - 1 - b)) & 1) for b, name in enumerate(exp['inputs'])}
        for label, sim in (('backup .v', simulate_backup(backup, ins)), ('.vo', simulate_vo(vo, ins))):
            got = ''.join('1' if sim.get(o) else '0' for o in exp['outputs'])
            if got != want: problems.append(f'{label} row {i}: {got}, expected {want}')
    return problems[:4]


# --- Driver ----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('quartzite')
    ap.add_argument('--count', type=int, default=200)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--work')
    ap.add_argument('--keep', action='store_true', help='keep the work folder')
    a = ap.parse_args()
    exe = str(pathlib.Path(a.quartzite).resolve())
    work = pathlib.Path(a.work or tempfile.mkdtemp(prefix='quartzite-random-'))
    work.mkdir(parents=True, exist_ok=True)
    def q(*args):
        return subprocess.run([exe, *map(str, args)], capture_output=True, text=True, timeout=300)

    rng = random.Random(a.seed)
    stats = dict(designs=0, refused=0, checked=0, reimported=0, failed=0)
    failures = []
    for t in range(a.count):
        spec = (block_design if t % 4 == 3 else flat_design)(rng, t)
        d = work / f'd{t}'
        shutil.rmtree(d, ignore_errors=True); d.mkdir()
        (d / 'spec.json').write_text(json.dumps(spec, indent=1))
        r = q('--build-design', d / 'spec.json', d / 'design.qzproj')
        if r.returncode: failures.append(f'd{t}: --build-design failed: {r.stderr.strip()[:300]}'); continue
        stats['designs'] += 1
        r = q('--export-project', d / 'design.qzproj', d / 'out')
        if r.returncode: stats['refused'] += 1; continue
        folder = next(p for p in (d / 'out').iterdir() if p.is_dir())
        exp = json.loads((folder / 'expected.json').read_text())
        stats['checked'] += 1
        ok, notes = bdf_check.check_folder(folder)
        problems = [] if ok else [f'bdf_check: {m}' for m in notes[:4]]
        try:
            problems += netlist_problems(folder, exp)
        except (KeyError, StopIteration) as e:
            problems.append(f'could not simulate the written netlists ({e!r})')
        if not problems:
            r = q('--import', next(folder.glob('*.qpf')), d / 'imported.qzproj')
            if r.returncode: problems.append(f'--import failed: {r.stderr.strip()[:300]}')
            elif q('--export-project', d / 'imported.qzproj', d / 'again').returncode == 0:
                # Re-exporting may be refused (the importer redraws the wires); if it works,
                # the circuit must be the same.
                stats['reimported'] += 1
                again = json.loads(next((d / 'again').glob('*/expected.json')).read_text())
                diff = [k for k in ('inputs', 'outputs', 'rows', 'top', 'files', 'symbols', 'macros') if exp.get(k) != again.get(k)]
                if diff: problems.append(f'import round trip changed {diff}')
        if problems:
            stats['failed'] += 1
            failures.append(f'd{t} ({d / "spec.json"}): ' + '; '.join(problems))
    for f in failures: print('FAIL ' + f)
    print(f"random designs (seed {a.seed}): {stats['designs']} built, {stats['refused']} refused by the export, "
          f"{stats['checked']} exported and checked, {stats['reimported']} imported and exported again, {stats['failed']} failed")
    if not a.keep and not failures: shutil.rmtree(work, ignore_errors=True)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
