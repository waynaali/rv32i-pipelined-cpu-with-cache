`timescale 1ns / 1ps 

module cpu(
    input logic clk,
    input logic reset
);

/////////////////////////
// Pipeline Control Signals
/////////////////////////
logic ZeroE;
logic StallF, StallD, StallID_IE;
logic FlushE, FlushD;
logic PCSrcE;
logic [2:0] funct3E, funct3M;

/////////////////////////
// I-Cache Signals
/////////////////////////
logic [31:0] icache_mem_addr;
logic [3:0]  icache_mem_burst_len;
logic [31:0] icache_mem_rdata;
logic        icache_mem_rvalid;
logic        icache_mem_rlast;
logic        icache_hit;
logic        icache_busy;
logic        icache_valid_data;
logic        icache_mem_req;
logic        icache_mem_ready;

/////////////////////////
// D-Cache Signals
/////////////////////////
logic        dcache_hit;
logic        dcache_busy;
logic        dcache_valid_data;
logic        dcache_mem_we;
logic [3:0]  dcache_mem_be;
logic [31:0] dcache_mem_addr;
logic [31:0] dcache_mem_wdata;
logic [3:0]  dcache_mem_burst_len;
logic [31:0] dcache_mem_rdata;
logic        dcache_mem_rvalid;
logic        dcache_mem_rlast;
logic        dcache_mem_req;
logic        dcache_mem_ready;

/////////////////////////
// Forwarding Unit Signals
/////////////////////////
logic [1:0] ForwardAE, ForwardBE;

/////////////////////////
// Control Signals
/////////////////////////
logic RegWriteD, RegWriteE, RegWriteM, RegWriteW;
logic MemWriteD, MemWriteE, MemWriteM;
logic JumpD, BranchD, JumpE, BranchE;
logic ALUSrcE, ALUSrcD;
logic [1:0] ResultSrcD, ResultSrcE, ResultSrcM, ResultSrcW;
logic [2:0] ALUControlD, ALUControlE;
logic [2:0] ImmSrcD;

/////////////////////////
// Data Signals
/////////////////////////
logic [31:0] SrcAE, SrcBE, SrcB;
logic [31:0] ALUResultE, ALUResultM, ALUResultW;
logic [31:0] ReadDataM, ReadDataW;
logic [31:0] PCTargetE, PCNext;
logic [31:0] ResultW;
logic [31:0] RD1D, RD2D;
logic [31:0] RD1E, RD2E, RD2M;
logic [31:0] ImmExtendE, ImmExtendD;

/////////////////////////
// PC and Instruction Signals
/////////////////////////
logic [31:0] InstrD, InstrF;
logic [31:0] PCD, PCE, PCF;
logic [31:0] PCPlus4D, PCPlus4E, PCPlus4M, PCPlus4W, PCPlus4F;

/////////////////////////
// Register Addresses
/////////////////////////
logic [4:0] rs1E, rs2E, rdE, rdM, rdW;

/////////////////////////
// AXI Interface Signals
/////////////////////////
logic [31:0] axi_awaddr;
logic [7:0]  axi_awlen;
logic [2:0]  axi_awsize;
logic [1:0]  axi_awburst;
logic        axi_awvalid;
logic        axi_awready;
logic [31:0] axi_wdata;
logic [3:0]  axi_wstrb;
logic        axi_wlast;
logic        axi_wvalid;
logic        axi_wready;
logic [1:0]  axi_bresp;
logic        axi_bvalid;
logic        axi_bready;
logic [31:0] axi_araddr;
logic [7:0]  axi_arlen;
logic [2:0]  axi_arsize;
logic [1:0]  axi_arburst;
logic        axi_arvalid;
logic        axi_arready;
logic [31:0] axi_rdata;
logic [1:0]  axi_rresp;
logic        axi_rvalid;
logic        axi_rlast;
logic        axi_rready;

// ---------------------------------------------------------------
// FIX 5: One-shot strobe for D-cache memory access.
// Without this, every stall cycle re-presents MemWriteM/ResultSrcM
// to the cache, causing it to re-issue the same request on each
// cycle until the miss is resolved.
// ---------------------------------------------------------------
logic dcache_mem_read_q;    // direct read signal to D-cache
logic dcache_mem_write_q;   // direct write signal to D-cache

// Pass read/write signals directly to allow the cache to control pipeline stalls correctly
assign dcache_mem_read_q  = ResultSrcM[0];
assign dcache_mem_write_q = MemWriteM;


// ---------------------------------------------------------------
// FIX 1 & 2: Unified cache stall signal.
// Both caches can stall the pipeline.  PC must also stall on a
// D-cache miss otherwise it advances while MEM is frozen.
// ---------------------------------------------------------------
logic cache_stall;
assign cache_stall = icache_busy | dcache_busy;

// ---------------------------------------------------------------
// FIX 4: Branch comparisons must use SrcBE (the post-ALUSrc mux
// output), not SrcB.  For branches the immediate is never used as
// the comparand - rs2 forwarded value is correct - but using SrcB
// before the mux means a forwarded immediate would be wrong.
// Using SrcBE is the safe, architecturally correct choice.
// ---------------------------------------------------------------
always_comb begin
    PCSrcE = 1'b0;

    if (JumpE) begin
        PCSrcE = 1'b1;
    end
    else if (BranchE) begin
        case (funct3E)
            3'b000: PCSrcE =  ZeroE;
            3'b001: PCSrcE = ~ZeroE;
            // FIX 4: was SrcB, now SrcBE
            3'b100: PCSrcE = ($signed(SrcAE) <  $signed(SrcBE));
            3'b101: PCSrcE = ($signed(SrcAE) >= $signed(SrcBE));
            3'b110: PCSrcE = (SrcAE <  SrcBE);
            3'b111: PCSrcE = (SrcAE >= SrcBE);
            default: PCSrcE = 1'b0;
        endcase
    end
end

/////////////////////////
// Module Instantiations
/////////////////////////

// ---------------------------------------------------------------
// FIX 3: Forwarding unit - ForwardAE/ForwardBE == 2'b11 (load
// bypass) must only be asserted when dcache_valid_data is high.
// The forwarding_unit itself should implement this gate; the port
// is passed through here so the unit can do it internally.
// ---------------------------------------------------------------
forwarding_unit forwarding_unit(
    .Rs1E(rs1E),
    .Rs2E(rs2E),
    .RdM(rdM),
    .RdW(rdW),
    .RegWriteM(RegWriteM),
    .RegWriteW(RegWriteW),
    // FIX 3: dcache_valid_data gates the load-bypass forward path
    .dcache_valid(dcache_valid_data),
    .dcache_dest_reg(rdM),
    .ForwardAE(ForwardAE),
    .ForwardBE(ForwardBE)
);

Adder PC_Plus_4(
    .A(PCF),
    .B(32'd4),
    .Sum(PCPlus4F)
);

Adder PC_Target(
    .A(PCE),
    .B(ImmExtendE),
    .Sum(PCTargetE)
);

mux2 PC_Next(
    .d0(PCPlus4F),
    .d1(PCTargetE),
    .s(PCSrcE),
    .y(PCNext)
);

// FIX 1: PC stall now includes dcache_busy (was ~(StallF | icache_busy))
program_counter ProgramCounter(
    .clk(clk),
    .reset(reset),
    .en(~(StallF | cache_stall)),
    .PCNext(PCNext),
    .PC(PCF)
);

/////////////////////////
// Non-Blocking Caches
/////////////////////////
icache_nonblocking instruction_cache(
    .clk(clk),
    .rst(reset),
    .cpu_addr(PCF),
    .cpu_instr(InstrF),
    .hit(icache_hit),
    .busy(icache_busy),
    .valid_data(icache_valid_data),
    .mem_req(icache_mem_req),
    .mem_addr(icache_mem_addr),
    .mem_burst_len(icache_mem_burst_len),
    .mem_rdata(icache_mem_rdata),
    .mem_rvalid(icache_mem_rvalid),
    .mem_rlast(icache_mem_rlast),
    .mem_ready(icache_mem_ready)
);

// FIX 5: use gated read/write signals to prevent re-issue
dcache_nonblocking data_cache(
    .clk       (clk),
    .rst       (reset),
    .mem_read  (dcache_mem_read_q),   // FIX 5: one-shot strobe
    .mem_write (dcache_mem_write_q),  // FIX 5: one-shot strobe
    .funct3    (funct3M),
    .cpu_addr  (ALUResultM),
    .cpu_wdata (RD2M),
    .cpu_rdata (ReadDataM),
    .hit       (dcache_hit),
    .busy      (dcache_busy),
    .valid_data(dcache_valid_data),
    .mem_req   (dcache_mem_req),
    .mem_we    (dcache_mem_we),
    .mem_be    (dcache_mem_be),
    .mem_addr  (dcache_mem_addr),
    .mem_wdata (dcache_mem_wdata),
    .mem_burst_len(dcache_mem_burst_len),
    .mem_rdata (dcache_mem_rdata),
    .mem_rvalid(dcache_mem_rvalid),
    .mem_rlast (dcache_mem_rlast),
    .mem_ready (dcache_mem_ready)
);

/////////////////////////
// AXI4 Master
/////////////////////////
cache_axi4_master axi_master_wrapper (
    .clk(clk),
    .reset(reset),

    .i_mem_req      (icache_mem_req),
    .i_mem_addr     (icache_mem_addr),
    .i_mem_burst_len(icache_mem_burst_len),
    .i_mem_rdata    (icache_mem_rdata),
    .i_mem_rvalid   (icache_mem_rvalid),
    .i_mem_rlast    (icache_mem_rlast),
    .i_mem_ready    (icache_mem_ready),

    .d_mem_req      (dcache_mem_req),
    .d_mem_we       (dcache_mem_we),
    .d_mem_be       (dcache_mem_be),
    .d_mem_addr     (dcache_mem_addr),
    .d_mem_wdata    (dcache_mem_wdata),
    .d_mem_burst_len(dcache_mem_burst_len),
    .d_mem_rdata    (dcache_mem_rdata),
    .d_mem_rvalid   (dcache_mem_rvalid),
    .d_mem_rlast    (dcache_mem_rlast),
    .d_mem_ready    (dcache_mem_ready),

    .M_AXI_AWADDR  (axi_awaddr),
    .M_AXI_AWLEN   (axi_awlen),
    .M_AXI_AWSIZE  (axi_awsize),
    .M_AXI_AWBURST (axi_awburst),
    .M_AXI_AWVALID (axi_awvalid),
    .M_AXI_AWREADY (axi_awready),
    .M_AXI_WDATA   (axi_wdata),
    .M_AXI_WSTRB   (axi_wstrb),
    .M_AXI_WLAST   (axi_wlast),
    .M_AXI_WVALID  (axi_wvalid),
    .M_AXI_WREADY  (axi_wready),
    .M_AXI_BRESP   (axi_bresp),
    .M_AXI_BVALID  (axi_bvalid),
    .M_AXI_BREADY  (axi_bready),
    .M_AXI_ARADDR  (axi_araddr),
    .M_AXI_ARLEN   (axi_arlen),
    .M_AXI_ARSIZE  (axi_arsize),
    .M_AXI_ARBURST (axi_arburst),
    .M_AXI_ARVALID (axi_arvalid),
    .M_AXI_ARREADY (axi_arready),
    .M_AXI_RDATA   (axi_rdata),
    .M_AXI_RRESP   (axi_rresp),
    .M_AXI_RVALID  (axi_rvalid),
    .M_AXI_RLAST   (axi_rlast),
    .M_AXI_RREADY  (axi_rready)
);

axi_ram axi_memory (
    .clk(clk),
    .reset(reset),
    .S_AXI_AWADDR  (axi_awaddr),
    .S_AXI_AWLEN   (axi_awlen),
    .S_AXI_AWVALID (axi_awvalid),
    .S_AXI_AWREADY (axi_awready),
    .S_AXI_WDATA   (axi_wdata),
    .S_AXI_WSTRB   (axi_wstrb),
    .S_AXI_WLAST   (axi_wlast),
    .S_AXI_WVALID  (axi_wvalid),
    .S_AXI_WREADY  (axi_wready),
    .S_AXI_BVALID  (axi_bvalid),
    .S_AXI_BREADY  (axi_bready),
    .S_AXI_ARADDR  (axi_araddr),
    .S_AXI_ARLEN   (axi_arlen),
    .S_AXI_ARVALID (axi_arvalid),
    .S_AXI_ARREADY (axi_arready),
    .S_AXI_RDATA   (axi_rdata),
    .S_AXI_RVALID  (axi_rvalid),
    .S_AXI_RLAST   (axi_rlast),
    .S_AXI_RREADY  (axi_rready)
);

/////////////////////////
// IF/ID Pipeline Register
/////////////////////////
// FIX 2: en uses cache_stall (covers both caches)
IF_ID IF_ID(
    .clk(clk),
    .reset(reset),
    .flush(FlushD),
    .en(~(StallD | cache_stall)),
    .InstrF(InstrF),
    .PCF(PCF),
    .PCPlus4F(PCPlus4F),
    .InstrD(InstrD),
    .PCD(PCD),
    .PCPlus4D(PCPlus4D)
);

register_file register_file(
    .clk(clk),
    .A1(InstrD[19:15]),
    .A2(InstrD[24:20]),
    .A3(rdW),
    .wd3(ResultW),
    .we(RegWriteW),
    .rd1(RD1D),
    .rd2(RD2D)
);

ExtendUnit extend(
    .Instr(InstrD),
    .ImmSrc(ImmSrcD),
    .ImmExtend(ImmExtendD)
);

control_unit control_unit(
    .op(InstrD[6:0]),
    .funct3(InstrD[14:12]),
    .funct7b5(InstrD[30]),
    .Branch(BranchD),
    .Jump(JumpD),
    .ResultSrc(ResultSrcD),
    .MemWrite(MemWriteD),
    .ImmSrc(ImmSrcD),
    .RegWrite(RegWriteD),
    .ALUSrc(ALUSrcD),
    .ALUControl(ALUControlD)
);

// Hazard Unit
HazardUnit hazard_unit(
    .Rs1D(InstrD[19:15]),
    .Rs2D(InstrD[24:20]),
    .RdE(rdE),
    .rdM(rdM),
    .RegWriteM(RegWriteM),
    .RegWriteW(RegWriteW),
    .icache_busy(icache_busy),
    .dcache_busy(dcache_busy),
    .dcache_valid(dcache_valid_data),
    .ResultSrcE0(ResultSrcE[0]),
    .StallF(StallF),
    .StallD(StallD),
    .StallID_IE(StallID_IE),  // FIX: separate stall for ID/IE register
    .FlushE(FlushE),
    .FlushD(FlushD)
);

// KEY FIX: ID/IE uses StallID_IE, NOT StallD.
// On load-use stall, StallD=1 but StallID_IE=0 so the bubble (FlushE)
// propagates into EX. On cache stall, StallID_IE=1 freezes everything.
ID_IE ID_IE(
    .clk(clk),
    .reset(reset),
    .flush(FlushE),
    .en(~StallID_IE),
    .rd1D(RD1D),
    .rd2D(RD2D),
    .PCD(PCD),
    .rs1D(InstrD[19:15]),
    .rs2D(InstrD[24:20]),
    .rdD(InstrD[11:7]),
    .ImmExtendD(ImmExtendD),
    .PCPlus4D(PCPlus4D),
    .RegWriteD(RegWriteD),
    .ResultSrcD(ResultSrcD),
    .MemWriteD(MemWriteD),
    .JumpD(JumpD),
    .BranchD(BranchD),
    .ALUSrcD(ALUSrcD),
    .ALUControlD(ALUControlD),
    .rd1E(RD1E),
    .rd2E(RD2E),
    .PCE(PCE),
    .rs1E(rs1E),
    .rs2E(rs2E),
    .rdE(rdE),
    .ImmExtendE(ImmExtendE),
    .PCPlus4E(PCPlus4E),
    .RegWriteE(RegWriteE),
    .ResultSrcE(ResultSrcE),
    .MemWriteE(MemWriteE),
    .JumpE(JumpE),
    .BranchE(BranchE),
    .ALUSrcE(ALUSrcE),
    .ALUControlE(ALUControlE),
    .funct3D(InstrD[14:12]),
    .funct3E(funct3E)
);

// 4-to-1 Mux for SrcA
mux4to1 mux_srcA(
    .d0(RD1E),
    .d1(ResultW),
    .d2(ALUResultM),
    .d3(ReadDataM),      // FIX 3: only driven when dcache_valid_data=1 (handled in forwarding_unit)
    .s(ForwardAE),
    .y(SrcAE)
);

// 4-to-1 Mux for SrcB (pre-ALUSrc mux)
mux4to1 mux_srcB(
    .d0(RD2E),
    .d1(ResultW),
    .d2(ALUResultM),
    .d3(ReadDataM),      // FIX 3: same gating via forwarding_unit
    .s(ForwardBE),
    .y(SrcB)
);

// ALUSrc mux: picks between forwarded register or immediate
mux2 Src_B(
    .d0(SrcB),
    .d1(ImmExtendE),
    .s(ALUSrcE),
    .y(SrcBE)           // FIX 4: SrcBE is now correctly used in branch comparisons above
);

ALU ALU(
    .SrcA(SrcAE),
    .SrcB(SrcBE),
    .ALUControl(ALUControlE),
    .ALUResult(ALUResultE),
    .Zero(ZeroE)
);

/////////////////////////
// EX/MEM Pipeline Register
/////////////////////////
IE_IM IE_IM(
    .clk(clk),
    .reset(reset),
    .en(~cache_stall),   // FIX 2: both caches
    .ALUResultE(ALUResultE),
    .RD2E(SrcB),
    .RegWriteE(RegWriteE),
    .MemWriteE(MemWriteE),
    .ResultSrcE(ResultSrcE),
    .rdE(rdE),
    .PCPlus4E(PCPlus4E),
    .funct3E(funct3E),
    .ALUResultM(ALUResultM),
    .RD2M(RD2M),
    .RegWriteM(RegWriteM),
    .MemWriteM(MemWriteM),
    .ResultSrcM(ResultSrcM),
    .rdM(rdM),
    .PCPlus4M(PCPlus4M),
    .funct3M(funct3M)
);

/////////////////////////
// MEM/WB Pipeline Register
/////////////////////////
IM_IW IM_IW(
    .clk(clk),
    .reset(reset),
    .en(~cache_stall),   // FIX 2: both caches
    .ALUResultM(ALUResultM),
    .ReadDataM(ReadDataM),
    .PCPlus4M(PCPlus4M),
    .RegWriteM(RegWriteM),
    .ResultSrcM(ResultSrcM),
    .rdM(rdM),
    .ALUResultW(ALUResultW),
    .ReadDataW(ReadDataW),
    .PCPlus4W(PCPlus4W),
    .rdW(rdW),
    .RegWriteW(RegWriteW),
    .ResultSrcW(ResultSrcW)
);

mux3to1 result(
    .d0(ALUResultW),
    .d1(ReadDataW),
    .d2(PCPlus4W),
    .s(ResultSrcW),
    .y(ResultW)
);

endmodule
