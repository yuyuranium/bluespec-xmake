package Lib;
import Leaf::*;
interface ValueIfc;
    method Bit#(8) value;
endinterface
(* synthesize *)
module mkValue(ValueIfc);
    method Bit#(8) value = leafValue;
endmodule
endpackage
