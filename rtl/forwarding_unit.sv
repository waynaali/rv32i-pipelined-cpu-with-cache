`timescale 1ns / 1ps

module forwarding_unit(
    input logic [4:0] Rs1E,
    input logic [4:0] Rs2E,
    input logic [4:0] RdM,
    input logic [4:0] RdW,
    input logic        RegWriteM,
    input logic        RegWriteW,
    // dcache bypass ports kept for interface compatibility but bypass removed
    input logic        dcache_valid,
    input logic [4:0]  dcache_dest_reg,
    output logic [1:0] ForwardAE,
    output logic [1:0] ForwardBE
);
    always_comb begin
        // SrcA forwarding
        if      (RdM != 5'b0 && RdM == Rs1E && RegWriteM) ForwardAE = 2'b10;
        else if (RdW != 5'b0 && RdW == Rs1E && RegWriteW) ForwardAE = 2'b01;
        else                                                ForwardAE = 2'b00;

        // SrcB forwarding
        if      (RdM != 5'b0 && RdM == Rs2E && RegWriteM) ForwardBE = 2'b10;
        else if (RdW != 5'b0 && RdW == Rs2E && RegWriteW) ForwardBE = 2'b01;
        else                                                ForwardBE = 2'b00;
    end
endmodule
