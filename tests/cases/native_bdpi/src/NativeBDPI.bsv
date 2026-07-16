package NativeBDPI;

import "BDPI" function Bit#(32) golden_value();
import "BDPI" function Bit#(32) golden_bonus();

(* synthesize *)
module mkNativeBDPI(Empty);
    rule check;
        if (golden_value() + golden_bonus() != 42) begin
            $display("FAIL");
            $finish(1);
        end
        $display("OK");
        $finish(0);
    endrule
endmodule

endpackage
