// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/
//
// ns_sprites (ex boogwings_sprites) — DECO_SPRITE (DECO52) engine, SCANLINE-BASED.
//
// MAME equivalente: m_sprite_bitmap full-frame 320×256 + draw_sprites_common.
// HW vincolo M10K (41 disponibili, 160 richiesti per double-buffer full-frame) →
// architettura SCANLINE-BASED double-buffer (front/back).
//
// Pattern:
//   - 2 linebuf 512×12-bit per chip (front + back) = 4 M10K totali per 2 chip
//   - hbl_rise di linea N → scan 256 sprite per linea N+1
//   - Per ogni sprite, check intersezione scanline N+1 con bounding box
//     (ypos..ypos+16*(multi+1)-1). Se sì, fetch ROM per la row corretta e
//     draw 16 col nel linebuf back (x = sx..sx+15).
//   - Render area attiva: pxl* = linebuf_front[render_x]
//   - Pipeline elastica a 3 linebuffer (2026-07-11): consumo solo a hbl,
//     draw fino a 2 linee avanti nel video attivo, legacy in vblank.
//
// Output identico al MAME m_sprite_bitmap se scan ordinata correttamente.
// Race ELIMINATA per costruzione (scan scrive back, render legge front).
//
// MAME standard format (offs +0/+1/+2):
//   +0: efFbSssyyyyyyyyy  e=priority, f=flipy, F=flipx, b=flash, S=w, ss=h
//   +1: tttttttttttttttt  tile code
//   +2: ppcccccxxxxxxxxx  pp=priority, ccccc=color (5b), x=xpos
//
// Pen extraction (validato col tool sprite_viewer):
//   pen[3]=byte[3], pen[2]=byte[2], pen[1]=byte[1], pen[0]=byte[0]

module ns_sprites #(
	// NS chip0 sprites are 5bpp: SPR0_5BPP=1 adds a 5th plane fetched from the
	// rom0_p4_* channel and widens pxl0 to {color[7:0], pen[4:0]} (13-bit).
	// Default 0 = Boogie Wings behaviour (4bpp, pxl 12-bit) — unchanged.
	parameter SPR0_5BPP = 0,
	// 2026-07-10 SCAN PARALLELO (fix bubbling): i due chip DECO sono
	// INDIPENDENTI sull'hardware vero, ma la FSM li scandiva in SERIE
	// (chip0 poi chip1 nella stessa finestra di riga) raddoppiando il tempo.
	// CHIP_ONLY: 2'b00 = entrambi (legacy), 2'b01 = solo chip0, 2'b10 = solo
	// chip1 -> due istanze parallele = tempo di scan DIMEZZATO per riga.
	parameter [1:0] CHIP_ONLY = 2'b00
) (
	input  wire        clk,
	input  wire        reset,

	// VRAM read port chip0/chip1
	output reg  [9:0]  sram0_addr,
	input  wire [15:0] sram0_data,
	output reg  [9:0]  sram1_addr,
	input  wire [15:0] sram1_data,

	// ROM read port chip0/chip1 (toggle protocol)
	output reg  [23:0] rom0_addr,
	output reg         rom0_req,
	input  wire [31:0] rom0_data,
	input  wire        rom0_valid,
	output reg  [23:0] rom1_addr,
	output reg         rom1_req,
	input  wire [31:0] rom1_data,
	input  wire        rom1_valid,

	// NS chip0 5th-plane fetch channel (only used when SPR0_5BPP=1). 1 byte/group.
	output reg  [23:0] rom0_p4_addr,
	output reg         rom0_p4_req,
	input  wire [7:0]  rom0_p4_data,
	input  wire        rom0_p4_valid,

	// Video timing
	input  wire  [9:0] render_x,
	input  wire  [9:0] render_y,
	input  wire        hblank_in,
	input  wire        vblank_in,
	input  wire        ce_pix,
	input  wire        pause_in,      // pausa frame-aligned: gela frame_odd (flash sprite)
	input  wire        flip_screen,

	// OSD toggles (decode permutations sprite_viewer-validated)
	input  wire        osd_spr_swap_hl,
	input  wire        osd_spr_brev8,
	input  wire        osd_spr_nibsw,
	input  wire        osd_spr_bs_ab,

	// === EXTRA spr permutation OSD (per BG sprite decoder debug) ===
	input  wire        osd_spr_msb_first,    // bit_x: 1=MSB first (7-pix), 0=LSB first (pix)
	input  wire        osd_spr_half_inv,     // scambia half logical (sx/dx)
	input  wire        osd_spr_half_eff_inv, // scambia half EFFETTIVO al fetch ROM
	input  wire        osd_spr_row_inv,      // 15 - row_in_tile (flip Y dentro tile)
	input  wire        osd_spr_plane_inv,    // bit-reverse del nibble pen (= reverse plane order)
	input  wire [1:0]  osd_spr_p0_src,       // da quale byte del fetch 32-bit pesca plane 0 (LSB nibble)
	input  wire [1:0]  osd_spr_p1_src,
	input  wire [1:0]  osd_spr_p2_src,
	input  wire [1:0]  osd_spr_p3_src,
	input  wire        osd_spr_w_swap_pos,          // w-mode: scambia posizione 1°/2° blocco
	input  wire        osd_spr_w_offset_first,      // w-mode: applica offset al 1° blocco (debug X assoluta)
	input  wire        osd_spr_w_code_swap,         // w-mode: swap code primo/secondo
	input  wire signed [3:0] osd_spr_w_offset,      // w-mode: offset X signed (step 16)

	// Pixel output (12-bit = {color[7:0], pen[3:0]})
	output wire [12:0] pxl0,    // {color[7:0], pen[4:0]} when SPR0_5BPP, else pen[3:0] in [3:0]
	output wire [11:0] pxl1
);

// flipscreen sprite — MAME boogwing.cpp:424 set_flip_screen(!BIT(flip,7))
// → SEMPRE invertito rispetto a flip_screen input (= tilemap flip).
// Default boogwing (DSW flip=Off, flip_screen=0): flipscreen_spr=1 → identity coord.
wire flipscreen_spr = ~flip_screen;

// ============================================================
// HBlank edge detect — trigger scan per scanline successiva
// ============================================================
reg hblank_d;
always @(posedge clk) hblank_d <= hblank_in;
wire hbl_rise = hblank_in & ~hblank_d;

// Go-latch: cattura hbl_rise anche se FSM è in mezzo a uno sprite.
// Senza latch, l'edge viene perso → scanline NON scansionata → render legge
// buffer vecchio → tile sprite "instabili" anche in pausa (= edge perso casualmente
// in funzione di quanto la scanline precedente era satura di sprite).
// Pattern copiato da deco16ic_jt pf*_go_latch.
reg       go_latch;
reg [9:0] latched_render_y;
// SCAN-OMBRA: start di linea comune alle DUE FSM (scan + draw), definito
// dopo le dichiarazioni degli stati (assign piu' sotto).
wire      line_start;

// Frame parity per il FLASH sprite (MAME decospr.cpp:227: flag y_word[12], lo sprite
// e' nascosto sui frame DISPARI -> if(!(flash && (frame_number & 1))) draw). Toggle a
// ogni vblank rise = frame_number[0].
reg       vblank_in_d;
reg       frame_odd;
always @(posedge clk) begin
	if (reset) begin
		vblank_in_d <= 1'b0;
		frame_odd   <= 1'b0;
	end else begin
		vblank_in_d <= vblank_in;
		// ~pause_in: in pausa il vblank continua (display vivo) ma la parita' frame
		// resta ferma -> il FLASH si congela come su PCB/MAME (niente flicker in pausa).
		if (vblank_in & ~vblank_in_d & ~pause_in) frame_odd <= ~frame_odd;  // 1 toggle per frame
	end
end

// ============================================================
// Linebuf 512 x 3 BUFFER per chip — PIPELINE ELASTICA 2026-07-11.
// Prima (double buffer): swap quando il draw finiva, anche A META' LINEA
// dopo un abort -> la linea visibile mescolava meta' buffer vecchio e meta'
// troncato = "righe che si muovono" nelle zone congestionate (jitter DDR3
// attorno alla deadline: visibile ANCHE IN PAUSA con dati statici).
// Ora: 3 buffer in coda circolare. Il consumo avviene SOLO a hbl_rise
// (mai swap a meta' linea); il draw lavora fino a 2 linee avanti durante
// il video attivo (budget ammortizzato ~2 linee = jitter assorbito);
// in vblank pacing legacy identico a prima (1 start/hbl, coda vuota:
// zero cambi su DMA sprite RAM e wrap di frame).
// ============================================================
// RING ELASTICO A 8 BUFFER per chip (lead fino a 6) — 2026-07-19.
// Positional: disp_buf=buffer in display; fill=buffer PRONTI (0..6);
// build_buf = disp_buf + fill + 1 (mod 8) = buffer in costruzione.
// Con fill<=6 -> build_buf != disp_buf SEMPRE (fill+1 mai 0 mod 8) -> il render
// NON legge MAI il buffer in costruzione = niente strappo per collisione.
// disp_buf punta SEMPRE a un buffer COMPLETO (fill conta solo i done_ok) ->
// incompleto mai mostrato. NIENTE ABORT (era l'altra fonte di strappo).
// Underrun (fill piccolo) -> disp avanza piano = REPLICA (mai strappo). Lead 6
// = budget ~6 righe: le righe cariche spendono il margine accumulato su quelle
// scariche. La collisione mod-3/fill-2 del vecchio elastico (build==disp) e'
// eliminata (8 buffer, mod 8).
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_0 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_1 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_2 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_3 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_4 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_5 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_6 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_7 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_8 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_9 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_10 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [12:0] linebuf_spr0_11 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_0 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_1 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_2 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_3 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_4 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_5 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_6 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_7 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_8 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_9 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_10 [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [11:0] linebuf_spr1_11 [0:511];

// 12 BUFFER (lead 10) — 2026-07-19. mod 12: build = disp+fill+1 (>=12 -> -12).
// fill<=10 -> build != disp SEMPRE. Piu' lead = piu' righe cariche assorbite.
reg  [3:0] disp_buf;
reg  [3:0] fill;                          // 0..10
wire [3:0] disp_nxt = (disp_buf == 4'd11) ? 4'd0 : (disp_buf + 4'd1);
reg [9:0] clear_idx;

// done_ok = completamento (S_DONE): il buffer entra in coda (fill++).
// Consume a hbl: se c'e' un pronto (o ne arriva uno nello stesso ciclo).
wire done_ok;      // definito dopo state/S_DONE
wire cons = hbl_rise && ((fill != 4'd0) || done_ok);
always @(posedge clk) begin
	if (reset) begin
		disp_buf <= 4'd0;
		fill     <= 4'd0;
	end else begin
		if (cons) disp_buf <= disp_nxt;
		fill <= fill + {3'd0, done_ok} - {3'd0, cons};
	end
end

wire [4:0] build_sum = {1'b0, disp_buf} + {1'b0, fill} + 5'd1;
wire [3:0] build_buf = (build_sum >= 5'd12) ? (build_sum - 5'd12) : build_sum[3:0]; // mod 12

// ============================================================
// Renderer read — 8 letture registrate + mux per disp_buf (stabile per linea:
// disp avanza solo a hbl, mai a meta' scanline -> nessun cambio buffer a video).
// ============================================================
reg [12:0] lb0_rd [0:11];   // read-reg (NON RAM): mux per disp_buf_d
reg [11:0] lb1_rd [0:11];
reg [3:0]  disp_buf_d;
always @(posedge clk) lb0_rd[0]  <= linebuf_spr0_0[render_x[8:0]];
always @(posedge clk) lb0_rd[1]  <= linebuf_spr0_1[render_x[8:0]];
always @(posedge clk) lb0_rd[2]  <= linebuf_spr0_2[render_x[8:0]];
always @(posedge clk) lb0_rd[3]  <= linebuf_spr0_3[render_x[8:0]];
always @(posedge clk) lb0_rd[4]  <= linebuf_spr0_4[render_x[8:0]];
always @(posedge clk) lb0_rd[5]  <= linebuf_spr0_5[render_x[8:0]];
always @(posedge clk) lb0_rd[6]  <= linebuf_spr0_6[render_x[8:0]];
always @(posedge clk) lb0_rd[7]  <= linebuf_spr0_7[render_x[8:0]];
always @(posedge clk) lb0_rd[8]  <= linebuf_spr0_8[render_x[8:0]];
always @(posedge clk) lb0_rd[9]  <= linebuf_spr0_9[render_x[8:0]];
always @(posedge clk) lb0_rd[10] <= linebuf_spr0_10[render_x[8:0]];
always @(posedge clk) lb0_rd[11] <= linebuf_spr0_11[render_x[8:0]];
always @(posedge clk) lb1_rd[0]  <= linebuf_spr1_0[render_x[8:0]];
always @(posedge clk) lb1_rd[1]  <= linebuf_spr1_1[render_x[8:0]];
always @(posedge clk) lb1_rd[2]  <= linebuf_spr1_2[render_x[8:0]];
always @(posedge clk) lb1_rd[3]  <= linebuf_spr1_3[render_x[8:0]];
always @(posedge clk) lb1_rd[4]  <= linebuf_spr1_4[render_x[8:0]];
always @(posedge clk) lb1_rd[5]  <= linebuf_spr1_5[render_x[8:0]];
always @(posedge clk) lb1_rd[6]  <= linebuf_spr1_6[render_x[8:0]];
always @(posedge clk) lb1_rd[7]  <= linebuf_spr1_7[render_x[8:0]];
always @(posedge clk) lb1_rd[8]  <= linebuf_spr1_8[render_x[8:0]];
always @(posedge clk) lb1_rd[9]  <= linebuf_spr1_9[render_x[8:0]];
always @(posedge clk) lb1_rd[10] <= linebuf_spr1_10[render_x[8:0]];
always @(posedge clk) lb1_rd[11] <= linebuf_spr1_11[render_x[8:0]];
always @(posedge clk) disp_buf_d <= disp_buf;

reg [12:0] pxl0_r;
reg [11:0] pxl1_r;
always @(posedge clk) pxl0_r <= lb0_rd[disp_buf_d];
always @(posedge clk) pxl1_r <= lb1_rd[disp_buf_d];

assign pxl0 = pxl0_r;
assign pxl1 = pxl1_r;

// ============================================================
// Linebuf write port: il draw scrive SEMPRE build_buf (invariante sotto
// consume: cons non muove build_buf -> mai spostato a meta' linea).
// ============================================================
reg [8:0]  lb_waddr;
reg [12:0] lb_wdata;       // chip0 (5bpp) uses all 13 bits; chip1 uses [11:0]
reg        lb_we0, lb_we1;

always @(posedge clk) if (lb_we0 && build_buf == 4'd0)  linebuf_spr0_0[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd1)  linebuf_spr0_1[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd2)  linebuf_spr0_2[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd3)  linebuf_spr0_3[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd4)  linebuf_spr0_4[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd5)  linebuf_spr0_5[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd6)  linebuf_spr0_6[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd7)  linebuf_spr0_7[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd8)  linebuf_spr0_8[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd9)  linebuf_spr0_9[lb_waddr]  <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd10) linebuf_spr0_10[lb_waddr] <= lb_wdata;
always @(posedge clk) if (lb_we0 && build_buf == 4'd11) linebuf_spr0_11[lb_waddr] <= lb_wdata;
always @(posedge clk) if (lb_we1 && build_buf == 4'd0)  linebuf_spr1_0[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd1)  linebuf_spr1_1[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd2)  linebuf_spr1_2[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd3)  linebuf_spr1_3[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd4)  linebuf_spr1_4[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd5)  linebuf_spr1_5[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd6)  linebuf_spr1_6[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd7)  linebuf_spr1_7[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd8)  linebuf_spr1_8[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd9)  linebuf_spr1_9[lb_waddr]  <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd10) linebuf_spr1_10[lb_waddr] <= lb_wdata[11:0];
always @(posedge clk) if (lb_we1 && build_buf == 4'd11) linebuf_spr1_11[lb_waddr] <= lb_wdata[11:0];

// ============================================================
// FSM scan: ad ogni hbl_rise, scan 256 sprite per linea N+1
// ============================================================
reg [4:0]  state;
reg [9:0]  scan_y;          // = render_y + 1 (scanline target)
reg signed [9:0] sx_anchor;
reg signed [9:0] sy_signed;
reg [15:0] code_base;
reg [7:0]  color;
reg        flipy, flipx;
reg [2:0]  multi;           // 0/1/3/7 → 1/2/4/8 tile alti
reg        w_mode;
reg        w_iter;
reg [3:0]  tile_idx;        // tile vertical idx (0..multi)
reg [3:0]  row_in_tile;     // row Y within tile (0..15)
reg        half;            // 0=cols 0..7, 1=cols 8..15
reg signed [9:0] sx_col;
reg        chip_idx;        // 0=chip0, 1=chip1

localparam [4:0]
	S_IDLE      = 5'd0,
	S_CLEAR     = 5'd1,
	S_POP       = 5'd2,   // SCAN-OMBRA: preleva un match dalla FIFO (via S_W0..S_CHECK)
	S_FIND_ROW  = 5'd6,   // Calcola se sprite intersezione scanline + tile_idx + row_in_tile
	S_ROM_REQ   = 5'd7,
	S_ROM_WAIT  = 5'd8,
	S_DRAW      = 5'd9,
	S_NEXT_HALF = 5'd10,
	S_NEXT_W    = 5'd11,
	S_NEXT_SPR  = 5'd12,
	S_FLUSH     = 5'd13,  // attesa fine draw engine prima di chiudere la linea
	S_DONE      = 5'd14;

// done_ok: completamento (S_DONE) -> buffer in coda (fill++). NIENTE ABORT: il
// draw non viene mai troncato; su underrun disp resta fermo = replica (mai
// strappo). disp punta sempre a un buffer completo (fill conta solo done_ok).
assign done_ok = (state == S_DONE);

// go_latch always block — cattura hbl_rise anche se FSM non in S_IDLE.
// Senza latch, edge perso quando FSM ancora processando scanline N → scanline N+1
// non scansionata → render legge buffer vecchio = sprite instabili anche in pausa.
always @(posedge clk) begin
	if (reset) begin
		go_latch <= 1'b0;
		latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			go_latch <= 1'b1;
			latched_render_y <= render_y;
		end else if (line_start) begin
			// SCAN-OMBRA: si consuma quando ENTRAMBE le FSM sono pronte
			go_latch <= 1'b0;
		end
	end
end

// MAME decospr.cpp:267-282 + 297-314 — formula completa boogwing con flipscreen=ON:
//
//   STEP 1 (riga 267-282): y = 240 - sign_ext_256(y_sram); x = 304 - sign_ext_320(x_sram)
//   STEP 2 (riga 297-304, flipscreen=ON): y = 240 - y  (doppia inversione = y_sram_signed)
//   STEP 3 (riga 306-314, flipscreen=ON): x = 304 - x  (doppia inversione = x_sram_signed)
//
// → Con flipscreen=ON (default boogwing): y_final = signed(y_sram), x_final = signed(x_sram).
// → Con flipscreen=OFF (DSW flip): y_final = 240 - signed(y_sram), x_final = 304 - signed(x_sram).
//
// MAME boogwing.cpp:424 set_flip_screen(!BIT(flip,7)) → default ON (flip[7]=0).
//
// Anche `mult` cambia: flipscreen=ON usa mult=+16 (tile crescono verso il basso),
// flipscreen=OFF usa mult=-16 (tile crescono verso l'alto). fx/fy si invertono.
function signed [9:0] sxy_decode_y(input [8:0] raw);
	// Solo sign-ext signed(y_sram). flip_screen applicato dopo nella FSM.
	begin
		sxy_decode_y = {{1{raw[8]}}, raw};
	end
endfunction

function signed [9:0] sxy_decode_x(input [8:0] raw);
	// Solo "sign-ext" con soglia 320 (MAME decospr.cpp:267-269):
	//   x = x & 0x1ff;            (9-bit 0..511)
	//   if (x >= 320) x -= 512;   (0..319 unsigned, 320..511 → -192..-1)
	// Risultato: signed -192..319 (10-bit signed sufficiente).
	// flip_screen applicato dopo nella FSM (304 - x se OFF, identity se ON).
	begin
		if (raw >= 9'd320)
			sxy_decode_x = $signed({1'b1, raw[8:0]});   // -192..-1
		else
			sxy_decode_x = {1'b0, raw};                  // 0..319
	end
endfunction

// ============================================================
// SCAN-OMBRA 2026-07-10 (anti-bubbling, colpo grosso: ~1800 clk/linea).
// FSM di scan SEPARATA che scandisce i 256 sprite e accoda i MATCH in una
// FIFO mentre la FSM di draw disegna: la scansione seriale esce dal percorso
// critico. Ordine di push = ordine di scansione di oggi (chip0 poi chip1,
// entry ascendenti) -> priorita' visiva IDENTICA. Il fast-skip Y e il test
// entry-vuota replicano ESATTAMENTE la vecchia S_W2/S_CHECK.
// La FIFO (64 match, ben oltre il disegnabile in una linea) stalla lo scan
// se piena: nessun match perso per costruzione.
// ============================================================
localparam [2:0] SC_IDLE = 3'd0, SC_A0 = 3'd1, SC_A1 = 3'd2, SC_A2 = 3'd3,
                 SC_D1 = 3'd4, SC_PUSH = 3'd5, SC_NEXT = 3'd6;
reg [2:0]  sc_state;
reg [9:0]  sc_off;
reg        sc_chip;
reg [15:0] sc_d0, sc_d1;
reg        scan_fin;
// FIFO match: {chip, x_word, code_word, y_word} = 49 bit x 64 entry.
// MLAB come Darius2NW 67db37a: la FIFO scan->render in M10K aveva race
// read-during-write sul ferro; MLAB (LUTRAM write-through) la elimina.
(* ramstyle = "MLAB" *) reg [48:0] mfifo [0:127];
reg [7:0]  mf_w, mf_r;
reg [48:0] mf_q_r;
reg        mf_empty_d;
wire mf_empty = (mf_w == mf_r);
wire mf_full  = (mf_w[7] != mf_r[7]) && (mf_w[6:0] == mf_r[6:0]);
wire [15:0] sc_sram = sc_chip ? sram1_data : sram0_data;

// Start di produzione (comune a scan+draw):
// - video ATTIVO: free-run — appena entrambe le FSM sono idle e c'e' un
//   buffer libero (fill<2) si parte con la prossima linea (lead fino a 2).
// - VBLANK: pacing legacy identico al double-buffer (1 start per hbl via
//   go_latch, coda vuota): il render della linea 0 avviene alla stessa hbl
//   di prima (dopo il DMA sprite) e il wrap di frame resta quello di sempre.
assign line_start = (state == S_IDLE) && (sc_state == SC_IDLE) &&
                    (vblank_in ? (go_latch && fill == 4'd0)
                               : (fill < 4'd10));

always @(posedge clk) begin
	// lettura FIFO registrata (M10K); mf_empty_d = guardia read-during-write:
	// il draw poppa solo entry scritte da >=1 ciclo (mixed-port RDW indefinito).
	mf_q_r     <= mfifo[mf_r[6:0]];
	mf_empty_d <= mf_empty;
end

always @(posedge clk) begin
	if (reset) begin
		sc_state   <= SC_IDLE;
		sc_off     <= 10'd0;
		sc_chip    <= 1'b0;
		scan_fin   <= 1'b1;
		mf_w       <= 8'd0;
		sram0_addr <= 10'd0;
		sram1_addr <= 10'd0;
	end else begin
		case (sc_state)
			SC_IDLE: if (line_start) begin
				sc_off   <= 10'd0;
				sc_chip  <= CHIP_ONLY[1];
				scan_fin <= 1'b0;
				mf_w     <= 8'd0;
				sc_state <= SC_A0;
			end
			SC_A0: begin
				if (sc_chip) sram1_addr <= sc_off;
				else         sram0_addr <= sc_off;
				sc_state <= SC_A1;
			end
			SC_A1: begin
				if (sc_chip) sram1_addr <= sc_off + 10'd1;
				else         sram0_addr <= sc_off + 10'd1;
				sc_state <= SC_A2;
			end
			SC_A2: begin
				// sc_sram = y_word. Fast-skip identico alla vecchia S_W2.
				sc_d0 <= sc_sram;
				if (sc_chip) sram1_addr <= sc_off + 10'd2;
				else         sram0_addr <= sc_off + 10'd2;
				begin : sc_fast_skip
					reg signed [9:0] sy_pre;
					reg [2:0] multi_pre;
					reg [10:0] height;
					reg signed [10:0] dy_pre;
					reg signed [10:0] sy_top;
					sy_pre = sxy_decode_y(sc_sram[8:0]);
					case ({sc_sram[10], sc_sram[9]})
						2'd0: multi_pre = 3'd0;
						2'd1: multi_pre = 3'd1;
						2'd2: multi_pre = 3'd3;
						2'd3: multi_pre = 3'd7;
					endcase
					height = {7'd0, multi_pre, 4'b0} + 11'd16;
					sy_top = flipscreen_spr ? $signed({sy_pre[9], sy_pre}) : 11'sd0;
					dy_pre = $signed({scan_y[9], scan_y}) - sy_top;
					if (sc_sram == 16'd0)
						sc_state <= SC_NEXT;
					else if (sc_sram[12] && frame_odd)
						sc_state <= SC_NEXT;   // flash: spento su frame dispari
					else if (flipscreen_spr && (dy_pre < 0 || dy_pre >= $signed({1'b0, height})))
						sc_state <= SC_NEXT;
					else
						sc_state <= SC_D1;
				end
			end
			SC_D1: begin
				sc_d1 <= sc_sram;          // = code word
				sc_state <= SC_PUSH;
			end
			SC_PUSH: begin
				// sc_sram = x word (indirizzo fermo da SC_A2: stabile in stall).
				if (sc_d0 == 16'd0 && sc_d1 == 16'd0 && sc_sram == 16'd0) begin
					sc_state <= SC_NEXT;   // entry tutta zero (vecchia S_CHECK)
				end else if (!mf_full) begin
					mfifo[mf_w[6:0]] <= {sc_chip, sc_sram, sc_d1, sc_d0};
					mf_w <= mf_w + 8'd1;
					sc_state <= SC_NEXT;
				end
				// mf_full: stall qui finche' il draw libera spazio
			end
			SC_NEXT: begin
				if (sc_off >= 10'd1020) begin
					if (sc_chip == 1'b0 && CHIP_ONLY == 2'b00) begin
						sc_chip  <= 1'b1;
						sc_off   <= 10'd0;
						sc_state <= SC_A0;
					end else begin
						scan_fin <= 1'b1;
						sc_state <= SC_IDLE;
					end
				end else begin
					sc_off   <= sc_off + 10'd4;
					sc_state <= SC_A0;
				end
			end
			default: sc_state <= SC_IDLE;
		endcase
	end
end

// ROM permutations (validate via sprite_viewer)
function [7:0] brev8(input [7:0] b);
	brev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction

wire [31:0] rom_data_cur  = chip_idx ? rom1_data : rom0_data;
wire        rom_valid_cur = chip_idx ? rom1_valid : rom0_valid;
// 2026-07-09 FIX GLITCH P4: il fetch P4 viaggia su porta DDR separata (piu'
// lenta del main: l'arbitro serve prima rd4 poi rd7). La FSM aspettava SOLO
// rom_valid_cur: i primi pixel del gruppo leggevano il byte P4 STANTIO del
// gruppo precedente -> glitch/tile spuri. p4_ok latcha l'arrivo del P4.
reg         p4_ok;
// FIX 2026-07-09 sera (build a vuoto: sprite SPARITI): rom0/rom1_valid sono
// IMPULSI di 1 ck (il bridge li azzera ogni clk) e il P4 arriva sempre DOPO il
// main (arbitro: rd4 prima di rd7) -> "valid && p4_ok" non era MAI vero nello
// stesso ciclo -> FSM inchiodata. I DATI restano stabili negli holding reg del
// bridge: si latchano gli ARRIVI (rom_ok/p4_ok) e la wait guarda i latch.
reg         rom_ok;

// PREFETCH 2026-07-10 (anti-bubbling): il draw legge dalla COPIA LATCHATA
// (rom_lat/p4_lat) invece che dagli holding reg del bridge, cosi' la fetch
// della meta' B parte MENTRE si disegna la meta' A (round-trip DDR nascosto
// sotto gli 8 px di draw). Output bit-identico: la copia == holding reg al
// momento del latch, e il draw di oggi leggeva quel valore stabile.
reg [31:0] rom_lat;
reg [7:0]  p4_lat;
// ── DRAW ENGINE DISACCOPPIATO (cross-sprite prefetch 2026-07-18) ──
// Il draw degli 8 px gira in PARALLELO alla FSM: al dispatch (arrivo del fetch)
// si snapshotta il contesto minimo (rom_lat/p4_lat + questi 5 reg) e la FSM
// prosegue SUBITO con l'address-gen del gruppo successivo — B, colonna 2, o
// PRIMO GRUPPO DEL PROSSIMO SPRITE — cosi' ogni round-trip DDR (incluso quello
// al confine tra sprite, prima scoperto) corre sotto gli 8 px in draw.
// Pixel bit-identici: stessi dati, stessi indirizzi, stesso ordine per gruppo.
reg        d_busy;
reg [2:0]  d_pix;
reg signed [9:0] d_sx;
reg        d_half, d_chip, d_flipx;
reg [7:0]  d_color;
wire [31:0] rom_swap = osd_spr_swap_hl ? {rom_lat[15:0], rom_lat[31:16]} : rom_lat;
wire [31:0] rom_bsab = osd_spr_bs_ab ?
	{rom_swap[23:16], rom_swap[31:24], rom_swap[7:0], rom_swap[15:8]} :
	rom_swap;
wire [31:0] rom_nibsw = osd_spr_nibsw ?
	{rom_bsab[27:24], rom_bsab[31:28], rom_bsab[19:16], rom_bsab[23:20],
	 rom_bsab[11:8],  rom_bsab[15:12], rom_bsab[3:0],   rom_bsab[7:4]} :
	rom_bsab;
wire [31:0] rom_perm = osd_spr_brev8 ?
	{brev8(rom_nibsw[31:24]), brev8(rom_nibsw[23:16]),
	 brev8(rom_nibsw[15:8]),  brev8(rom_nibsw[7:0])} :
	rom_nibsw;

// fx_eff = flipx ^ flipscreen_spr (MAME riga 306-313: flipscreen invertito m_flipallx=0)
// NB: fx_eff (dai reg FSM) serve SOLO all'address-gen (half_use in S_ROM_REQ);
// la catena pen del DRAW usa lo snapshot d_flipx/d_pix (il draw gira in parallelo
// mentre la FSM ha gia' decodificato lo sprite successivo).
wire fx_eff = flipx ^ flipscreen_spr;
wire d_fx_eff = d_flipx ^ flipscreen_spr;
// MSB-first vs LSB-first selection runtime (osd_spr_msb_first)
wire [2:0] bit_x_lsb = d_fx_eff ? d_pix : (3'd7 - d_pix);
wire [2:0] bit_x_msb = d_fx_eff ? (3'd7 - d_pix) : d_pix;
wire [2:0] bit_x = osd_spr_msb_first ? bit_x_msb : bit_x_lsb;

// per-plane byte source selection: ogni plane sceglie da quale dei 4 byte del fetch 32-bit pescare.
// default boogwing: p0=byte0, p1=byte1, p2=byte2, p3=byte3 (= [0..7], [8..15], [16..23], [24..31])
function [4:0] byte_base(input [1:0] src);
	case (src)
		2'd0: byte_base = 5'd0;
		2'd1: byte_base = 5'd8;
		2'd2: byte_base = 5'd16;
		2'd3: byte_base = 5'd24;
	endcase
endfunction
wire p0_bit = rom_perm[byte_base(osd_spr_p0_src) + {2'd0, bit_x}];
wire p1_bit = rom_perm[byte_base(osd_spr_p1_src) + {2'd0, bit_x}];
wire p2_bit = rom_perm[byte_base(osd_spr_p2_src) + {2'd0, bit_x}];
wire p3_bit = rom_perm[byte_base(osd_spr_p3_src) + {2'd0, bit_x}];

// MAME planeoffset = {hi+8, hi+0, lo+8, lo+0} → plane 0 = byte 3 (mbd-05 alto),
// plane 1 = byte 2, plane 2 = byte 1, plane 3 = byte 0 (mbd-06 basso).
// FIX BUG #4: default pen = {p3, p2, p1, p0} (= reversed), verificato sim DIFF=0
// per tutti i tile testati (1..1000). Era {p0,p1,p2,p3} = sbagliato.
// OSD plane_inv ora flippa al inverso (= ripristina vecchia logica per regression).
wire [3:0] pen_raw = {p3_bit, p2_bit, p1_bit, p0_bit};
wire [3:0] draw_pen = osd_spr_plane_inv ? {pen_raw[0], pen_raw[1], pen_raw[2], pen_raw[3]} : pen_raw;

// NS chip0 5th plane (mbh-06): the rom0_p4 byte holds 8 px of plane 0 (= pen MSB).
// p4_bit for the current pixel; only meaningful on chip0 when SPR0_5BPP=1.
// PREFETCH: legge dalla copia latchata (vedi rom_lat).
wire p4_bit = p4_lat[bit_x];
// 5-bit pen for the NS 5bpp path: plane0(mbh06)=MSB, then planes1..4 = draw_pen.
// draw_pen[3:0] are the 4 normal planes (mbh-02/04). MAME order: pen={p4,planes1..4}.
wire [4:0] draw_pen5 = {p4_bit, draw_pen};
// transparency: chip0 5bpp tests the 5-bit pen, everything else the 4-bit pen.
// (d_chip: snapshot al dispatch — la FSM puo' aver gia' cambiato chip_idx.)
wire pen_nonzero = ((SPR0_5BPP != 0) && !d_chip) ? (draw_pen5 != 5'd0)
                                                 : (draw_pen != 4'd0);

// ============================================================
// FSM
// ============================================================
always @(posedge clk) begin
	if (reset) begin
		state      <= S_IDLE;
		lb_we0     <= 1'b0;
		lb_we1     <= 1'b0;
		rom0_req   <= 1'b0;
		rom1_req   <= 1'b0;
		rom0_p4_req  <= 1'b0;
		rom0_p4_addr <= 24'd0;
		p4_ok      <= 1'b1;
		rom_ok     <= 1'b1;
		// SCAN-OMBRA: sram0/1_addr ora pilotati SOLO dalla FSM di scan
		mf_r       <= 8'd0;
		chip_idx   <= 1'b0;
		d_busy     <= 1'b0;
		d_pix      <= 3'd0;
	end else begin
		lb_we0 <= 1'b0;
		lb_we1 <= 1'b0;
		// PREFETCH: default-clear delle req ogni ciclo -> ogni emissione (da
		// S_ROM_REQ o dal ramo prefetch in S_ROM_WAIT) dura ESATTAMENTE 1 clk
		// (l'assegnazione nello stato, successiva nel sorgente, vince quel ciclo).
		rom0_req    <= 1'b0;
		rom1_req    <= 1'b0;
		rom0_p4_req <= 1'b0;
		// Latch degli ARRIVI (i valid sono impulsi 1 ck; i dati restano negli
		// holding reg del bridge). Il clear a nuova richiesta sta in S_ROM_REQ
		// (assegnazione successiva nel sorgente = vince quel ciclo).
		if (rom0_p4_valid)  p4_ok  <= 1'b1;
		if (rom_valid_cur)  rom_ok <= 1'b1;

		// ── DRAW ENGINE (parallelo alla FSM, gruppo di 8 px atomico) ──
		// Scrive il linebuffer dal contesto snapshottato al dispatch (d_*).
		// Mai in conflitto con S_CLEAR: il clear precede ogni dispatch.
		if (d_busy) begin
			begin : draw_engine
				reg signed [10:0] xpos_s;
				reg signed [10:0] sx_ext;
				reg signed [10:0] pix_ext;
				sx_ext  = $signed({d_sx[9], d_sx});
				pix_ext = $signed({7'b0, d_half ^ osd_spr_half_inv, d_pix});
				xpos_s  = sx_ext + pix_ext;
				if (pen_nonzero
				    && xpos_s >= 11'sd0 && xpos_s < 11'sd320) begin
					lb_waddr <= xpos_s[8:0];
					lb_wdata <= ((SPR0_5BPP != 0) && !d_chip)
					            ? {d_color, draw_pen5}
					            : {1'b0, d_color, draw_pen};
					if (d_chip) lb_we1 <= 1'b1;
					else        lb_we0 <= 1'b1;
				end
			end
			if (d_pix == 3'd7) d_busy <= 1'b0;
			else               d_pix  <= d_pix + 3'd1;
		end

		case (state)
			S_IDLE: begin
				if (line_start) begin
					// ELASTICO: target = linea che il display richiedera' tra
					// (1+fill) hbl = latched_render_y + 1 + fill. Con fill=0 e'
					// il legacy (latched+1, incluso il comportamento al wrap di
					// frame in vblank); con fill>0 si lavora avanti (max +2).
					// Il buffer o esce nel suo slot esatto o viene scartato
					// dall'abort LATE: mai linee sfasate a schermo.
					scan_y     <= latched_render_y + 10'd1 + {8'd0, fill};
					mf_r       <= 8'd0;
					clear_idx  <= 10'd0;
					state      <= S_CLEAR;
				end
			end

			S_CLEAR: begin
				// Clear linebuf back (entrambi i chip in parallelo)
				lb_we0   <= 1'b1;
				lb_we1   <= 1'b1;
				lb_waddr <= clear_idx[8:0];
				lb_wdata <= 13'h000;
				if (clear_idx == 10'd511) begin
					state       <= S_POP;
				end else begin
					clear_idx <= clear_idx + 10'd1;
				end
			end

			S_POP: begin
				// SCAN-OMBRA: preleva il prossimo match dalla FIFO. mf_q_r e'
				// la lettura registrata di mfifo[mf_r]: valida perche' mf_r e'
				// fermo da >=1 ciclo; mf_empty_d (ritardato) garantisce che
				// l'entry sia stata scritta >=1 ciclo prima (guardia RDW).
				// Decode identico alla vecchia S_CHECK, sorgenti dalla FIFO:
				// entry = {chip[48], x_word[47:32], code_word[31:16], y_word[15:0]}.
				if (!mf_empty && !mf_empty_d) begin
					chip_idx <= mf_q_r[48];
					flipy    <= mf_q_r[14];
					flipx    <= mf_q_r[13];
					w_mode   <= mf_q_r[11];
					begin : decode_h
						reg [1:0] hbits;
						hbits = {mf_q_r[10], mf_q_r[9]};
						case (hbits)
							2'd0: multi <= 3'd0;
							2'd1: multi <= 3'd1;
							2'd2: multi <= 3'd3;
							2'd3: multi <= 3'd7;
						endcase
					end
					color     <= {mf_q_r[15], mf_q_r[47:41]};
					code_base <= mf_q_r[31:16];
					w_iter    <= 1'b0;
					begin : decode_xy
						reg signed [9:0] sy_d;
						reg signed [9:0] sx_d;
						reg signed [9:0] anchor_base;
						reg signed [9:0] sx_first;
						sy_d = sxy_decode_y(mf_q_r[8:0]);
						sx_d = sxy_decode_x(mf_q_r[40:32]);
						// flipscreen_spr applicato: se ON, identity (= sy_d, sx_d).
						// Se OFF, doppia inversione MAME (240-y, 304-x).
						if (flipscreen_spr) begin
							sy_signed   <= sy_d;
							anchor_base = sx_d;
						end else begin
							sy_signed   <= $signed(10'sd240) - sy_d;
							anchor_base = $signed(10'sd304) - sx_d;
						end
						sx_anchor <= anchor_base;
						if (osd_spr_w_swap_pos)
							sx_first = anchor_base
							           + (flipscreen_spr ? 10'sd16 : -10'sd16)
							           + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
						else if (osd_spr_w_offset_first)
							sx_first = anchor_base + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
						else
							sx_first = anchor_base;
						sx_col    <= sx_first;
					end
					mf_r  <= mf_r + 8'd1;
					state <= S_FIND_ROW;
				end else if (mf_empty && scan_fin) begin
					// FIFO vuota E scan finita: linea completa (S_FLUSH attende
					// l'eventuale ultimo draw ancora in corso)
					state <= S_FLUSH;
				end
				// FIFO vuota ma scan in corso: attendi qui
			end

			S_FIND_ROW: begin
				// MAME decospr.cpp:297-304:
				//   flipscreen OFF: mult = -16, tile cresce verso l'alto da sy
				//     → bounding box [sy - 16*multi, sy + 16)
				//     → dy_top = scan_y - (sy - 16*multi) = (scan_y - sy) + 16*multi
				//   flipscreen ON:  mult = +16, tile cresce verso il basso da sy
				//     → bounding box [sy, sy + 16*(multi+1))
				//     → dy_top = scan_y - sy
				// fy_eff = flipy ^ flipscreen_spr  (MAME riga 300: if (fy) fy=0; else fy=1)
				//
				// tile_idx = "posizione visiva del tile dentro lo sprite multi" (0=top).
				// = dy_u[6:4] SEMPRE (la flip di fy NON va qui, va sul code in S_ROM_REQ).
				// row_in_tile = riga Y dentro il tile, invertita se fy_eff (= row flip del tile).
				begin : isect_calc
					reg signed [10:0] dy_s;
					reg [10:0] dy_u;
					reg [10:0] height_total;
					reg signed [10:0] offset_top;
					offset_top = flipscreen_spr ? 11'sd0
					                            : $signed({{4{1'b0}}, multi, 4'b0});
					dy_s = ($signed({scan_y[9], scan_y}) - $signed({sy_signed[9], sy_signed}))
					     + offset_top;
					height_total = {7'd0, multi, 4'b0} + 11'd16;  // = 16*(multi+1)
					if (dy_s >= 11'sd0 && dy_s < $signed({1'b0, height_total})) begin
						dy_u = dy_s[10:0];
						tile_idx <= dy_u[6:4];   // 0..multi, NO fy inv
						// fy_eff row inversion
						if (flipy ^ flipscreen_spr)
							row_in_tile <= 4'd15 - dy_u[3:0];
						else
							row_in_tile <= dy_u[3:0];
						half        <= 1'b0;
						state       <= S_ROM_REQ;
					end else begin
						// Sprite NON intersezione: skip TOTALE (S_NEXT_SPR).
						// FIX 2026-07-18: prima passava da S_NEXT_W e per gli sprite
						// w_mode il ramo w scattava comunque -> DRAW FANTASMA della
						// col2 di uno sprite rifiutato (dati stantii nel vecchio
						// flusso, fetch sprecata nel nuovo) = pixel spuri sugli
						// overlap + budget bruciato. MAME: non-intersecante = nulla.
						state <= S_NEXT_SPR;
					end
				end
			end

			S_ROM_REQ: begin
				// FIX BUG #1: code_y, code_col_extra, code_sel calcolati BLOCKING per evitare
				// non-blocking dependency intra-ck (= leggere code_y prima dell'assegnazione
				// non-blocking → valore VECCHIO dello sprite/iter precedente).
				begin : compute_and_fetch
					reg [15:0] base_aligned;
					reg        fy_eff;
					reg [15:0] code_y_new;
					reg [15:0] code_col_extra_new;
					reg        half_use;
					reg [3:0]  row_use;
					reg [15:0] code_sel;

					fy_eff = flipy ^ flipscreen_spr;
					base_aligned = code_base & ~({13'd0, multi});
					code_y_new = fy_eff
					             ? (base_aligned + ({13'd0, multi} - {12'd0, tile_idx}))
					             : (base_aligned + {12'd0, tile_idx});
					code_col_extra_new = code_y_new - {13'd0, multi} - 16'd1;


					// FIX flipx half-swap: quando fx_eff=1 (sprite specchiato), MAME inverte
					// anche l'ordine dei 2 half del tile (oltre al flip pixel-in-byte già
					// fatto da bit_x). Senza questo XOR, lo sprite specchiato mostra il
					// quadrante sx dove dovrebbe esserci il dx (e viceversa).
					half_use = (~half ^ fx_eff) ^ osd_spr_half_eff_inv;
					row_use  = osd_spr_row_inv ? (4'd15 - row_in_tile) : row_in_tile;
					code_sel = (w_iter ^ osd_spr_w_code_swap) ? code_col_extra_new : code_y_new;

					// HALF-ADIACENTE (2026-07-11): main = {code, ROW, HALF} (meta' A/B
					// adiacenti in DDR = fetch B cache-hit arbitro). Il download applica
					// la stessa rotazione (spr_G*s nel top). P4 resta {code, half, row}
					// (layout lineare invariato).
					if (chip_idx) begin
						rom1_addr <= {2'd0, code_sel, row_use, half_use, 1'b0};
						rom1_req  <= 1'b1;
					end else begin
						rom0_addr <= {2'd0, code_sel, row_use, half_use, 1'b0};
						rom0_req  <= 1'b1;
						// P4 (5th plane) fetch: 1 byte/group, layout LINEARE originale.
						rom0_p4_addr <= {3'd0, code_sel, half_use, row_use};
						rom0_p4_req  <= 1'b1;
						p4_ok        <= 1'b0;   // aspetta il P4 di QUESTO gruppo
					end
					rom_ok <= 1'b0;             // aspetta il main di QUESTO gruppo
				end
				state       <= S_ROM_WAIT;
			end

			S_ROM_WAIT: begin
				rom0_req <= 1'b0;
				rom0_p4_req <= 1'b0;
				rom1_req <= 1'b0;
				// FIX P4 v2: aspetta i LATCH di entrambi gli arrivi (main + P4).
				if (rom_ok && (chip_idx || (SPR0_5BPP == 0) || p4_ok) && ~d_busy) begin
					// DISPATCH (cross-sprite prefetch 2026-07-18): snapshot del
					// contesto draw e prosecuzione IMMEDIATA con l'address-gen del
					// gruppo successivo (B, col2 o primo gruppo del PROSSIMO sprite,
					// via S_NEXT_*/S_POP/S_FIND_ROW/S_ROM_REQ): il suo round-trip
					// DDR corre sotto gli 8 px appena lanciati. Il vecchio ramo
					// prefetch within-sprite e' assorbito da questo caso generale.
					rom_lat <= rom_data_cur;
					p4_lat  <= rom0_p4_data;
					d_sx    <= sx_col;
					d_half  <= half;
					d_chip  <= chip_idx;
					d_flipx <= flipx;
					d_color <= color;
					d_pix   <= 3'd0;
					d_busy  <= 1'b1;
					if (~half) begin
						half  <= 1'b1;
						state <= S_ROM_REQ;    // fetch B sotto il draw della A
					end else begin
						state <= S_NEXT_HALF;  // col2/prossimo sprite sotto il draw della B
					end
				end
			end

			S_NEXT_HALF: begin
				// 16 col disegnati per la row corrente del sprite. Vai a w_mode o next sprite.
				half <= 1'b0;
				state <= S_NEXT_W;
			end

			S_NEXT_W: begin
				if (w_mode && !w_iter) begin
					w_iter <= 1'b1;
					// FIX BUG #2: MAME decospr.cpp:351 → 2° blocco a (x+16) per flipscreen_spr=1,
					// (x-16) per flipscreen_spr=0. Era cablato a -16 fisso = INVERTITO per boogwing default.
					// OSD w_swap_pos: scambia 1°/2° blocco. OSD w_offset: offset extra signed.
					if (osd_spr_w_swap_pos)
						sx_col <= sx_anchor;
					else
						sx_col <= sx_anchor
						          + (flipscreen_spr ? 10'sd16 : -10'sd16)
						          + ({{6{osd_spr_w_offset[3]}}, osd_spr_w_offset, 4'd0});
					half   <= 1'b0;
					// cross-sprite prefetch: la richiesta della col2 parte da
					// S_ROM_REQ ADESSO, mentre il draw della B col1 gira in parallelo.
					state  <= S_ROM_REQ;
				end else begin
					state <= S_NEXT_SPR;
				end
			end

			// 2026-07-09 scan ASCENDENTE (verdetto a schermo). SCAN-OMBRA: l'ordine
			// e' garantito dalla FIFO (push in ordine di scansione); qui si torna
			// semplicemente a prelevare il prossimo match.
			S_NEXT_SPR: begin
				state <= S_POP;
			end

			S_FLUSH: begin
				// Chiusura linea: attende la fine del draw engine (8 px atomici),
				// mai scritture linebuffer oltre done_ok/swap. 1 ciclo se idle.
				if (~d_busy) state <= S_DONE;
			end

			S_DONE: begin
				// Linea completa: done_ok (wire) mette il buffer in coda in
				// questo stesso ciclo (o lo scarta se abortito). Si torna IDLE:
				// col free-run la prossima linea puo' partire subito.
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
