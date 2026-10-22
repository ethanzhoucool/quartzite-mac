#!/usr/bin/env python3
"""Run real Quartus on exported design folders and compare with Quartzite.

For each folder (written by `Quartzite --export-suite`):
  1. quartus_sh --flow compile  -> must succeed and produce the .sof
  2. the fitter's .pin report must place every pin where the .qsf asked
  3. quartus_map --convert_bdf_to_verilog: Quartus' own reading of the .bdf,
     simulated exhaustively with Icarus Verilog against expected.json
  4. quartus_eda --gen_testbench from Waveform.vwf: proves Quartus parses the
     vectors; the generated testbench is run and sampled mid-step
Steps 3 and 4 are skipped, with the reason, for designs with several .bdf files or a
library macro (see skip_reason).
"""
import json, os, pathlib, re, subprocess, sys

CONVERSION = "Quartus' reading of the .bdf matches Quartzite"
WAVEFORM = 'Waveform.vwf counts through every input and gives the expected outputs'

def skip_reason(exp):
    """Why steps 3 and 4 can't check this design, or None. --convert_bdf_to_verilog
    translates the top .bdf alone, so blocks from other .bdf files and the 7447 (a
    maxplus2 macro that altera_primitives.v doesn't define) are left undefined.
    Check their compiled .vo with vo_check.py instead."""
    files, macros = exp.get('files', []), exp.get('macros', [])
    parts = ([f'{len(files)} .bdf files'] if len(files) > 1 else []) + \
            [f'the {m} library macro' for m in macros]
    if not parts:
        return None
    return ('skipped: the design has ' + ' and '.join(parts) +
            ", and the converted top .bdf can't be simulated on its own")

def run(cmd, cwd, log):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    log.write(f"$ {' '.join(cmd)}\n{p.stdout}\n{p.stderr}\n[exit {p.returncode}]\n\n")
    return p

def check(folder):
    d = pathlib.Path(folder).resolve()
    exp = json.loads((d / 'expected.json').read_text())
    e, ins, outs, rows = exp['entity'], exp['inputs'], exp['outputs'], exp['rows']
    log = open(d / 'quartus_check.log', 'w')
    results = []
    def result(name, ok, detail=''):
        results.append((name, ok, detail))

    p = run(['quartus_sh', '--flow', 'compile', e], d, log)
    sof = d / 'output_files' / f'{e}.sof'
    result('full compilation (map, fit, asm)', p.returncode == 0 and sof.exists(),
           '' if p.returncode == 0 else (p.stdout + p.stderr)[-1500:])

    pin = d / 'output_files' / f'{e}.pin'
    if pin.exists():
        placed = {}
        for line in pin.read_text(errors='replace').splitlines():
            m = re.match(r'\s*([A-Za-z_]\w*)\s*:\s*([A-Z]+\d+)\s*:\s*(input|output)', line)
            if m: placed[m.group(1)] = 'PIN_' + m.group(2)
        bad = {n: (loc, placed.get(n)) for n, loc in exp['locations'].items() if placed.get(n) != loc.upper()}
        result('pin locations in fitter report', not bad, str(bad) if bad else f"{len(exp['locations'])} pins as assigned")
    else:
        result('pin locations in fitter report', False, 'no .pin file')

    reason = skip_reason(exp)
    if reason:
        result(CONVERSION, None, reason)
        result(WAVEFORM, None, reason)
        log.close()
        return results

    # Quartus' own Verilog translation of the schematic
    conv = d / f'{e}.v'
    conv.unlink(missing_ok=True)
    p = run(['quartus_map', e, '-c', e, f'--convert_bdf_to_verilog={e}.bdf'], d, log)
    if p.returncode == 0 and conv.exists():
        tb = d / 'qz_tb.v'
        decl = '\n'.join([f'  reg {n};' for n in ins] + [f'  wire {n};' for n in outs])
        conn = ', '.join(f'.{n}({n})' for n in ins + outs)
        assigns = '\n'.join(f'      {n} = (i >> {len(ins) - 1 - k}) & 1;' for k, n in enumerate(ins))
        tb.write_text(f'''`timescale 1ns/1ps
module qz_tb;
{decl}
  integer i;
  {e} dut({conn});
  initial begin
    for (i = 0; i < {1 << len(ins)}; i = i + 1) begin
{assigns}
      #10 $display("ROW %0d %b", i, {{{', '.join(outs)}}});
    end
    $finish;
  end
endmodule
''')
        libs = [str(pathlib.Path(os.environ['QUARTUS_ROOTDIR']) / 'eda/sim_lib/altera_primitives.v')]
        p = run(['iverilog', '-o', 'qz_tb.out', '-s', 'qz_tb', 'qz_tb.v', f'{e}.v'] + libs, d, log)
        if p.returncode == 0:
            p = run(['vvp', 'qz_tb.out'], d, log)
            got = {int(m.group(1)): m.group(2) for m in re.finditer(r'ROW (\d+) ([01xz]+)', p.stdout)}
            bad = [i for i, r in enumerate(rows) if got.get(i) != r]
            result(CONVERSION, p.returncode == 0 and not bad,
                   f'{len(rows)} rows' if not bad else f'rows {bad[:8]}: quartus {[got.get(i) for i in bad[:8]]} vs {[rows[i] for i in bad[:8]]}')
        else:
            result(CONVERSION, False, 'iverilog failed: ' + p.stderr[-800:])
    else:
        result(CONVERSION, False, 'convert_bdf_to_verilog produced nothing')

    # Waveform vectors through Quartus' testbench generator
    vt = d / 'qz_wave.vt'
    vt.unlink(missing_ok=True)
    p = run(['quartus_eda', '--gen_testbench', '--tool=modelsim_oem', '--format=verilog',
             '--vector_source=Waveform.vwf', '--testbench_file=qz_wave.vt', e, '-c', e], d, log)
    if p.returncode == 0 and vt.exists() and conv.exists():
        top = re.search(r'module\s+(\w+)', vt.read_text()).group(1)
        step_ps = int(round(exp['step_ns'] * 1000))
        mon = d / 'qz_mon.v'
        sig = ', '.join(f'{top}.{n}' for n in ins + outs)
        mon.write_text(f'''`timescale 1 ps/ 1 ps
module qz_mon;
  integer i;
  initial begin
    #{step_ps // 2};
    for (i = 0; i < {1 << len(ins)}; i = i + 1) begin
      $display("WAVE %0d %b", i, {{{sig}}});
      #{step_ps};
    end
  end
endmodule
''')
        libs = [str(pathlib.Path(os.environ['QUARTUS_ROOTDIR']) / 'eda/sim_lib/altera_primitives.v')]
        p = run(['iverilog', '-o', 'qz_wave.out', '-s', top, '-s', 'qz_mon', 'qz_wave.vt', 'qz_mon.v', f'{e}.v'] + libs, d, log)
        if p.returncode == 0:
            p = run(['vvp', 'qz_wave.out'], d, log)
            got = {int(m.group(1)): m.group(2) for m in re.finditer(r'WAVE (\d+) ([01xz]+)', p.stdout)}
            n = len(ins)
            want = {i: format(i, f'0{n}b') + rows[i] for i in range(1 << n)}
            bad = [i for i in want if got.get(i) != want[i]]
            result(WAVEFORM, p.returncode == 0 and not bad,
                   f'{len(want)} steps' if not bad else f'steps {bad[:6]}: {[got.get(i) for i in bad[:6]]} vs {[want[i] for i in bad[:6]]}')
        else:
            result(WAVEFORM, False, p.stderr[-800:])
    else:
        result(WAVEFORM, False,
               'quartus_eda produced no testbench' if not vt.exists() else 'no converted Verilog')

    log.close()
    return results

if __name__ == '__main__':
    all_ok = True
    summary = ['# Real Quartus check', '']
    for f in sys.argv[1:]:
        res = check(f)
        summary.append(f'## {pathlib.Path(f).name}')
        for name, ok, detail in res:
            if ok is not None:
                all_ok &= ok
            line = f"- {'SKIP' if ok is None else 'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else '')
            print(f"{pathlib.Path(f).name}: {line}")
            summary.append(line)
        summary.append('')
    out = os.environ.get('GITHUB_STEP_SUMMARY')
    if out:
        with open(out, 'a') as fh: fh.write('\n'.join(summary) + '\n')
    sys.exit(0 if all_ok else 1)
