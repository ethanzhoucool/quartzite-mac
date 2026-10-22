"""Regression coverage for the validator without requiring a Quartus install."""
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import quartus_check


class QuartusCheckTests(unittest.TestCase):
    def test_failed_generators_cannot_reuse_stale_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            (folder / 'expected.json').write_text(json.dumps({
                'entity': 'Example', 'inputs': ['a'], 'outputs': ['f'],
                'rows': ['0', '1'], 'step_ns': 500, 'locations': {},
            }))
            (folder / 'Example.v').write_text('module Example; endmodule')
            (folder / 'qz_wave.vt').write_text('module stale; endmodule')
            commands = []

            def failing_run(command, cwd, log):
                commands.append(command[0])
                return subprocess.CompletedProcess(command, 1, '', 'generator failed')

            with patch.object(quartus_check, 'run', side_effect=failing_run):
                results = quartus_check.check(folder)

            self.assertFalse((folder / 'Example.v').exists())
            self.assertFalse((folder / 'qz_wave.vt').exists())
            self.assertNotIn('iverilog', commands)
            self.assertTrue(all(not ok for _, ok, _ in results))

    def test_generator_failure_is_checked_even_if_it_writes_a_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            (folder / 'expected.json').write_text(json.dumps({
                'entity': 'Example', 'inputs': ['a'], 'outputs': ['f'],
                'rows': ['0', '1'], 'step_ns': 500, 'locations': {},
            }))
            commands = []

            def partial_run(command, cwd, log):
                commands.append(command[0])
                if command[0] == 'quartus_map':
                    (folder / 'Example.v').write_text('module Example; endmodule')
                if command[0] == 'quartus_eda':
                    (folder / 'qz_wave.vt').write_text('module partial; endmodule')
                return subprocess.CompletedProcess(command, 1, '', 'generator failed')

            with patch.object(quartus_check, 'run', side_effect=partial_run):
                results = quartus_check.check(folder)
            self.assertNotIn('iverilog', commands)
            self.assertTrue(all(not ok for _, ok, _ in results))

    def test_multi_file_and_macro_designs_skip_conversion_and_waveform(self):
        for files, macros, reason in [(['Top.bdf', 'HA.bdf'], [], '2 .bdf files'),
                                      (['Top.bdf'], ['7447'], 'the 7447 library macro'),
                                      (['Top.bdf', 'HA.bdf', 'FA.bdf'], ['7447'], '3 .bdf files and the 7447 library macro')]:
            with self.subTest(files=files, macros=macros), tempfile.TemporaryDirectory() as temporary:
                folder = pathlib.Path(temporary)
                (folder / 'expected.json').write_text(json.dumps({
                    'entity': 'Top', 'top': 'Top', 'files': files, 'macros': macros, 'inputs': ['a'],
                    'outputs': ['f'], 'rows': ['0', '1'], 'step_ns': 500, 'locations': {},
                }))
                commands = []

                def compiling_run(command, cwd, log):
                    commands.append(command[0])
                    (folder / 'output_files').mkdir(exist_ok=True)
                    (folder / 'output_files' / 'Top.sof').write_text('')
                    (folder / 'output_files' / 'Top.pin').write_text('')
                    return subprocess.CompletedProcess(command, 0, '', '')

                with patch.object(quartus_check, 'run', side_effect=compiling_run):
                    results = quartus_check.check(folder)
                self.assertEqual(commands, ['quartus_sh'])
                skipped = [(name, detail) for name, ok, detail in results if ok is None]
                self.assertEqual([name for name, _ in skipped], [quartus_check.CONVERSION, quartus_check.WAVEFORM])
                self.assertTrue(all(reason in detail for _, detail in skipped))
                self.assertTrue(all(ok for _, ok, _ in results if ok is not None))

    def test_single_file_designs_are_not_skipped(self):
        self.assertIsNone(quartus_check.skip_reason({'entity': 'Example'}))
        self.assertIsNone(quartus_check.skip_reason({'files': ['Example.bdf'], 'macros': []}))


if __name__ == '__main__':
    unittest.main()
