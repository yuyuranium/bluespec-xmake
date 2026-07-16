package DefineRepro;

import DefineLib::*;

interface DefineReproIfc;
    method Bit#(16) depth;
    method Bool fast;
endinterface

(* synthesize *)
module mkDefineRepro(DefineReproIfc);
    method Bit#(16) depth = fromInteger(`DEPTH + definedDepth);
`ifdef USE_FAST
    method Bool fast = True;
`else
    method Bool fast = False;
`endif
endmodule

endpackage
