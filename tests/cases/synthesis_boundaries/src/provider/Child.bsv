package Child;
interface ChildIfc;
    method Action req(Bit#(8) value);
    method Bit#(8) result;
endinterface

(* synthesize *)
module mkChild(ChildIfc);
    Reg#(Bit#(8)) state <- mkReg(0);
    // This ordering attribute becomes invalid if neutral .bo compilation
    // causes an imported synthesized child to be inlined into its parent.
    (* execution_order = "req, advance" *)
    rule advance(state != 0);
        state <= state - 1;
    endrule
    method Action req(Bit#(8) value);
        state <= value;
    endmethod
    method Bit#(8) result = state;
endmodule
endpackage
