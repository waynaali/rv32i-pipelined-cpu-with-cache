# RV32I Pipelined CPU with Non-Blocking Caches

A 5-stage pipelined RISC-V RV32I processor with non-blocking instruction and data caches connected through an AXI4-compatible memory subsystem, implemented in SystemVerilog and verified using Vivado XSim.

## Overview

This project implements a classic in-order 5-stage RISC-V pipeline:

**Fetch → Decode → Execute → Memory → Writeback**

The processor supports the complete RV32I base integer instruction set and integrates separate instruction and data caches. Both caches support **hit-under-miss** operation, allowing cache hits to be serviced even while another cache line refill is in progress.

The data cache additionally supports **early forwarding**, returning the requested word directly from the refill bus before the entire cache line has completed loading.

---

## Features

### Processor Core

* RV32I Base Integer ISA
* 5-stage pipelined architecture

  * IF (Instruction Fetch)
  * ID (Instruction Decode)
  * EX (Execute)
  * MEM (Memory Access)
  * WB (Write Back)
* Register file with writeback support
* ALU supporting arithmetic, logical, comparison, and shift operations

### Hazard Handling

* Full forwarding network

  * EX/MEM → EX
  * MEM/WB → EX
* Load-use hazard detection and pipeline stalls
* Branch and jump flushing
* Static branch handling (no branch prediction)

### Cache System

* Separate instruction and data caches
* Direct-mapped organization
* Non-blocking operation
* Hit-under-miss support
* Burst line refill mechanism
* Early-forwarding during cache refill

### Data Cache Features

* Write-through policy
* Write-allocate on misses
* Byte, halfword, and word accesses
* Store merging during refill
* Early-forward path for pending load requests

### Memory Interface

* Burst-capable cache-to-memory interface
* AXI4 master adapter support
* Multi-beat line refill transactions
* Single-beat write-through transactions

### Verification

* Self-checking testbenches
* Vivado XSim simulation environment
* ISA-level instruction validation
* Cache functionality verification
* Pipeline hazard testing
* Memory subsystem testing

---

## Architecture

```text
        ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
        │  IF  │──▶│  ID  │──▶│  EX  │──▶│ MEM  │──▶│  WB  │
        └──┬───┘   └──────┘   └──┬───┘   └──┬───┘   └──────┘
           │                     │           │
           ▼                     ▼           ▼
       ┌────────┐           Forwarding   ┌────────┐
       │ I-Cache│                        │ D-Cache│
       └───┬────┘                        └───┬────┘
           │                                  │
           └───────────────┬──────────────────┘
                           ▼
                   AXI4 Interconnect
                           ▼
                         Memory
```

### Pipeline Operation

| Stage | Function                                      |
| ----- | --------------------------------------------- |
| IF    | Fetch instruction from I-cache                |
| ID    | Decode instruction and read register operands |
| EX    | Execute ALU operations and branch resolution  |
| MEM   | Load/store access through D-cache             |
| WB    | Write results back to register file           |

---

## Hazard Handling

### Data Hazards

Most Read-After-Write (RAW) hazards are resolved through forwarding:

```text
EX/MEM ─────► EX
MEM/WB ─────► EX
```

### Load-Use Hazards

When an instruction immediately depends on a load result, the pipeline inserts a stall because the loaded value becomes available only in the MEM stage.

Example:

```assembly
lw   x5, 0(x1)
add  x6, x5, x2   # requires stall
```

### Control Hazards

Branches and jumps are resolved in the execute stage.

The processor uses:

* No branch prediction
* Pipeline flush on taken branches
* Correct-path refetch after branch resolution

---

## Cache Configuration

### Instruction Cache

| Parameter     | Value         |
| ------------- | ------------- |
| Organization  | Direct-Mapped |
| Lines         | 64            |
| Line Size     | 16 Bytes      |
| Words/Line    | 4             |
| Capacity      | 1 KB          |
| Tag Bits      | 22            |
| Index Bits    | 6             |
| Access Type   | Read Only     |
| Miss Handling | Non-Blocking  |

Address format:

```text
31          10 9      4 3    2 1 0
+-------------+--------+------+---+
|     Tag     | Index  | Word |00 |
+-------------+--------+------+---+
```

---

### Data Cache

| Parameter         | Value          |
| ----------------- | -------------- |
| Organization      | Direct-Mapped  |
| Lines             | 16             |
| Line Size         | 16 Bytes       |
| Words/Line        | 4              |
| Capacity          | 256 B          |
| Tag Bits          | 24             |
| Index Bits        | 4              |
| Access Type       | Read / Write   |
| Write Policy      | Write-Through  |
| Allocation Policy | Write-Allocate |
| Miss Handling     | Non-Blocking   |

Address format:

```text
31           8 7      4 3    2 1   0
+-------------+--------+------+-----+
|     Tag     | Index  | Word |Byte |
+-------------+--------+------+-----+
```

---

## Non-Blocking Cache Behavior

### Hit-Under-Miss

A cache miss does not prevent other accesses from being serviced.

Example:

```text
Miss: Line A being refilled
Hit : Line B requested

Result:
Line B is served immediately.
```

### Early Forwarding

When the requested word arrives during a refill:

```text
Memory → Refill Bus → CPU
```

The word is forwarded directly without waiting for the remainder of the cache line.

---

## Data Cache Write Policy

### Write Hit

1. Update cache line
2. Issue write-through transaction
3. Wait for memory acknowledgement

```text
CPU Store
    │
    ▼
 D-Cache Update
    │
    ▼
 Memory Write
```

### Write Miss

1. Allocate line
2. Refill cache line
3. Merge pending store
4. Write-through updated data

```text
Store Miss
     │
     ▼
Line Refill
     │
     ▼
Store Merge
     │
     ▼
Write-Through
```

---

## Memory Interface

Caches communicate using a burst-oriented memory interface.

| Signal        | Direction      | Description         |
| ------------- | -------------- | ------------------- |
| mem_req       | Cache → Memory | Request transaction |
| mem_addr      | Cache → Memory | Address             |
| mem_burst_len | Cache → Memory | Burst length        |
| mem_we        | Cache → Memory | Write enable        |
| mem_be        | Cache → Memory | Byte enables        |
| mem_wdata     | Cache → Memory | Write data          |
| mem_ready     | Memory → Cache | Request accepted    |
| mem_rdata     | Memory → Cache | Read data beat      |
| mem_rvalid    | Memory → Cache | Data valid          |
| mem_rlast     | Memory → Cache | Final burst beat    |

---

## Repository Structure

```text
rv32i-pipelined-cpu-with-cache/
│
├── rtl/
│   ├── pipeline/
│   ├── cache/
│   ├── axi/
│   └── memory/
│
├── tb/
│   ├── cpu_tb.sv
│   ├── icache_tb.sv
│   ├── dcache_tb.sv
│   └── memory_tb.sv
│
├── sim/
│   ├── scripts/
│   └── waveforms/
│
├── sw/
│   ├── isa_tests/
│   ├── cache_tests/
│   └── benchmarks/
│
└── README.md
```

---

## Verification

The processor has been verified using self-checking testbenches in Vivado XSim.

### Tested Areas

#### ISA Validation

* Arithmetic instructions
* Logical instructions
* Shift operations
* Branches and jumps
* Loads and stores

#### Pipeline Verification

* RAW hazard forwarding
* Load-use stalls
* Branch flushing
* Pipeline recovery

#### Cache Verification

* Cache hits and misses
* Hit-under-miss behavior
* Early forwarding
* Write-through operation
* Write-allocate handling
* Line refills

#### Memory Interface

* Burst reads
* Burst writes
* AXI4 adapter correctness
* Transaction ordering

---

## Current Status

### Completed

* [x] RV32I Processor Core
* [x] 5-Stage Pipeline
* [x] Forwarding Network
* [x] Hazard Detection Unit
* [x] Non-Blocking I-Cache
* [x] Non-Blocking D-Cache
* [x] Burst Memory Interface
* [x] AXI4 Master Adapter
* [x] Self-Checking Testbenches

### Planned Enhancements

* [ ] Dynamic Branch Prediction
* [ ] Set-Associative Cache Designs
* [ ] Exception Handling
* [ ] Interrupt Support
* [ ] CSR Instructions
* [ ] FPGA Synthesis
* [ ] FPGA Board Validation

---

## Tools Used

* SystemVerilog
* Vivado XSim
* AXI4 Protocol
* RISC-V RV32I ISA
