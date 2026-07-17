package Top;

`ifndef BACKEND_VALUE
`define BACKEND_VALUE 0
`endif

interface TopIfc;
    method Bit#(8) value;
endinterface

(* synthesize *)
module mkTop(TopIfc);
    rule stop;
        $display("BACKEND_VALUE=%0d", `BACKEND_VALUE);
        $finish(0);
    endrule
    method Bit#(8) value = `BACKEND_VALUE;
endmodule

endpackage
