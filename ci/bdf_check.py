#!/usr/bin/env python3
"""Independent check of an exported Quartus .bdf.

Parses the S-expression file, rebuilds connectivity the way the Quartus Block
Editor does (connector endpoints join ports/other connectors they touch, a
connector endpoint on another connector's interior joins it, same-named
connectors and pins join), simulates every input combination and compares with
expected.json written by Quartzite. Usage: bdf_check.py <design-folder>...

It also checks the geometry of every primitive symbol and pin against the Quartus
library drawings below, including rotated and flipped symbols. Quartus writes a
rotated/flipped symbol with all coordinates already transformed plus one tag:
  rotate90 (x,y)->(y,W-x)  rotate180 (x,y)->(W-x,H-y)  rotate270 (x,y)->(H-y,x)
  flipy    (x,y)->(W-x,y)  flipx     (x,y)->(x,H-y)
and swaps the end points of arcs when mirroring. `bdf_check.py --geometry <file.bdf>...`
runs only this geometry check, which is how the tables and the convention were
verified against .bdf files saved by real Quartus (II 13 to Prime 20).

A design folder may hold several .bdf files (one per entity) and their .bsf symbols.
The check flattens the hierarchy from the top-level entity (expected.json "top", else
"entity"), checks block symbols against rules R2-R7 of the hierarchy plan and their .bsf,
VCC/GND and the 7447 against the Quartus symbol text, the .qsf file list, top-level entity
and pin assignments, then simulates with its own 7447 model.
`bdf_check.py --bsf <file.bsf>...` checks .bsf files on their own (R1-R8).
"""
import json, os, re, sys, itertools, pathlib

def tokenize(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.findall(r'"(?:[^"\\]|\\.)*"|\(|\)|[^\s()"]+', s)

def parse(tokens):
    stack, cur = [], []
    for t in tokens:
        if t == '(':
            stack.append(cur); cur = []
        elif t == ')':
            done = cur; cur = stack.pop(); cur.append(done)
        else:
            cur.append(t[1:-1] if t.startswith('"') else t)
    assert not stack, "unbalanced parentheses"
    return cur

def find(node, key):
    return [c for c in node if isinstance(c, list) and c and c[0] == key]

def pt(node):
    return (int(node[1]), int(node[2]))

PRIMS = {
    'NOT': lambda v: not v[0], 'XOR': lambda v: v[0] != v[1], 'XNOR': lambda v: v[0] == v[1],
}
for n in (2, 3, 4):
    PRIMS[f'AND{n}'] = lambda v: all(v)
    PRIMS[f'OR{n}'] = lambda v: any(v)
    PRIMS[f'NAND{n}'] = lambda v: not all(v)
    PRIMS[f'NOR{n}'] = lambda v: not any(v)

# Quartus library primitives: size, ports {name: (pt, lead end)}, drawing.
# Transcribed from .bdf files saved by Quartus; verified with --geometry.
def _L(x1, y1, x2, y2): return ('line', ((x1, y1), (x2, y2)))
def _A(x1, y1, x2, y2, r): return ('arc', ((x1, y1), (x2, y2), r))
def _C(*r): return ('circle', (tuple(r),))
_OR2 = [_L(14,13,25,13), _L(14,36,25,36), _A(7,29,7,19,(-14,8,19,41)), _A(49,24,25,13,(-6,13,57,76)), _A(25,35,49,24,(-6,-27,57,36))]
_NOR2 = [_L(12,13,23,13), _L(12,36,23,36), _A(5,29,5,19,(-16,8,17,41)), _A(46,24,23,13,(-6,13,53,72)), _A(23,35,46,24,(-6,-23,53,36)), _C(46,20,54,28)]
def _ports(ins, out, single=False):
    d = {('IN' if single else f'IN{i+1}'): ((0, y), (x, y)) for i, (y, x) in enumerate(ins)}
    d['OUT'] = ((out[0], out[1]), (out[2], out[1]))
    return d
CANON = {
    'NOT': (48, 32, _ports([(16, 13)], (48, 16, 39), True), [_L(13,25,13,7), _L(13,7,31,16), _L(13,25,31,16), _C(31,12,39,20)]),
    'AND2': (64, 48, _ports([(16,14),(32,14)], (64,24,42)), [_L(14,12,30,12), _L(14,37,31,37), _L(14,12,14,37), _A(31,37,30,12,(18,12,43,37))]),
    'AND3': (64, 48, _ports([(16,16),(24,16),(32,16)], (64,24,43)), [_L(16,12,31,12), _L(16,37,31,37), _L(16,12,16,37), _A(31,36,31,12,(19,12,44,37))]),
    'AND4': (64, 80, _ports([(16,18),(32,18),(48,18),(64,18)], (64,40,46)), [_L(18,28,34,28), _L(18,52,18,28), _L(18,67,18,13), _L(34,53,18,53), _A(34,52,34,28,(22,28,47,53))]),
    'OR2': (64, 48, _ports([(16,15),(32,15)], (64,24,48)), _OR2),
    'OR3': (64, 48, _ports([(16,16),(24,18),(32,16)], (64,24,49)), _OR2),
    'OR4': (64, 80, _ports([(16,13),(32,15),(48,15),(64,13)], (64,40,48)), [_L(13,12,13,29), _L(13,29,25,29), _L(13,67,13,51), _L(25,52,13,52), _A(7,45,7,35,(-14,24,19,57)), _A(49,40,25,29,(-6,29,57,92)), _A(25,51,49,40,(-6,-11,57,52))]),
    'NAND2': (64, 48, _ports([(16,15),(32,15)], (64,24,52)), [_L(15,37,32,37), _L(15,12,32,12), _L(15,36,15,12), _A(32,36,32,12,(20,12,45,37)), _C(44,20,52,28)]),
    'NAND3': (64, 48, _ports([(16,16),(24,16),(32,16)], (64,24,52)), [_L(16,12,32,12), _L(16,36,16,12), _L(16,37,32,37), _A(32,36,32,12,(20,12,45,37)), _C(44,20,52,28)]),
    'NAND4': (64, 80, _ports([(16,18),(32,18),(48,18),(64,18)], (64,40,54)), [_L(18,28,34,28), _L(18,53,34,53), _L(18,67,18,13), _A(34,52,34,28,(22,28,47,53)), _C(46,36,54,44)]),
    'NOR2': (64, 48, _ports([(16,14),(32,14)], (64,24,54)), _NOR2),
    'NOR3': (64, 48, _ports([(16,14),(24,16),(32,14)], (64,24,54)), _NOR2),
    'NOR4': (64, 80, _ports([(16,14),(32,16),(48,16),(64,14)], (64,40,56)), [_L(14,29,14,13), _L(14,29,25,29), _L(14,52,25,52), _L(14,67,14,51), _A(8,45,8,35,(-13,24,20,57)), _A(48,40,25,29,(-4,29,55,88)), _A(25,51,48,40,(-4,-7,55,52)), _C(48,36,56,44)]),
    'XOR': (64, 48, _ports([(16,11),(32,11)], (64,24,49)), _OR2 + [_A(8,36,8,12,(-21,7,14,42))]),
    'XNOR': (64, 48, _ports([(16,11),(32,11)], (64,24,56)), _OR2 + [_A(2,29,2,19,(-19,8,14,41)), _C(48,20,56,28)]),
}
# Pins: Quartus Prime 17+ input pins are 168 wide, Quartus II 13 ones 176; both are accepted.
PIN_CANON = {
    ('input', 168): (168, 16, (168, 8), [_L(84,12,109,12), _L(84,4,109,4), _L(113,8,168,8), _L(84,12,84,4), _L(109,4,113,8), _L(109,12,113,8)]),
    ('input', 176): (176, 16, (176, 8), [_L(92,12,117,12), _L(92,4,117,4), _L(121,8,176,8), _L(92,12,92,4), _L(117,4,121,8), _L(117,12,121,8)]),
    ('output', 176): (176, 16, (0, 8), [_L(0,8,52,8), _L(52,4,78,4), _L(52,12,78,12), _L(52,12,52,4), _L(78,4,82,8), _L(82,8,78,12), _L(78,12,82,8)]),
}
# Some Quartus versions keep the 176-style arrow (x 92..121) on a 168-wide input pin.
PIN_ALT_DRAWINGS = {('input', 168): [_L(92,12,117,12), _L(92,4,117,4), _L(121,8,168,8), _L(92,12,92,4), _L(117,4,121,8), _L(117,12,121,8)]}
TAGS = ('rotate90', 'rotate180', 'rotate270', 'flipx', 'flipy')

def orient(tag, W, H):
    """Point map from library coordinates to the coordinates Quartus writes."""
    return {
        None: lambda x, y: (x, y),
        'rotate90': lambda x, y: (y, W - x),
        'rotate180': lambda x, y: (W - x, H - y),
        'rotate270': lambda x, y: (H - y, x),
        'flipy': lambda x, y: (W - x, y),
        'flipx': lambda x, y: (x, H - y),
    }[tag]

def oriented_shape(shape, tag, W, H):
    f = orient(tag, W, H)
    kind, args = shape
    def rect(r):
        a, b = f(r[0], r[1]), f(r[2], r[3])
        return (min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
    if kind == 'line':
        return ('line', frozenset([f(*args[0]), f(*args[1])]))
    if kind == 'circle':
        return ('circle', rect(args[0]))
    a, b = f(*args[0]), f(*args[1])
    if tag in ('flipx', 'flipy'): a, b = b, a     # mirroring reverses the arc
    return ('arc', (a, b, rect(args[2])))

def read_shape(d):
    pts = [pt(p) for p in find(d, 'pt')]
    if d[0] == 'line': return ('line', frozenset(pts))
    r = find(d, 'rect')[0]; r = tuple(int(v) for v in r[1:5])
    if d[0] == 'circle': return ('circle', r)
    if d[0] == 'arc': return ('arc', (pts[0], pts[1], r))
    return None

def tag_of(item):
    tags = [c[0] for c in item if isinstance(c, list) and len(c) == 1 and c[0] in TAGS]
    return tags[0] if tags else None, tags

def geometry_problems(tree, strict_pins=True):
    """Compares each primitive symbol / pin with the library drawing under its orientation."""
    problems, checked = [], 0
    for item in tree:
        if not isinstance(item, list) or item[0] not in ('symbol', 'pin'): continue
        tag, tags = tag_of(item)
        if len(tags) > 1: problems.append(f"more than one orientation tag: {tags}")
        r = find(item, 'rect')[0]; w, h = int(r[3]) - int(r[1]), int(r[4]) - int(r[2])
        drawn = find(item, 'drawing')
        got = sorted(map(repr, filter(None, (read_shape(d) for d in drawn[0][1:])))) if drawn else []
        if item[0] == 'pin':
            direction = 'input' if find(item, 'input') else 'output' if find(item, 'output') else None
            width = h if tag in ('rotate90', 'rotate270') else w
            canon = PIN_CANON.get((direction, width))
            if canon is None:
                if strict_pins and direction: problems.append(f"{direction} pin with unknown size {w}x{h}")
                continue
            W, H, p0, draw = canon
            alt = PIN_ALT_DRAWINGS.get((direction, width))
            if alt and sorted(repr(oriented_shape(d, tag, W, H)) for d in alt) == got: draw = alt
            label = f"{direction} pin {find(item, 'text')[1][1]}"
            ports = {'': (p0, p0)}
            got_ports = {'': (pt(find(item, 'pt')[0]), pt(find(item, 'pt')[0]))}
        else:
            name = find(item, 'text')[0][1]
            if name not in CANON: continue
            W, H, ports, draw = CANON[name]
            label = f"{name} {find(item, 'text')[1][1]}"
            got_ports = {}
            for port in find(item, 'port'):
                lines = find(port, 'line')
                got_ports[find(port, 'text')[0][1]] = (pt(find(port, 'pt')[0]),
                                                       frozenset(pt(q) for q in find(lines[0], 'pt')) if lines else None)
        checked += 1
        f = orient(tag, W, H)
        want_size = (H, W) if tag in ('rotate90', 'rotate270') else (W, H)
        if (w, h) != want_size: problems.append(f"{label}: size {w}x{h}, expected {want_size[0]}x{want_size[1]} for {tag}")
        for pn, (p, end) in ports.items():
            if pn not in got_ports: problems.append(f"{label}: port {pn} missing"); continue
            gp, gline = got_ports[pn]
            if gp != f(*p): problems.append(f"{label}: port {pn or 'pt'} at {gp}, expected {f(*p)}")
            if item[0] == 'symbol' and gline is not None and gline != frozenset([f(*p), f(*end)]):
                problems.append(f"{label}: port {pn} lead {sorted(gline)}, expected {sorted([f(*p), f(*end)])}")
        want = sorted(repr(oriented_shape(d, tag, W, H)) for d in draw)
        if got != want: problems.append(f"{label}: drawing differs from the Quartus library ({tag})")
    return problems, checked

# ---------------------------------------------------------------------------
# Hierarchical designs: several .bdf files, block symbols (.bsf), VCC/GND and the
# 7447 library macro.

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = pathlib.Path(os.environ.get('QUARTZITE_FIXTURES') or HERE / 'fixtures' / 'quartus18')

# 7447 (others > maxplus2), written independently from the plan's section 3 table.
# A segment output is 1 when the segment is off. n = 8D + 4C + 2B + A.
SEG_OFF_7447 = {'a': {1, 4, 6, 10, 11, 12, 14, 15}, 'b': {5, 6, 10, 11, 13, 14, 15},
                'c': {2, 10, 12, 13, 14, 15}, 'd': {1, 4, 7, 9, 12, 15},
                'e': {1, 3, 4, 5, 7, 9, 11, 12, 13, 15}, 'f': {1, 2, 3, 7, 10, 11, 15}, 'g': {0, 1, 7, 15}}

def ttl7447(v):
    n = v['A'] + 2 * v['B'] + 4 * v['C'] + 8 * v['D']
    zero_blank = bool(v['LTN'] and not v['RBIN'] and n == 0)
    out = {}
    for seg in 'abcdefg':
        if not v['BIN']: out['O' + seg.upper()] = True
        elif not v['LTN']: out['O' + seg.upper()] = False
        else: out['O' + seg.upper()] = zero_blank or n in SEG_OFF_7447[seg]
    out['RBON'] = not zero_blank      # provisional: independent of BIN (CT-1 7447 probe)
    return out

MACROS = {'7447': ttl7447}

# GND is PROVISIONAL until CT-0b P1-4 captures a Quartus 18 GND; it matches Quartzite's.
GND_TEXT = """(symbol
	(rect 0 0 32 32)
	(text "GND" (rect 8 16 29 26)(font "Arial" (font_size 6)))
	(text "inst" (rect 3 21 26 33)(font "Arial" )(invisible))
	(port
		(pt 16 0)
		(output)
		(text "1" (rect 18 0 26 12)(font "Courier New" (bold))(invisible))
		(text "1" (rect 18 0 26 12)(font "Courier New" (bold))(invisible))
		(line (pt 16 8)(pt 16 0))
	)
	(drawing
		(line (pt 8 8)(pt 16 16))
		(line (pt 16 16)(pt 24 8))
		(line (pt 8 8)(pt 24 8))
	)
)"""

def _first_symbol(text):
    return [i for i in parse(tokenize(text)) if isinstance(i, list) and i and i[0] == 'symbol'][0]

def _reference(name):
    if name == 'VCC': return _first_symbol((FIXTURES / 'lab2' / 'vcc_symbol.txt').read_text())
    if name == 'GND': return _first_symbol(GND_TEXT)
    if name == '7447': return _first_symbol((FIXTURES / 'lab2' / 'sym7447_template.txt').read_text())
    return None

def normalized(sym, keep_instance_rect=False):
    """A symbol without its placement: the rect becomes its size and the instance string is
    dropped (with its rect too, unless keep_instance_rect)."""
    texts = [i for i, c in enumerate(sym) if isinstance(c, list) and c and c[0] == 'text']
    out = []
    for i, c in enumerate(sym):
        if isinstance(c, list) and c and c[0] == 'rect' and i == 1:
            out.append(['size', int(c[3]) - int(c[1]), int(c[4]) - int(c[2])])
        elif len(texts) > 1 and i == texts[1]:
            if keep_instance_rect: out.append(['text', ''] + c[2:])
        else:
            out.append(c)
    return out

def rect_of(node):
    r = find(node, 'rect')[0]
    return tuple(int(v) for v in r[1:5])

def font_of(text):
    f = find(text, 'font')
    if not f: return None
    size = find(f[0], 'font_size')
    return (f[0][1], int(size[0][1]) if size else None)

def round_up16(v):
    return (v + 15) // 16 * 16

def block_rules(sym, bsf=False):
    """Rules R2-R7 (and the width bounds for a .bsf) for a block symbol, with each text width
    read from the port's or name's first text rect."""
    probs = []
    x0, y0, x1, y1 = rect_of(sym)
    W, H = x1 - x0, y1 - y0
    B = H - 16
    name = find(sym, 'text')[0][1] if find(sym, 'text') else '?'
    def bad(m): probs.append(f"{name}: {m}")
    if bsf and (x0, y0) != (16, 16): bad(f"R2 rect starts at {(x0, y0)}, expected (16, 16)")
    texts = find(sym, 'text')
    if len(texts) < 2:
        bad("missing name or instance text"); return probs
    nt, it = texts[0], texts[1]
    tw = rect_of(nt)[2] - rect_of(nt)[0]
    if rect_of(nt) != (5, 0, 5 + tw, 19) or font_of(nt) != ('Intel Clear', 8): bad(f"R6 name text {rect_of(nt)} {font_of(nt)}")
    iw = rect_of(it)[2] - rect_of(it)[0]
    if rect_of(it) != (8, B - 5, 8 + iw, B + 12) or font_of(it) != ('Intel Clear', None): bad(f"R7 instance text {rect_of(it)} {font_of(it)}")
    ports = find(sym, 'port')
    dirs = ['output' if find(p, 'output') else 'input' for p in ports]
    if dirs != sorted(dirs, key=lambda d: d == 'output'): bad("R3 inputs must come before outputs")
    k = {'input': 0, 'output': 0}
    widths = {'input': [0], 'output': [0]}
    for port, d in zip(ports, dirs):
        y = 32 + 16 * k[d]; k[d] += 1
        pn = find(port, 'text')[0][1] if find(port, 'text') else '?'
        x = 0 if d == 'input' else W
        if pt(find(port, 'pt')[0]) != (x, y): bad(f"R3 port {pn} at {pt(find(port, 'pt')[0])}, expected {(x, y)}")
        lines = find(port, 'line')
        lead = {(x, y), (16 if d == 'input' else W - 16, y)}
        if not lines or set(pt(q) for q in find(lines[0], 'pt')) != lead: bad(f"R3 port {pn} lead")
        t = find(port, 'text')
        if len(t) != 2 or t[0][1] != t[1][1]: bad(f"R4 port {pn} needs two texts with its name"); continue
        ptw = rect_of(t[0])[2]
        widths[d].append(ptw)
        if rect_of(t[0]) != (0, 0, ptw, 19) or font_of(t[0]) != ('Intel Clear', 8): bad(f"R4 port {pn} first text {rect_of(t[0])}")
        want = (21, y - 5, 21 + ptw, y + 14) if d == 'input' else (W - 21 - ptw, y - 5, W - 21, y + 14)
        if rect_of(t[1]) != want or font_of(t[1]) != ('Intel Clear', 8): bad(f"R4 port {pn} label {rect_of(t[1])}, expected {want}")
    drawing = find(sym, 'drawing')
    shapes = drawing[0][1:] if drawing else []
    if len(shapes) != 1 or shapes[0][0] != 'rectangle' or rect_of(shapes[0]) != (16, 16, W - 16, B) or find(shapes[0], 'line_width'):
        bad(f"R5 body must be one (rectangle (rect 16 16 {W - 16} {B}))")
    if bsf:
        s = max(widths['input']) + max(widths['output'])
        lo, hi = 32 + max(64, round_up16(s + 10)), 32 + max(64, round_up16(s + 25))
        if W % 16 or not lo <= W <= hi: bad(f"R8 width {W} outside {lo}..{hi}")
    return probs

def bsf_symbol(tree):
    syms = [i for i in tree if isinstance(i, list) and i and i[0] == 'symbol']
    return syms[0] if len(syms) == 1 else None

def symbol_problems(tree, fname, bsfs, blocks=None):
    """VCC/GND and the 7447 against the Quartus text; blocks (a name in `blocks`, or any
    symbol with a .bsf in `bsfs` when `blocks` is None) against R3-R7 and their .bsf."""
    problems = []
    for item in tree:
        if not (isinstance(item, list) and item and item[0] == 'symbol'): continue
        name = find(item, 'text')[0][1]
        if name in ('VCC', 'GND') or name in MACROS:
            if normalized(item, keep_instance_rect=True) != normalized(_reference(name), keep_instance_rect=True):
                problems.append(f"{fname}: {name} {find(item, 'text')[1][1]} differs from the Quartus symbol")
        elif name.lower() in (blocks if blocks is not None else bsfs):
            problems += [f"{fname}: {m}" for m in block_rules(item)]
            b = bsfs.get(name.lower())
            sym = bsf_symbol(b) if b is not None else None
            if sym is None: problems.append(f"{fname}: no {name}.bsf for block {name}")
            elif normalized(item) != normalized(sym): problems.append(f"{fname}: block {name} differs from {name}.bsf")
    return problems

def bsf_problems(path):
    """--bsf: R1-R8 for one .bsf file."""
    raw = pathlib.Path(path).read_bytes()
    probs = []
    if raw.replace(b'\r\n', b'').count(b'\n') or not raw.endswith(b'\r\n'): probs.append("R1 line endings must be CRLF")
    text = raw.decode('utf-8', errors='replace')
    if not text.startswith('/*\r\nWARNING: Do NOT edit'): probs.append("R1 must start with the WARNING comment")
    tree = parse(tokenize(text))
    heads = [i for i in tree if isinstance(i, list)]
    if not heads or heads[0] != ['header', 'symbol', ['version', '1.2']]: probs.append('R1 header must be (header "symbol" (version "1.2"))')
    syms = [i for i in heads if i[0] == 'symbol']
    if len(syms) != 1: probs.append(f"R1 needs exactly one symbol, found {len(syms)}"); return probs
    return probs + block_rules(syms[0], bsf=True)

def sheet_netlist(tree):
    """Pins, symbols (port directions from (input)/(output)) and the local nets of one .bdf."""
    parent = {}
    def node(k):
        parent.setdefault(k, k); return k
    def root(k):
        node(k)
        while parent[k] != k:
            parent[k] = parent[parent[k]]; k = parent[k]
        return k
    def join(a, b):
        ra, rb = root(a), root(b)
        if ra != rb: parent[ra] = rb
    points, pins, symbols, segs = {}, [], [], []
    junctions = 0
    def at(p, key):
        node(key); points.setdefault(p, []).append(key)
    for item in tree:
        if not isinstance(item, list): continue
        if item[0] == 'pin':
            direction = 'input' if find(item, 'input') else 'output'
            x0, y0 = rect_of(item)[:2]
            texts = find(item, 'text')
            name = texts[1][1]
            default = texts[2][1].upper() if direction == 'input' and len(texts) > 2 else 'VCC'
            p = pt(find(item, 'pt')[0]); p = (x0 + p[0], y0 + p[1])
            key = ('pin', name)
            pins.append((name, direction, key, default))
            at(p, key); join(key, ('name', name.lower()))
        elif item[0] == 'symbol':
            x0, y0 = rect_of(item)[:2]
            texts = find(item, 'text')
            sym, inst = texts[0][1], texts[1][1]
            ports = {}
            for port in find(item, 'port'):
                p = pt(find(port, 'pt')[0]); p = (x0 + p[0], y0 + p[1])
                pname = find(port, 'text')[0][1]
                key = ('port', inst, pname)
                ports[pname] = (key, 'output' if find(port, 'output') else 'input')
                at(p, key)
            symbols.append({'inst': inst, 'name': sym, 'ports': ports, 'item': item})
        elif item[0] == 'connector':
            ps = [pt(q) for q in find(item, 'pt')]
            key = ('seg', len(segs))
            segs.append((ps[0], ps[1], key))
            for q in ps: at(q, key)
            texts = find(item, 'text')
            if texts: join(key, ('name', texts[0][1].lower()))
        elif item[0] == 'junction':
            junctions += 1
            at(pt(find(item, 'pt')[0]), ('junction', junctions))
    for p, keys in points.items():
        for k in keys[1:]: join(keys[0], k)
    # endpoints (and junctions) lying on another connector's interior connect to it
    def on(p, a, b):
        if a[0] == b[0] == p[0]: return min(a[1], b[1]) <= p[1] <= max(a[1], b[1])
        if a[1] == b[1] == p[1]: return min(a[0], b[0]) <= p[0] <= max(a[0], b[0])
        return False
    for p, keys in points.items():
        for a, b, key in segs:
            if p != a and p != b and on(p, a, b):
                # Quartus only joins a T when a junction or connector endpoint sits there
                if any(k[0] in ('seg', 'junction') for k in keys):
                    join(keys[0], key)
    members = {}
    for k in list(parent): members.setdefault(root(k), []).append(k)
    return {'pins': pins, 'symbols': symbols, 'root': root, 'members': members}

def classify(name, sheets):
    if name in PRIMS: return 'primitive'
    if name in ('VCC', 'GND'): return 'constant'
    if name in MACROS: return 'macro'
    if name.lower() in sheets: return 'block'
    return None

def check_folder(folder):
    """Flattens every .bdf in a bundle from the top, checks the symbols, the .qsf and the
    drivers, then simulates every input row against expected.json."""
    folder = pathlib.Path(folder)
    exp = json.loads((folder / 'expected.json').read_text())
    top = exp.get('top', exp['entity'])
    sheets = {f.stem.lower(): (f.name, parse(tokenize(f.read_text()))) for f in sorted(folder.glob('*.bdf'))}
    bsfs = {f.stem.lower(): parse(tokenize(f.read_text())) for f in sorted(folder.glob('*.bsf'))}
    if top.lower() not in sheets: return False, [f"no {top}.bdf"]
    problems = []
    # Geometry: primitives and pins, then VCC/GND, the 7447 and blocks.
    for stem, (fname, tree) in sheets.items():
        geo, _ = geometry_problems(tree)
        problems += [f"{fname}: {g}" for g in geo]
        problems += symbol_problems(tree, fname, bsfs, blocks=sheets)
    for stem, b in bsfs.items():
        sym = bsf_symbol(b)
        problems += [f"{stem}.bsf: {m}" for m in (block_rules(sym, bsf=True) if sym else ['needs exactly one symbol'])]
    if problems: return False, problems

    # Flatten.
    parent = {}
    def froot(k):
        parent.setdefault(k, k)
        while parent[k] != k:
            parent[k] = parent[parent[k]]; k = parent[k]
        return k
    def fjoin(a, b):
        ra, rb = froot(a), froot(b)
        if ra != rb: parent[ra] = rb
    gates, consts, macros, top_pins, used, used_macros = [], [], [], [], [], []
    def expand(stem, prefix, bindings, stack):
        fname, tree = sheets[stem]
        if fname not in used: used.append(fname)
        net = sheet_netlist(tree)
        def fk(k): return (prefix, net['root'](k))
        def connected(k): return len(net['members'][net['root'](k)]) > 1
        for name, d, key, default in net['pins']:
            froot(fk(key))
            if not prefix:
                top_pins.append((name, d, fk(key)))
            elif name.lower() in bindings:
                fjoin(fk(key), bindings[name.lower()])
            elif d == 'input':
                consts.append((fk(key), default != 'GND', '/'.join(prefix) + '/' + name + ' (default)'))
        for s in net['symbols']:
            path = '/'.join(prefix + (s['inst'],))
            kind = classify(s['name'], sheets)
            ports = s['ports']
            if kind == 'primitive':
                ins = [fk(k) for pn, (k, d) in sorted(ports.items()) if d == 'input']
                outs = [fk(k) for pn, (k, d) in ports.items() if d == 'output']
                if len(outs) != 1: problems.append(f"{path}: {s['name']} needs one output port"); continue
                gates.append((path, s['name'], ins, outs[0]))
            elif kind == 'constant':
                for pn, (k, d) in ports.items(): consts.append((fk(k), s['name'] == 'VCC', path))
            elif kind == 'macro':
                if s['name'] not in used_macros: used_macros.append(s['name'])
                macros.append((path, s['name'], {pn: fk(k) for pn, (k, d) in ports.items() if d == 'input'},
                               {pn: fk(k) for pn, (k, d) in ports.items() if d == 'output'}))
            elif kind == 'block':
                child = s['name'].lower()
                if child in stack: problems.append(f"{path}: {s['name']} contains itself"); continue
                cpins = {n.lower(): d for n, d, _, _ in sheet_netlist(sheets[child][1])['pins']}
                if cpins != {pn.lower(): d for pn, (k, d) in ports.items()}:
                    problems.append(f"{path}: ports of {s['name']} differ from the pins of {sheets[child][0]}"); continue
                expand(child, prefix + (s['inst'],), {pn.lower(): fk(k) for pn, (k, d) in ports.items() if connected(k)}, stack + [child])
            else:
                problems.append(f"{path}: unknown symbol {s['name']} (no {s['name']}.bdf in the folder)")
    expand(top.lower(), (), {}, [top.lower()])
    if problems: return False, problems

    # The .qsf and the file set.
    qsfs = [f for f in folder.glob('*.qsf') if not f.name.endswith('_pins.qsf')]
    if len(qsfs) != 1: problems.append(f"expected one project .qsf, found {[f.name for f in qsfs]}")
    else:
        q = qsfs[0].read_text()
        files = re.findall(r'^set_global_assignment -name BDF_FILE (\S+)', q, re.M)
        if sorted(files) != sorted(used): problems.append(f"{qsfs[0].name}: BDF_FILE {files}, used {used}")
        tops = re.findall(r'^set_global_assignment -name TOP_LEVEL_ENTITY (\S+)', q, re.M)
        if tops != [top]: problems.append(f"{qsfs[0].name}: TOP_LEVEL_ENTITY {tops}, expected {top}")
        located = re.findall(r'^set_location_assignment \S+ -to (\S+)', q, re.M)
        names = {n for n, _, _ in top_pins}
        if set(located) - names: problems.append(f"{qsfs[0].name}: locations for non-top pins {sorted(set(located) - names)}")
        io = set(re.findall(r'^set_instance_assignment -name IO_STANDARD "[^"]+" -to (\S+)', q, re.M))
        if set(located) - io: problems.append(f"{qsfs[0].name}: no IO_STANDARD for {sorted(set(located) - io)}")
    unused = sorted(n for n, _ in sheets.values() if n not in used)
    if unused: problems.append(f"files not used under {top}: {unused}")
    if 'files' in exp and sorted(exp['files']) != sorted(used): problems.append(f"expected.json files {exp['files']}, used {used}")
    if 'symbols' in exp and sorted(exp['symbols']) != sorted(f.name for f in folder.glob('*.bsf')): problems.append("expected.json symbols differ from the .bsf files")
    if 'macros' in exp and sorted(exp['macros']) != sorted(used_macros): problems.append(f"expected.json macros {exp['macros']}, used {used_macros}")

    # Drivers across the hierarchy.
    drivers = {}
    for name, d, key in top_pins:
        if d == 'input': drivers.setdefault(froot(key), []).append(f"pin {name}")
    for path, prim, ins, out in gates: drivers.setdefault(froot(out), []).append(path)
    for key, v, path in consts: drivers.setdefault(froot(key), []).append(path)
    for path, m, ins, outs in macros:
        for pn, k in outs.items(): drivers.setdefault(froot(k), []).append(f"{path}.{pn}")
    problems += [f"net with {len(v)} drivers: {v}" for v in drivers.values() if len(v) > 1]
    for path, prim, ins, out in gates:
        for i, k in enumerate(ins):
            if froot(k) not in drivers: problems.append(f"{path} input {i + 1} undriven")
    for path, m, ins, outs in macros:
        for pn, k in ins.items():
            if froot(k) not in drivers: problems.append(f"{path}.{pn} undriven")
    for name, d, key in top_pins:
        if d == 'output' and froot(key) not in drivers: problems.append(f"output {name} undriven")
    by_name = {n: (n, d, k) for n, d, k in top_pins}
    if sorted(exp['inputs']) != sorted(n for n, d, _ in top_pins if d == 'input') or sorted(exp['outputs']) != sorted(n for n, d, _ in top_pins if d == 'output'):
        problems.append("pin set differs from expected.json")
    if problems: return False, problems

    # Evaluation order (also finds combinational loops).
    nodes = [('g', g) for g in gates] + [('m', m) for m in macros]
    produced = {}
    for i, (kind, n) in enumerate(nodes):
        for k in ([n[3]] if kind == 'g' else list(n[3].values())): produced[froot(k)] = i
    deps = [set(produced[froot(k)] for k in (n[2] if kind == 'g' else n[2].values()) if froot(k) in produced) for kind, n in nodes]
    order, state = [], [0] * len(nodes)
    def visit(i):
        if state[i] == 2: return True
        if state[i] == 1: return False
        state[i] = 1
        for j in deps[i]:
            if not visit(j): return False
        state[i] = 2; order.append(i); return True
    sys.setrecursionlimit(max(1000, 4 * len(nodes) + 100))
    if not all(visit(i) for i in range(len(nodes))): return False, ["combinational loop"]

    in_order = [by_name[n] for n in exp['inputs']]
    out_order = [by_name[n] for n in exp['outputs']]
    mismatches = []
    n = len(in_order)
    for i in range(1 << n):
        val = {froot(k): v for k, v, _ in consts}
        for b, (name, d, key) in enumerate(in_order):
            val[froot(key)] = bool((i >> (n - 1 - b)) & 1)
        for j in order:
            kind, g = nodes[j]
            if kind == 'g':
                val[froot(g[3])] = PRIMS[g[1]]([val[froot(k)] for k in g[2]])
            else:
                res = MACROS[g[1]]({pn: val[froot(k)] for pn, k in g[2].items()})
                for pn, k in g[3].items(): val[froot(k)] = res[pn]
        got = ''.join('1' if val.get(froot(key)) else '0' for name, d, key in out_order)
        if got != exp['rows'][i]: mismatches.append(f"row {i}: bdf gives {got}, expected {exp['rows'][i]}")
    return not mismatches, mismatches

def check(folder):
    return check_folder(folder)

def strip_attrs(node):
    """Drops styling such as (line_width 1) that some Quartus versions add."""
    if not isinstance(node, list): return node
    return [strip_attrs(c) for c in node if not (isinstance(c, list) and c and c[0] in ('line_width', 'color'))]

if __name__ == '__main__' and sys.argv[1:2] == ['--bsf']:
    ok_all = True
    for f in sys.argv[2:]:
        problems = bsf_problems(f)
        ok_all &= not problems
        print(('PASS ' if not problems else 'FAIL ') + f)
        for m in problems[:10]: print('   ', m)
    sys.exit(0 if ok_all else 1)

if __name__ == '__main__' and sys.argv[1:2] == ['--geometry']:
    ok_all, total = True, 0
    for f in sys.argv[2:]:
        tree = [strip_attrs(i) for i in parse(tokenize(open(f, errors='replace').read()))]
        problems, n = geometry_problems(tree, strict_pins=False)
        here = pathlib.Path(f).parent
        bsfs = {b.stem.lower(): parse(tokenize(b.read_text(errors='replace'))) for b in here.glob('*.bsf')}
        problems += symbol_problems(tree, pathlib.Path(f).name, bsfs)
        total += n
        ok_all &= not problems
        print(('PASS ' if not problems else 'FAIL ') + f + f" ({n} primitives)")
        for m in problems[:10]: print('   ', m)
    print(f"{total} primitive symbols and pins checked")
    sys.exit(0 if ok_all else 1)

if __name__ == '__main__':
    ok_all = True
    for f in sys.argv[1:]:
        ok, notes = check(f)
        ok_all &= ok
        print(('PASS ' if ok else 'FAIL ') + f)
        for m in notes[:10]: print('   ', m)
    sys.exit(0 if ok_all else 1)
