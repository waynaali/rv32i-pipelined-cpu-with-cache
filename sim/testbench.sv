`timescale 1ns / 1ps

module cpu_tb;

    // --------------------------------------------------------
    // Clock & Reset
    // --------------------------------------------------------
    reg clk;
    reg reset;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // --------------------------------------------------------
    // DUT
    // --------------------------------------------------------
    cpu dut (
        .clk   (clk),
        .reset (reset)
    );

    // --------------------------------------------------------
    // Signals
    // --------------------------------------------------------
    wire [31:0] PCF         = dut.PCF;
    wire        StallF      = dut.StallF;
    wire        StallD      = dut.StallD;
    wire        dcache_busy = dut.dcache_busy;
    wire        icache_busy = dut.icache_busy;

    // --------------------------------------------------------
    // Variables
    // --------------------------------------------------------
    reg checked = 1'b0;
    integer stall_streak = 0;

    // --------------------------------------------------------
    // Stall Warning
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            stall_streak <= 0;
        end else begin
            if (StallF || StallD) begin
                stall_streak <= stall_streak + 1;
                if ((stall_streak + 1) % 5 == 0) begin
                    $display("[WARN] @ %0t: Stall streak %0d cycles | icache_busy=%0b dcache_busy=%0b",
                             $time, stall_streak + 1, icache_busy, dcache_busy);
                end
            end else begin
                stall_streak <= 0;
            end
        end
    end

    // --------------------------------------------------------
    // Functional Correctness Check
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !checked && PCF == 32'h00000034) begin   // adjusted for busy-wait
            checked <= 1'b1;

            // Wait for all pending writes to finish
            wait (dcache_busy == 1'b0 && icache_busy == 1'b0);
            repeat (30) @(posedge clk);   // extra safety margin

            $display("");
            $display("============================================================");
            $display("              FUNCTIONAL CORRECTNESS REPORT");
            $display("============================================================");
            $display(" [REGISTERS]");
            $display("    x10 (expected 16) : %0d", dut.register_file.rf[10]);
            $display("    x11 (expected 1)  : %0d", dut.register_file.rf[11]);
            $display("    x12 (expected 2)  : %0d", dut.register_file.rf[12]);
            $display("");
            $display(" [DATA RAM]");
            $display("    RAM[0x1000] (expected 16) : %0d", dut.axi_memory.RAM[1024]);
            $display("    RAM[0x1004] (expected 1)  : %0d", dut.axi_memory.RAM[1025]);
            $display("    RAM[0x1008] (expected 2)  : %0d", dut.axi_memory.RAM[1026]);
            $display("============================================================");

            if (dut.register_file.rf[10] == 16 &&
                dut.register_file.rf[11] == 1  &&
                dut.register_file.rf[12] == 2  &&
                dut.axi_memory.RAM[1024] == 16 &&
                dut.axi_memory.RAM[1025] == 1  &&
                dut.axi_memory.RAM[1026] == 2) begin
                $display(" [SUCCESS] CPU executed program correctly! 🎉");
            end else begin
                $display(" [FAILURE] Correctness check failed!");
            end
            $display("============================================================");
        end
    end

    // --------------------------------------------------------
    // Simulation Control
    // --------------------------------------------------------
    initial begin
        reset = 1'b1;
        repeat (25) @(posedge clk);
        reset = 1'b0;
        $display("[TB] Reset released at %0t ns", $time);

        // Run long enough
        repeat (5000) @(posedge clk);

        $display("[TB] Simulation finished.");
        $finish;
    end

endmodule
