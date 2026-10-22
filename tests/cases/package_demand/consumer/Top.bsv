package Top;
import Lib::*;
module mkTop(Empty);
    ValueIfc child <- mkValue;
    rule finish;
        $display("VALUE=%0d", child.value);
        $finish(0);
    endrule
endmodule
endpackage
