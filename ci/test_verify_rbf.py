"""Regression checks for the independent physical-netlist verifier."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("verify_rbf", Path(__file__).resolve().parents[1] / "toolchain/verify_rbf.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class LUTModeTests(unittest.TestCase):
    def test_lutram_is_not_accepted_as_a_constant_lut(self):
        block = "MLAB.039.061"
        settings = {(block, "TDFF0", 0): "NLUT", (block, "RAM_DIS", -1): "0", (block, "WRITE_EN", -1): "1"}
        net = verify.Netlist({}, settings, {}, {})
        with self.assertRaisesRegex(verify.VerifyError, "LUTRAM"):
            net.value(block + ".0:FFT0", {})

    def test_disabled_ram_remains_an_ordinary_lut(self):
        block = "MLAB.039.061"
        net = verify.Netlist({}, {(block, "TDFF0", 0): "NLUT"}, {}, {})
        self.assertEqual(net.value(block + ".0:FFT0", {}), 0)

    def test_register_output_is_rejected(self):
        net = verify.Netlist({}, {}, {}, {})
        with self.assertRaisesRegex(verify.VerifyError, "register"):
            net.value("LAB.088.021.0:FFT0", {})


if __name__ == "__main__":
    unittest.main()
