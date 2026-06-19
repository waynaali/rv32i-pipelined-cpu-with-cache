`timescale 1ns / 1ps

module HazardUnit(
    input  logic [4:0] Rs1D,
    input  logic [4:0] Rs2D,
    input  logic [4:0] RdE,
    input  logic [4:0] rdM,
    input  logic        RegWriteM,
    input  logic        RegWriteW,
    input  logic        icache_busy,
    input  logic        dcache_busy,
    input  logic        dcache_valid,
    input  logic        ResultSrcE0,
    output logic        StallF,
    output logic        StallD,
    output logic        StallID_IE,  // NEW: separate enable for ID/IE register
    output logic        FlushE,
    output logic        FlushD
);

    logic load_use_stall;
    logic cache_hazard;

    // Load-use: LW is in EX (ResultSrcE0=1), next instr in ID needs same reg
    assign load_use_stall = ResultSrcE0 &&
                            ((Rs1D == RdE && RdE != 5'b0) ||
                             (Rs2D == RdE && RdE != 5'b0));

    assign cache_hazard = dcache_busy || icache_busy;

    always_comb begin
        StallF    = 1'b0;
        StallD    = 1'b0;
        StallID_IE = 1'b0;  // by default ID/IE is free to latch
        FlushE    = 1'b0;
        FlushD    = 1'b0;

        if (cache_hazard) begin
            // Freeze the ENTIRE pipeline including ID/IE
            StallF     = 1'b1;
            StallD     = 1'b1;
            StallID_IE = 1'b1;  // hold ID/IE too during cache miss
        end
        else if (load_use_stall) begin
            // Freeze fetch + decode, but let ID/IE latch the bubble
            StallF     = 1'b1;
            StallD     = 1'b1;
            StallID_IE = 1'b0;  // KEY FIX: ID/IE must latch the FlushE bubble
            FlushE     = 1'b1;  // zero out EX stage (insert NOP bubble)
        end
    end

endmodule
