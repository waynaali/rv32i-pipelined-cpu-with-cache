`timescale 1ns / 1ps

module axi4_ram (
    input  logic        clk,
    input  logic        reset,

    // AXI4 Write Address Channel
    input  logic [31:0] S_AXI_AWADDR,
    input  logic [7:0]  S_AXI_AWLEN,
    input  logic [2:0]  S_AXI_AWSIZE,
    input  logic [1:0]  S_AXI_AWBURST,
    input  logic        S_AXI_AWVALID,
    output logic        S_AXI_AWREADY,

    // AXI4 Write Data Channel
    input  logic [31:0] S_AXI_WDATA,
    input  logic [3:0]  S_AXI_WSTRB,
    input  logic        S_AXI_WLAST,
    input  logic        S_AXI_WVALID,
    output logic        S_AXI_WREADY,

    // AXI4 Write Response Channel
    output logic [1:0]  S_AXI_BRESP,
    output logic        S_AXI_BVALID,
    input  logic        S_AXI_BREADY,

    // AXI4 Read Address Channel
    input  logic [31:0] S_AXI_ARADDR,
    input  logic [7:0]  S_AXI_ARLEN,
    input  logic [2:0]  S_AXI_ARSIZE,
    input  logic [1:0]  S_AXI_ARBURST,
    input  logic        S_AXI_ARVALID,
    output logic        S_AXI_ARREADY,

    // AXI4 Read Data Channel
    output logic [31:0] S_AXI_RDATA,
    output logic [1:0]  S_AXI_RRESP,
    output logic        S_AXI_RLAST,
    output logic        S_AXI_RVALID,
    input  logic        S_AXI_RREADY
);

    localparam int RAM_DEPTH = 256;
    logic [31:0] RAM [0:RAM_DEPTH-1];

    // Constant Status Responses (OKAY)
    assign S_AXI_BRESP = 2'b00;
    assign S_AXI_RRESP = 2'b00;

    // Internal Write Management States & Registers
    logic [31:0] reg_awaddr;
    logic [7:0]  reg_awlen;
    logic        w_addr_valid; 

    // Internal Read Management Registers
    logic [31:0] reg_araddr;
    logic [7:0]  reg_arlen;
    logic [1:0]  reg_arburst;

    // -------------------------------------------------------------------------
    // Memory Array Initialization
    // -------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < RAM_DEPTH; i = i + 1) begin
            RAM[i] = 32'h00000013; // NOP Default Instruction
        end
        $readmemh("inst.mem", RAM);
    end

    // -------------------------------------------------------------------------
    // AXI4 Ready Protocols (Simultaneous Handshake Support)
    // -------------------------------------------------------------------------
    assign S_AXI_AWREADY = !w_addr_valid; 
    assign S_AXI_WREADY  = w_addr_valid || S_AXI_AWVALID;
    assign S_AXI_ARREADY = !S_AXI_RVALID;

    // Mux addressing between raw input pins or registered state
    logic [7:0] write_index;
    assign write_index = w_addr_valid ? reg_awaddr[9:2] : S_AXI_AWADDR[9:2];

    // -------------------------------------------------------------------------
    // Synchronous Memory State Machine
    // -------------------------------------------------------------------------
    // Variable declared at module level/top of process block to avoid procedural errors
    logic [7:0] current_len;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            w_addr_valid  <= 1'b0;
            reg_awaddr    <= 32'b0;
            reg_awlen     <= 8'b0;
            S_AXI_BVALID  <= 1'b0;

            reg_araddr    <= 32'b0;
            reg_arlen     <= 8'b0;
            reg_arburst   <= 2'b0;
            S_AXI_RVALID  <= 1'b0;
            S_AXI_RLAST   <= 1'b0;
            S_AXI_RDATA   <= 32'b0;
        end
        else begin

            // --- WRITE CHANNELS PIPELINE ---
            // 1. Capture Write Address independently
            if (S_AXI_AWVALID && S_AXI_AWREADY) begin
                reg_awaddr   <= S_AXI_AWADDR;
                reg_awlen    <= S_AXI_AWLEN;
                w_addr_valid <= 1'b1;
            end

            // 2. Consume Data independently when available
            if (S_AXI_WVALID && S_AXI_WREADY) begin
                // Byte-masked write execution
                if (S_AXI_WSTRB[0]) RAM[write_index][7:0]   <= S_AXI_WDATA[7:0];
                if (S_AXI_WSTRB[1]) RAM[write_index][15:8]  <= S_AXI_WDATA[15:8];
                if (S_AXI_WSTRB[2]) RAM[write_index][23:16] <= S_AXI_WDATA[23:16];
                if (S_AXI_WSTRB[3]) RAM[write_index][31:24] <= S_AXI_WDATA[31:24];

                // Evaluation using safe pre-declared tracking register
                current_len = w_addr_valid ? reg_awlen : S_AXI_AWLEN;

                if (current_len == 8'd0 || S_AXI_WLAST) begin
                    w_addr_valid <= 1'b0; // Reset allocation latch
                    S_AXI_BVALID <= 1'b1; // Trigger downstream write response handshake
                end else begin
                    // Handle address incrementation for active burst handling
                    if (w_addr_valid) begin
                        reg_awaddr <= reg_awaddr + 32'd4;
                        reg_awlen  <= reg_awlen - 1'b1;
                    end else begin
                        reg_awaddr <= S_AXI_AWADDR + 32'd4;
                        reg_awlen  <= S_AXI_AWLEN - 1'b1;
                    end
                end
            end

            // Clear Write Response validation once completed
            if (S_AXI_BVALID && S_AXI_BREADY) begin
                S_AXI_BVALID <= 1'b0;
            end


            // --- READ CHANNELS PIPELINE ---
            // 1. Process Address capture sequence if memory channel is open
            if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                S_AXI_RDATA  <= RAM[S_AXI_ARADDR[9:2]];
                S_AXI_RVALID <= 1'b1;
                reg_araddr   <= S_AXI_ARADDR;
                reg_arlen    <= S_AXI_ARLEN;
                reg_arburst  <= S_AXI_ARBURST;
                S_AXI_RLAST  <= (S_AXI_ARLEN == 8'd0);
            end
            // 2. Drive Burst reading iterations if currently active
            else if (S_AXI_RVALID && S_AXI_RREADY) begin
                if (reg_arlen == 8'd0) begin
                    S_AXI_RVALID <= 1'b0;
                    S_AXI_RLAST  <= 1'b0;
                end else begin
                    automatic logic [31:0] next_addr = reg_araddr + 32'd4;
                    
                    // Support standard WRAP burst mapping structures (Used for Cache Line Fills)
                    if (reg_arburst == 2'b10) begin 
                        if (S_AXI_ARLEN == 8'd3) begin
                            next_addr[3:0] = (reg_araddr[3:0] + 4'd4) & 4'b1100;
                        end
                    end
                    
                    S_AXI_RDATA  <= RAM[next_addr[9:2]];
                    reg_araddr   <= next_addr;
                    reg_arlen    <= reg_arlen - 1'b1;
                    S_AXI_RLAST  <= (reg_arlen == 8'd1);
                end
            end

        end
    end

endmodule
