// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original algorithm: MAME project (deco56.cpp (74 variant) + init_nslasher (deco32.cpp)).
    RTL port: Umberto Parisi (rmonic79)
*/

//
// deco74_ioctl_decrypt.sv
// Gemello di deco56_ioctl_decrypt.sv per le TILE DECO74 di Night Slashers
// (regione tiles2 = mbh-01.9c). COMBINATORIO PURO, remap inverso INLINE, zero
// buffer, zero FSM, zero ioctl_wait. hps_io fa il pacing naturale.
//
// DIFFERENZE vs deco56:
//   - tabelle deco74 (inv_address/xor/swap) caricate da deco74_*.hex.
//   - xor_masks[16] e swap_patterns[8][16] sono IDENTICHE a deco56
//     (verificato: deco74_tables.json == decocrpt.cpp deco56) -> funzioni riusate.
//   - BITPLANE REORDER INLINE (parametro REORDER): swap dei blocchi da 512KB
//     [0x080000,0x100000) <-> [0x100000,0x180000) DENTRO la ROM 2MB, come fa
//     init_nslasher (deco32.cpp:1354-1356) PRIMA del deco_decrypt. In word units
//     (0x800 word/blocco) = blk_hi [0x80,0x100) <-> [0x100,0x180).
//
// REMAP (deco74): la word FISICA p va al LOGICO i_lo = inv_addr[p_lo].
// DATA DECRYPT: dec = bitswap(swap[i_lo], raw_be ^ xor_mask(xor[p_lo])).
//   xor su FISICO (p_lo), swap su LOGICO (i_lo) — come deco_decrypt MAME.
// Verificato bit-exact (DIFF=0 vs work/ns_spr/mame_tiles2.bin) in
//   work/tiles2_check/verify_deco74_hex.py (legge gli .hex generati).
//
// Opera su WORD 16-bit BIG-endian (byte-swap in ingresso, come deco56).
//

module deco74_ioctl_decrypt #(
	parameter [26:0] T_BASE  = 27'h630000,   // base ioctl regione tiles2 (FG1/ba1)
	parameter [26:0] T_END   = 27'h830000,   // fine  ioctl regione tiles2
	parameter        REORDER = 1             // 1 = bitplane reorder 512KB inline
)
(
	input  wire        clk,

	input  wire [26:0] ioctl_addr_in,
	input  wire [15:0] ioctl_dout_in,
	input  wire        ioctl_wr_in,
	input  wire [15:0] ioctl_index_in,
	input  wire        ioctl_download_in,

	output wire [26:0] ioctl_addr_out,   // logico (scattered) nel range tile
	output wire [15:0] ioctl_dout_out,   // decrittato nel range tile
	output wire        ioctl_wr_out,
	output wire [15:0] ioctl_index_out,
	output wire        ioctl_download_out,

	// TIMING 2026-08-10: esposto per il mux a PRIORITA' del download (Template.sv).
	output wire        remap_out
);

	wire is_rom_dl = ioctl_download_in & (ioctl_index_in == 16'd0);

	wire is_remapped = is_rom_dl && (ioctl_addr_in >= T_BASE) && (ioctl_addr_in < T_END);

	wire [25:0] wrel   = (ioctl_addr_in - T_BASE) >> 1;   // word index fisico relativo
	wire [10:0] p_lo   = wrel[10:0];
	wire [14:0] blk_hi = wrel[25:11];

	// ── Tabelle deco74 (ROM combinatorie async, solo download) ──────────────
	// TIMING 2026-08-10: vedi deco56. swap[inv[p]] precomposta in swap_of_p ->
	// le due ROM async da 2048 voci non sono piu' IN SERIE. Zero latenza aggiunta.
	(* ramstyle = "logic" *) reg [10:0] inv_addr_table [0:2047];
	(* ramstyle = "logic" *) reg [3:0]  xor_table      [0:2047];
	(* ramstyle = "logic" *) reg [2:0]  swap_of_p_table[0:2047];
	initial $readmemh("deco74_inv_address_table.hex", inv_addr_table);
	initial $readmemh("deco74_xor_table.hex",         xor_table);
	initial $readmemh("deco74_swap_of_p.hex",         swap_of_p_table);

	// la word FISICA p va al LOGICO i_lo = inv_addr[p_lo]. xor su p (fisico),
	// swap su i_lo (logico).
	wire [10:0] i_lo = inv_addr_table[p_lo];

	// ── xor_masks[16] (decocrpt.cpp:49) — IDENTICHE a deco56 ─────────────────
	function [15:0] xor_mask(input [3:0] idx);
		case (idx)
			4'h0: xor_mask = 16'hd556; 4'h1: xor_mask = 16'h73cb;
			4'h2: xor_mask = 16'h2963; 4'h3: xor_mask = 16'h4b9a;
			4'h4: xor_mask = 16'hb3bc; 4'h5: xor_mask = 16'hbc73;
			4'h6: xor_mask = 16'hcbc9; 4'h7: xor_mask = 16'haeb5;
			4'h8: xor_mask = 16'h1e6d; 4'h9: xor_mask = 16'hd5b5;
			4'ha: xor_mask = 16'he676; 4'hb: xor_mask = 16'h5cc5;
			4'hc: xor_mask = 16'h395a; 4'hd: xor_mask = 16'hdaae;
			4'he: xor_mask = 16'h2629; 4'hf: xor_mask = 16'he59e;
		endcase
	endfunction

	// swap_patterns[8][16] (decocrpt.cpp:55), out[15-k]=in[pat[k]] — IDENTICHE a deco56
	function [15:0] bitswap_apply(input [2:0] pat_idx, input [15:0] d);
		case (pat_idx)
			3'd0: bitswap_apply = {d[15],d[ 8],d[ 9],d[12],d[10],d[13],d[11],d[14], d[ 2],d[ 7],d[ 4],d[ 3],d[ 1],d[ 5],d[ 6],d[ 0]};
			3'd1: bitswap_apply = {d[12],d[10],d[11],d[ 9],d[ 8],d[15],d[14],d[13], d[ 6],d[ 0],d[ 3],d[ 5],d[ 7],d[ 4],d[ 2],d[ 1]};
			3'd2: bitswap_apply = {d[ 8],d[12],d[11],d[ 9],d[13],d[14],d[15],d[10], d[ 4],d[ 6],d[ 5],d[ 0],d[ 3],d[ 1],d[ 7],d[ 2]};
			3'd3: bitswap_apply = {d[ 8],d[ 9],d[10],d[13],d[11],d[15],d[14],d[12], d[ 5],d[ 4],d[ 0],d[ 7],d[ 2],d[ 6],d[ 1],d[ 3]};
			3'd4: bitswap_apply = {d[12],d[13],d[14],d[15],d[ 8],d[ 9],d[10],d[11], d[ 1],d[ 5],d[ 0],d[ 3],d[ 2],d[ 7],d[ 6],d[ 4]};
			3'd5: bitswap_apply = {d[14],d[15],d[13],d[ 8],d[12],d[10],d[11],d[ 9], d[ 1],d[ 2],d[ 7],d[ 6],d[ 4],d[ 3],d[ 0],d[ 5]};
			3'd6: bitswap_apply = {d[13],d[14],d[10],d[11],d[ 9],d[ 8],d[12],d[15], d[ 3],d[ 1],d[ 7],d[ 4],d[ 5],d[ 0],d[ 2],d[ 6]};
			3'd7: bitswap_apply = {d[ 9],d[ 8],d[14],d[10],d[15],d[11],d[13],d[12], d[ 6],d[ 0],d[ 5],d[ 2],d[ 4],d[ 1],d[ 3],d[ 7]};
		endcase
	endfunction

	// BYTE-SWAP ingresso: hps_io WIDE da' word LITTLE-endian, il decode DECO74
	// opera su BIG-endian (verificato vs golden tiles2).
	wire [15:0] din_be = {ioctl_dout_in[7:0], ioctl_dout_in[15:8]};

	// dato decrittato della word fisica corrente: xor su p (fisico), swap su i_lo (logico)
	wire [15:0] dec_phys = bitswap_apply(swap_of_p_table[p_lo], din_be ^ xor_mask(xor_table[p_lo]));

	// ── BITPLANE REORDER (512KB block swap) ─────────────────────────────────
	// init_nslasher: swap [0x080000,0x100000) <-> [0x100000,0x180000) DENTRO la ROM.
	// In word/blocco (0x800 word): blk_hi [0x80,0x100) <-> [0x100,0x180).
	wire [14:0] blk_hi_log =
		!REORDER                              ? blk_hi :
		(blk_hi >= 15'h080 && blk_hi < 15'h100) ? (blk_hi + 15'h080) :
		(blk_hi >= 15'h100 && blk_hi < 15'h180) ? (blk_hi - 15'h080) :
		                                          blk_hi;

	// indirizzo LOGICO: base + ((blk_hi_log<<11 | i_lo) << 1)
	wire [26:0] addr_logical = T_BASE + {{blk_hi_log, i_lo}, 1'b0};

	// ── Output COMBINATORIO (no registri) ────────────────────────────────────
	assign ioctl_addr_out     = is_remapped ? addr_logical : ioctl_addr_in;
	assign ioctl_dout_out     = is_remapped ? dec_phys     : ioctl_dout_in;
	assign ioctl_wr_out       = ioctl_wr_in;
	assign ioctl_index_out    = ioctl_index_in;
	assign ioctl_download_out = ioctl_download_in;
	assign remap_out          = is_remapped;

endmodule
