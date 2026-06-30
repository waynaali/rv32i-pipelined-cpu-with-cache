`timescale 1ns / 1ps

module icache_nonblocking (
    input  logic        clk,
    input  logic        rst,
    input  logic        flush,      

    // CPU Interface
    input  logic [31:0] cpu_addr,
    output logic [31:0] cpu_instr,
    output logic        hit,
    output logic        stall,

    // Memory/Bus Interface
    output logic        mem_req,
    output logic [31:0] mem_addr,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ready
);

    localparam CACHE_LINES     = 16;
    localparam INDEX_BITS      = 4;
    localparam TAG_BITS        = 26;
    localparam MISS_QUEUE_SIZE = 4;
    localparam QUEUE_PTR_BITS  = 2;

    // Cache Storage Arrays
    logic [31:0]         data_array  [0:CACHE_LINES-1];
    logic [TAG_BITS-1:0] tag_array   [0:CACHE_LINES-1];
    logic                valid_array [0:CACHE_LINES-1];

    // CPU Input Address Decomposition
    logic [INDEX_BITS-1:0] cpu_index;
    logic [TAG_BITS-1:0]   cpu_tag;
    assign cpu_index = cpu_addr[5:2];
    assign cpu_tag   = cpu_addr[31:6];

    // Miss Queue Structure
    typedef struct packed {
        logic [31:0]           addr;
        logic [INDEX_BITS-1:0] index;
        logic [TAG_BITS-1:0]   tag;
        logic                  valid;
    } miss_entry_t;

    miss_entry_t miss_queue [0:MISS_QUEUE_SIZE-1];
    logic [QUEUE_PTR_BITS-1:0] miss_head;  
    logic [QUEUE_PTR_BITS-1:0] miss_tail;  
    
    logic [QUEUE_PTR_BITS:0]   queue_count; 
    logic                      queue_full;
    logic                      queue_empty;

    assign queue_empty = (queue_count == 0);
    assign queue_full  = (queue_count == MISS_QUEUE_SIZE);

    // Cache Pipeline Lookups
    assign hit = valid_array[cpu_index] && (tag_array[cpu_index] == cpu_tag);

    logic addr_in_queue;
    always_comb begin
        addr_in_queue = 1'b0;
        for (int i = 0; i < MISS_QUEUE_SIZE; i = i + 1) begin
            if (miss_queue[i].valid && 
                miss_queue[i].index == cpu_index && 
                miss_queue[i].tag == cpu_tag) begin
                addr_in_queue = 1'b1;
            end
        end
    end

    // Core Steering logic
    always_comb begin
        cpu_instr = 32'b0;
        stall     = 1'b0;

        if (flush) begin
            stall     = 1'b0;
            cpu_instr = 32'b0;
        end 
        else if (hit) begin
            cpu_instr = data_array[cpu_index];
            stall     = 1'b0; 
        end 
        else begin
            stall = 1'b1; // Default miss stall until allocated and returned
        end
    end

    // Memory Interface Outputs
    always_comb begin
        if (!queue_empty && miss_queue[miss_head].valid) begin
            mem_req  = 1'b1;
            mem_addr = miss_queue[miss_head].addr;
        end else begin
            mem_req  = 1'b0;
            mem_addr = 32'b0;
        end
    end

    // Sequential Queue State & Execution Controllers
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            miss_head   <= '0;
            miss_tail   <= '0;
            queue_count <= '0;

            for (int i = 0; i < MISS_QUEUE_SIZE; i = i + 1) miss_queue[i] <= '0;
            for (int i = 0; i < CACHE_LINES; i = i + 1) begin
                valid_array[i] <= 1'b0;
                tag_array[i]   <= '0;
                data_array[i]  <= 32'b0;
            end
        end 
        else begin
            logic queue_allocate;
            logic queue_deallocate;
            
            queue_allocate   = (!flush && !hit && !addr_in_queue && !queue_full);
            queue_deallocate = (mem_ready && !queue_empty && miss_queue[miss_head].valid);

            // Memory Fill Update Phase
            if (queue_deallocate) begin
                valid_array[miss_queue[miss_head].index] <= 1'b1;
                tag_array[miss_queue[miss_head].index]   <= miss_queue[miss_head].tag;
                data_array[miss_queue[miss_head].index]  <= mem_rdata;
            end

            // Safe Non-Destructive Flush Execution
            if (flush) begin
                // In-flight processing slots safe are retained to prevent bus anomalies
                if (queue_empty) begin
                    miss_head   <= '0;
                    miss_tail   <= '0;
                    queue_count <= '0;
                    for (int i = 0; i < MISS_QUEUE_SIZE; i = i + 1) begin
                        miss_queue[i].valid <= 1'b0;
                    end
                end
            end 
            else begin
                if (queue_allocate) begin
                    miss_queue[miss_tail].addr  <= cpu_addr;
                    miss_queue[miss_tail].index <= cpu_index;
                    miss_queue[miss_tail].tag   <= cpu_tag;
                    miss_queue[miss_tail].valid <= 1'b1;
                    miss_tail <= (miss_tail + 1) % MISS_QUEUE_SIZE;
                end

                if (queue_deallocate) begin
                    miss_queue[miss_head].valid <= 1'b0;
                    miss_head <= (miss_head + 1) % MISS_QUEUE_SIZE;
                end

                if (queue_allocate && !queue_deallocate) begin
                    queue_count <= queue_count + 1'b1;
                end else if (!queue_allocate && queue_deallocate) begin
                    queue_count <= queue_count - 1'b1;
                end
            end
        end
    end

endmodule
