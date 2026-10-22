"""Tests for bdf_check.py's hierarchy support: the Quartus 18.0 fixtures, broken copies of
them, and small hand-written multi-file designs."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import bdf_check

HERE = pathlib.Path(__file__).resolve().parent
HIER = bdf_check.FIXTURES / 'hier'


def run(*args):
    return subprocess.run([sys.executable, str(HERE / 'bdf_check.py'), *map(str, args)], capture_output=True, text=True)


# --- A tiny .bdf writer (independent of Quartzite) -------------------------------------

def _pt(p):
    return f"(pt {p[0]} {p[1]})"


def pin(direction, name, x, y):
    W, H, p, draw = bdf_check.PIN_CANON[(direction, 168 if direction == 'input' else 176)]
    lines = ''.join(f"\t\t(line {_pt(a)}{_pt(b)})\n" for _, (a, b) in draw)
    tail = '\t(text "VCC" (rect 128 7 148 17)(font "Arial" (font_size 6)))\n' if direction == 'input' else ''
    return (f"(pin\n\t({direction})\n\t(rect {x} {y} {x + W} {y + H})\n"
            f"\t(text \"{direction.upper()}\" (rect 125 0 153 10)(font \"Arial\" (font_size 6)))\n"
            f"\t(text \"{name}\" (rect 5 0 17 12)(font \"Arial\" ))\n\t{_pt(p)}\n\t(drawing\n{lines}\t)\n{tail})\n")


def _shape(kind, args):
    if kind == 'line': return f"\t\t(line {_pt(args[0])}{_pt(args[1])})\n"
    if kind == 'arc': return f"\t\t(arc {_pt(args[0])}{_pt(args[1])}(rect {' '.join(map(str, args[2]))}))\n"
    return f"\t\t(circle (rect {' '.join(map(str, args[0]))}))\n"


def gate(name, inst, x, y):
    W, H, ports, draw = bdf_check.CANON[name]
    out = f"(symbol\n\t(rect {x} {y} {x + W} {y + H})\n\t(text \"{name}\" (rect 1 0 25 10)(font \"Arial\" (font_size 6)))\n" \
          f"\t(text \"{inst}\" (rect 3 37 31 49)(font \"Arial\" (font_size 6)))\n"
    for pn, (p, end) in ports.items():
        d = 'output' if pn == 'OUT' else 'input'
        out += f"\t(port\n\t\t{_pt(p)}\n\t\t({d})\n\t\t(text \"{pn}\" (rect 2 7 19 19)(font \"Courier New\" (bold))(invisible))\n" \
               f"\t\t(line {_pt(p)}{_pt(end)})\n\t)\n"
    return out + "\t(drawing\n" + ''.join(_shape(k, a) for k, a in draw) + "\t)\n)\n"


def gate_ports(name, x, y):
    return {pn: (x + p[0], y + p[1]) for pn, (p, _) in bdf_check.CANON[name][2].items()}


# Text widths (Intel Clear 8 pt) used by the block writer: any value works for the rules.
TW = {'a': 6, 'b': 8, 's': 5, 'c': 7, 'x': 5, 'y': 7, 'cin': 19, 'cout': 24, 'inst': 16, 'inst1': 22}


def block_symbol(name, ins, outs, x=16, y=16, inst='inst'):
    s = max([TW.get(n, 8) for n in ins] + [0]) + max([TW.get(n, 8) for n in outs] + [0])
    W = 32 + max(64, bdf_check.round_up16(s + 10))
    B = 16 * max(len(ins), len(outs)) + 48
    out = f"(symbol\n\t(rect {x} {y} {x + W} {y + B + 16})\n\t(text \"{name}\" (rect 5 0 {5 + 8 * len(name)} 19)(font \"Intel Clear\" (font_size 8)))\n" \
          f"\t(text \"{inst}\" (rect 8 {B - 5} {8 + TW.get(inst, 22)} {B + 12})(font \"Intel Clear\" ))\n"
    ports = {}
    for d, names in (('input', ins), ('output', outs)):
        for k, n in enumerate(names):
            py, tw = 32 + 16 * k, TW.get(n, 8)
            px, lead = (0, 16) if d == 'input' else (W, W - 16)
            label = (21, py - 5, 21 + tw, py + 14) if d == 'input' else (W - 21 - tw, py - 5, W - 21, py + 14)
            out += f"\t(port\n\t\t(pt {px} {py})\n\t\t({d})\n\t\t(text \"{n}\" (rect 0 0 {tw} 19)(font \"Intel Clear\" (font_size 8)))\n" \
                   f"\t\t(text \"{n}\" (rect {' '.join(map(str, label))})(font \"Intel Clear\" (font_size 8)))\n" \
                   f"\t\t(line (pt {px} {py})(pt {lead} {py}))\n\t)\n"
            ports[n] = (x + px, y + py)
    return out + f"\t(drawing\n\t\t(rectangle (rect 16 16 {W - 16} {B}))\n\t)\n)\n", ports


def bsf(name, ins, outs):
    sym, _ = block_symbol(name, ins, outs)
    text = "/*\nWARNING: Do NOT edit the input and output ports in this file in a text\neditor if you plan to continue " \
           "editing the block that represents it in\nthe Block Editor! File corruption is VERY likely to occur.\n*/\n" \
           "(header \"symbol\" (version \"1.2\"))\n" + sym
    return text.replace('\n', '\r\n').encode()


def stub(p, label, outward):
    """A labelled wire from a port, `outward` pixels to the right (negative: left)."""
    return f"(connector\n\t(text \"{label}\" (rect {p[0]} {p[1] - 12} {p[0] + 20} {p[1]})(font \"Arial\" ))\n" \
           f"\t{_pt(p)}\n\t{_pt((p[0] + outward, p[1]))}\n)\n"


class Sheet:
    def __init__(self):
        self.items = []
        self.pins = []

    def pin(self, direction, name):
        self.pins.append((name, direction))
        self.items.append(pin(direction, name, 40 if direction == 'input' else 800, 40 + 40 * len(self.pins)))

    def gate(self, name, inst, x, y, nets):
        self.items.append(gate(name, inst, x, y))
        for pn, p in gate_ports(name, x, y).items():
            self.items.append(stub(p, nets[pn], 16 if pn == 'OUT' else -16))

    def block(self, name, inst, x, y, ins, outs, nets):
        sym, ports = block_symbol(name, ins, outs, x, y, inst)
        self.items.append(sym)
        for pn, p in ports.items():
            if pn in nets: self.items.append(stub(p, nets[pn], -16 if pn in ins else 16))

    def text(self):
        return '(header "graphic" (version "1.4"))\n' + ''.join(self.items)


HA = (['a', 'b'], ['s', 'c'])
FA = (['x', 'y', 'cin'], ['s', 'cout'])


def ha_sheet():
    s = Sheet()
    for n in HA[0]: s.pin('input', n)
    for n in HA[1]: s.pin('output', n)
    s.gate('XOR', 'inst', 300, 40, {'IN1': 'a', 'IN2': 'b', 'OUT': 's'})
    s.gate('AND2', 'inst1', 300, 160, {'IN1': 'a', 'IN2': 'b', 'OUT': 'c'})
    return s


def fa_sheet(child='HA', drop=None):
    s = Sheet()
    for n in FA[0]: s.pin('input', n)
    for n in FA[1]: s.pin('output', n)
    first = {'a': 'x', 'b': 'y', 's': 'p', 'c': 'g1'}
    if drop: first.pop(drop)
    s.block(child, 'inst', 300, 40, *HA, first)
    s.block(child, 'inst1', 300, 240, *HA, {'a': 'p', 'b': 'cin', 's': 's', 'c': 'g2'})
    s.gate('OR2', 'inst2', 600, 160, {'IN1': 'g1', 'IN2': 'g2', 'OUT': 'cout'})
    return s


def qsf(top, files, pins):
    lines = [f"set_global_assignment -name TOP_LEVEL_ENTITY {top}"] + [f"set_global_assignment -name BDF_FILE {f}" for f in files]
    for k, n in enumerate(pins):
        lines += [f"set_location_assignment PIN_AB{30 - k} -to {n}", f'set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to {n}']
    return '\n'.join(lines) + '\n'


def fa_rows(drop=None):
    rows = []
    for i in range(8):
        x, y, cin = (i >> 2) & 1, (i >> 1) & 1, i & 1
        b = 1 if drop == 'b' else y          # an unconnected HA input reads its pin's default, VCC
        p, g1 = x ^ b, x & b
        rows.append(f"{p ^ cin}{g1 | (p & cin)}")
    return rows


def write_fa(folder, child='HA', drop=None):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'HA.bdf').write_text(ha_sheet().text())
    (folder / 'FA.bdf').write_text(fa_sheet(child, drop).text())
    (folder / 'HA.bsf').write_bytes(bsf('HA', *HA))
    (folder / 'FA.qsf').write_text(qsf('FA', ['FA.bdf', 'HA.bdf'], FA[0] + FA[1]))
    (folder / 'expected.json').write_text(json.dumps({
        'entity': 'FA', 'top': 'FA', 'inputs': FA[0], 'outputs': FA[1], 'rows': fa_rows(drop),
        'files': ['FA.bdf', 'HA.bdf'], 'symbols': ['HA.bsf'], 'macros': []}))
    return folder


class FixtureTests(unittest.TestCase):
    def setUp(self):
        if not HIER.exists(): self.skipTest(f"no fixtures in {HIER}")
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_quartus_files_pass(self):
        p = run('--bsf', HIER / 'HA.bsf', HIER / 'BIGBLK.bsf')
        self.assertEqual(p.returncode, 0, p.stdout)
        # hiertop.bdf is the Quartus-saved sheet; HA.bdf and BIGBLK.bdf were written by hand.
        p = run('--geometry', HIER / 'hiertop.bdf')
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_compiled_7447_and_vcc_match_the_library(self):
        lab2 = bdf_check.FIXTURES / 'lab2'
        tree = bdf_check.parse(bdf_check.tokenize((lab2 / '7447_instance.txt').read_text() + (lab2 / 'vcc_symbol.txt').read_text()))
        self.assertEqual(bdf_check.symbol_problems(tree, 'lab2', {}), [])
        moved = (lab2 / '7447_instance.txt').read_text().replace('(pt 0 88)', '(pt 0 96)', 1)
        self.assertNotEqual(bdf_check.symbol_problems(bdf_check.parse(bdf_check.tokenize(moved)), 'lab2', {}), [])

    def test_moved_output_pt_fails(self):
        for f in ('HA.bsf', 'BIGBLK.bsf', 'hiertop.bdf'): shutil.copy(HIER / f, self.tmp / f)
        bad = self.tmp / 'HA.bsf'
        raw = bad.read_bytes()
        self.assertIn(b'(pt 96 32)', raw)
        bad.write_bytes(raw.replace(b'(pt 96 32)', b'(pt 96 40)', 1))
        p = run('--bsf', bad)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('R3', p.stdout)
        # the instance in hiertop.bdf no longer matches HA.bsf
        self.assertNotEqual(run('--geometry', self.tmp / 'hiertop.bdf').returncode, 0)

    def test_renamed_port_fails(self):
        for f in ('HA.bsf', 'BIGBLK.bsf'): shutil.copy(HIER / f, self.tmp / f)
        text = (HIER / 'hiertop.bdf').read_bytes()
        self.assertIn(b'(text "cout"', text)
        (self.tmp / 'hiertop.bdf').write_bytes(text.replace(b'(text "cout"', b'(text "cy"'))
        p = run('--geometry', self.tmp / 'hiertop.bdf')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('differs from HA.bsf', p.stdout)


class FolderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_half_adders_in_a_full_adder_simulate(self):
        folder = write_fa(self.tmp / 'fa')
        ok, notes = bdf_check.check(folder)
        self.assertTrue(ok, notes)
        self.assertEqual(json.loads((folder / 'expected.json').read_text())['rows'],
                         ['00', '10', '10', '01', '10', '01', '01', '11'])

    def test_wrong_rows_fail(self):
        folder = write_fa(self.tmp / 'fa')
        exp = json.loads((folder / 'expected.json').read_text())
        exp['rows'][3] = '10'
        (folder / 'expected.json').write_text(json.dumps(exp))
        ok, notes = bdf_check.check(folder)
        self.assertFalse(ok)
        self.assertTrue(any('row 3' in n for n in notes), notes)

    def test_unconnected_block_input_reads_vcc(self):
        folder = write_fa(self.tmp / 'fa', drop='b')
        ok, notes = bdf_check.check(folder)
        self.assertTrue(ok, notes)

    def test_renamed_block_port_fails(self):
        folder = write_fa(self.tmp / 'fa')
        fa = folder / 'FA.bdf'
        fa.write_text(fa.read_text().replace('(text "c" (rect 0 0', '(text "cy" (rect 0 0'))
        ok, notes = bdf_check.check(folder)
        self.assertFalse(ok)
        self.assertTrue(any('HA.bsf' in n for n in notes), notes)

    def test_recursive_design_fails(self):
        folder = write_fa(self.tmp / 'rec')
        ha = Sheet()
        for n in HA[0]: ha.pin('input', n)
        for n in HA[1]: ha.pin('output', n)
        ha.block('HA', 'inst', 300, 40, *HA, {n: n for n in HA[0] + HA[1]})
        (folder / 'HA.bdf').write_text(ha.text())
        ok, notes = bdf_check.check(folder)
        self.assertFalse(ok)
        self.assertTrue(any('contains itself' in n for n in notes), notes)

    def test_missing_child_fails(self):
        folder = write_fa(self.tmp / 'missing')
        (folder / 'HA.bdf').unlink()
        ok, notes = bdf_check.check(folder)
        self.assertFalse(ok)
        self.assertTrue(any('unknown symbol HA' in n for n in notes), notes)

    def test_qsf_must_list_every_used_file(self):
        folder = write_fa(self.tmp / 'qsf')
        (folder / 'FA.qsf').write_text(qsf('FA', ['FA.bdf'], FA[0] + FA[1]))
        ok, notes = bdf_check.check(folder)
        self.assertFalse(ok)
        self.assertTrue(any('BDF_FILE' in n for n in notes), notes)

    def test_7447_model(self):
        on = {0: 'abcdef', 1: 'bc', 2: 'abdeg', 3: 'abcdg', 4: 'bcfg', 5: 'acdfg', 6: 'cdefg', 7: 'abc', 8: 'abcdefg', 9: 'abcfg'}
        for n, segs in on.items():
            v = {'A': n & 1, 'B': n >> 1 & 1, 'C': n >> 2 & 1, 'D': n >> 3 & 1, 'LTN': 1, 'RBIN': 1, 'BIN': 1}
            out = bdf_check.ttl7447(v)
            self.assertEqual({s for s in 'abcdefg' if not out['O' + s.upper()]}, set(segs), n)
            self.assertTrue(out['RBON'])
        blank = bdf_check.ttl7447({'A': 0, 'B': 0, 'C': 0, 'D': 0, 'LTN': 1, 'RBIN': 0, 'BIN': 1})
        self.assertTrue(all(blank['O' + s] for s in 'ABCDEFG'))
        self.assertFalse(blank['RBON'])
        lamp = bdf_check.ttl7447({'A': 1, 'B': 0, 'C': 0, 'D': 0, 'LTN': 0, 'RBIN': 1, 'BIN': 1})
        self.assertFalse(any(lamp['O' + s] for s in 'ABCDEFG'))


if __name__ == '__main__':
    unittest.main()
