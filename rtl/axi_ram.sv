`timescale 1ns / 1ps

module axi_ram (
    input  logic        clk,
    input  logic        reset,

    // Write address channel
    input  logic [31:0] S_AXI_AWADDR,
    input  logic [7:0]  S_AXI_AWLEN,
    input  logic        S_AXI_AWVALID,
    output logic        S_AXI_AWREADY,

    // Write data channel
    input  logic [31:0] S_AXI_WDATA,
    input  logic [3:0]  S_AXI_WSTRB,
    input  logic        S_AXI_WLAST,
    input  logic        S_AXI_WVALID,
    output logic        S_AXI_WREADY,

    // Write response channel
    output logic        S_AXI_BVALID,
    input  logic        S_AXI_BREADY,

    // Read address channel
    input  logic [31:0] S_AXI_ARADDR,
    input  logic [7:0]  S_AXI_ARLEN,
    input  logic        S_AXI_ARVALID,
    output logic        S_AXI_ARREADY,

    // Read data channel
    output logic [31:0] S_AXI_RDATA,
    output logic        S_AXI_RVALID,
    output logic        S_AXI_RLAST,
    input  logic        S_AXI_RREADY
);

    // ----------------------------------------------------------
    // Memory - 4 K words = 16 KB
    //   Instruction region : byte 0x0000 - 0x0FFF  (word 0-1023)
    //   Data region        : byte 0x1000 - 0x3FFF  (word 1024-4095)
    // ----------------------------------------------------------
    localparam DEPTH = 4096;
    logic [31:0] RAM [0:DEPTH-1];

    // ----------------------------------------------------------
    // FSM
    // ----------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE,
        READ_BURST,
        WRITE_BURST,
        WRITE_RESP
    } state_t;

    state_t      state;
    logic [31:0] base_addr;
    logic [7:0]  burst_len;
    logic [7:0]  beat_cnt;

    // Ready signals: only accept new transactions in IDLE
    assign S_AXI_ARREADY = (state == IDLE);
    assign S_AXI_AWREADY = (state == IDLE);
    assign S_AXI_WREADY  = (state == WRITE_BURST);

    // ----------------------------------------------------------
    // Test program initialisation
    //
    // Instruction region (byte 0x0000 - 0x002C, word 0 - 11):
    //   Computes simple arithmetic, stores results to data region
    //   (base address 0x1000 via LUI), then loops.
    //
    // Decoded:
    //   0: addi x10, x0,  16      x10 = 16   (0x10)
    //   1: addi x11, x0,   1      x11 =  1
    //   2: addi x12, x0,   2      x12 =  2
    //   3: addi x13, x0,   3      x13 =  3
    //   4: lui  x6,  0x1          x6  = 0x0000_1000  (data base)
    //   5: sw   x10,  0(x6)       mem[0x1000] = 16
    //   6: sw   x11,  4(x6)       mem[0x1004] =  1
    //   7: sw   x12,  8(x6)       mem[0x1008] =  2
    //   8: lw   x10,  0(x6)       x10 = mem[0x1000]  (expect 16)
    //   9: lw   x11,  4(x6)       x11 = mem[0x1004]  (expect  1)
    //  10: lw   x12,  8(x6)       x12 = mem[0x1008]  (expect  2)
    //  11: jal  x0,   0           infinite loop
    // ----------------------------------------------------------
    initial begin
        // Default everything to NOP (addi x0,x0,0)
        for (int i = 0; i < DEPTH; i++)
            RAM[i] = 32'h00000013;

        $display("--- Loading Test Program into Memory ---");

        // ---- Instructions (word addresses 0-11) ----
        RAM[0]  = 32'h01000513; // addi x10, x0, 16
        RAM[1]  = 32'h00100593; // addi x11, x0,  1
        RAM[2]  = 32'h00200613; // addi x12, x0,  2
        RAM[3]  = 32'h00300693; // addi x13, x0,  3
        RAM[4]  = 32'h00001337; // lui  x6,  0x1      ? x6 = 0x1000
        RAM[5]  = 32'h00A32023; // sw   x10,  0(x6)   ? mem[0x1000] = 16
        RAM[6]  = 32'h00B32223; // sw   x11,  4(x6)   ? mem[0x1004] =  1
        RAM[7]  = 32'h00C32423; // sw   x12,  8(x6)   ? mem[0x1008] =  2
        RAM[8]  = 32'h00032503; // lw   x10,  0(x6)   ? x10 = 16
        RAM[9]  = 32'h00432583; // lw   x11,  4(x6)   ? x11 =  1
        RAM[10] = 32'h00832603; // lw   x12,  8(x6)   ? x12 =  2
        RAM[11] = 32'h0000006F; // jal  x0,   0       infinite loop

        // ---- Data region (word addresses 0x400 = byte 0x1000 onward) ----
        // Zero-initialised; CPU stores will write here at runtime.
        for (int i = 1024; i < DEPTH; i++)
            RAM[i] = 32'h00000000;

        $display("Program loaded. Start execution.");
    end
initial begin
    #1;
    $display("RAM0=%h", RAM[0]);
    $display("RAM1=%h", RAM[1]);
    $display("RAM2=%h", RAM[2]);
end
    // ----------------------------------------------------------
    // Sequential FSM
    // ----------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            state        <= IDLE;
            S_AXI_BVALID <= 1'b0;
            S_AXI_RVALID <= 1'b0;
            S_AXI_RLAST  <= 1'b0;
            S_AXI_RDATA  <= 32'b0;
            beat_cnt     <= 8'b0;
            base_addr    <= 32'b0;
            burst_len    <= 8'b0;
        end else begin
            case (state)

                // ------------------------------------------------
                IDLE: begin
                    S_AXI_RVALID <= 1'b0;
                    S_AXI_RLAST  <= 1'b0;

                    // Write takes priority (matches AXI4 convention)
                    if (S_AXI_AWVALID) begin
                        state     <= WRITE_BURST;
                        base_addr <= S_AXI_AWADDR;
                        burst_len <= S_AXI_AWLEN;
                        beat_cnt  <= 8'b0;

                    end else if (S_AXI_ARVALID) begin
                        state        <= READ_BURST;
                        base_addr    <= S_AXI_ARADDR;
                        burst_len    <= S_AXI_ARLEN;
                        beat_cnt     <= 8'b0;
                        // Present first beat immediately
                        S_AXI_RDATA  <= RAM[(S_AXI_ARADDR >> 2) % DEPTH];
                        S_AXI_RVALID <= 1'b1;
                        // FIX 1: RLAST on beat 0 only when burst_len=0
                        //        (beat_cnt==0 == burst_len==0)
                        S_AXI_RLAST  <= (S_AXI_ARLEN == 8'b0);
                    end
                end

                // ------------------------------------------------
                READ_BURST: begin
                    if (S_AXI_RVALID && S_AXI_RREADY) begin
                        if (S_AXI_RLAST) begin
                            // Last beat consumed - return to IDLE
                            state        <= IDLE;
                            S_AXI_RVALID <= 1'b0;
                            S_AXI_RLAST  <= 1'b0;
                        end else begin
                            beat_cnt    <= beat_cnt + 8'd1;
                            // Next word: base word address + (beat_cnt+1)
                            S_AXI_RDATA <= RAM[((base_addr >> 2) + beat_cnt + 1) % DEPTH];
                            // FIX 1: assert RLAST when the NEXT beat_cnt
                            //        equals burst_len (i.e. we are about to
                            //        present the last beat).
                            //        Old: (beat_cnt + 1 == burst_len)  ? too early
                            //        New: (beat_cnt     == burst_len)  ? on last beat
                            S_AXI_RLAST <= (beat_cnt == burst_len - 8'd1);
                        end
                    end
                end

                // ------------------------------------------------
                WRITE_BURST: begin
                    if (S_AXI_WVALID && S_AXI_WREADY) begin
                        // Byte-enable aware write
                        if (S_AXI_WSTRB[0]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][7:0]   <= S_AXI_WDATA[7:0];
                        if (S_AXI_WSTRB[1]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][15:8]  <= S_AXI_WDATA[15:8];
                        if (S_AXI_WSTRB[2]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][23:16] <= S_AXI_WDATA[23:16];
                        if (S_AXI_WSTRB[3]) RAM[((base_addr>>2)+beat_cnt)%DEPTH][31:24] <= S_AXI_WDATA[31:24];

                        if (S_AXI_WLAST || (beat_cnt == burst_len)) begin
                            state        <= WRITE_RESP;
                            S_AXI_BVALID <= 1'b1;
                        end else begin
                            beat_cnt <= beat_cnt + 8'd1;
                        end
                    end
                end

                // ------------------------------------------------
                // Hold BVALID until master accepts (AXI4 compliant)
                WRITE_RESP: begin
                    if (S_AXI_BVALID && S_AXI_BREADY) begin
                        S_AXI_BVALID <= 1'b0;
                        state        <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
