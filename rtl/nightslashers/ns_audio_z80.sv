// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

//
// ns_audio_z80.sv — audio Night Slashers (set World): Z80 + YM2151 + 2x OKI.
//
// MAME deco32.cpp (autorevole):
//   Z80 @ 32.22/9 = 3.58 MHz (qui cen 96/27 = 3.556, -0.68%)
//   z80_sound_map: 0000-7FFF ROM, 8000-87FF RAM, A000-A001 YM2151,
//                  B000 OKI0, C000 OKI1, D000 soundlatch_r (DECO104)
//   IRQ0 = merger(soundlatch | ym_irq)  (:2380)
//   YM2151 @3.58, port_write -> sound_bankswitch: oki0.bank=CT1, oki1.bank=CT2
//   OKI0 @32.22/32=1.007 PIN7_HIGH (route 0.80) ; OKI1 @32.22/16=2.014 (0.10)
//   YM route 0.40.
//
// Struttura RIUSATA VERBATIM da boogwings_audio.sv (provata sul ferro):
//   gains OSD, ROM even/odd BRAM, FIFO soundlatch, busy-YM back-pressure,
//   bank via reg YM 0x1B (CT), jt51/jt6295, prefetch DDR OKI, mixer Q4.4.
// CPU: tv80s instrumentato auto_ss (VERBATIM TaitoF2 — sistema savestate rodato).
//

module ns_audio_z80 (
	input  wire        clk,             // clk_sys (96 MHz)
	input  wire        reset,
	input  wire        pause,           // paused_safe: congela i cen
	input  wire        fetch_rst,       // ss_reset: re-prime prefetch OKI (client bridge DDR)
	input  wire        ce_ym,           // 96/27 = 3.556 MHz (jt51 cen, e fase Z80)
	input  wire        ce_ym_p1,        // 96/54 (jt51 cen_p1)
	input  wire        ce_oki0,         // ~1.0 MHz
	input  wire        ce_oki1,         // ~2.0 MHz

	// Soundlatch dal DECO104
	input  wire [7:0]  soundlatch_data,
	input  wire        soundlatch_irq_pulse,

	// Download ROM Z80 (sndprg.17l, 64 KB @ ioctl 0x100000; usati i primi 32 KB)
	// ROM sonora CONDIVISA (ns_audio_rom nel top): qui solo indirizzo out e dati in.
	// Le due catene non girano mai insieme -> una sola copia da 64 KB. Latenza
	// identica a prima (read registrata dentro ns_audio_rom).
	output wire [14:0] rom_rd_addr,
	input  wire [7:0]  rom_even_rd,
	input  wire [7:0]  rom_odd_rd,

	// DDR3 sample ROM OKI (porte ddram rd5/rd6 del top)
	output wire [27:0] oki0_ddr_addr,
	output wire        oki0_ddr_req,
	input  wire [31:0] oki0_ddr_data,
	input  wire        oki0_ddr_ack,
	output wire [27:0] oki1_ddr_addr,
	output wire        oki1_ddr_req,
	input  wire [31:0] oki1_ddr_data,
	input  wire        oki1_ddr_ack,

	// OSD gain
	input  wire [3:0]  osd_sel_fm,
	input  wire [3:0]  osd_sel_oki0,
	input  wire [3:0]  osd_sel_oki1,

	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// ── Savestate: SOLO FILI PIATTI (compartimentalizzato: gli adaptor vivono
	// nel TOP come tutti gli altri; qui nessuna interfaccia, nessuna logica SS).
	// A SS spento: tutti gli *_ss_wr=0 e ram_ss_sel=0 -> tutto inerte.
	output wire [357:0]  z80_ss_out,
	input  wire [357:0]  z80_ss_in,
	input  wire          z80_ss_wr,
	output wire [2819:0] ym_ss_out,
	input  wire [2819:0] ym_ss_in,
	input  wire          ym_ss_wr,
	output wire [358:0]  oki0_ss_out,
	input  wire [358:0]  oki0_ss_in,
	input  wire          oki0_ss_wr,
	output wire [358:0]  oki1_ss_out,
	input  wire [358:0]  oki1_ss_in,
	input  wire          oki1_ss_wr,
	output wire [31:0]   bus_ss_out,
	input  wire [31:0]   bus_ss_load,
	input  wire          bus_ss_wr,
	// RAM 2KB: porta SS passante (mux BW-style dentro, sel=0 -> gioco intatto)
	input  wire          ram_ss_sel,
	input  wire          ram_ss_we,
	input  wire [10:0]   ram_ss_addr,
	input  wire [7:0]    ram_ss_wd,
	output wire [7:0]    ram_ss_rd
);

// ── Gain: Default = bilanciamento CONVALIDATO A SCHERMO dall'utente 2026-07-10
// (FM Default, OKI0 1000%, OKI1 1000% sul ferro = 0x06 / 0x0D*10 / 0x02*10).
// La voce OSD "MAME" resta ai pesi route MAME fedeli (ym 0.40, oki0 0.80,
// oki1 0.10 in Q4.4) per confronto.
localparam [9:0] DEF_GAIN_FM   = 10'h004;   // 0x06 al 75% (bilanciamento utente)
localparam [9:0] DEF_GAIN_OKI0 = 10'h0A8;   // x10.5 = il 75% di x14: e' la voce OSD su cui l'utente ha tarato a orecchio
localparam [9:0] DEF_GAIN_OKI1 = 10'h023;   // x2.1875 = idem (0x05 al 700%): 5*1792>>8 = 35. Rapporto OKI0/OKI1 = 6.4, il suo.
localparam [9:0] MAME_GAIN_FM   = 10'h006;
localparam [9:0] MAME_GAIN_OKI0 = 10'h00D;
localparam [9:0] MAME_GAIN_OKI1 = 10'h002;

function [11:0] osd_mul12_aud;
	input [3:0] sel;
	case (sel)
		4'd3:  osd_mul12_aud = 12'd64;
		4'd4:  osd_mul12_aud = 12'd128;
		4'd5:  osd_mul12_aud = 12'd192;
		4'd6:  osd_mul12_aud = 12'd256;
		4'd7:  osd_mul12_aud = 12'd320;
		4'd8:  osd_mul12_aud = 12'd384;
		4'd9:  osd_mul12_aud = 12'd512;
		4'd10: osd_mul12_aud = 12'd640;
		4'd11: osd_mul12_aud = 12'd768;
		4'd12: osd_mul12_aud = 12'd1024;
		4'd13: osd_mul12_aud = 12'd1280;
		4'd14: osd_mul12_aud = 12'd1792;
		4'd15: osd_mul12_aud = 12'd2560;
		default: osd_mul12_aud = 12'd256;
	endcase
endfunction

// Guadagno a 10 bit (Q6.4, fino a x63.9): a 8 bit il default dell'utente
// (OKI0 = 0xFF = x15.94) stava sul TETTO e ogni percentuale sopra il 100%
// saturava, cioe' l'OSD non regolava piu' verso l'alto. Con 10 bit il default
// sta a meta' scala e le voci salgono fino al 400% prima di toccare il limite.
function [9:0] gain_resolve;
	input [3:0] sel;
	input [9:0] def_g;
	input [9:0] mame_g;
	reg [21:0] scaled;
	begin
		case (sel)
			4'd0: gain_resolve = def_g;
			4'd1: gain_resolve = 10'h000;
			4'd2: gain_resolve = mame_g;
			default: begin
				scaled = def_g * osd_mul12_aud(sel);
				gain_resolve = (scaled[21:8] > 14'h3FF) ? 10'h3FF : scaled[17:8];
			end
		endcase
	end
endfunction

wire [9:0] gain_fm   = gain_resolve(osd_sel_fm,   DEF_GAIN_FM,   MAME_GAIN_FM);
wire [9:0] gain_oki0 = gain_resolve(osd_sel_oki0, DEF_GAIN_OKI0, MAME_GAIN_OKI0);
wire [9:0] gain_oki1 = gain_resolve(osd_sel_oki1, DEF_GAIN_OKI1, MAME_GAIN_OKI1);

// ── cen Z80: ce_ym (3.556 MHz) gated pause — tv80s (F2) usa un cen singolo ──
wire ce_z80 = ce_ym & ~pause;

// ── ROM Z80 64 KB (even/odd, write dal download come boogwings_audio) ────────
// ROM 64KB spostata in ns_audio_rom (condivisa fra le due catene).
reg       z80_a0_d;


// ── Z80 (tv80s instrumentato auto_ss — VERBATIM F2, _reference/taitof2_full:
// rtl/tv80_auto_ss.v + F2.sv:1298; il T80pa+DIRSet era invenzione, rimosso) ──
wire [15:0] z80_addr;
wire  [7:0] z80_dout;
reg   [7:0] z80_din;
wire z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_rfsh_n;
wire z80_int_n, z80_halt_n;

tv80s u_z80 (
	.auto_ss_out(z80_ss_out),
	.auto_ss_in (z80_ss_in),
	.auto_ss_wr (z80_ss_wr),
	.clk    (clk),
	.cen    (ce_z80),
	.reset_n(~reset),
	.wait_n (1'b1),
	.int_n  (z80_int_n),
	.nmi_n  (1'b1),
	.busrq_n(1'b1),
	.m1_n   (z80_m1_n),
	.mreq_n (z80_mreq_n),
	.iorq_n (z80_iorq_n),
	.rd_n   (z80_rd_n),
	.wr_n   (z80_wr_n),
	.rfsh_n (z80_rfsh_n),
	.halt_n (z80_halt_n),
	.busak_n(),
	.A      (z80_addr),
	.di     (z80_din),
	.dout   (z80_dout)
);


// ── Z80 access strobes (mreq-based, refresh filtrato) ───────────────────────
wire z80_mem_rd = ~z80_mreq_n & ~z80_rd_n & z80_rfsh_n;
wire z80_mem_wr = ~z80_mreq_n & ~z80_wr_n & z80_rfsh_n;

// ── Decode (mappa MAME z80_sound_map) ───────────────────────────────────────
wire is_rom = ~z80_addr[15];                      // 0000-7FFF
wire is_ram = (z80_addr[15:11] == 5'b1_0000);     // 8000-87FF (2 KB)
wire is_ym  = (z80_addr[15:12] == 4'hA);          // A000-A001
wire is_ok0 = (z80_addr[15:12] == 4'hB);          // B000
wire is_ok1 = (z80_addr[15:12] == 4'hC);          // C000
wire is_snd = (z80_addr[15:12] == 4'hD);          // D000 soundlatch_r
wire mem_rd = z80_mem_rd;
wire mem_wr = z80_mem_wr;

// ROM read pipeline (1 ck)
assign rom_rd_addr = z80_addr[15:1];   // -> ns_audio_rom (dato al ck dopo)
always @(posedge clk) z80_a0_d    <= z80_addr[0];
wire [7:0] rom_rd_r = z80_a0_d ? rom_odd_rd : rom_even_rd;

// ── RAM 2 KB ─────────────────────────────────────────────────────────────────
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_mem [0:2047];
reg [7:0] ram_rd_r;
// Savestate RAM: mux BW-style (bw_audio:216-231). sel=0 -> path di gioco
// IDENTICO. ram_we di gioco gated ~pause (lezione BW: strobe congelato a pausa
// calata riscriverebbe la RAM appena restorata).
wire        z80ram_we_eff   = ram_ss_sel ? ram_ss_we   : (is_ram & mem_wr & ~pause);
wire [10:0] z80ram_addr_eff = ram_ss_sel ? ram_ss_addr : z80_addr[10:0];
wire [7:0]  z80ram_wd_eff   = ram_ss_sel ? ram_ss_wd   : z80_dout;
assign ram_ss_rd = ram_rd_r;
always @(posedge clk) begin
	if (z80ram_we_eff) ram_mem[z80ram_addr_eff] <= z80ram_wd_eff;
	ram_rd_r <= ram_mem[z80ram_addr_eff];
end


// ── Soundlatch MAME-exact (deco146 soundlatch_r / write_soundlatch) ─────────
// FIX 2026-07-10: il latch REALE e' UN byte + flag IRQ level: ogni write
// SOVRASCRIVE (l'ultima vince), la read Z80 di D000 CLEARA l'IRQ e restituisce
// il byte corrente. NIENTE FIFO: il driver NS (sndprg.17l, disassemblato) al
// comando 0x00 SI RE-INIZIALIZZA (0x142: or a; jp z,0x3B) e durante l'init fa
// UNA read di pulizia di D000 (0x00A0). Col FIFO 16-deep (ereditato BW) quella
// read POPPAVA il comando successivo — la coppia tipica "0x00 reset + N play"
// a ogni cambio brano — comando perso -> main loop in spin su 0x870D (paced
// SOLO dal Timer B) = musica morta dopo il primo brano. Uniche read D000 nel
// driver: 0x142 (handler IRQ) e 0x00A0 (init). Semantica MAME = per makeup.
reg  [7:0] sndlatch_byte;
reg        sndlatch_irq_r;
reg        sl_pulse_d, sl_rd_d;
wire       sl_rd_lvl = is_snd & mem_rd;

always @(posedge clk) begin
	sl_pulse_d <= soundlatch_irq_pulse;
	sl_rd_d    <= sl_rd_lvl;
	if (reset) begin
		sndlatch_byte  <= 8'h00;
		sndlatch_irq_r <= 1'b0;
	end else begin
		if (bus_ss_wr) begin
			sndlatch_byte  <= bus_ss_load[7:0];
			sndlatch_irq_r <= bus_ss_load[8];
		end else if (soundlatch_irq_pulse & ~sl_pulse_d) begin
			sndlatch_byte  <= soundlatch_data;   // overwrite: l'ultima write vince
			sndlatch_irq_r <= 1'b1;              // ASSERT_LINE (level)
		end else if (~sl_rd_lvl & sl_rd_d) begin
			sndlatch_irq_r <= 1'b0;              // CLEAR_LINE alla read (soundlatch_r)
		end
	end
end
wire [7:0] sndlatch_reg = sndlatch_byte;

// ── YM2151 (jt51) — write a impulso 1 ck (jt51_mmr campiona ogni posedge) ───
reg  ym_wr_lvl_d;
wire ym_wr_lvl   = is_ym & mem_wr;
always @(posedge clk) ym_wr_lvl_d <= ym_wr_lvl;
wire ym_wr_pulse = ym_wr_lvl & ~ym_wr_lvl_d;

wire        ym_cs_n = ~is_ym;
wire        ym_wr_n = ~ym_wr_pulse;
wire [7:0]  ym_dout_raw;
wire        ym_irq_n;

// Busy back-pressure: senza freno il driver concatena write e il jt51 (busy
// reale quasi morto) stona un canale (lezione BW). FIX 2026-07-10: durata
// HARDWARE-FEDELE = 68 cicli phiM YM2151 (datasheet) = 68*27 = 1836 clk96
// (~19us). Il valore BW 7680 (~80us) era tarato sul driver HuC: il driver NS
// (sndprg.17l) gira su tick Timer B da 750us (reg 0x12=0xF9) con 3 write YM
// di ack per tick + le write del motore musica, ognuna dietro busy-wait
// (0x0EAE) -> a 80us/write il motore arrancava (musica trascinata/sbagliata).
localparam [12:0] YM_BUSY_TICKS = 13'd1836;
reg [12:0] ym_busy_cnt;
wire ym_data_wr = ym_wr_pulse & z80_addr[0];
always @(posedge clk) begin
	if (reset)                     ym_busy_cnt <= 13'd0;
	else if (bus_ss_wr)            ym_busy_cnt <= bus_ss_load[21:9];
	else if (ym_data_wr)           ym_busy_cnt <= YM_BUSY_TICKS;
	else if (ym_busy_cnt != 13'd0) ym_busy_cnt <= ym_busy_cnt - 13'd1;
end
wire [7:0] ym_dout = {ym_dout_raw[7] | (ym_busy_cnt != 13'd0), ym_dout_raw[6:0]};
wire signed [15:0] ym_left, ym_right;

jt51 u_ym (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_ym),
	.cen_p1 (ce_ym_p1),
	.cs_n   (ym_cs_n),
	.wr_n   (ym_wr_n),
	.a0     (z80_addr[0]),
	.din    (z80_dout),
	.dout   (ym_dout_raw),
	.ct1    (),
	.ct2    (),
	.irq_n  (ym_irq_n),
	.sample (),
	.left   (),
	.right  (),
	.xleft  (ym_left),
	.xright (ym_right),
	.auto_ss_in (ym_ss_in),
	.auto_ss_out(ym_ss_out),
	.auto_ss_wr (ym_ss_wr)
);

// ── IRQ merger (MAME :2380): soundlatch | YM -> IRQ0 ────────────────────────
assign z80_int_n = ~sndlatch_irq_r & ym_irq_n;

// ── Bank OKI via reg YM 0x1B (CT1/CT2) — nslasher sound_bankswitch_w:
//    oki0.bank = data&1 (CT1), oki1.bank = (data>>1)&1 (CT2). Identico a BW. ──
reg [7:0] ym_last_reg;
always @(posedge clk) begin
	if (bus_ss_wr)                   ym_last_reg <= bus_ss_load[29:22];
	else if (ym_wr_pulse && ~z80_addr[0]) ym_last_reg <= z80_dout;
end
reg [1:0] oki_bank_bits;   // {CT2, CT1}
always @(posedge clk) begin
	if (reset) oki_bank_bits <= 2'd0;
	else if (bus_ss_wr) oki_bank_bits <= bus_ss_load[31:30];
	else if (ym_wr_pulse && z80_addr[0] && ym_last_reg == 8'h1B)
		oki_bank_bits <= z80_dout[7:6];
end
wire oki0_bank = oki_bank_bits[0];
wire oki1_bank = oki_bank_bits[1];

// ── OKI #0/#1 (jt6295) ───────────────────────────────────────────────────────
wire        oki0_wrn = ~(is_ok0 & mem_wr);
wire [7:0]  oki0_dout;
wire signed [13:0] oki0_sound;
wire [17:0] oki0_rom_addr;
wire        oki0_rom_ok_w;
wire [7:0]  oki0_rom_data;
jt6295 #(.INTERPOL(1)) u_oki0 (
	.rst        (reset),
	.clk        (clk),
	.cen        (ce_oki0),
	.ss         (1'b1),
	.wrn        (oki0_wrn),
	.din        (z80_dout),
	.dout       (oki0_dout),
	.rom_addr   (oki0_rom_addr),
	.rom_data   (oki0_rom_data),
	.rom_ok     (oki0_rom_ok_w),
	.sound      (oki0_sound),
	.sample     (),
	.auto_ss_in (oki0_ss_in),
	.auto_ss_out(oki0_ss_out),
	.auto_ss_wr (oki0_ss_wr)
);

wire        oki1_wrn = ~(is_ok1 & mem_wr);
wire [7:0]  oki1_dout;
wire signed [13:0] oki1_sound;
wire [17:0] oki1_rom_addr;
wire        oki1_rom_ok_w;
wire [7:0]  oki1_rom_data;
jt6295 #(.INTERPOL(1)) u_oki1 (
	.rst        (reset),
	.clk        (clk),
	.cen        (ce_oki1),
	.ss         (1'b1),
	.wrn        (oki1_wrn),
	.din        (z80_dout),
	.dout       (oki1_dout),
	.rom_addr   (oki1_rom_addr),
	.rom_data   (oki1_rom_data),
	.rom_ok     (oki1_rom_ok_w),
	.sound      (oki1_sound),
	.sample     (),
	.auto_ss_in (oki1_ss_in),
	.auto_ss_out(oki1_ss_out),
	.auto_ss_wr (oki1_ss_wr)
);

// ── Prefetch DDR OKI (verbatim boogwings_audio: current + next word) ────────
reg [17:0] oki0_addr_pending;
reg [15:0] oki0_word_addr;
reg [15:0] oki0_word_n_addr;
reg [31:0] oki0_word;
reg [31:0] oki0_word_n;
reg        oki0_req_toggle;
reg        oki0_fetch_busy;
reg        oki0_fetch_is_next;
reg        oki0_rom_ok;
wire       oki0_ddr_ack_match = (oki0_ddr_ack == oki0_req_toggle);
wire [15:0] oki0_cur_widx  = oki0_rom_addr[17:2];
wire [15:0] oki0_next_widx = oki0_rom_addr[17:2] + 16'd1;
wire       oki0_word_hit   = (oki0_word_addr   == oki0_cur_widx);
wire       oki0_word_n_hit = (oki0_word_n_addr == oki0_cur_widx);

always @(posedge clk) begin
	if (reset | fetch_rst) begin
		oki0_addr_pending <= 18'h00000;
		oki0_word_addr    <= 16'hFFFF;
		oki0_word_n_addr  <= 16'hFFFF;
		oki0_word         <= 32'd0;
		oki0_word_n       <= 32'd0;
		oki0_req_toggle   <= 1'b0;
		oki0_fetch_busy   <= 1'b0;
		oki0_fetch_is_next<= 1'b0;
		oki0_rom_ok       <= 1'b0;
	end else begin
		if (oki0_fetch_busy && oki0_ddr_ack_match) begin
			if (oki0_fetch_is_next) begin
				oki0_word_n      <= oki0_ddr_data;
				oki0_word_n_addr <= oki0_addr_pending[17:2];
			end else begin
				oki0_word        <= oki0_ddr_data;
				oki0_word_addr   <= oki0_addr_pending[17:2];
			end
			oki0_fetch_busy <= 1'b0;
		end
		if (!oki0_fetch_busy && !oki0_word_hit && oki0_word_n_hit) begin
			oki0_word        <= oki0_word_n;
			oki0_word_addr   <= oki0_word_n_addr;
			oki0_word_n_addr <= 16'hFFFF;
		end
		oki0_rom_ok <= (oki0_word_hit || oki0_word_n_hit) && !oki0_fetch_busy;
		if (!oki0_fetch_busy) begin
			if (!oki0_word_hit && !oki0_word_n_hit) begin
				oki0_addr_pending  <= oki0_rom_addr;
				oki0_fetch_is_next <= 1'b0;
				oki0_req_toggle    <= ~oki0_req_toggle;
				oki0_fetch_busy    <= 1'b1;
			end else if (oki0_word_hit && (oki0_word_n_addr != oki0_next_widx)) begin
				oki0_addr_pending  <= {oki0_next_widx[15:0], 2'b00};
				oki0_fetch_is_next <= 1'b1;
				oki0_req_toggle    <= ~oki0_req_toggle;
				oki0_fetch_busy    <= 1'b1;
			end
		end
	end
end
wire [31:0] oki0_word_sel = oki0_word_hit ? oki0_word : oki0_word_n;
assign oki0_rom_data = oki0_word_sel[{oki0_rom_addr[1:0], 3'b000} +:8];
assign oki0_ddr_addr = 28'h5500000 + {9'd0, oki0_bank, oki0_addr_pending};
assign oki0_ddr_req  = oki0_req_toggle;
assign oki0_rom_ok_w = oki0_rom_ok;

reg [17:0] oki1_addr_pending;
reg [15:0] oki1_word_addr;
reg [15:0] oki1_word_n_addr;
reg [31:0] oki1_word;
reg [31:0] oki1_word_n;
reg        oki1_req_toggle;
reg        oki1_fetch_busy;
reg        oki1_fetch_is_next;
reg        oki1_rom_ok;
wire       oki1_ddr_ack_match = (oki1_ddr_ack == oki1_req_toggle);
wire [15:0] oki1_cur_widx  = oki1_rom_addr[17:2];
wire [15:0] oki1_next_widx = oki1_rom_addr[17:2] + 16'd1;
wire       oki1_word_hit   = (oki1_word_addr   == oki1_cur_widx);
wire       oki1_word_n_hit = (oki1_word_n_addr == oki1_cur_widx);

always @(posedge clk) begin
	if (reset | fetch_rst) begin
		oki1_addr_pending <= 18'h00000;
		oki1_word_addr    <= 16'hFFFF;
		oki1_word_n_addr  <= 16'hFFFF;
		oki1_word         <= 32'd0;
		oki1_word_n       <= 32'd0;
		oki1_req_toggle   <= 1'b0;
		oki1_fetch_busy   <= 1'b0;
		oki1_fetch_is_next<= 1'b0;
		oki1_rom_ok       <= 1'b0;
	end else begin
		if (oki1_fetch_busy && oki1_ddr_ack_match) begin
			if (oki1_fetch_is_next) begin
				oki1_word_n      <= oki1_ddr_data;
				oki1_word_n_addr <= oki1_addr_pending[17:2];
			end else begin
				oki1_word        <= oki1_ddr_data;
				oki1_word_addr   <= oki1_addr_pending[17:2];
			end
			oki1_fetch_busy <= 1'b0;
		end
		if (!oki1_fetch_busy && !oki1_word_hit && oki1_word_n_hit) begin
			oki1_word        <= oki1_word_n;
			oki1_word_addr   <= oki1_word_n_addr;
			oki1_word_n_addr <= 16'hFFFF;
		end
		oki1_rom_ok <= (oki1_word_hit || oki1_word_n_hit) && !oki1_fetch_busy;
		if (!oki1_fetch_busy) begin
			if (!oki1_word_hit && !oki1_word_n_hit) begin
				oki1_addr_pending  <= oki1_rom_addr;
				oki1_fetch_is_next <= 1'b0;
				oki1_req_toggle    <= ~oki1_req_toggle;
				oki1_fetch_busy    <= 1'b1;
			end else if (oki1_word_hit && (oki1_word_n_addr != oki1_next_widx)) begin
				oki1_addr_pending  <= {oki1_next_widx[15:0], 2'b00};
				oki1_fetch_is_next <= 1'b1;
				oki1_req_toggle    <= ~oki1_req_toggle;
				oki1_fetch_busy    <= 1'b1;
			end
		end
	end
end
wire [31:0] oki1_word_sel = oki1_word_hit ? oki1_word : oki1_word_n;
assign oki1_rom_data = oki1_word_sel[{oki1_rom_addr[1:0], 3'b000} +:8];
assign oki1_ddr_addr = 28'h5580000 + {9'd0, oki1_bank, oki1_addr_pending};
assign oki1_ddr_req  = oki1_req_toggle;
assign oki1_rom_ok_w = oki1_rom_ok;

// ── DIN mux Z80 ──────────────────────────────────────────────────────────────
// FIX 2026-07-10 — LA CAUSA DEL "motore muto": MAME z80_sound_io
// (deco32.cpp:688) mappa TUTTI i 64KB della ROM nello spazio I/O:
//   map(0x0000, 0xffff).rom().region("audiocpu", 0);
// Il driver legge i DATI CANZONE con `in a,(c)` (unico sito 0x0EA5, raggiunto
// dai RST 10/18/20) con BC = puntatore 16-bit nella ROM 64KB (master table
// @0x4000: entry 0xCA59/0xD969... = offset nel file, NON indirizzi memoria).
// Senza questa decodifica ogni IN restituiva 0xFF -> il motore partiva ma
// leggeva spazzatura -> nessuna nota, solo mantenimento timer = idle percepito.
// rom_even/odd contengono gia' TUTTI i 64KB e rom_rd_r indicizza addr[15:1]
// completo: basta instradare le read I/O sulla ROM.
wire io_rd = ~z80_iorq_n & ~z80_rd_n & z80_m1_n;   // IN (esclude INT-ack: M1=0)
always @(*) begin
	if      (io_rd)  z80_din = rom_rd_r;   // I/O space = ROM 64KB (z80_sound_io)
	else if (is_rom) z80_din = rom_rd_r;
	else if (is_ram) z80_din = ram_rd_r;
	else if (is_snd) z80_din = sndlatch_reg;
	else if (is_ym ) z80_din = ym_dout;
	else if (is_ok0) z80_din = oki0_dout;
	else if (is_ok1) z80_din = oki1_dout;
	else             z80_din = 8'hFF;
end

// ── Mixer Q4.4 con pipeline 2 stadi (pattern collaudato) ─────────────────────
wire signed [15:0] oki0_ext = { {2{oki0_sound[13]}}, oki0_sound };
wire signed [15:0] oki1_ext = { {2{oki1_sound[13]}}, oki1_sound };

wire signed [26:0] ym_l_mul = $signed(ym_left)  * $signed({1'b0, gain_fm});
wire signed [26:0] ym_r_mul = $signed(ym_right) * $signed({1'b0, gain_fm});
wire signed [26:0] oki0_mul = $signed(oki0_ext) * $signed({1'b0, gain_oki0});
wire signed [26:0] oki1_mul = $signed(oki1_ext) * $signed({1'b0, gain_oki1});

reg signed [22:0] ym_l_s, ym_r_s, oki0_s, oki1_s;
always @(posedge clk) begin
	ym_l_s <= ym_l_mul >>> 4;
	ym_r_s <= ym_r_mul >>> 4;
	oki0_s <= oki0_mul >>> 4;
	oki1_s <= oki1_mul >>> 4;
end

reg signed [23:0] mix_l, mix_r;
always @(posedge clk) begin
	mix_l <= ym_l_s + oki0_s + oki1_s;
	mix_r <= ym_r_s + oki0_s + oki1_s;
end

function signed [15:0] sat16(input signed [23:0] v);
	if      (v >  $signed(24'sd32767))  sat16 = 16'sd32767;
	else if (v < -$signed(24'sd32768))  sat16 = -16'sd32768;
	else                                sat16 = v[15:0];
endfunction

assign audio_l = sat16(mix_l);
assign audio_r = sat16(mix_r);


// ── Savestate: pack stato bus (i consumer del load usano bus_ss_load/bus_ss_wr
// nei loro always; qui solo l'assemblaggio del vettore di save). ──
assign bus_ss_out = {oki_bank_bits, ym_last_reg, ym_busy_cnt, sndlatch_irq_r, sndlatch_byte};

endmodule
