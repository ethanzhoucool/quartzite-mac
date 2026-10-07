// Example design: f(w,x,y,z) = sum m(2,3,6,7,9,13,14), w = MSB
// Minimal SOP: f = w' y + w y' z + x y z'
module demo4 (
    input  wire w,   // SW3  PIN_AC30
    input  wire x,   // SW2  PIN_AB28
    input  wire y,   // SW1  PIN_Y27
    input  wire z,   // SW0  PIN_AB30
    output wire f    // LEDR0 PIN_AA24
);
    assign f = (~w & y) | (w & ~y & z) | (x & y & ~z);
endmodule
