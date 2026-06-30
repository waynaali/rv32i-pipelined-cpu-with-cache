`timescale 1ns / 1ps

module cache_axi4_master (
    input  logic        clk,
    input  logic        reset,

    // I-Cache Interface
    input  logic        i_req,
    input  logic [31:0] i_addr,
    output logic [31:0] i_rdata,
    output logic        i_ready,

    // D-Cache Interface
    input  logic        d_req,
    input  logic        d_we,
    input  logic [3:0]  d_be,
    input  logic [31:0] d_addr,
    input  logic [31:0] d_wdata,
    output logic [31:0] d_rdata,
    output logic        d_ready,

    // AXI4 Write Address Channel
    output logic [31:0] M_AXI_AWADDR,
    output logic [7:0]  M_AXI_AWLEN,
    output logic [2:0]  M_AXI_AWSIZE,
    output logic [1:0]  M_AXI_AWBURST,
    output logic        M_AXI_AWVALID,
    input  logic        M_AXI_AWREADY,

    // AXI4 Write Data Channel
    output logic [31:0] M_AXI_WDATA,
    output logic [3:0]  M_AXI_WSTRB,
    output logic        M_AXI_WLAST,
    output logic        M_AXI_WVALID,
    input  logic        M_AXI_WREADY,

    // AXI4 Write Response Channel
    input  logic [1:0]  M_AXI_BRESP,
    input  logic        M_AXI_BVALID,
    output logic        M_AXI_BREADY,

    // AXI4 Read Address Channel
    output logic [31:0] M_AXI_ARADDR,
    output logic [7:0]  M_AXI_ARLEN,
    output logic [2:0]  M_AXI_ARSIZE,
    output logic [1:0]  M_AXI_ARBURST,
    output logic        M_AXI_ARVALID,
    input  logic        M_AXI_ARREADY,

    // AXI4 Read Data Channel
    input  logic [31:0] M_AXI_RDATA,
    input  logic [1:0]  M_AXI_RRESP,
    input  logic        M_AXI_RLAST,
    input  logic        M_AXI_RVALID,
    output logic        M_AXI_RREADY
);

    // State machine optimized for continuous streaming throughput
    typedef enum logic [2:0] {
        IDLE,
        READ_ADDR,
        READ_DATA,
        WRITE_EXECUTE,
        WRITE_RESP
    } state_t;

    state_t state;

    // Internal Arbitration and Protocol Tracking Flags
    logic active_is_d;
    logic reg_aw_done;
    logic reg_w_done;

    // Combinational real-time handshake monitoring wires
    logic aw_handshake_comb;
    logic w_handshake_comb;
    logic aw_complete;
    logic w_complete;

    // Fixed AXI4 Protocol Attributes (Single-Beat 32-bit Operations)
    assign M_AXI_AWLEN   = 8'd0;
    assign M_AXI_AWSIZE  = 3'b010; // 4 Bytes
    assign M_AXI_AWBURST = 2'b01;  // INCR

    assign M_AXI_ARLEN   = 8'd0;
    assign M_AXI_ARSIZE  = 3'b010; // 4 Bytes
    assign M_AXI_ARBURST = 2'b01;  // INCR

    assign M_AXI_WLAST   = M_AXI_WVALID;

    // Calculate real-time handshake tracking
    assign aw_handshake_comb = M_AXI_AWVALID && M_AXI_AWREADY;
    assign w_handshake_comb  = M_AXI_WVALID  && M_AXI_WREADY;
    
    assign aw_complete = reg_aw_done || aw_handshake_comb;
    assign w_complete  = reg_w_done  || w_handshake_comb;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= IDLE;
            active_is_d   <= 1'b0;
            reg_aw_done   <= 1'b0;
            reg_w_done    <= 1'b0;

            M_AXI_AWADDR  <= 32'b0;
            M_AXI_AWVALID <= 1'b0;
            M_AXI_WDATA   <= 32'b0;
            M_AXI_WSTRB   <= 4'b0000;
            M_AXI_WVALID  <= 1'b0;
            M_AXI_BREADY  <= 1'b0;

            M_AXI_ARADDR  <= 32'b0;
            M_AXI_ARVALID <= 1'b0;
            M_AXI_RREADY  <= 1'b0;

            i_rdata       <= 32'b0;
            d_rdata       <= 32'b0;
            i_ready       <= 1'b0;
            d_ready       <= 1'b0;
        end
        else begin
            // Pulse interface flags by default
            i_ready <= 1'b0;
            d_ready <= 1'b0;

            case (state)

                IDLE: begin
                    reg_aw_done <= 1'b0;
                    reg_w_done  <= 1'b0;

                    if (d_req) begin
                        active_is_d <= 1'b1;
                        if (d_we) begin
                            M_AXI_AWADDR  <= d_addr;
                            M_AXI_WDATA   <= d_wdata;
                            M_AXI_WSTRB   <= d_be;
                            M_AXI_AWVALID <= 1'b1;
                            M_AXI_WVALID  <= 1'b1;
                            state         <= WRITE_EXECUTE;
                        end else begin
                            M_AXI_ARADDR  <= d_addr;
                            M_AXI_ARVALID <= 1'b1;
                            state         <= READ_ADDR;
                        end
                    end
                    else if (i_req) begin
                        active_is_d   <= 1'b0;
                        M_AXI_ARADDR  <= i_addr;
                        M_AXI_ARVALID <= 1'b1;
                        state         <= READ_ADDR;
                    end
                end

                READ_ADDR: begin
                    if (M_AXI_ARVALID && M_AXI_ARREADY) begin
                        M_AXI_ARVALID <= 1'b0;
                        M_AXI_RREADY  <= 1'b1;
                        state         <= READ_DATA;
                    end
                end

                READ_DATA: begin
                    if (M_AXI_RVALID && M_AXI_RREADY) begin
                        M_AXI_RREADY <= 1'b0;
                        if (active_is_d) begin
                            d_rdata <= M_AXI_RDATA;
                            d_ready <= 1'b1;  // Instant pulse notification
                        end else begin
                            i_rdata <= M_AXI_RDATA;
                            i_ready <= 1'b1;  // Instant pulse notification
                        end
                        state <= IDLE; // Instantly ready for next transaction
                    end
                end

                WRITE_EXECUTE: begin
                    // Independently register completion flags as they clear
                    if (aw_handshake_comb) begin
                        M_AXI_AWVALID <= 1'b0;
                        reg_aw_done   <= 1'b1;
                    end
                    if (w_handshake_comb) begin
                        M_AXI_WVALID  <= 1'b0;
                        reg_w_done    <= 1'b1;
                    end

                    // Evaluate mixed completion combining history and current state combinationally
                    if (aw_complete && w_complete) begin
                        M_AXI_AWVALID <= 1'b0;
                        M_AXI_WVALID  <= 1'b0;
                        M_AXI_BREADY  <= 1'b1;
                        reg_aw_done   <= 1'b0;
                        reg_w_done    <= 1'b0;
                        state         <= WRITE_RESP;
                    end
                end

                WRITE_RESP: begin
                    if (M_AXI_BVALID && M_AXI_BREADY) begin
                        M_AXI_BREADY <= 1'b0;
                        d_ready      <= 1'b1; // Direct pulse feedback
                        state        <= IDLE;    // Cycle directly back to serve next queue line
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
