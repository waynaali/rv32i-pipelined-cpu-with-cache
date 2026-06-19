`timescale 1ns / 1ps

module mux4to1(
    input  logic [31:0] d0,   // 00: From Register File (RD1E/RD2E)
    input  logic [31:0] d1,   // 01: From Writeback Stage (ResultW)
    input  logic [31:0] d2,   // 10: From Memory Stage (ALUResultM)
    input  logic [31:0] d3,   // 11: Direct D-Cache Bypass (dcache_mem_rdata)
    input  logic [1:0]  s,    // Selection signal from Forwarding Unit
    output logic [31:0] y     // Output to ALU
);

    always_comb begin
        case (s)
            2'b00: y = d0; // Use data from register file
            2'b01: y = d1; // Forward from WB stage
            2'b10: y = d2; // Forward from MEM stage
            2'b11: y = d3; // **NEW**: Forward directly from D-Cache result
            default: y = d0;
        endcase
    end

endmodule
