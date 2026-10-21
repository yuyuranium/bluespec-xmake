package Top;
import Child::*;
`include "Value.bsvh"

module [Module] mkFixed(Empty);
    ChildIfc child <- mkChild;
    Reg#(Bit#(8)) count <- mkReg(0);
    rule drive;
        child.req(count);
        count <= count + 1;
        if (count == `FINISH_COUNT) begin
            $display("BOUNDARY_OK count=%0d", count);
            $finish(0);
        end
    endrule
endmodule

// The endpoint's -g context constrains this otherwise polymorphic module.
// Compiling it as an ordinary package first rejects the fixed Module child.
module mkTop();
    let child <- mkFixed;
endmodule
endpackage
