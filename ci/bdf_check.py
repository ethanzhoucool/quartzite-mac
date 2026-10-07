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
"""
import json, re, sys, itertools, pathlib

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

def check(folder):
    folder = pathlib.Path(folder)
    exp = json.loads((folder / 'expected.json').read_text())
    tree = parse(tokenize((folder / f"{exp['entity']}.bdf").read_text()))
    geo, _ = geometry_problems(tree)
    if geo:
        return False, geo
    parent = {}
    def node(k):
        parent.setdefault(k, k); return k
    def root(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]; k = parent[k]
        return k
    def join(a, b):
        ra, rb = root(node(a)), root(node(b))
        if ra != rb: parent[ra] = rb

    points = {}     # absolute point -> list of node keys at that point
    pins, gates, segs = [], [], []
    junctions = 0
    def at(p, key):
        node(key); points.setdefault(p, []).append(key)

    for item in tree:
        if not isinstance(item, list): continue
        if item[0] == 'pin':
            direction = 'input' if find(item, 'input') else 'output'
            r = find(item, 'rect')[0]; x0, y0 = int(r[1]), int(r[2])
            name = find(item, 'text')[1][1]
            p = pt(find(item, 'pt')[0]); p = (x0 + p[0], y0 + p[1])
            key = ('pin', name)
            pins.append((name, direction, key))
            at(p, key); join(key, ('name', name.lower()))
        elif item[0] == 'symbol':
            r = find(item, 'rect')[0]; x0, y0 = int(r[1]), int(r[2])
            prim = find(item, 'text')[0][1]
            inst = find(item, 'text')[1][1]
            ports = {}
            for port in find(item, 'port'):
                p = pt(find(port, 'pt')[0]); p = (x0 + p[0], y0 + p[1])
                pname = find(port, 'text')[0][1]
                key = ('port', inst, pname)
                ports[pname] = key
                at(p, key)
            gates.append((inst, prim, ports))
        elif item[0] == 'connector':
            ps = [pt(p) for p in find(item, 'pt')]
            key = ('seg', len(segs))
            segs.append((ps[0], ps[1], key))
            for p in ps: at(p, key)
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

    gate_index = {g[0]: g for g in gates}
    ins = [p for p in pins if p[1] == 'input']
    outs = [p for p in pins if p[1] == 'output']
    by_name = {p[0]: p for p in pins}
    in_order = [by_name[n] for n in exp['inputs']]
    out_order = [by_name[n] for n in exp['outputs']]
    assert len(in_order) == len(ins) and len(out_order) == len(outs), "pin set differs from expected.json"

    # every gate input must be driven by exactly one driver
    drivers = {}
    for name, d, key in ins: drivers.setdefault(root(key), []).append(key)
    for inst, prim, ports in gates: drivers.setdefault(root(ports['OUT']), []).append(ports['OUT'])
    problems = [f"net with {len(v)} drivers: {v}" for v in drivers.values() if len(v) > 1]
    for inst, prim, ports in gates:
        for pn, key in ports.items():
            if pn != 'OUT' and root(key) not in drivers: problems.append(f"{inst}.{pn} undriven")
    for name, d, key in outs:
        if root(key) not in drivers: problems.append(f"output {name} undriven")
    if problems:
        return False, problems

    mismatches = []
    n = len(in_order)
    for i in range(1 << n):
        val = {}
        for k, (name, d, key) in enumerate(in_order):
            val[root(key)] = bool((i >> (n - 1 - k)) & 1)
        for _ in range(len(gates) + 1):
            for inst, prim, ports in gates:
                ins_v = [val.get(root(ports[p])) for p in sorted(ports) if p != 'OUT']
                if None not in ins_v: val[root(ports['OUT'])] = PRIMS[prim](ins_v)
        got = ''.join('1' if val.get(root(key)) else '0' for name, d, key in out_order)
        if got != exp['rows'][i]: mismatches.append(f"row {i}: bdf gives {got}, expected {exp['rows'][i]}")
    return not mismatches, mismatches

def strip_attrs(node):
    """Drops styling such as (line_width 1) that some Quartus versions add."""
    if not isinstance(node, list): return node
    return [strip_attrs(c) for c in node if not (isinstance(c, list) and c and c[0] in ('line_width', 'color'))]

if __name__ == '__main__' and sys.argv[1:2] == ['--geometry']:
    ok_all, total = True, 0
    for f in sys.argv[2:]:
        tree = [strip_attrs(i) for i in parse(tokenize(open(f, errors='replace').read()))]
        problems, n = geometry_problems(tree, strict_pins=False)
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
