// Asymmetric 6-input functions, to exercise the 6-LUT (C/D swap) encoding
// and the pin permutation nextpnr applies to LUT inputs.
module lut6 (input wire [9:0] SW, output wire [9:0] LEDR);
    wire [1:0] s = SW[9:8];
    assign LEDR[0] = SW[s];                                     // 4:1 mux, 6 inputs
    assign LEDR[1] = (SW[0] & SW[1]) | ((SW[2] ^ SW[3]) & SW[4]) | (~SW[5] & SW[0] & ~SW[2]);
    assign LEDR[2] = SW[5] ? (SW[4] ? SW[3] : SW[2]) : (SW[1] & ~SW[0]);
    assign LEDR[3] = {SW[2:0]} == {SW[5:3]};                    // 3-bit equality, 6 inputs
    assign LEDR[4] = (SW[6] & SW[0]) | (SW[7] & SW[1]) | (SW[8] & ~SW[2]);
    assign LEDR[5] = ^{SW[9], SW[7], SW[5]} & (SW[0] | ~SW[3]) & ~SW[6];
    assign LEDR[6] = (SW[3:0] == 4'b1010) | (SW[9] & ~SW[4]);
    assign LEDR[7] = SW[0] ? SW[9] : (SW[1] ? ~SW[8] : (SW[2] ? SW[7] : SW[6]));
    assign LEDR[8] = ~(SW[1] & SW[3]) & (SW[5] | SW[7]) & (SW[9] ^ SW[0]);
    assign LEDR[9] = (SW[2] | SW[4]) ^ (SW[6] & SW[8]) ^ SW[0];
endmodule
