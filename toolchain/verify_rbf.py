#!/usr/bin/env python3
"""Independent check of a Cyclone V .rbf produced by nextpnr-mistral.

The bitstream is decompiled with Mistral's `mistral-cv decomp` (not with
nextpnr), then this script:

  1. checks every constrained pin's GPIO block: inputs must have a routed
     DATAIN and no output enable; outputs must have a routed DATAOUT, the
     output-enable inversion set, and a drive strength;
  2. rebuilds the routed netlist from the decompiled `r` (routing) lines;
  3. simulates every output over the full truth table by walking back from
     the output pin through routing into ALM LUT masks and on to the input
     pins, and compares with the expected boolean expression.

ALM model used for evaluation (from Mistral's documentation and the bit
mapping nextpnr-mistral uses; see docs/TOOLCHAIN_NOTES.md):
  * 64-bit LUT_MASK per ALM; top half = bits 0..31 (inputs A,B,C,E0,F0),
    bottom half = bits 32..63 (inputs A,B,D,E1,F1) in 5-LUT mode
    (TMODE=E_0 / BMODE=E_1); 6-LUT mode (Mistral default TMODE=D_E,
    BMODE=C_E) uses A,B,C,D plus E0,F0 (top outputs) or E1,F1 (bottom
    outputs); E = bit5 selects the half, F = bit4, and C/D sit at bit2/bit3
    in the low half and bit3/bit2 in the high half;
  * 5-LUT address = A | B<<1 | (C|D)<<2 | E<<3 | F<<4;
  * ALM inputs are inverted on the way into the LUT and the stored mask is
    the complement: out = ~MASK[addr(~inputs)];
  * FFT0/FFT1/FFT1L (FFB0/FFB1/FFB1L) carry the top (bottom) combinational
    output when TDFFx (BDFFx) = NLUT;
  * MLAB masks are permuted (table copied from nextpnr-mistral lab.cc).
An unrouted ALM input must not influence the output (checked by enumerating it).

Spec file (JSON):
  {"device": "5CSXFC6D6F31C6",
   "inputs":  {"w": "AC30", "x": "AB28", ...},
   "outputs": {"f": {"pin": "AA24", "expr": "x&z | w&~x&~y | ~x&y&~z"}}}
expr uses the input names with Python & | ^ ~ on 0/1 values.

Usage: verify_rbf.py spec.json design.rbf [--bt out.bt] [--mistral-cv PATH] [--table]
Exit status 0 only if every check passes.
"""
import argparse
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile

DEFAULT_MCV = os.path.expanduser("~/.quartzite/toolchain/prefix/bin/mistral-cv")

MLAB_PERMUTE = [0, 1, 4, 5, 8, 9, 12, 13, 29, 28, 25, 24, 21, 20, 17, 16,
                2, 3, 6, 7, 10, 11, 14, 15, 31, 30, 27, 26, 23, 22, 19, 18,
                32, 33, 36, 37, 40, 41, 44, 45, 61, 60, 57, 56, 53, 52, 49, 48,
                34, 35, 38, 39, 42, 43, 46, 47, 63, 62, 59, 58, 55, 54, 51, 50]

TOP_OUTS = {"FFT0": "TDFF0", "FFT1": "TDFF1", "FFT1L": "TDFF1L"}
BOT_OUTS = {"FFB0": "BDFF0", "FFB1": "BDFF1", "FFB1L": "BDFF1L"}


class VerifyError(Exception):
    pass


def parse_bt(path):
    routes = {}       # dst -> src
    route_pins = {}   # pnode -> pin name (from comments)
    settings = {}     # (block, mux, idx) -> value
    gpio_pins = {}    # pin -> list of (block, mux, idx, value)
    inv = {}          # node -> (value, pin)
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            body, _, comment = line.partition(" ; ")
            parts = body.split()
            if not parts:
                continue
            if parts[0] == "r":
                src, dst = parts[1], parts[2]
                if dst in routes and routes[dst] != src:
                    raise VerifyError(f"node {dst} has two drivers: {routes[dst]} and {src}")
                routes[dst] = src
                # Pin comments name the pad of a pin-attached source/destination;
                # pads in the hard-memory-controller area are reached through
                # HMC bypass nodes (e.g. HMC.025.000:IOINTDQDOUT.160).
                pins = comment.split() if comment else []
                for node in (src, dst):
                    if node.startswith(("GPIO.", "HMC.")) and pins:
                        route_pins[node] = pins.pop(0)
            elif parts[0] == "s":
                m = re.match(r"(\w+\.\d+\.\d+):(\w+)(?:\.(\d+))?$", parts[1])
                if not m:
                    continue
                block, mux, idx = m.group(1), m.group(2), int(m.group(3)) if m.group(3) else -1
                settings[(block, mux, idx)] = parts[2]
                if block.startswith("GPIO.") and comment:
                    gpio_pins.setdefault(comment.split()[0], []).append((block, mux, idx, parts[2]))
            elif parts[0] == "i":
                fields = comment.split(" ; ") if comment else [""]
                pin = fields[0]
                # HMC-area inverters print the GPIO node they stand for last
                alias = fields[-1].split()[-1] if len(fields) > 1 else parts[1]
                inv[parts[1]] = (parts[2], pin, alias)
    return routes, route_pins, settings, gpio_pins, inv


def lut_mask(settings, block, alm):
    v = settings.get((block, "LUT_MASK", alm))
    if v is None:
        return None
    mask = int(v.replace(".", ""), 16)
    if block.startswith("MLAB."):
        orig = 0
        for i in range(64):
            if (mask >> MLAB_PERMUTE[i]) & 1:
                orig |= 1 << i
        mask = orig
    return mask


class Netlist:
    def __init__(self, routes, settings, inv, in_nodes):
        self.routes = routes
        self.settings = settings
        self.inv = inv
        self.in_nodes = in_nodes  # GPIO DATAIN node -> input name
        self.used_alms = set()

    def driver_chain(self, node):
        seen = []
        while node in self.routes:
            seen.append(node)
            node = self.routes[node]
            if node in seen:
                raise VerifyError(f"routing loop at {node}")
        return node, seen

    def value(self, node, env, depth=0):
        if depth > 64:
            raise VerifyError("combinational depth > 64 (loop?)")
        src, chain = self.driver_chain(node)
        for n in chain + [src]:
            if n in self.inv:
                raise VerifyError(f"routing node {n} has a non-default inversion; not modelled")
        if src in self.in_nodes:
            return env[self.in_nodes[src]]
        m = re.match(r"((?:LAB|MLAB)\.\d+\.\d+)\.(\d+):(\w+)$", src)
        if not m:
            raise VerifyError(f"net {node} is driven by unsupported source {src}")
        block, alm, pin = m.group(1), int(m.group(2)), m.group(3)
        return self.alm_output(block, alm, pin, env, depth)

    def alm_output(self, block, alm, pin, env, depth):
        if pin in TOP_OUTS:
            half, sel = 0, TOP_OUTS[pin]
        elif pin in BOT_OUTS:
            half, sel = 1, BOT_OUTS[pin]
        else:
            raise VerifyError(f"unsupported ALM output {block}.{alm}:{pin}")
        if self.settings.get((block, sel, alm)) != "NLUT":
            raise VerifyError(f"{block}.{alm}:{pin} is a register output ({sel} != NLUT); "
                              "sequential logic is not modelled")
        # Mistral defaults: TMODE=D_E, BMODE=C_E (the 6-LUT arrangement);
        # nextpnr writes E_0/E_1 explicitly for two independent 5-LUT halves.
        tmode = self.settings.get((block, "TMODE", alm), "D_E")
        bmode = self.settings.get((block, "BMODE", alm), "C_E")
        if self.settings.get((block, "ARITH_SEL", alm), "LUT") != "LUT":
            raise VerifyError(f"{block}.{alm}: ALM in arithmetic (carry-chain) mode; not modelled")
        if block.startswith("MLAB.") and self.settings.get((block, "RAM_DIS", -1), "1") != "1":
            raise VerifyError(f"{block}: LUTRAM mode; memory is not modelled")
        mask = lut_mask(self.settings, block, alm)
        if mask is None:
            mask = (1 << 64) - 1  # default: all ones
        if (tmode, bmode) == ("E_0", "E_1"):
            l6 = False
            pins = ["A", "B", "C" if half == 0 else "D", "E0" if half == 0 else "E1", "F0" if half == 0 else "F1"]
        elif (tmode, bmode) == ("D_E", "C_E"):
            # 6-LUT: a top output uses E0/F0, a bottom output E1/F1
            l6 = True
            pins = ["A", "B", "C", "D", "E0" if half == 0 else "E1", "F0" if half == 0 else "F1"]
        else:
            raise VerifyError(f"{block}.{alm}: TMODE/BMODE {tmode}/{bmode} not modelled")
        self.used_alms.add((block, alm, half, l6))
        vals, floating = [], []
        for i, p in enumerate(pins):
            node = f"{block}.{alm}:{p}"
            if node in self.routes:
                vals.append(self.value(node, env, depth + 1))
            else:
                vals.append(None)
                floating.append(i)
        outs = set()
        # QZ_FLOAT_INPUT=0|1 fixes unrouted ALM inputs to that value (to study how Quartus
        # leaves unused inputs); by default every combination is tried and must agree.
        fixed = os.environ.get("QZ_FLOAT_INPUT")
        combos = [tuple([int(fixed)] * len(floating))] if fixed in ("0", "1") else \
            itertools.product((0, 1), repeat=len(floating))
        for combo in combos:
            v = dict(zip(pins, vals))
            for i, b in zip(floating, combo):
                v[pins[i]] = b
            n = {k: (1 - x) & 1 for k, x in v.items()}  # ALM inputs are inverted
            if not l6:
                # 5-LUT half: A=bit0 B=bit1 C|D=bit2 E=bit3 F=bit4, offset 32 for bottom
                addr = n["A"] | n["B"] << 1 | n[pins[2]] << 2 | n[pins[3]] << 3 | n[pins[4]] << 4
                bit = 32 * half + addr
            else:
                # 6-LUT: E (bit5) selects the half; low half sees C at bit2 and
                # D at bit3 (TMODE=D_E), high half the reverse (BMODE=C_E); F = bit4
                e = n[pins[4]]
                cd = (n["C"] << 2 | n["D"] << 3) if e == 0 else (n["D"] << 2 | n["C"] << 3)
                bit = n["A"] | n["B"] << 1 | cd | n[pins[5]] << 4 | e << 5
            outs.add(1 - ((mask >> bit) & 1))
        if len(outs) != 1:
            raise VerifyError(f"{block}.{alm} half {half}: output depends on an unrouted input")
        return outs.pop()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec")
    ap.add_argument("rbf")
    ap.add_argument("--bt", help="write/keep the decompiled bitstream text here")
    ap.add_argument("--mistral-cv", default=os.environ.get("MISTRAL_CV", DEFAULT_MCV))
    ap.add_argument("--table", action="store_true", help="print the full truth table")
    args = ap.parse_args()

    spec = json.load(open(args.spec))
    device = spec.get("device", "5CSXFC6D6F31C6")
    bt = args.bt or os.path.join(tempfile.mkdtemp(), "design.bt")
    r = subprocess.run([args.mistral_cv, "decomp", device, args.rbf, bt], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        print("FAIL: mistral-cv decomp failed")
        return 2
    routes, route_pins, settings, gpio_pins, inv = parse_bt(bt)
    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    pin_node = {}
    for node, pin in route_pins.items():
        pin_node.setdefault(pin, set()).add(node)

    print(f"Decompiled {args.rbf} -> {bt}: {len(routes)} routed links, {len(settings)} non-default settings")
    print("I/O blocks:")
    in_nodes = {}
    def output_enabled(pin):
        # nextpnr drives OE by inverting the constant OEIN inputs: an output has
        # OEIN.0 inverted (1) and OEIN.1 not inverted (0). Either non-default
        # value is taken as evidence (Mistral master and nextpnr-latest disagree
        # on the printed default for HMC-area OEIN.0 nodes).
        return [k for k, (v, p, a) in inv.items()
                if p == pin and ((a.endswith(":OEIN.0") and v == "1") or (a.endswith(":OEIN.1") and v == "0"))]

    for name, pin in spec["inputs"].items():
        nodes = [n for n in pin_node.get(pin, ()) if re.search(r":(DATAIN|\w*DIN)\.\d+$", n)]
        oe = output_enabled(pin)
        cfg = gpio_pins.get(pin, [])
        drive = [c for c in cfg if c[1] == "DRIVE_STRENGTH"]
        check(len(nodes) == 1 and not oe and not drive,
              f"input  {name:>4} PIN_{pin}: DATAIN routed={bool(nodes)} OE={'on' if oe else 'off'} "
              f"cfg={[f'{c[1]}={c[3]}' for c in cfg]}")
        for n in nodes:
            in_nodes[n] = name
    out_nodes = {}
    for name, o in spec["outputs"].items():
        pin = o["pin"]
        nodes = [n for n in pin_node.get(pin, ()) if re.search(r":(DATAOUT|\w*DOUT)\.\d+$", n)]
        oe = output_enabled(pin)
        cfg = gpio_pins.get(pin, [])
        drive = [c[3] for c in cfg if c[1] == "DRIVE_STRENGTH"]
        check(len(nodes) == 1 and len(oe) >= 1 and len(drive) == 1,
              f"output {name:>4} PIN_{pin}: DATAOUT routed={bool(nodes)} OE={'on' if oe else 'off'} "
              f"drive={drive}")
        if nodes:
            out_nodes[name] = nodes[0]

    net = Netlist(routes, settings, inv, in_nodes)
    names = list(spec["inputs"].keys())
    print(f"Truth table over {', '.join(names)} (first name = MSB), {2 ** len(names)} rows:")
    bad = 0
    rows = []
    try:
        for idx in range(2 ** len(names)):
            env = {n: (idx >> (len(names) - 1 - i)) & 1 for i, n in enumerate(names)}
            got, exp = {}, {}
            for oname, o in spec["outputs"].items():
                exp[oname] = eval(o["expr"], {}, dict(env)) & 1
                got[oname] = net.value(out_nodes[oname], env) if oname in out_nodes else None
            ok = got == exp
            bad += not ok
            rows.append((idx, env, got, exp, ok))
    except VerifyError as e:
        check(False, f"netlist evaluation: {e}")
    else:
        if args.table or len(rows) <= 16:
            hdr = " ".join(names) + " | " + " ".join(spec["outputs"])
            print("    m  " + hdr + "   expected  ")
            for idx, env, got, exp, ok in rows:
                print(f"   {idx:2d}  " + " ".join(str(env[n]).rjust(len(n)) for n in names) + " | "
                      + " ".join(str(got[o]).rjust(len(o)) for o in spec["outputs"]) + "   "
                      + " ".join(str(exp[o]) for o in spec["outputs"]) + ("" if ok else "   <-- MISMATCH"))
        for oname in spec["outputs"]:
            nbad = sum(1 for r_ in rows if r_[2][oname] != r_[3][oname])
            print(f"    {oname:>6}: {len(rows) - nbad}/{len(rows)} rows correct")
        check(bad == 0, f"{len(rows) - bad}/{len(rows)} rows match the expected function")
    alms = sorted(net.used_alms)
    print(f"ALM halves on the input->output paths: {len(alms)}")
    for block, alm, half, l6 in alms:
        print(f"    {block}.{alm} {'6-LUT' if l6 else ('top' if half == 0 else 'bottom')} LUT_MASK="
              f"{settings.get((block, 'LUT_MASK', alm), '(default)')}")
    print("PASS" if not failures else f"FAIL ({len(failures)} problem(s))")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
