// Scaling test: 10 switches -> 10 LEDs on the DE10-Standard, one gate-style
// function per LED (wide AND/OR/XOR force multi-level LUT trees).
module gates10 (
    input  wire [9:0] SW,
    output wire [9:0] LEDR
);
    assign LEDR[0] = &SW;                       // 10-input AND
    assign LEDR[1] = |SW;                       // 10-input OR
    assign LEDR[2] = ^SW;                       // 10-input XOR (parity)
    assign LEDR[3] = ~(SW[0] & SW[1]);          // NAND2
    assign LEDR[4] = ~(SW[2] | SW[3]);          // NOR2
    assign LEDR[5] = ~(SW[4] ^ SW[5]);          // XNOR2
    assign LEDR[6] = ~SW[6];                    // NOT
    assign LEDR[7] = SW[7];                     // BUF (pin to pin)
    assign LEDR[8] = SW[9] ? SW[8] : SW[7];     // 2:1 MUX
    // 4-bit magnitude compare SW[3:0] > SW[7:4], written as gates on purpose:
    // a behavioural ">" is mapped by yosys onto the ALM carry chain
    // (MISTRAL_ALUT_ARITH), which verify_rbf.py does not model yet.
    wire [3:0] a = SW[3:0], b = SW[7:4];
    wire [3:0] e = ~(a ^ b);
    assign LEDR[9] = (a[3] & ~b[3]) | (e[3] & a[2] & ~b[2])
                   | (e[3] & e[2] & a[1] & ~b[1]) | (e[3] & e[2] & e[1] & a[0] & ~b[0]);
endmodule
