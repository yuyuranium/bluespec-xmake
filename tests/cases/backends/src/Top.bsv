package Top;

interface TopIfc;
    method Bool value;
endinterface

(* synthesize *)
module mkTop(TopIfc);
    rule stop;
        $finish(0);
    endrule
    method Bool value = True;
endmodule

endpackage
