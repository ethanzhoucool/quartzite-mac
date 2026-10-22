"""Exercise toolchain orchestration without requiring FPGA tooling in CI."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CompileScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="quartzite paths ")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.src = self.dir / 'source with "quote"; name.v'
        self.src.write_text("module demo(input a, output b); assign b=a; endmodule\n")
        self.qsf = self.dir / "pins.qsf"
        self.qsf.write_text("")
        self.out = self.dir / "output with spaces.rbf"
        self.yosys = self.dir / "mock-yosys"
        self.yosys.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
script = pathlib.Path(args[args.index('-s') + 1]).read_text()
assert args[args.index('-f') + 1] == 'verilog -sv'
src = args[args.index('-f') + 2]
assert src not in script
assert pathlib.Path(src).is_file(), src
assert src == os.environ['EXPECTED_SOURCE'], src
pathlib.Path(args[args.index('-l') + 1]).write_text('synthesis log')
if os.environ.get('MOCK_YOSYS_MODE') != 'missing':
    pathlib.Path(args[args.index('-o') + 1]).write_text('{}')
''')
        self.nextpnr = self.dir / "mock-nextpnr"
        self.nextpnr.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args=sys.argv[1:]
pathlib.Path(args[args.index('--log')+1]).write_text('routing log')
if os.environ.get('MOCK_NEXTPNR_MODE') == 'fail':
    sys.exit(1)
if os.environ.get('MOCK_NEXTPNR_MODE') != 'missing':
    pathlib.Path(args[args.index('--rbf')+1]).write_bytes(b'new bitstream')
''')
        self.yosys.chmod(0o755)
        self.nextpnr.chmod(0o755)
        self.env = dict(os.environ, YOSYS=str(self.yosys), NEXTPNR=str(self.nextpnr),
                        EXPECTED_SOURCE=str(self.src))

    def run_compile(self, **env):
        return subprocess.run(["bash", str(ROOT / "toolchain/compile_rbf.sh"),
                               str(self.src), str(self.qsf), str(self.out), "demo"],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_paths_and_successful_fresh_outputs(self):
        result = self.run_compile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), b"new bitstream")
        self.assertEqual(self.out.with_suffix(".json").read_text(), "{}")
        self.assertEqual(list(self.dir.glob(".quartzite-build.*")), [])

    def test_success_without_new_bitstream_cannot_reuse_previous_output(self):
        self.out.write_bytes(b"old bitstream")
        result = self.run_compile(MOCK_NEXTPNR_MODE="missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.out.read_bytes(), b"old bitstream")
        self.assertIn("did not produce a bitstream", result.stderr)

    def test_failed_route_preserves_previous_outputs_and_cleans_scratch(self):
        self.out.write_bytes(b"old bitstream")
        self.out.with_suffix(".json").write_text("old netlist")
        result = self.run_compile(MOCK_NEXTPNR_MODE="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.out.read_bytes(), b"old bitstream")
        self.assertEqual(self.out.with_suffix(".json").read_text(), "old netlist")
        self.assertEqual(list(self.dir.glob(".quartzite-build.*")), [])

    def test_success_without_new_netlist_does_not_invoke_routing(self):
        result = self.run_compile(MOCK_YOSYS_MODE="missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists())
        self.assertFalse(self.out.with_suffix(".nextpnr.log").exists())

class BuildScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.toolchain = self.dir / "relative toolchain"
        for repo, head in [("mistral", "master"), ("mistral-nextpnr", "old-pin"), ("nextpnr", "nextpnr"),
                           ("openFPGALoader", "ofl-pin")]:
            path = self.toolchain / repo
            (path / ".git").mkdir(parents=True)
            (path / "HEAD").write_text(head)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.tool("git", '''import pathlib, sys
args=sys.argv[1:]; repo=pathlib.Path(args[1]); args=args[2:]
if args[0]=='rev-parse':
    print((repo/'HEAD').read_text() if args[1]=='HEAD' else args[1].replace('^{commit}', ''))
elif args[0]=='status':
    print('M staged-change' if (repo/'dirty').exists() else '')
elif args[0]=='checkout':
    (repo/'HEAD').write_text(args[-1])
elif args[0]=='apply':
    pass
else:
    raise RuntimeError(args)
''')
        self.tool("brew", "print('/mock/homebrew')\n")
        self.tool("ninja", "pass\n")
        self.tool("cmake", '''import os, pathlib, sys
args=sys.argv[1:]; build=pathlib.Path(args[args.index('-B')+1]); build.mkdir(exist_ok=True)
with open(os.environ['CMAKE_CALLS'], 'a') as f: f.write(str(pathlib.Path.cwd())+' '+repr(args)+'\\n')
if build.name=='build-nextpnr':
    dest=build/'nextpnr-mistral'; text='#!/bin/sh\\necho mock-nextpnr\\n'
elif build.name=='build-openFPGALoader':
    dest=build/'openFPGALoader'; text='#!/bin/sh\\necho openFPGALoader v1.2.0\\necho "usb-blasterII            0x09fb:6810"\\n'
else:
    dest=build/'mistral-cv'/'mistral-cv'; dest.parent.mkdir(exist_ok=True)
    text='#!/bin/sh\\necho 5CSXFC6D6F31C6\\n'
dest.write_text(text); dest.chmod(0o755)
''')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TOOLCHAIN=self.toolchain.name, JOBS="1", SKIP_BREW="1",
                        MISTRAL_COMMIT="master", MISTRAL_NEXTPNR_COMMIT="new-pin", NEXTPNR_COMMIT="nextpnr",
                        OPENFPGALOADER_COMMIT="ofl-pin",
                        CMAKE_CALLS=str(self.dir / "cmake-calls"))

    def tool(self, name, body):
        p = self.bin / name
        p.write_text("#!/usr/bin/env python3\n" + body)
        p.chmod(0o755)

    def run_build(self):
        return subprocess.run(["bash", str(ROOT / "toolchain/build_toolchain.sh")], cwd=self.dir,
                              env=self.env, capture_output=True, text=True)

    def test_existing_worktree_updates_pin_and_relative_paths_resolve(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.toolchain / "mistral-nextpnr/HEAD").read_text(), "new-pin")
        calls = (self.dir / "cmake-calls").read_text()
        self.assertIn("-DMISTRAL_ROOT=" + str((self.toolchain / "mistral-nextpnr").resolve()), calls)
        self.assertTrue((self.toolchain / "prefix/bin/nextpnr-mistral").is_file())
        self.assertTrue((self.toolchain / "prefix/bin/openFPGALoader").is_file())
        self.assertIn("-DENABLE_CMSISDAP=OFF", calls)
        self.assertEqual(self.run_build().returncode, 0)
        self.assertEqual(len((self.dir / "cmake-calls").read_text().splitlines()), 8)

    def test_skip_openfpgaloader(self):
        self.env["SKIP_OPENFPGALOADER"] = "1"
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("openFPGALoader", (self.dir / "cmake-calls").read_text())
        self.assertFalse((self.toolchain / "prefix/bin/openFPGALoader").exists())

    def test_existing_worktree_with_staged_changes_refuses_new_pin(self):
        (self.toolchain / "mistral-nextpnr/dirty").write_text("staged edit")
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local changes", result.stderr)
        self.assertEqual((self.toolchain / "mistral-nextpnr/HEAD").read_text(), "old-pin")


if __name__ == "__main__":
    unittest.main()
