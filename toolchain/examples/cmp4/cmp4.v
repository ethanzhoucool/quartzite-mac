// Carry-chain smoke test: behavioural 4-bit compare maps onto MISTRAL_ALUT_ARITH.
// Compiles and routes; verify_rbf.py reports the carry chain as not modelled.
module cmp4 (input wire [9:0] SW, output wire [9:0] LEDR);
    assign LEDR[0] = SW[3:0] > SW[7:4];
    assign LEDR[9:1] = 9'b0;
endmodule
