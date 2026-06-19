`timescale 1ns / 1ps

module icache_nonblocking (
    input  logic        clk,
    input  logic        rst,

    // CPU Interface
    input  logic [31:0] cpu_addr,
    output logic [31:0] cpu_instr,
    output logic        hit,
    output logic        busy,
    output logic        valid_data,

    // Memory Interface (burst command + multi-beat data)
    output logic        mem_req,         // held high in REQ state until mem_ready
    output logic [31:0] mem_addr,        // burst start address (line-aligned)
    output logic [3:0]  mem_burst_len,   // number of words requested (LINE_WORDS)
    input  logic [31:0] mem_rdata,       // one beat of burst data
    input  logic        mem_rvalid,      // beat valid this cycle
    input  logic        mem_rlast,       // asserted on last beat of burst
    input  logic        mem_ready        // memory accepted mem_req (one-cycle pulse)
);

    //----------------------------------------------------
    // CONFIG
    //----------------------------------------------------
    localparam CACHE_LINES = 64;
    localparam INDEX_BITS  = 6;
    localparam TAG_BITS    = 22;
    localparam LINE_WORDS  = 4;
    localparam OFF_BITS    = 2; // log2(LINE_WORDS)

    //----------------------------------------------------
    // STORAGE
    //----------------------------------------------------
    logic [31:0]         data_array  [0:CACHE_LINES-1][0:LINE_WORDS-1];
    logic [TAG_BITS-1:0] tag_array   [0:CACHE_LINES-1];
    logic                valid_array [0:CACHE_LINES-1];

    //----------------------------------------------------
    // ADDRESS DECOMPOSITION
    //   [31:10] tag        (22 bits)
    //   [9:4]   index      (6 bits)
    //   [3:2]   word_off   (2 bits)
    //   [1:0]   byte_off   (unused for instruction fetch)
    //----------------------------------------------------
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag;
    logic [OFF_BITS-1:0]   word_offset;

    assign index       = cpu_addr[9:4];
    assign tag         = cpu_addr[31:10];
    assign word_offset = cpu_addr[3:2];

    assign hit = valid_array[index] && (tag_array[index] == tag);

    //----------------------------------------------------
    // STATE
    //----------------------------------------------------
    typedef enum logic [1:0] {
        IDLE,
        REQ,     // burst command held, waiting for mem_ready
        REFILL   // burst data streaming in
    } state_t;

    state_t state;

    logic [INDEX_BITS-1:0] current_idx;
    logic [TAG_BITS-1:0]   current_tag;
    logic [OFF_BITS-1:0]   current_off;  // word offset of the triggering miss
    logic [OFF_BITS:0]     beat_cnt;     // extra bit avoids width warning on compare

    //----------------------------------------------------
    // Conflict check: is the current CPU address the
    // same line we are currently refilling?
    //----------------------------------------------------
    logic refill_in_progress;
    logic addr_conflicts_refill;

    assign refill_in_progress    = (state == REQ) || (state == REFILL);
    assign addr_conflicts_refill = refill_in_progress &&
                                   (index == current_idx) &&
                                   (tag   == current_tag);

    //----------------------------------------------------
    // COMBINATIONAL OUTPUTS
    //----------------------------------------------------
    always_comb begin
        cpu_instr     = '0;
        busy          = 0;
        valid_data    = 0;
        mem_req       = 0;
        mem_addr      = '0;
        mem_burst_len = LINE_WORDS[3:0];

        // ---- Priority 1: normal cache hit
        //      (works even while a different line is being
        //      refilled -> hit-under-miss for other addresses)
        if (hit && !addr_conflicts_refill) begin
            cpu_instr  = data_array[index][word_offset];
            valid_data = 1;
            busy       = 0;
        end
        // ---- Priority 2: early-forward the requested word
        //      directly off the memory bus the cycle it arrives
        else if (state == REFILL && mem_rvalid &&
                 (beat_cnt[OFF_BITS-1:0] == current_off) &&
                 (index == current_idx) && (tag == current_tag) ) begin
            cpu_instr  = mem_rdata;
            valid_data = 1;
            busy       = 0;
        end
        // ---- Priority 3: miss / conflicting refill -> stall
        else begin
            busy       = 1;
            valid_data = 0;
        end

        // Issue / hold burst command while in REQ state.
        // mem_req stays asserted until cache_axi4_master
        // pulses mem_ready (one cycle), at which point the
        // FSM advances to REFILL.
        if (state == REQ) begin
            mem_req       = 1;
            mem_addr      = {current_tag, current_idx, {(OFF_BITS+2){1'b0}}};
            mem_burst_len = LINE_WORDS[3:0];
        end
    end

    //----------------------------------------------------
    // SEQUENTIAL LOGIC
    //----------------------------------------------------
    integer i;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= IDLE;
            beat_cnt    <= '0;
            current_idx <= '0;
            current_tag <= '0;
            current_off <= '0;

            for (i = 0; i < CACHE_LINES; i++) begin
                valid_array[i] <= 0;
                tag_array[i]   <= '0;
            end
        end else begin
            case (state)
                //--------------------------------------------
                // IDLE: begin a refill the cycle a miss is
                // detected.  If the CPU address hits (or
                // changes to a hit address) stay in IDLE.
                //--------------------------------------------
                IDLE: begin
                    if (!hit) begin
                        current_idx <= index;
                        current_tag <= tag;
                        current_off <= word_offset;
                        beat_cnt    <= '0;
                        state       <= REQ;
                    end
                end

                //--------------------------------------------
                // REQ: hold mem_req until the arbiter accepts
                // (mem_ready pulse).  Do not re-latch address
                // here â€" the transaction is already in flight.
                //--------------------------------------------
                REQ: begin
                    if (mem_ready) begin
                        beat_cnt <= '0;
                        state    <= REFILL;
                    end
                end

                //--------------------------------------------
                // REFILL: capture each beat. On RLAST mark
                // the line valid and return to IDLE so the
                // next cycle can immediately serve a hit.
                //--------------------------------------------
                REFILL: begin
                    if (mem_rvalid) begin
                        data_array[current_idx][beat_cnt[OFF_BITS-1:0]] <= mem_rdata;

                        if (mem_rlast) begin
                            valid_array[current_idx] <= 1;
                            tag_array[current_idx]   <= current_tag;
                            state                    <= IDLE;
                            beat_cnt                 <= '0;
                        end else begin
                            beat_cnt <= beat_cnt + 1'b1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
