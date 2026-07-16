package Top;

import Base::*;

(* synthesize *)
module mkIncrementalTop(Empty);
    Reg#(Bit#(32)) value <- mkReg(0);

    rule update;
        value <= fromInteger(baseValue());
    endrule
endmodule

endpackage
