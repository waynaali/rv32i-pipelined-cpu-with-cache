// =============================================================
//  cache_axi4_master.sv  -  Fixed version
//
//  FIX 3: Burst re-request storm - suppression window extended
//          from 1 cycle to 2 cycles.
//
//  Root cause:
//    Single-bit suppress cleared after 1 cycle. But the cache FSM
//    needs that same 1 cycle to see mem_ready and move REQ?REFILL
//    (which is where it stops asserting mem_req). So the arbiter
//    saw mem_req=1 again on the very next cycle and re-granted,
//    producing the burst-request storm in the simulation log.
//
//  Fix:
//    suppress_i_sr / suppress_d_sr are 2-bit shift registers.
//    Bit[1] is loaded with 1'b1 the cycle the grant fires.
//    Each clock the register shifts right: [1]?[0]?0.
//    wire suppress_X = |suppress_X_sr keeps the mask up for
//    exactly 2 cycles, giving the cache FSM one full cycle to
//    drop its request before the arbiter considers it again.
// =============================================================

`timescale 1ns / 1ps

module cache_axi4_master (
    input  logic        clk,
    input  logic        reset,

    //------------------------------------------------------------
    // I-cache memory port (burst read only)
    //------------------------------------------------------------
    input  logic        i_mem_req,
    input  logic [31:0] i_mem_addr,
    input  logic [3:0]  i_mem_burst_len,
    output logic [31:0] i_mem_rdata,
    output logic        i_mem_rvalid,
    output logic        i_mem_rlast,
    output logic        i_mem_ready,

    //------------------------------------------------------------
    // D-cache memory port (burst read + single-beat write)
    //------------------------------------------------------------
    input  logic        d_mem_req,
    input  logic        d_mem_we,
    input  logic [3:0]  d_mem_be,
    input  logic [31:0] d_mem_addr,
    input  logic [31:0] d_mem_wdata,
    input  logic [3:0]  d_mem_burst_len,
    output logic [31:0] d_mem_rdata,
    output logic        d_mem_rvalid,
    output logic        d_mem_rlast,
    output logic        d_mem_ready,

    //------------------------------------------------------------
    // AXI4 master
    //------------------------------------------------------------
    output logic [31:0] M_AXI_AWADDR,
    output logic [7:0]  M_AXI_AWLEN,
    output logic [2:0]  M_AXI_AWSIZE,
    output logic [1:0]  M_AXI_AWBURST,
    output logic        M_AXI_AWVALID,
    input  logic        M_AXI_AWREADY,
    output logic [31:0] M_AXI_WDATA,
    output logic [3:0]  M_AXI_WSTRB,
    output logic        M_AXI_WLAST,
    output logic        M_AXI_WVALID,
    input  logic        M_AXI_WREADY,
    input  logic [1:0]  M_AXI_BRESP,
    input  logic        M_AXI_BVALID,
    output logic        M_AXI_BREADY,
    output logic [31:0] M_AXI_ARADDR,
    output logic [7:0]  M_AXI_ARLEN,
    output logic [2:0]  M_AXI_ARSIZE,
    output logic [1:0]  M_AXI_ARBURST,
    output logic        M_AXI_ARVALID,
    input  logic        M_AXI_ARREADY,
    input  logic [31:0] M_AXI_RDATA,
    input  logic [1:0]  M_AXI_RRESP,
    input  logic        M_AXI_RVALID,
    input  logic        M_AXI_RLAST,
    output logic        M_AXI_RREADY
);

    // ----------------------------------------------------------
    // FSM - exclusive bus from grant until full AXI completion.
    // Priority: D-write > D-read > I-read
    // ----------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        READ_ADDR,
        READ_DATA,
        WRITE_ADDR,
        WRITE_RESP
    } state_t;

    state_t state;

    logic [31:0] active_addr;
    logic [31:0] active_wdata;
    logic [3:0]  active_be;
    logic [7:0]  active_arlen;
    logic        is_iop;
    logic        aw_done;
    logic        w_done;

    logic i_mem_ready_r, d_mem_ready_r;

    // ----------------------------------------------------------
    // FIX 3: 2-bit shift-register suppressors.
    //   Bit[1] loaded with 1 on the grant cycle.
    //   Shifts right each clock: [1]?[0]?0.
    //   suppress = |sr keeps mask asserted for 2 cycles.
    // ----------------------------------------------------------
    logic [1:0] suppress_i_sr;
    logic [1:0] suppress_d_sr;
    wire        suppress_i = |suppress_i_sr;
    wire        suppress_d = |suppress_d_sr;

    // ----------------------------------------------------------
    // COMBINATIONAL AXI OUTPUTS
    // ----------------------------------------------------------
    always_comb begin
        M_AXI_ARVALID = 1'b0;
        M_AXI_RREADY  = 1'b0;
        M_AXI_AWVALID = 1'b0;
        M_AXI_WVALID  = 1'b0;
        M_AXI_BREADY  = 1'b0;

        M_AXI_ARADDR  = active_addr;
        M_AXI_ARLEN   = active_arlen;
        M_AXI_ARSIZE  = 3'b010;
        M_AXI_ARBURST = 2'b01;

        M_AXI_AWADDR  = active_addr;
        M_AXI_AWLEN   = 8'd0;       // single-beat writes
        M_AXI_AWSIZE  = 3'b010;
        M_AXI_AWBURST = 2'b01;

        M_AXI_WDATA   = active_wdata;
        M_AXI_WSTRB   = active_be;
        M_AXI_WLAST   = 1'b1;

        case (state)
            READ_ADDR:  M_AXI_ARVALID = 1'b1;
            READ_DATA:  M_AXI_RREADY  = 1'b1;
            WRITE_ADDR: begin
                M_AXI_AWVALID = !aw_done;
                M_AXI_WVALID  = !w_done;
            end
            WRITE_RESP: M_AXI_BREADY = 1'b1;
            default: ;
        endcase
    end

    // ----------------------------------------------------------
    // CACHE-FACING OUTPUTS
    // ----------------------------------------------------------
    assign i_mem_ready = (state == READ_ADDR) && M_AXI_ARREADY && is_iop;
    assign d_mem_ready = (!is_iop && (state == READ_ADDR) && M_AXI_ARREADY) ||
                         ((state == WRITE_ADDR) && (aw_done || M_AXI_AWREADY) && (w_done || M_AXI_WREADY));

    assign i_mem_rvalid = (state == READ_DATA) && M_AXI_RVALID &&  is_iop;
    assign i_mem_rdata  = M_AXI_RDATA;
    assign i_mem_rlast  = M_AXI_RLAST;

    assign d_mem_rvalid = (state == READ_DATA) && M_AXI_RVALID && !is_iop;
    assign d_mem_rdata  = M_AXI_RDATA;
    assign d_mem_rlast  = M_AXI_RLAST;

    // ----------------------------------------------------------
    // SEQUENTIAL FSM + ARBITRATION
    // ----------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= IDLE;
            is_iop        <= 1'b0;
            active_addr   <= 32'b0;
            active_wdata  <= 32'b0;
            active_be     <= 4'b0;
            active_arlen  <= 8'b0;
            aw_done       <= 1'b0;
            w_done        <= 1'b0;
            i_mem_ready_r <= 1'b0;
            d_mem_ready_r <= 1'b0;
            suppress_i_sr <= 2'b00;
            suppress_d_sr <= 2'b00;
        end else begin
            // Default: ready pulses clear each cycle
            i_mem_ready_r <= 1'b0;
            d_mem_ready_r <= 1'b0;

            // FIX 3: shift right each cycle (clears within 2 cycles)
            suppress_i_sr <= suppress_i_sr >> 1;
            suppress_d_sr <= suppress_d_sr >> 1;

            case (state)
                // ------------------------------------------------
                // IDLE: arbitrate - D-write > D-read > I-read
                // ------------------------------------------------
                IDLE: begin
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;

                    if (d_mem_req && d_mem_we && !suppress_d) begin
                        active_addr  <= d_mem_addr;
                        active_wdata <= d_mem_wdata;
                        active_be    <= d_mem_be;
                        is_iop       <= 1'b0;
                        state        <= WRITE_ADDR;
                    end
                    else if (d_mem_req && !d_mem_we && !suppress_d) begin
                        active_addr  <= d_mem_addr;
                        active_arlen <= d_mem_burst_len - 4'd1;
                        is_iop       <= 1'b0;
                        state        <= READ_ADDR;
                    end
                    else if (i_mem_req && !suppress_i) begin
                        active_addr  <= i_mem_addr;
                        active_arlen <= i_mem_burst_len - 4'd1;
                        is_iop       <= 1'b1;
                        state        <= READ_ADDR;
                    end
                end

                // ------------------------------------------------
                // READ_ADDR: hold ARVALID until slave accepts.
                // On acceptance: pulse *_mem_ready and load the
                // suppress shift register with 2'b10 so the mask
                // covers THIS cycle and the NEXT cycle.
                // ------------------------------------------------
                READ_ADDR: begin
                    if (M_AXI_ARREADY) begin
                        if (is_iop) begin
                            i_mem_ready_r <= 1'b1;
                            // FIX 3: preset both bits so suppress stays
                            // asserted for 2 full cycles from this point.
                            suppress_i_sr <= 2'b11;
                        end else begin
                            d_mem_ready_r <= 1'b1;
                            suppress_d_sr <= 2'b11;
                        end
                        state <= READ_DATA;
                    end
                end

                // ------------------------------------------------
                // READ_DATA: forward beats; done on RLAST
                // ------------------------------------------------
                READ_DATA: begin
                    if (M_AXI_RVALID && M_AXI_RLAST)
                        state <= IDLE;
                end

                // ------------------------------------------------
                // WRITE_ADDR: drive AW+W simultaneously.
                // Pulse d_mem_ready when both channels complete.
                // ------------------------------------------------
                WRITE_ADDR: begin
                    if (!aw_done && M_AXI_AWREADY) aw_done <= 1'b1;
                    if (!w_done  && M_AXI_WREADY)  w_done  <= 1'b1;

                    if ((aw_done || M_AXI_AWREADY) &&
                        (w_done  || M_AXI_WREADY)) begin
                        d_mem_ready_r <= 1'b1;
                        // FIX 3: 2-cycle suppress for write grant
                        suppress_d_sr <= 2'b11;
                        state         <= WRITE_RESP;
                    end
                end

                // ------------------------------------------------
                // WRITE_RESP: wait for BVALID, then return to IDLE.
                // The 2-cycle suppress window ensures dcache has
                // seen write_done_q and dropped d_mem_req before
                // the next arbitration.
                // ------------------------------------------------
                WRITE_RESP: begin
                    if (M_AXI_BVALID)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
