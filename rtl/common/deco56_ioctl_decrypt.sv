// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original algorithm: MAME project (deco56.cpp + init_nslasher (deco32.cpp)).
    RTL port: Umberto Parisi (rmonic79)
*/

//
// deco56_ioctl_decrypt.sv  (NIGHT SLASHERS — tiles1 = mbh-00)
// Wrapper trasparente sul flusso ioctl che decritta le TILE DECO56 di Night
// Slashers DURANTE IL DOWNLOAD. COMBINATORIO PURO, remap inverso dell'indirizzo
// INLINE, zero buffer, zero FSM, zero ioctl_wait. ioctl_wr passthrough -> hps_io
// fa il pacing naturale. Il bridge scrive a indirizzi logici scattered 1:1.
//
// REMAP (deco56): la word FISICA all'indice p va scritta all'indice LOGICO
//   i = (p & ~0x7FF) | inv_addr[p & 0x7FF].  inv_addr e' l'inversa di address_table.
// DATA DECRYPT: dec = bitswap(swap[i_lo], raw_be ^ xor_mask[xor[p_lo]]).
//   xor su FISICO (p_lo), swap su LOGICO (i_lo) — come deco56_decrypt_gfx MAME.
// BITPLANE REORDER (init_nslasher, solo BG1): swap blocchi 512KB [0x80,0x100)<->
//   [0x100,0x180) word PRIMA del decode. Le sezioni text ricevono gia' la sotto-
//   regione giusta dall'MRA -> reorder no-op.
//
// 3 sezioni NS (verificate bit-exact vs work/ns_spr/mame_tiles1.bin):
//   text_lo @0x110000 = mbh-00[0:0x10000]       -> BRAM tile1_lo
//   text_hi @0x120000 = mbh-00[0x80000:0x90000] -> BRAM tile1_hi
//   BG1     @0x130000 = mbh-00 full 2MB         -> ba3 (reorder)
//
// Opera su WORD 16-bit BIG-endian (byte-swap in ingresso). p_lo = wrel[10:0].
//

module deco56_ioctl_decrypt
(
	input  wire        clk,

	input  wire [26:0] ioctl_addr_in,
	input  wire [15:0] ioctl_dout_in,
	input  wire        ioctl_wr_in,
	input  wire [15:0] ioctl_index_in,
	input  wire        ioctl_download_in,

	output wire [26:0] ioctl_addr_out,   // logico (scattered) nei range tile
	output wire [15:0] ioctl_dout_out,   // decrittato nei range tile
	output wire        ioctl_wr_out,
	output wire [15:0] ioctl_index_out,
	output wire        ioctl_download_out,

	// TIMING 2026-08-10: esposto per il mux a PRIORITA' del download (Template.sv),
	// che sostituisce la cascata in serie de156->deco56->deco74->deco74.
	output wire        remap_out
);

	// ── Sezioni tile1 NIGHT SLASHERS (MRA byte address). tiles1 = mbh-00, deco56.
	// 3 destinazioni (verificato bit-exact vs work/ns_spr/mame_tiles1.bin):
	//   text_lo @0x110000 (64KB)  = mbh-00 raw[0:0x10000]        -> BRAM tile1_lo (no reorder)
	//   text_hi @0x120000 (64KB)  = mbh-00 raw[0x80000:0x90000]  -> BRAM tile1_hi (no reorder)
	//   BG1     @0x130000 (2MB)   = mbh-00 raw full              -> ba3 (reorder 512KB)
	// Il reorder (init_nslasher: swap blocchi [0x80,0x100)<->[0x100,0x180) word) serve SOLO
	// per BG1 (mbh-00 full): le sezioni text ricevono gia' la sotto-regione giusta dall'MRA.
	localparam [26:0] TXL_BASE  = 27'h110000;  // text lo  -> BRAM tile1_lo
	localparam [26:0] TXL_END   = 27'h120000;
	localparam [26:0] TXH_BASE  = 27'h120000;  // text hi  -> BRAM tile1_hi
	localparam [26:0] TXH_END   = 27'h130000;
	localparam [26:0] BG1_BASE  = 27'h130000;  // BG1 (chip0.pf2) -> ba3, reorder
	localparam [26:0] BG1_END   = 27'h330000;

	wire is_rom_dl = ioctl_download_in & (ioctl_index_in == 16'd0);

	wire in_txl = is_rom_dl && (ioctl_addr_in >= TXL_BASE) && (ioctl_addr_in < TXL_END);
	wire in_txh = is_rom_dl && (ioctl_addr_in >= TXH_BASE) && (ioctl_addr_in < TXH_END);
	wire in_bg1 = is_rom_dl && (ioctl_addr_in >= BG1_BASE) && (ioctl_addr_in < BG1_END);

	wire is_remapped = in_txl | in_txh | in_bg1;
	wire remap_only  = 1'b0;                    // NS: nessuna regione remap_only (no mbd-02 P4)
	wire do_reorder  = in_bg1;                  // reorder 512KB solo per BG1 (mbh-00 full)

	wire [26:0] cur_base = in_txl ? TXL_BASE :
	                       in_txh ? TXH_BASE :
	                       in_bg1 ? BG1_BASE : 27'd0;

	wire [25:0] wrel    = (ioctl_addr_in - cur_base) >> 1;   // word index fisico relativo
	wire [10:0] p_lo    = wrel[10:0];
	wire [14:0] blk_hi  = wrel[25:11];

	// ── Tabelle (ROM combinatorie async, solo download) ─────────────────────
	// TIMING 2026-08-10: swap era letta come swap_table[i_lo] con i_lo a sua volta
	// uscita di inv_addr_table -> DUE ROM async da 2048 voci IN SERIE nel cammino
	// combinatorio del download. swap[inv[p]] e' funzione del solo p: precomposta
	// offline in swap_of_p (bit-identica per costruzione), le due letture ora sono
	// PARALLELE. Nessuna latenza aggiunta: l'uscita resta combinatoria.
	(* ramstyle = "logic" *) reg [10:0] inv_addr_table [0:2047];
	(* ramstyle = "logic" *) reg [3:0]  xor_table      [0:2047];
	(* ramstyle = "logic" *) reg [2:0]  swap_of_p_table[0:2047];
	initial $readmemh("deco56_inv_address_table.hex", inv_addr_table);
	initial $readmemh("deco56_xor_table.hex",         xor_table);
	initial $readmemh("deco56_swap_of_p.hex",         swap_of_p_table);

	// la word FISICA p va al LOGICO i_lo = inv_addr[p_lo]. decrypt: xi su p (fisico),
	// pat su i_lo (logico) — come lo script de56_decrypt.
	wire [10:0] i_lo = inv_addr_table[p_lo];

	// ── xor_masks[16] (decocrpt.cpp:49) ─────────────────────────────────────
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

	// swap_patterns[8][16] (decocrpt.cpp:55), out[15-k]=in[pat[k]]
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

	// BYTE-SWAP ingresso: hps_io WIDE da' le word LITTLE-endian, ma il decode
	// DECO56 (tabelle MAME) opera su word BIG-endian. Verificato sui dati reali
	// vs golden tiles1: BIG-endian = 1000/1000 match, LITTLE = 2/1000.
	// NB: il de102 (main) NON va swappato (verificato: main vuole LITTLE 1000/1000).
	wire [15:0] din_be = {ioctl_dout_in[7:0], ioctl_dout_in[15:8]};

	// dato decrittato della word fisica corrente: xi su p (fisico), pat su i_lo (logico)
	wire [15:0] dec_phys  = bitswap_apply(swap_of_p_table[p_lo], din_be ^ xor_mask(xor_table[p_lo]));
	wire [15:0] data_phys = dec_phys;          // NS: sempre decode completo (no remap_only)

	// ── BITPLANE REORDER (512KB block swap, solo BG1) ────────────────────────
	// init_nslasher: swap [0x080000,0x100000) <-> [0x100000,0x180000) DENTRO mbh-00,
	// PRIMA del deco_decrypt. In word/blocco (0x800 word): blk_hi [0x80,0x100)<->[0x100,0x180).
	// TIMING: le due condizioni sono esattamente "bit8=0 e bit7=1" e "bit8=1 e
	// bit7=0", e +0x080 / -0x080 su quei due casi sono lo SCAMBIO dei bit 8 e 7.
	// Quando i due bit sono uguali (0x000-0x07F e 0x180-0x1FF) l'espressione
	// originale lascia il valore com'e' — e lo scambio pure. La guardia
	// blk_hi[14:9]==0 rende l'equivalenza valida per OGNI valore, non solo per il
	// campo di BG1 (che per costruzione e' 0..0x1FF: 0x200000 byte = 0x100000
	// word -> wrel <= 0xFFFFF -> blk_hi <= 0x1FF). Verificata in modo esaustivo
	// su tutti i 32768 valori. Cosi' sparisce una catena di somma a 15 bit dal
	// mezzo del cammino combinatorio del download (~1,0 ns nel path misurato).
	wire hi_swap = do_reorder & (blk_hi[14:9] == 6'd0);
	wire [14:0] blk_hi_log = hi_swap
		? {blk_hi[14:9], blk_hi[7], blk_hi[8], blk_hi[6:0]}
		: blk_hi;

	// indirizzo LOGICO: base + ((blk_hi_log<<11 | i_lo) << 1). Il remap inv_addr e'
	// DENTRO il blocco 0x800 word; il reorder agisce sul blocco (solo BG1).
	wire [26:0] addr_logical = cur_base + {{blk_hi_log, i_lo}, 1'b0};

	// ── Output COMBINATORIO (no registri): ioctl_wait e dati allineati 0ck ->
	// hps_io si ferma in tempo, nessuna word in volo persa. I registri (rimossi)
	// sfasavano il pacing -> word perse in SDRAM ("mancano tile" prima del decoding).
	assign ioctl_addr_out     = is_remapped ? addr_logical : ioctl_addr_in;
	assign ioctl_dout_out     = is_remapped ? data_phys    : ioctl_dout_in;
	assign ioctl_wr_out       = ioctl_wr_in;
	assign ioctl_index_out    = ioctl_index_in;
	assign ioctl_download_out = ioctl_download_in;
	assign remap_out          = is_remapped;

endmodule
