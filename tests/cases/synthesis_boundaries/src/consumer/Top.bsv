package Top;
import Child::*;

(* synthesize *)
module mkTop(Empty);
    ChildIfc child <- mkChild;
    Reg#(Bit#(8)) count <- mkReg(0);
    rule drive;
        child.req(count);
        count <= count + 1;
        if (count == 3) begin
            $display("BOUNDARY_OK");
            $finish(0);
        end
    endrule
endmodule
endpackage
