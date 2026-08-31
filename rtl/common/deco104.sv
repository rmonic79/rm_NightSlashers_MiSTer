// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original algorithm: MAME project (deco104.cpp).
    RTL port: Umberto Parisi (rmonic79)
*/

//
// deco104.sv
// Data East 104 protection + IO device — wrapper attorno a deco146_base.
//
// Parametri DECO104 (deco146.cpp:42-46):
//   XOR_PORT         = 0x42
//   MASK_PORT        = 0xee
//   SOUND_PORT       = 0xa8
//   BANK_SWAP_ADDR   = 0x66
//   MAGIC_READ_XOR   = 0x2a4
//   CS_REGION        = 0xc (non usato per i giochi semplici)
//
// Boogie Wings specifico (boogwing.cpp:775-776):
//   set_interface_scramble_reverse()      -> ADDR_SCRAMBLE = 1 (reversed)
//   set_use_magic_read_address_xor(true)  -> MAGIC_XOR_ENABLED = 1
//
// Port table: rtl/common/deco104_offset.hex + deco104_mapping.hex + deco104_flags.hex
// (1024 entry, estratte da reference/mame/deco104.cpp via extract_deco104_table.py).
//

module deco104 #(
    parameter integer SS_RB0_IDX = 0,
    parameter integer SS_RB1_IDX = 0,
    // Per-game protection config. Defaults = Boogie Wings; Night Slashers
    // overrides ADDR_SCRAMBLE to interleave (set_interface_scramble_interleave).
    parameter [1:0]   ADDR_SCRAMBLE_P      = 2'd1,        // 1=reversed(BW) 2=interleave(NS)
    parameter [15:0]  MAGIC_READ_ADDR_XOR_P= 16'h02a4,
    parameter [0:0]   MAGIC_XOR_ENABLED_P  = 1'b1
)
(
    input  wire        clk,
    input  wire        reset,

    // CPU bus (16-bit) — cpu_addr e' l'offset relativo a 0x24E000 (12-bit)
    input  wire [11:0] cpu_addr,
    input  wire        cpu_cs,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire [15:0] cpu_wdata,
    input  wire  [1:0] cpu_dsn,
    output wire [15:0] cpu_rdata,

    // IO ports
    input  wire [15:0] port_a,        // INPUTS  (p1+p2)
    input  wire [15:0] port_b,        // SYSTEM  (coin+start+service+vblank)
    input  wire [15:0] port_c,        // DSW

    // Sound latch
    output wire  [7:0] soundlatch_data,
    output wire        soundlatch_irq,
    input  wire        soundlatch_rd,
    output wire  [7:0] soundlatch_dout,

    // Savestate: reg protezione (69 bit, no soundlatch_irq) + rambank0/1 via ssbus
    input  wire [68:0] dc_ss_in,
    output wire [68:0] dc_ss_out,
    input  wire        dc_ss_wr,
    ssbus_if.slave     ss_rb0,
    ssbus_if.slave     ss_rb1
);

wire [7:0] sl_data;
wire       sl_irq;

deco146_base #(
    .XOR_PORT             (8'h42),
    .MASK_PORT            (8'hee),
    .SOUND_PORT           (8'ha8),
    .BANK_SWAP_READ_ADDR  (8'h66),
    .MAGIC_READ_ADDR_XOR  (MAGIC_READ_ADDR_XOR_P),
    .MAGIC_XOR_ENABLED    (MAGIC_XOR_ENABLED_P),
    .ADDR_SCRAMBLE        (ADDR_SCRAMBLE_P),   // BW=1 reversed, NS=2 interleave
    .TABLE_OFFSET_HEX     ("deco104_offset.hex"),
    .TABLE_MAPPING_HEX    ("deco104_mapping.hex"),
    .TABLE_FLAGS_HEX      ("deco104_flags.hex"),
    .SS_RB0_IDX           (SS_RB0_IDX),
    .SS_RB1_IDX           (SS_RB1_IDX)
) u_base (
    .clk             (clk),
    .reset           (reset),
    .cpu_addr        (cpu_addr),
    .cpu_cs          (cpu_cs),
    .cpu_rd          (cpu_rd),
    .cpu_wr          (cpu_wr),
    .cpu_wdata       (cpu_wdata),
    .cpu_dsn         (cpu_dsn),
    .cpu_rdata       (cpu_rdata),
    .port_a          (port_a),
    .port_b          (port_b),
    .port_c          (port_c),
    .soundlatch_data (sl_data),
    .soundlatch_irq  (sl_irq),
    .soundlatch_rd   (soundlatch_rd),
    .soundlatch_dout (soundlatch_dout),
    .dc_ss_in        (dc_ss_in),
    .dc_ss_out       (dc_ss_out),
    .dc_ss_wr        (dc_ss_wr),
    .ss_rb0          (ss_rb0),
    .ss_rb1          (ss_rb1)
);

assign soundlatch_data = sl_data;
assign soundlatch_irq  = sl_irq;

endmodule
