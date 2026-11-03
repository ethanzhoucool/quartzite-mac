"""Tests for random_designs.py's netlist simulators and design generators (no Quartzite needed)."""
import random
import unittest

import random_designs as rd

BACKUP = """module T (
\tinput  wire a,
\tinput  wire b,
\toutput wire f,
\toutput wire g
);
\twire n1, one;

\tnot inst1 (n1, a);
\tand inst (f, n1, b, one);
\tassign one = 1'b1;
\tassign g = a;
endmodule
"""

VO = """module T (f, a, b);
wire qz_lut_0;

qz_lcell_comb #(.lut_mask(64'h4444444444444444)) qz_cell_0 (
\t.dataa(a),
\t.datab(b),
\t.datac(1'b0),
\t.datad(1'b0),
\t.datae(1'b0),
\t.dataf(1'b0),
\t.combout(qz_lut_0));

assign f = qz_lut_0;
assign g = 1'b1;

endmodule
"""


class Simulators(unittest.TestCase):
    def test_backup_gates_assigns_and_constants(self):
        for a in (False, True):
            for b in (False, True):
                v = rd.simulate_backup(BACKUP, {'a': a, 'b': b})
                self.assertEqual(v['f'], (not a) and b)
                self.assertEqual(v['g'], a)

    def test_vo_lut_mask_indexing(self):
        # 0x4 repeated: bit 2 of each nibble, i.e. dataa = 0 and datab = 1.
        for a in (False, True):
            for b in (False, True):
                v = rd.simulate_vo(VO, {'a': a, 'b': b})
                self.assertEqual(v['f'], (not a) and b)
                self.assertTrue(v['g'])


class Generators(unittest.TestCase):
    def test_same_seed_same_designs(self):
        def specs(seed):
            rng = random.Random(seed)
            return [(rd.block_design if t % 4 == 3 else rd.flat_design)(rng, t) for t in range(20)]
        self.assertEqual(specs(5), specs(5))
        self.assertNotEqual(specs(5), specs(6))

    def test_every_endpoint_has_one_label(self):
        rng = random.Random(3)
        for t in range(40):
            spec = (rd.block_design if t % 4 == 3 else rd.flat_design)(rng, t)
            for sheet in spec['sheets']:
                names = {}
                for end, name in sheet['labels']:
                    self.assertEqual(names.setdefault(end, name), name, f'{sheet["name"]}: {end}')
                parts = {p['id'] for p in sheet['parts']}
                pins = {p['name'] for p in sheet['inputs'] + sheet['outputs']}
                for end in [e for w in sheet['wires'] for e in w] + [l[0] for l in sheet['labels']]:
                    self.assertTrue(end in pins or end.split('.')[0] in parts, f'{sheet["name"]}: {end}')


if __name__ == '__main__':
    unittest.main()
