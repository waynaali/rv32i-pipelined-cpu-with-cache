// =============================================================
// axi_ram.sv - Final Version (inst.mem + Proper Data Region)
// =============================================================
`timescale 1ns / 1ps

module axi_ram (
    input logic clk,
    input logic reset,
    // Write address channel
    input logic [31:0] S_AXI_AWADDR,
    input logic [7:0] S_AXI_AWLEN,
    input logic S_AXI_AWVALID,
    output logic S_AXI_AWREADY,
    // Write data channel
    input logic [31:0] S_AXI_WDATA,
    input logic [3:0] S_AXI_WSTRB,
    input logic S_AXI_WLAST,
    input logic S_AXI_WVALID,
    output logic S_AXI_WREADY,
    // Write response channel
    output logic S_AXI_BVALID,
    input logic S_AXI_BREADY,
    // Read address channel
    input logic [31:0] S_AXI_ARADDR,
    input logic [7:0] S_AXI_ARLEN,
    input logic S_AXI_ARVALID,
    output logic S_AXI_ARREADY,
    // Read data channel
    output logic [31:0] S_AXI_RDATA,
    output logic S_AXI_RVALID,
    output logic S_AXI_RLAST,
    input logic S_AXI_RREADY
);
    // ----------------------------------------------------------
    // Memory - 4K words = 16 KB
    // ----------------------------------------------------------
    localparam DEPTH = 4096;
    logic [31:0] RAM [0:DEPTH-1];

    // ----------------------------------------------------------
    // FSM signals
    // ----------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE, READ_BURST, WRITE_BURST, WRITE_RESP
    } state_t;

    state_t state;
    logic [31:0] base_addr;
    logic [7:0] burst_len;
    logic [7:0] beat_cnt;

    assign S_AXI_ARREADY = (state == IDLE);
    assign S_AXI_AWREADY = (state == IDLE);
    assign S_AXI_WREADY  = (state == WRITE_BURST);

    // ----------------------------------------------------------
    // Memory Initialization
    // ----------------------------------------------------------
    initial begin
        integer i;

        // 1. Default everything to NOP
        for (i = 0; i < DEPTH; i++)
            RAM[i] = 32'h00000013;

        // 2. Clear Data Region to 0x00000000
        for (i = 1024; i < DEPTH; i++)
            RAM[i] = 32'h00000000;

        $display("--- Loading Test Program from inst.mem ---");
        
        // 3. Load instructions from file (only fills lower addresses)
        $readmemh("inst.mem", RAM);

        $display("Program loaded. Start execution.");
        $display("RAM0=%h  RAM1=%h  RAM2=%h", RAM[0], RAM[1], RAM[2]);
    end

    // ----------------------------------------------------------
    // AXI FSM
    // ----------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            state       <= IDLE;
            S_AXI_BVALID <= 1'b0;
            S_AXI_RVALID <= 1'b0;
            S_AXI_RLAST  <= 1'b0;
            S_AXI_RDATA  <= 32'b0;
            beat_cnt     <= 8'b0;
            base_addr    <= 32'b0;
            burst_len    <= 8'b0;
        end else begin
            case (state)
                IDLE: begin
                    S_AXI_RVALID <= 1'b0;
                    S_AXI_RLAST  <= 1'b0;

                    if (S_AXI_AWVALID) begin
                        state     <= WRITE_BURST;
                        base_addr <= S_AXI_AWADDR;
                        burst_len <= S_AXI_AWLEN;
                        beat_cnt  <= 8'b0;
                    end 
                    else if (S_AXI_ARVALID) begin
                        state     <= READ_BURST;
                        base_addr <= S_AXI_ARADDR;
                        burst_len <= S_AXI_ARLEN;
                        beat_cnt  <= 8'b0;

                        S_AXI_RDATA  <= RAM[(S_AXI_ARADDR >> 2) % DEPTH];
                        S_AXI_RVALID <= 1'b1;
                        S_AXI_RLAST  <= (S_AXI_ARLEN == 8'b0);
                    end
                end

                READ_BURST: begin
                    if (S_AXI_RVALID && S_AXI_RREADY) begin
                        if (S_AXI_RLAST) begin
                            state <= IDLE;
                            S_AXI_RVALID <= 1'b0;
                            S_AXI_RLAST  <= 1'b0;
                        end else begin
                            beat_cnt <= beat_cnt + 8'd1;
                            S_AXI_RDATA <= RAM[((base_addr >> 2) + beat_cnt + 1) % DEPTH];
                            S_AXI_RLAST <= (beat_cnt == burst_len - 8'd1);
                        end
                    end
                end

                WRITE_BURST: begin
                    if (S_AXI_WVALID && S_AXI_WREADY) begin
                        if (S_AXI_WSTRB[0]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][7:0]   <= S_AXI_WDATA[7:0];
                        if (S_AXI_WSTRB[1]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][15:8]  <= S_AXI_WDATA[15:8];
                        if (S_AXI_WSTRB[2]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][23:16] <= S_AXI_WDATA[23:16];
                        if (S_AXI_WSTRB[3]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][31:24] <= S_AXI_WDATA[31:24];

                        if (S_AXI_WLAST || (beat_cnt == burst_len)) begin
                            state <= WRITE_RESP;
                            S_AXI_BVALID <= 1'b1;
                        end else begin
                            beat_cnt <= beat_cnt + 8'd1;
                        end
                    end
                end

                WRITE_RESP: begin
                    if (S_AXI_BVALID && S_AXI_BREADY) begin
                        S_AXI_BVALID <= 1'b0;
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
