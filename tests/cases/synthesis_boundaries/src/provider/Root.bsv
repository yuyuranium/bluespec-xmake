package Root;
import Child::*;

`ifndef ROOT_VALUE
`define ROOT_VALUE 1
`endif

(* synthesize *)
module mkProviderTop(Empty);
    ChildIfc child <- mkChild;
    rule finish;
        child.req(0);
        $display("ROOT_VALUE=%0d", `ROOT_VALUE);
        $finish(0);
    endrule
endmodule
endpackage
