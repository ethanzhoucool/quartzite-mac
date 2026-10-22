#!/usr/bin/env python3
"""Simulate the gate-level netlist real Quartus wrote for an exported design.

After compiling a Quartzite bundle in Quartus (with EDA Netlist Writer on, which the
exported .qsf requests), Quartus leaves simulation/modelsim/<name>.vo. This runs every
input row through it with Icarus Verilog and compares the outputs with expected.json.

    vo_check.py <design-folder>... --sim-lib <quartus>/eda/sim_lib [--vo <file.vo>]

--sim-lib is the folder holding cyclonev_atoms.v and altera_primitives.v from a local
Quartus install (defaults to $QUARTUS_ROOTDIR/eda/sim_lib). Those files are Intel's and
are never committed here.
"""
import argparse, json, os, pathlib, re, subprocess, sys, tempfile

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_$]*\Z')


def vname(n):
    return n if IDENT.match(n) else f'\\{n} '


def find_vo(folder, exp):
    d = folder / 'simulation' / 'modelsim'
    for n in (exp.get('top'), exp.get('entity')):
        if n and (d / f'{n}.vo').exists(): return d / f'{n}.vo'
    found = sorted(d.glob('*.vo'))
    return found[0] if len(found) == 1 else None


def testbench(top, ins, outs):
    n, m = len(ins), len(outs)
    conn = [f'.{vname(p)}(qz_in[{n - 1 - k}])' for k, p in enumerate(ins)] + \
           [f'.{vname(p)}(qz_out[{m - 1 - k}])' for k, p in enumerate(outs)]
    return f'''`timescale 1 ps / 1 ps
module qz_vo_tb;
  reg [{max(n, 1) - 1}:0] qz_in;
  wire [{m - 1}:0] qz_out;
  integer i;
  {vname(top)} dut({', '.join(conn)});
  initial begin
    for (i = 0; i < {1 << n}; i = i + 1) begin
      qz_in = i;
      #1000 $display("ROW %0d %b", i, qz_out);
    end
    $finish;
  end
endmodule
'''


def check(folder, sim_lib, vo=None):
    folder = pathlib.Path(folder).resolve()
    exp = json.loads((folder / 'expected.json').read_text())
    top, ins, outs, rows = exp.get('top', exp['entity']), exp['inputs'], exp['outputs'], exp['rows']
    vo = pathlib.Path(vo) if vo else find_vo(folder, exp)
    if vo is None or not vo.exists():
        return False, [f"no .vo in {folder / 'simulation' / 'modelsim'}; compile in Quartus with EDA Netlist Writer on"]
    libs = [pathlib.Path(sim_lib) / f for f in ('cyclonev_atoms.v', 'altera_primitives.v')]
    missing = [str(l) for l in libs if not l.exists()]
    if missing: return False, [f"missing simulation library {m}" for m in missing]
    with tempfile.TemporaryDirectory() as tmp:
        tb = pathlib.Path(tmp) / 'qz_vo_tb.v'
        tb.write_text(testbench(top, ins, outs))
        out = pathlib.Path(tmp) / 'qz_vo_tb.out'
        p = subprocess.run(['iverilog', '-o', str(out), '-s', 'qz_vo_tb', str(tb), str(vo)] + list(map(str, libs)),
                           capture_output=True, text=True)
        if p.returncode != 0: return False, ['iverilog failed: ' + (p.stdout + p.stderr)[-1500:]]
        p = subprocess.run(['vvp', str(out)], capture_output=True, text=True)
    got = {int(m.group(1)): m.group(2) for m in re.finditer(r'ROW (\d+) ([01xzXZ]+)', p.stdout)}
    bad = [f"row {i}: .vo gives {got.get(i)}, expected {r}" for i, r in enumerate(rows) if got.get(i) != r]
    return not bad, bad or [f"{len(rows)} rows match ({vo.name})"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('folders', nargs='+')
    ap.add_argument('--sim-lib', default=os.path.join(os.environ.get('QUARTUS_ROOTDIR', ''), 'eda', 'sim_lib'))
    ap.add_argument('--vo', help='the .vo to use (only with one folder)')
    a = ap.parse_args()
    if a.vo and len(a.folders) != 1: ap.error('--vo needs exactly one folder')
    ok_all = True
    for f in a.folders:
        ok, notes = check(f, a.sim_lib, a.vo)
        ok_all &= ok
        print(('PASS ' if ok else 'FAIL ') + f)
        for n in notes[:10]: print('   ', n)
    sys.exit(0 if ok_all else 1)


if __name__ == '__main__':
    main()
