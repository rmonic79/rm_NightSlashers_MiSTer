/*  Night Slashers (Data East DECO 156) — ARM main CPU wrapper.

    Wraps the Amber 'amber23' ARMv2a core (OpenCores, with our reset +
    cache-off patches) and presents a simple arcade-style 32-bit bus to the
    Night Slashers top level, replacing the FX68K/68000 path that the core
    inherited from Boogie Wings.

    The DECO 156 is a 26-bit ARM2/3-class CPU at 28MHz/4 = 7.0805 MHz. Here it
    is paced by a clock-enable (ce_cpu) on the system clock, MiSTer-style: the
    Amber core advances only on ce ticks and is held otherwise via its native
    i_system_rdy stall input — so a low ce, OR a not-ready bus, both stall the
    pipeline cleanly without ever resetting it (needed for pause/savestate).

    Bus model (cache is disabled in the core, so every access is a single
    32-bit Wishbone transfer — no bursts):
      - bus_req      : 1 while the CPU wants a transfer
      - bus_we       : 1 = write, 0 = read
      - bus_addr     : 26-bit byte address (ARM addr[25:0]); word-aligned
      - bus_be       : 4-bit byte enables (which of the 4 bytes are active)
      - bus_wdata    : 32-bit write data
      - bus_rdata    : 32-bit read data (must be valid when bus_ready=1)
      - bus_ready    : target asserts to complete the transfer (= !wait)

    The top level decodes bus_addr and drives bus_ready/bus_rdata; on a write
    to the vblank-ack register (0x140000) it must also de-assert i_irq, since
    the 156 IRQ is level-triggered and acked by that write (Amber does not
    auto-clear it).
*/

module arm_cpu_wrapper
(
    input  wire        clk,            // system clock
    input  wire        ce_cpu,         // clock-enable: 7.0805 MHz tick
    input  wire        reset,          // active-high synchronous reset

    // Interrupts (level, active high). DECO156 uses a single vblank IRQ.
    input  wire        i_irq,          // vblank IRQ (held until ack write)
    input  wire        i_firq,         // unused on nslasher; tie 0

    // Arcade bus
    output wire [25:0] bus_addr,       // byte address, ARM addr[25:0]
    output wire        bus_req,        // transfer request
    output wire        bus_we,         // 1=write 0=read
    output wire [3:0]  bus_be,         // byte enables
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_ready,      // target ready (completes transfer)

    // ── Savestate scan (approccio B: estrazione/iniezione diretta reg fisici) ──
    input  wire        ss_load,        // 1: carica reg fisici da ss_wdata (a CPU ferma, dopo reset)
    input  wire [4:0]  ss_idx,         // indice word (0..20)
    input  wire [31:0] ss_wdata,
    output wire [31:0] ss_rdata,       // word selezionata (per il save)

    // 1 = CPU a confine istruzione PULITO (EXECUTE che resta EXECUTE). Il top parcheggia
    // la CPU qui prima dello snapshot savestate: garantisce che i 21 registri siano completi
    // (niente istruzione multi-ciclo LDM/STR/MEM_WAIT in volo). PROVATO in sim.
    output wire        cpu_at_boundary
);

    // ------------------------------------------------------------------
    // Wishbone signals between Amber and this wrapper.
    // ------------------------------------------------------------------
    wire [31:0] wb_adr;
    wire [3:0]  wb_sel;
    wire        wb_we;
    wire [31:0] wb_dat_w;   // core -> bus
    wire        wb_cyc;
    wire        wb_stb;

    wire        wb_ack;     // wrapper -> core (combinational)
    wire [31:0] wb_dat_r;   // bus -> core

    // ------------------------------------------------------------------
    // Bus request / handshake.
    //
    // A Wishbone access is in flight while (wb_cyc & wb_stb). We forward it to
    // the arcade bus, but ONLY actually start it on a ce_cpu tick or while it
    // is already running — this is what paces the CPU to 7.08 MHz. The arcade
    // target may take any number of cycles; it asserts bus_ready when the data
    // is valid (read) or the write is accepted. wb_ack is just that ready,
    // qualified by an in-flight access. This is latency-tolerant: bus_ready
    // can arrive 0, 1 or many cycles after the request.
    //
    // Pacing rule: hold the request off until a ce tick has "armed" it, then
    // keep it asserted until the access completes. running_r tracks that.
    // ------------------------------------------------------------------
    // Verified-correct handshake (tb_arm_ldm_direct, 7/8): Amber runs LDM/STM
    // correctly when it sees a CLASSIC Wishbone face (transparent ack, data with
    // ack) and pacing lives ONLY in i_system_rdy = ce_cpu. The ack must NOT be
    // gated by ce. Amber's fetch_stall freezes all pipeline stages together, so
    // bursts stay aligned across ce gaps.
    wire access = wb_cyc & wb_stb;        // Amber wants a transfer

    wire bus_ok     = ~access | bus_ready;        // no access, or bus completed it
    wire system_rdy = ce_cpu & bus_ok;            // pace + wait-state (here only)

    assign wb_ack   = access & bus_ready;         // TRANSPARENT ack (ungated by ce)
    assign wb_dat_r = bus_rdata;

    assign bus_addr  = wb_adr[25:0];
    assign bus_req   = access;                    // request whenever Amber wants it
    assign bus_we    = wb_we;
    assign bus_be    = wb_sel;
    assign bus_wdata = wb_dat_w;

    // ------------------------------------------------------------------
    // Amber 'amber23' core (patched: i_reset added, CP15 removed, cache off).
    // ------------------------------------------------------------------
    a23_core u_arm (
        .i_clk          ( clk        ),
        .i_reset        ( reset      ),
        .i_irq          ( i_irq      ),
        .i_firq         ( i_firq     ),
        .i_system_rdy   ( system_rdy ),

        .o_wb_adr       ( wb_adr     ),
        .o_wb_sel       ( wb_sel     ),
        .o_wb_we        ( wb_we      ),
        .i_wb_dat       ( wb_dat_r   ),
        .o_wb_dat       ( wb_dat_w   ),
        .o_wb_cyc       ( wb_cyc     ),
        .o_wb_stb       ( wb_stb     ),
        .i_wb_ack       ( wb_ack     ),
        .i_wb_err       ( 1'b0       ),

        // ── Savestate scan (approccio B) ──
        .i_ss_load      ( ss_load    ),
        .i_ss_idx       ( ss_idx     ),
        .i_ss_wdata     ( ss_wdata   ),
        .o_ss_rdata     ( ss_rdata   ),
        .o_exec_boundary( cpu_at_boundary )
    );

endmodule
