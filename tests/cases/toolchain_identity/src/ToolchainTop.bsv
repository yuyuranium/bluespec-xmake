package ToolchainTop;

(* synthesize *)
module mkToolchainTop(Empty);
    rule finish;
        $display("TOOLCHAIN_OK");
        $finish(0);
    endrule
endmodule

endpackage
