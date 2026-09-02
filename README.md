# AXI-FIR Filter 

---

## 1. Project Description
A **pipelined 32-tap FIR (Finite Impulse Response) filter** implemented in SystemVerilog, wrapped with an **AXI4 interface** for use as a memory-mapped, streaming-capable IP block (target flow: Xilinx/AMD Vivado, eventual PS/DMA integration on an Artix-7 or Zynq-class part).

**Design intent:** demonstrate RTL pipelining, MAC-unit design, and AXI protocol implementation as an interview-ready project for digital/VLSI ASIC-FPGA roles (ARM, AMD, Qualcomm, NXP, Nvidia, Cisco Hardware track).

---

## 2. Architecture

```
AXI4-Lite (control) ──┐
                       ├──> FIR.sv (top) ──> MAC.sv (x32, pipelined)
AXI4-Stream (data) ────┘
```

| Module | File | Role | Status |
|---|---|---|---|
| `MAC.sv` | `src/MAC.sv` | Single multiply-accumulate unit, pipelined | ✅ Verified (unit-level, `MAC_TB.sv`) |
| `FIR.sv` | `src/FIR.sv` | Top-level 32-tap FIR, instantiates 32x MAC | ✅ Verified (`FIR_tb.sv`) |
| `AXI_Lite.sv` | `src/AXI_Lite.sv` | AXI4-Lite control register interface | 🔧   **Last in-scope task** |
| `AXI_Stream.sv` | `src/AXI_Stream.sv`| Streaming data in/out with backpressure (TVALID/TREADY) | 🔧   **next in-scope task** |

**Design parameters:**
- Taps: **32**
- Coefficient/data width: (fill in — e.g. 16-bit signed, Q-format if fixed-point)
- Pipeline latency: **`FIR_LATENCY = 2 + $clog2(TAPS) = 7` cycles** (confirmed via testbench cycle-counting against a golden/reference model — this is the authoritative figure)
- Target part: `xc7a200tfbg676-2` (Artix-7, AC701 board part)

---

## 3. Confirmed Working (as of Sep 2, 2026)
- ✅ MAC unit functional correctness (MAC_TB.sv)
- ✅ FIR top-level functional correctness (FIR_tb.sv) 
- ✅ `FIR_LATENCY = 7` confirmed as the correct value via formula `2 + $clog2(32)`
- ✅ Vivado/XSim used as primary sim environment



## 4. In Progress / Next Steps
1. **AXI4-Stream** (current focus) — implement TVALID/TREADY backpressure handshake feeding the FIR pipeline.
2. **AXI4-Lite** control interface  — deprioritized 
3. Final AXI IP packaging (`ipx::package_project` flow), Vivado Block Design integration, PS/DMA integration .

---

## 5. Toolchain / Environment
- **OS:** Fedora Linux 43, Vivado 2026.1 (64-bit), XSim simulator
- **Part:** xc7a200tfbg676-2 / board part `xilinx.com:ac701:part0:1.4`
- **Secondary sim:** Icarus Verilog (for cross-checking against XSim)
- **Key Vivado gotchas already documented:**
  - `xvlog --incr` can silently reuse stale elaboration artifacts → run `reset_simulation -mode behavioral` before re-running after source changes.
  - `xsim.simulate.runtime` must be explicitly set to `-all` per new project (does not carry over on project recreation).
  - VCD/waveform output subdirectories must be pre-created (`file mkdir results`) before dump.

---
