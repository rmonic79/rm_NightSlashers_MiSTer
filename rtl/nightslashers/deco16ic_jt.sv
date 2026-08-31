//
// deco16ic_jt.sv — DECO16IC tilemap engine in stile Jotego BAC06.
//
// Riferimento architetturale: reference/jt/cop/hdl/jtcop_bac06.v
//
// Differenze rispetto a BAC06 (RoboCop / 1 chip = 1 layer):
//   - DECO16IC ha 2 layer pf1 + pf2 nello stesso chip
//   - VRAM pf1 e pf2 separate (8KB ciascuna)
//   - 1 set di ctrl registers (8 word) condiviso
//   - Rowscroll RAM separata pf1+pf2
//
// Stile rendering (copiato Jotego):
//   - Scanline-based con line buffer 2×320 pixel (1 per pf1, 1 per pf2)
//   - Al HSync rising: scan tile della linea successiva
//   - Per ogni tile: 1 fetch ROM 32-bit, shift right per estrarre 8 pixel,
//     scrittura linebuf 8 pixel
//   - 16x16: 2 fetch per tile (half=0 → bit5=1, half=1 → bit5=0)
//   - Output pixel: read linebuf @ render_x
//
// Pixel extraction (Jotego no-hflip):
//   draw_pxl = { rom_data[16], rom_data[24], rom_data[0], rom_data[8] }
//   draw_data >>= 1 per ogni pixel
//
// Color combine: 8-bit { tile_pal[3:0], draw_pxl[3:0] }
//

module deco16ic_jt
#(
	parameter [1:0] BANK1_MODE = 2'd0,
	parameter [1:0] BANK2_MODE = 2'd0,
	parameter [4:0] PF1_COL_BANK = 5'd0,
	parameter [3:0] PF1_COL_MASK = 4'hF,
	parameter [4:0] PF2_COL_BANK = 5'd0,
	parameter [3:0] PF2_COL_MASK = 4'hF,
	// NS tilemap_color_bank_w (0x164000) sets pf1/pf2 colour bank at runtime.
	// COL_BANK_DYN=1 → use the pfN_col_bank_dyn input instead of the static param.
	// Default 0 keeps every existing instance (chip0, Boogie Wings) unchanged.
	parameter COL_BANK_DYN = 0,
	parameter integer PF1_TILE_SIZE = 16,
	parameter integer PF2_TILE_SIZE = 16,
	parameter [2:0] PF1_REGION_ID = 3'd1,
	parameter [2:0] PF2_REGION_ID = 3'd1,
	// 5° plane support per pf2 (BoogieWings BG1 5bpp via mbd-02 = TILES2_HI).
	// Quando 1: usa pf2_p4_* port per fetch del 5° plane in parallelo.
	parameter integer PF2_HAS_5BPP = 0,
	parameter [2:0] PF2_REGION_ID_P4 = 3'd4,
	// Savestate SS_IDX per blocco (passati dal top, univoci per istanza)
	parameter integer SS_VRAM_PF1_IDX = 0,
	parameter integer SS_VRAM_PF2_IDX = 0,
	parameter integer SS_RS_PF1_IDX   = 0,
	parameter integer SS_RS_PF2_IDX   = 0,
	parameter integer SS_CTRL_IDX     = 0
)
(
	input  wire        clk,
	input  wire        reset,

	// CPU bus (16-bit)
	input  wire [15:0] cpu_addr,
	input  wire        cpu_cs,
	input  wire        cpu_rd,
	input  wire        cpu_wr,
	input  wire [15:0] cpu_wdata,
	input  wire  [1:0] cpu_dsn,
	output wire [15:0] cpu_rdata,

	// Render timing (forniti dal top)
	input  wire  [9:0] render_x,    // 0..319 in active, oltre in blanking
	input  wire  [9:0] render_y,    // 0..271 frame
	input  wire        hblank_in,   // attivo durante hblank
	input  wire        vblank_in,
	input  wire        ce_pix,

	output wire  [3:0] pf1_pix,
	output wire  [4:0] pf2_pix,    // 5-bit per supporto 5bpp (BG1 BoogieWings)
	output wire  [4:0] pf1_col,
	output wire  [4:0] pf2_col,
	output wire        pf1_opaque,
	output wire        pf2_opaque,

	// Flip screen globale (MAME boogwing.cpp:419-425: pf_control_r(0) bit 7).
	// Sponta solo da chip 0 (chip1 ha il suo ma MAME usa solo chip0).
	output wire        flip_screen,

	// Tile ROM fetch (1 client per layer)
	output wire [23:0] pf1_rom_addr,
	output wire [2:0]  pf1_region_id,
	output wire        pf1_rom_req,
	input  wire [31:0] pf1_rom_data,
	input  wire        pf1_rom_valid,
	output wire [23:0] pf2_rom_addr,
	output wire [2:0]  pf2_region_id,
	output wire        pf2_rom_req,
	input  wire [31:0] pf2_rom_data,
	input  wire        pf2_rom_valid,
	// Reset SOLO delle FSM fetch (sc1/sc2): al restore/boot-kick i bridge DDR si
	// resettano e l'ack in volo va perso -> senza questo il client resta appeso
	// (text/BG1 morti post-restore). NON tocca ctrl/VRAM (stato di gioco restorato).
	input  wire        fetch_rst,

	// Plane 4 dedicated channel (PF2_HAS_5BPP only). Byte raw, no tile_perm.
	// pf2_p4_req toggle separato da pf2_rom_req. Bypassa il path 4-plane:
	// risolve bug bit-pattern frammentato di p4 quando passa per tile_perm.
	output wire        pf2_p4_req,
	input  wire  [7:0] pf2_p4_data,
	input  wire        pf2_p4_valid,

	// === GFX permutazioni OSD runtime (RIMOSSE: hardcoded 0) ===
	input  wire [4:0]  osd_tile_decode_mode,
	input  wire        osd_pixel_bit_msb,
	input  wire        osd_plane_rev32,
	input  wire        osd_nibble_swap,
	input  wire        osd_byte_swap_ab,
	input  wire        osd_xhalf_inv,
	input  wire        osd_tile_hi_rev,
	input  wire [1:0]  osd_vram_swizzle,

	// === Plane 4 (BG1 5bpp) runtime permutations ===
	// Lavorano DOPO sc2_p4_latch (= dato post-tile_perm dal bridge), prima
	// del bit indexing. Solo PF2_HAS_5BPP=1.
	input  wire [1:0]  osd_p4_byte_pos,   // 00=[7:0] 01=[15:8] 10=[23:16] 11=[31:24]
	input  wire        osd_p4_brev8,      // bit-reverse del byte p4 selezionato
	input  wire        osd_p4_bit_shift,  // shift di 1 bit-position (test offset pix_y)

	// Combine 8bpp (MAME tilemap_12_combine_draw, priority 4/5): pf1 e pf2 sono lo STESSO
	// pixel (nibble basso/alto). pf1 usa veff+1, pf2 base usa veff (no +1, fix colscroll camini).
	// Nel combine i due DEVONO leggere la stessa riga Y -> pf2 deve usare veff+1 come pf1.
	// Senza, pf1 e pf2 leggono righe Y diverse di 1px -> rumore a strisce sulle foto 8bpp.
	input  wire        combine_mode,

	// NS dynamic colour banks (only used when COL_BANK_DYN=1). Tie 0 otherwise.
	input  wire [4:0]  pf1_col_bank_dyn,
	input  wire [4:0]  pf2_col_bank_dyn,

	// === Savestate ssbus (4 slot: vram pf1/pf2, rs pf1/pf2). Adaptor interni: dirottano la
	// porta CPU (write) e, durante SS (gioco in pausa), la porta SCAN per il read. Trasparenti
	// a SS idle. Il control[8] e' salvato direttamente via ss_ctrl (come TC0100SCN ctrl[]). ===
	ssbus_if.slave     ss_vram_pf1,
	ssbus_if.slave     ss_vram_pf2,
	ssbus_if.slave     ss_rs_pf1,
	ssbus_if.slave     ss_rs_pf2,
	ssbus_if.slave     ss_ctrl
);

assign pf1_region_id = PF1_REGION_ID;
// pf2 region_id: ora sempre PF2_REGION_ID (il p4 ha canale dedicato pf2_p4_*).
assign pf2_region_id = PF2_REGION_ID;

// p4 toggle req (canale dedicato, separato da pf2_rom_req)
reg sc2_p4_req_tgl;
assign pf2_p4_req = sc2_p4_req_tgl;

// Forward declarations per ModelSim 10.5b (Quartus le accetta inline, MS no).
// State allargato a 5 bit per supportare colscroll lookup per-half (MAME 1:1).
reg [4:0] sc1_state;
reg [4:0] sc2_state;
wire [31:0] rom_perm_fresh     = pf1_rom_data;
wire [31:0] rom_perm_fresh_pf2 = pf2_rom_data;

// =====================================================================
// VRAM + Ctrl regs (CPU side) — invariati rispetto al vecchio modulo
// =====================================================================
wire is_pf1_data = cpu_cs & (cpu_addr[15:13] == 3'b010);
wire is_pf2_data = cpu_cs & (cpu_addr[15:13] == 3'b011);
wire is_pf1_rs   = cpu_cs & (cpu_addr[15:12] == 4'h8);
wire is_pf2_rs   = cpu_cs & (cpu_addr[15:12] == 4'hA);
wire is_ctrl     = cpu_cs & (cpu_addr[15:4]  == 12'd0);

wire [11:0] cpu_pf_idx = cpu_addr[12:1];
wire [10:0] cpu_rs_idx = cpu_addr[11:1];

// no_rw_check: durante read-during-write sulla STESSA cella la M10K ritorna
// "don't care". Senza l'attributo Quartus inferisce comportamento NEW_DATA che
// può glitchare (= X transitorio). Con CPU che scrive e scan che legge in
// parallelo (porta separate ma stessa cella), il glitch su una scanline =
// impurità flicker. no_rw_check dice "non garantirmi NEW_DATA, vecchio va bene"
// → output stabile = no impurità.
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_vram_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_vram_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_vram_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_vram_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_rs_lo [0:2047];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf1_rs_hi [0:2047];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_rs_lo [0:2047];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] pf2_rs_hi [0:2047];
// Init esplicito BRAM (pattern ActFancer: senza init = monnezza al boot)
integer ii_vr;
initial begin
	for (ii_vr = 0; ii_vr < 4096; ii_vr = ii_vr + 1) begin
		pf1_vram_lo[ii_vr] = 8'd0; pf1_vram_hi[ii_vr] = 8'd0;
		pf2_vram_lo[ii_vr] = 8'd0; pf2_vram_hi[ii_vr] = 8'd0;
	end
	for (ii_vr = 0; ii_vr < 2048; ii_vr = ii_vr + 1) begin
		pf1_rs_lo[ii_vr] = 8'd0; pf1_rs_hi[ii_vr] = 8'd0;
		pf2_rs_lo[ii_vr] = 8'd0; pf2_rs_hi[ii_vr] = 8'd0;
	end
end

wire pf1_we_lo = is_pf1_data & cpu_wr & ~cpu_dsn[0];
wire pf1_we_hi = is_pf1_data & cpu_wr & ~cpu_dsn[1];
wire pf2_we_lo = is_pf2_data & cpu_wr & ~cpu_dsn[0];
wire pf2_we_hi = is_pf2_data & cpu_wr & ~cpu_dsn[1];
wire pf1rs_we_lo = is_pf1_rs & cpu_wr & ~cpu_dsn[0];
wire pf1rs_we_hi = is_pf1_rs & cpu_wr & ~cpu_dsn[1];
wire pf2rs_we_lo = is_pf2_rs & cpu_wr & ~cpu_dsn[0];
wire pf2rs_we_hi = is_pf2_rs & cpu_wr & ~cpu_dsn[1];

// Savestate: durante SS (gioco in pausa) la porta CPU write e' dirottata verso il bus SS.
// addr/data da ssbus, we = ssbus.write (scrive lo/hi insieme = 16 bit/parola). A SS idle:
// trasparente (we = CPU, addr = cpu_pf_idx/cpu_rs_idx, data = cpu_wdata).
wire ssv1 = ss_vram_pf1.access(SS_VRAM_PF1_IDX);
wire ssv2 = ss_vram_pf2.access(SS_VRAM_PF2_IDX);
wire ssr1 = ss_rs_pf1.access(SS_RS_PF1_IDX);
wire ssr2 = ss_rs_pf2.access(SS_RS_PF2_IDX);

wire [11:0] pf1v_waddr = ssv1 ? ss_vram_pf1.addr[11:0] : cpu_pf_idx;
wire [11:0] pf2v_waddr = ssv2 ? ss_vram_pf2.addr[11:0] : cpu_pf_idx;
wire [10:0] pf1r_waddr = ssr1 ? ss_rs_pf1.addr[10:0]   : cpu_rs_idx;
wire [10:0] pf2r_waddr = ssr2 ? ss_rs_pf2.addr[10:0]   : cpu_rs_idx;
wire [15:0] pf1v_wdata = ssv1 ? ss_vram_pf1.data[15:0] : cpu_wdata;
wire [15:0] pf2v_wdata = ssv2 ? ss_vram_pf2.data[15:0] : cpu_wdata;
wire [15:0] pf1r_wdata = ssr1 ? ss_rs_pf1.data[15:0]   : cpu_wdata;
wire [15:0] pf2r_wdata = ssr2 ? ss_rs_pf2.data[15:0]   : cpu_wdata;
wire pf1v_we_lo = ssv1 ? ss_vram_pf1.write : pf1_we_lo;
wire pf1v_we_hi = ssv1 ? ss_vram_pf1.write : pf1_we_hi;
wire pf2v_we_lo = ssv2 ? ss_vram_pf2.write : pf2_we_lo;
wire pf2v_we_hi = ssv2 ? ss_vram_pf2.write : pf2_we_hi;
wire pf1r_we_lo = ssr1 ? ss_rs_pf1.write : pf1rs_we_lo;
wire pf1r_we_hi = ssr1 ? ss_rs_pf1.write : pf1rs_we_hi;
wire pf2r_we_lo = ssr2 ? ss_rs_pf2.write : pf2rs_we_lo;
wire pf2r_we_hi = ssr2 ? ss_rs_pf2.write : pf2rs_we_hi;

always @(posedge clk) if (pf1v_we_lo)  pf1_vram_lo[pf1v_waddr] <= pf1v_wdata[ 7:0];
always @(posedge clk) if (pf1v_we_hi)  pf1_vram_hi[pf1v_waddr] <= pf1v_wdata[15:8];
always @(posedge clk) if (pf2v_we_lo)  pf2_vram_lo[pf2v_waddr] <= pf2v_wdata[ 7:0];
always @(posedge clk) if (pf2v_we_hi)  pf2_vram_hi[pf2v_waddr] <= pf2v_wdata[15:8];

always @(posedge clk) if (pf1r_we_lo)  pf1_rs_lo[pf1r_waddr] <= pf1r_wdata[ 7:0];
always @(posedge clk) if (pf1r_we_hi)  pf1_rs_hi[pf1r_waddr] <= pf1r_wdata[15:8];
always @(posedge clk) if (pf2r_we_lo)  pf2_rs_lo[pf2r_waddr] <= pf2r_wdata[ 7:0];
always @(posedge clk) if (pf2r_we_hi)  pf2_rs_hi[pf2r_waddr] <= pf2r_wdata[15:8];

// Setup + read-response SS per le 4 RAM. Il READ riusa la porta SCAN (sc*_vram_idx /
// sc*_rs lookup) dirottata: durante SS il renderer e' in pausa. read_delay 1 ck (latenza BRAM).
reg ssv1_rd_d, ssv2_rd_d, ssr1_rd_d, ssr2_rd_d;
always @(posedge clk) begin
	ss_vram_pf1.setup(SS_VRAM_PF1_IDX, 4096, 1);
	ss_vram_pf2.setup(SS_VRAM_PF2_IDX, 4096, 1);
	ss_rs_pf1.setup  (SS_RS_PF1_IDX,   2048, 1);
	ss_rs_pf2.setup  (SS_RS_PF2_IDX,   2048, 1);

	ssv1_rd_d <= ssv1 & ss_vram_pf1.read;
	ssv2_rd_d <= ssv2 & ss_vram_pf2.read;
	ssr1_rd_d <= ssr1 & ss_rs_pf1.read;
	ssr2_rd_d <= ssr2 & ss_rs_pf2.read;

	if (ssv1 & ss_vram_pf1.write) ss_vram_pf1.write_ack(SS_VRAM_PF1_IDX);
	if (ssv2 & ss_vram_pf2.write) ss_vram_pf2.write_ack(SS_VRAM_PF2_IDX);
	if (ssr1 & ss_rs_pf1.write)   ss_rs_pf1.write_ack(SS_RS_PF1_IDX);
	if (ssr2 & ss_rs_pf2.write)   ss_rs_pf2.write_ack(SS_RS_PF2_IDX);

	if (ssv1_rd_d) ss_vram_pf1.read_response(SS_VRAM_PF1_IDX, {48'b0, sc1_vram_rd});
	if (ssv2_rd_d) ss_vram_pf2.read_response(SS_VRAM_PF2_IDX, {48'b0, sc2_vram_rd});
	if (ssr1_rd_d) ss_rs_pf1.read_response(SS_RS_PF1_IDX, {48'b0, pf1_rs_ss_rd});
	if (ssr2_rd_d) ss_rs_pf2.read_response(SS_RS_PF2_IDX, {48'b0, pf2_rs_ss_rd});
end

// Ctrl regs
reg [15:0] pf12_control [0:7];
wire [2:0] ctrl_idx = cpu_addr[3:1];

// Control[8] regs: write CPU + accesso savestate diretto (8 word, pattern TC0100SCN ctrl[]).
always @(posedge clk) begin
	ss_ctrl.setup(SS_CTRL_IDX, 8, 1);
	if (ss_ctrl.access(SS_CTRL_IDX)) begin
		if (ss_ctrl.write) begin
			pf12_control[ss_ctrl.addr[2:0]] <= ss_ctrl.data[15:0];
			ss_ctrl.write_ack(SS_CTRL_IDX);
		end else if (ss_ctrl.read) begin
			ss_ctrl.read_response(SS_CTRL_IDX, {48'b0, pf12_control[ss_ctrl.addr[2:0]]});
		end
	end else if (is_ctrl & cpu_wr) begin
		if (~cpu_dsn[0]) pf12_control[ctrl_idx][ 7:0] <= cpu_wdata[ 7:0];
		if (~cpu_dsn[1]) pf12_control[ctrl_idx][15:8] <= cpu_wdata[15:8];
	end
end

// Flip screen globale (MAME boogwing.cpp:419-425):
//   flip = m_deco_tilegen[0]->pf_control_r(0); flip_screen = BIT(flip,7);
assign flip_screen = pf12_control[0][7];

// MAME deco16ic.cpp:899-900 (codice, NON il commento header che è invertito):
//   PF1 scroll = ctrl[1] (X), ctrl[2] (Y)
//   PF2 scroll = ctrl[3] (X), ctrl[4] (Y)
wire [15:0] pf1_scroll_x = pf12_control[1];
wire [15:0] pf1_scroll_y = pf12_control[2];
wire [15:0] pf2_scroll_x = pf12_control[3];
wire [15:0] pf2_scroll_y = pf12_control[4];

// Rowscroll enable + style (MAME deco16ic.cpp header riga 94-130)
//   pf12_control[5] (word 0xa):
//     bit 15    = pf1 enable
//     bit 14:11 = pf1 rowscroll style
//     bit 10:8  = pf1 colscroll style
//     bit 7     = pf2 enable
//     bit 6:3   = pf2 rowscroll style
//     bit 2:0   = pf2 colscroll style
//   pf12_control[6] (word 0xc):
//     bit 15 = pf1 8x8 tile
//     bit 14 = pf1 rowscroll enabled
//     bit 13 = pf1 colscroll enabled
//     bit 7  = pf2 8x8 tile
//     bit 6  = pf2 rowscroll enabled
//     bit 5  = pf2 colscroll enabled
// MAME deco16_pf_update condition: (control1 & 0x60) == 0x40 = bit6 set & bit5 clear.
// control1 per pf1 = pf12_control[6] & 0xff (riga 900), per pf2 = >> 8 (riga 899).
// Quindi pf1 rowscroll en = ctrl[6][6:5] == 2'b10. pf2 = ctrl[6][14:13] == 2'b10.
// Style: ctrl[0] per pf_update (per pf1 = ctrl[5] & 0xff = bit 7:0).
//        MAME riga 761: (control0 >> 3) & 0xf -> bit 6:3 per pf1 row style.
//        Per pf2 = ctrl[5] >> 8 = bit 15:8, poi (>> 3) & 0xf -> bit 14:11.
wire [3:0] pf1_rs_style = pf12_control[5][6:3];
wire [3:0] pf2_rs_style = pf12_control[5][14:11];
wire       pf1_rs_en    = (pf12_control[6][6:5] == 2'b10);
wire       pf2_rs_en    = (pf12_control[6][14:13] == 2'b10);

// COLSCROLL Y-per-column (MAME deco16ic.cpp:492-497, 812):
//   col_type = 8 << (control0 & 7) ∈ {8,16,32,64,128,256,512,1024}
//   col_idx = (src_x & 0x1ff) / col_type
//   col_offset = rowscroll_ptr[0x200 + col_idx]   // 16-bit Y offset
//   veff_eff = veff + col_offset
// MAME codice (NON il commento header che è invertito):
//   control0 PF1 = ctrl[5] & 0xff  → col_style = bit 2:0 = ctrl[5][2:0]
//   control0 PF2 = ctrl[5] >> 8    → col_style = bit 2:0 = ctrl[5][10:8]
//   control1 PF1 = ctrl[6] & 0xff  → col_en = bit 5 = ctrl[6][5]
//   control1 PF2 = ctrl[6] >> 8    → col_en = bit 5 = ctrl[6][13]
// Allineato col scroll swap commit aad6e00.
wire [2:0] pf1_cs_style = pf12_control[5][2:0];
wire [2:0] pf2_cs_style = pf12_control[5][10:8];
wire       pf1_cs_en    = pf12_control[6][5];
wire       pf2_cs_en    = pf12_control[6][13];

// PLAYFIELD DISABLE (MAME deco16ic.cpp:465: if(!BIT(control0,7)) return;).
// Il playfield si disegna SOLO se control0 bit7 == 1. control0 pf1 = ctrl[5][7:0] -> bit7=[7];
// control0 pf2 = ctrl[5][15:8] -> bit7=[15]. Se 0 -> playfield trasparente (opaque=0).
wire       pf1_enable   = pf12_control[5][7];
wire       pf2_enable   = pf12_control[5][15];
function [3:0] cs_col_shift(input [2:0] style);
	case (style)
		3'd0: cs_col_shift = 4'd3;   // col_type=8   → idx = x/8
		3'd1: cs_col_shift = 4'd4;   // col_type=16
		3'd2: cs_col_shift = 4'd5;   // col_type=32
		3'd3: cs_col_shift = 4'd6;   // col_type=64
		3'd4: cs_col_shift = 4'd7;   // col_type=128
		3'd5: cs_col_shift = 4'd8;   // col_type=256
		3'd6: cs_col_shift = 4'd9;   // col_type=512
		3'd7: cs_col_shift = 4'd10;  // col_type=1024
		default: cs_col_shift = 4'd3;
	endcase
endfunction
wire [3:0] pf1_cs_shift = cs_col_shift(pf1_cs_style);
wire [3:0] pf2_cs_shift = cs_col_shift(pf2_cs_style);

// Rowscroll lookup: indice = pixel_y_corrente / row_type.
// veff_for_rs = render_y + 1 + scroll_y (= y della prossima scanline).
// Per text 8x8 MAME dimezza numrows (riga 798); equivalente a >> 1 sull'idx.
// Forward decl: pf*_latched_render_y dichiarati sotto riga ~297 dentro go_latch.
// ModelSim 10.5b non accetta forward reg use; dichiaro qui.
reg [9:0] pf1_latched_render_y;
reg [9:0] pf2_latched_render_y;
reg       pf1_go_latch, pf2_go_latch;
// Indice rowscroll: lookahead +2. Con +1 la transizione tra le 2 velocita' era 1 riga fuori;
// togliendo il +1 (+0) diventavano 2 righe fuori (peggio) -> la direzione e' verso il +.
// +2 azzera lo sfasamento (il rowscroll value ha 1 ck di fetch in piu' del tile, serve guardare
// 1 riga oltre il +1 della posizione). NON tocca sc1_veff/sc2_veff (posizioni intatte).
wire [9:0] pf1_veff_rs = pf1_latched_render_y + 10'd2 + pf1_scroll_y[9:0];
wire [9:0] pf2_veff_rs = pf2_latched_render_y + 10'd2 + pf2_scroll_y[9:0];
wire [10:0] pf1_rs_idx_pre = (PF1_TILE_SIZE == 8) ? {1'b0, pf1_veff_rs[9:1]} : {1'b0, pf1_veff_rs};
wire [10:0] pf2_rs_idx_pre = (PF2_TILE_SIZE == 8) ? {1'b0, pf2_veff_rs[9:1]} : {1'b0, pf2_veff_rs};
// Divisione per row_type via shift (row_type e' sempre potenza di 2).
wire [3:0] pf1_rs_shift = (pf1_rs_style <= 4'd8) ? pf1_rs_style : 4'd0;
wire [3:0] pf2_rs_shift = (pf2_rs_style <= 4'd8) ? pf2_rs_style : 4'd0;
wire [10:0] pf1_rs_idx = pf1_rs_idx_pre >> pf1_rs_shift;
wire [10:0] pf2_rs_idx = pf2_rs_idx_pre >> pf2_rs_shift;

// COLSCROLL idx (per-half lookup, MAME 1:1 per pixel collassato a per-half perché
// cs_off è costante nei 8 px consecutivi per col_type≥8).
// idx = 0x200 + (src_x >> cs_shift) per half 0, idx = 0x200 + ((src_x+8) >> cs_shift) h1.
// FIX colonne durante scroll (MAME deco16ic.cpp:493 col_idx da src_x = pixel REALE):
// src_x deve azzerare il sub-tile offset scroll_x[3:0] (16x16) o [2:0] (8x8). Poiche'
// sc*_hn = scroll_x + N*tile (N*16 o N*8 non toccano i bit bassi), sottrarre sub ==
// MASCHERARE i bit bassi di sc*_hn -> bit-select a COSTO ZERO (no sottrattore, no
// cambio fit/timing/accessi DDR: la versione con sottrazione 9-bit rompeva l'audio).
wire [8:0] pf1_cs_hnm = (PF1_TILE_SIZE == 8) ? {sc1_hn[8:3], 3'b0} : {sc1_hn[8:4], 4'b0};
wire [8:0] pf2_cs_hnm = (PF2_TILE_SIZE == 8) ? {sc2_hn[8:3], 3'b0} : {sc2_hn[8:4], 4'b0};
wire [8:0] pf1_cs_off_h0 =  pf1_cs_hnm            >> pf1_cs_shift;
wire [8:0] pf1_cs_off_h1 = (pf1_cs_hnm + 9'd8)    >> pf1_cs_shift;
wire [8:0] pf2_cs_off_h0 =  pf2_cs_hnm            >> pf2_cs_shift;
wire [8:0] pf2_cs_off_h1 = (pf2_cs_hnm + 9'd8)    >> pf2_cs_shift;
wire [10:0] pf1_cs_idx_h0 = {2'b01, pf1_cs_off_h0};
wire [10:0] pf1_cs_idx_h1 = {2'b01, pf1_cs_off_h1};
wire [10:0] pf2_cs_idx_h0 = {2'b01, pf2_cs_off_h0};
wire [10:0] pf2_cs_idx_h1 = {2'b01, pf2_cs_off_h1};

// Mux read 3-way: CPU rd > scan colscroll h0/h1 > rowscroll (default).
wire [10:0] pf1_rs_read_idx = (is_pf1_rs & cpu_rd)        ? cpu_rs_idx :
                              (sc1_state == SC_CS_R)      ? pf1_cs_idx_h0 :
                              (sc1_state == SC_CS_R2)     ? pf1_cs_idx_h1 :
                                                            pf1_rs_idx;
wire [10:0] pf2_rs_read_idx = (is_pf2_rs & cpu_rd)        ? cpu_rs_idx :
                              (sc2_state == SC_CS_R)      ? pf2_cs_idx_h0 :
                              (sc2_state == SC_CS_R2)     ? pf2_cs_idx_h1 :
                                                            pf2_rs_idx;
reg [7:0] pf1_rs_lo_r, pf1_rs_hi_r, pf2_rs_lo_r, pf2_rs_hi_r;
// Read addr RS dirottato a ssbus.addr durante SS (renderer in pausa).
wire [10:0] pf1_rs_raddr = ssr1 ? ss_rs_pf1.addr[10:0] : pf1_rs_read_idx;
wire [10:0] pf2_rs_raddr = ssr2 ? ss_rs_pf2.addr[10:0] : pf2_rs_read_idx;
// 1 always per array → M10K safe
always @(posedge clk) pf1_rs_lo_r <= pf1_rs_lo[pf1_rs_raddr];
always @(posedge clk) pf1_rs_hi_r <= pf1_rs_hi[pf1_rs_raddr];
always @(posedge clk) pf2_rs_lo_r <= pf2_rs_lo[pf2_rs_raddr];
always @(posedge clk) pf2_rs_hi_r <= pf2_rs_hi[pf2_rs_raddr];
wire [15:0] pf1_rs_value = {pf1_rs_hi_r, pf1_rs_lo_r};
wire [15:0] pf2_rs_value = {pf2_rs_hi_r, pf2_rs_lo_r};
wire [15:0] pf1_rs_ss_rd = {pf1_rs_hi_r, pf1_rs_lo_r};
wire [15:0] pf2_rs_ss_rd = {pf2_rs_hi_r, pf2_rs_lo_r};

wire [7:0] bank1_in = pf12_control[7][7:0];
wire [7:0] bank2_in = pf12_control[7][15:8];

function [14:0] bank_calc(input [1:0] mode, input [7:0] bank);
	reg [14:0] base;
	begin
		base = {bank[6:4], 12'd0};
		case (mode)
			// MAME deco32.cpp:918 bank_callback = (bank & ~0xf) << 8 = bank[7:4]<<12,
			// UNIFORME, indipendente dal nibble basso. Il vecchio mode 2 aggiungeva
			// un +0x800 inventato su nibble==0xA (non in MAME) -> mis-bank scenografia
			// chip1 in scene con control[7] nibble 0xA -> tile trasparenti -> sfondo blu.
			2'd1: bank_calc = base;
			2'd2: bank_calc = base;
			default: bank_calc = 15'd0;
		endcase
	end
endfunction

wire [14:0] pf1_bank_off = bank_calc(BANK1_MODE, bank1_in);
wire [14:0] pf2_bank_off = bank_calc(BANK2_MODE, bank2_in);

// CPU readback minimal: rs read condivisa col mux scan (sopra).
reg [15:0] ctrl_rd;
always @(posedge clk) ctrl_rd     <= pf12_control[ctrl_idx];
reg [4:0] is_d;
always @(posedge clk) is_d <= {is_pf1_data, is_pf2_data, is_pf1_rs, is_pf2_rs, is_ctrl};

assign cpu_rdata = is_d[2] ? {pf1_rs_hi_r, pf1_rs_lo_r} :
                   is_d[1] ? {pf2_rs_hi_r, pf2_rs_lo_r} :
                   is_d[0] ? ctrl_rd                    :
                             16'h0000;

// =====================================================================
// HSync rising detection — start scan per la linea successiva
// =====================================================================
reg hbl_d;
always @(posedge clk) hbl_d <= hblank_in;
wire hbl_rise = hblank_in & ~hbl_d;   // start of HBlank = good time to scan

// go_latch: se hbl_rise arriva mentre la FSM è ancora in scan (non IDLE),
// il segnale verrebbe perso → linea non scansionata → linebuf con dati vecchi
// = MONNEZZA. Latcho qui finché la FSM SC_IDLE può consumarlo.
// Pattern copiato da tc0100scn_mame.sv (Darius2 WarriorBlade funzionante).
// pf*_go_latch / pf*_latched_render_y dichiarati sopra (forward use).

// FSM-side handshake declarations forward (sc1_state, sc2_state, SC_IDLE)
// pf1: latch su hbl_rise, clear quando FSM consuma in SC_IDLE.
// Wire forward declarations risolte dopo la FSM (sotto).

// =====================================================================
// SCANLINE SCAN pf1 (Jotego-style)
// =====================================================================
// All'inizio di HBlank della linea N: scansiona tile della linea N+1.
// veff = (render_y + 1) + scroll_y
// hn   = scroll_x  (= scroll iniziale per la riga)
// Per ogni tile: leggi VRAM, fetch ROM, scrivi line buffer pf1.
// Loop fino a riempire 320 pixel (= ~40 tile 16x16).

// State 5-bit (per supportare colscroll per-half + VRAM re-fetch per half 1).
// MAME 1:1: colscroll lookup PER PIXEL (in pratica per HALF di 8 px quando col_type≥8).
// Sequenza per tile 16x16:
//   IDLE → CS_R[h0] → CS_WT → VRAM_R → VRAM_WT/WT2 → ROM_REQ → ROM_TRIG → ROM_WT
//        → DRAW_LO (8 px) → CS_R2[h1] → CS_WT2 → VRAM_R [re-fetch] → ROM_REQ2 → DRAW_HI
//        → next tile (back a CS_R)
localparam [4:0]
	SC_IDLE    = 5'd0,
	SC_CS_R    = 5'd14,   // colscroll RAM lookup half 0 (cols 0..7)
	SC_CS_WT   = 5'd15,   // colscroll wait + latch h0
	SC_VRAM_R  = 5'd1,
	SC_VRAM_WT = 5'd2,
	SC_VRAM_WT2= 5'd11,
	SC_ROM_REQ = 5'd3,
	SC_ROM_TRIG= 5'd4,
	SC_ROM_WT  = 5'd5,
	SC_DRAW_LO = 5'd6,
	SC_CS_R2   = 5'd16,   // colscroll lookup half 1 (cols 8..15)
	SC_CS_WT2  = 5'd17,   // colscroll wait + latch h1
	SC_VRAM_R_H1  = 5'd18, // re-fetch VRAM per half 1 (cs h1 ≠ cs h0 → tile diverso)
	SC_VRAM_WT_H1 = 5'd19,
	SC_VRAM_WT2_H1= 5'd20,
	SC_ROM_LOAD_H1= 5'd21, // sample VRAM h1, update tile_code, va a SC_ROM_REQ2
	SC_ROM_REQ2= 5'd7,
	SC_ROM_TRIG2=5'd8,
	SC_ROM_WT2 = 5'd9,
	SC_DRAW_HI = 5'd10,
	SC_P4_TRIG = 5'd12,
	SC_P4_WT   = 5'd13;

// sc1_state dichiarato all'inizio per ModelSim forward decl
reg [9:0]  sc1_veff;       // y effettivo per la linea in scan
reg [9:0]  sc1_hn;         // x corrente
reg [5:0]  sc1_tile;       // tile counter 0..40
reg [11:0] sc1_vram_idx;
reg [14:0] sc1_tile_code;
reg [3:0]  sc1_tile_pal;
reg        sc1_rom_req_tgl;
reg [31:0] sc1_rom_latch;
reg [3:0]  sc1_pix_cnt;
reg [8:0]  sc1_buf_waddr;  // 0..319 line buffer write addr
reg        sc1_buf_we;
reg [7:0]  sc1_buf_wdata;  // {pal[3:0], pen[3:0]}
reg        sc1_half;       // 16x16 second half

// go_latch pf1: latch hbl_rise quando FSM occupata, consumato in SC_IDLE.
always @(posedge clk) begin
	if (reset) begin
		pf1_go_latch <= 1'b0;
		pf1_latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			pf1_go_latch <= 1'b1;
			pf1_latched_render_y <= render_y;
		end else if (sc1_state == SC_IDLE && pf1_go_latch) begin
			pf1_go_latch <= 1'b0;
		end
	end
end

// COLSCROLL Y latched per-half (h0 = cols 0..7, h1 = cols 8..15). MAME 1:1.
reg [15:0] sc1_cs_value_h0;
reg [15:0] sc1_cs_value_h1;
// Mux current half via sc1_half_logical (= 0 per cols 0..7, 1 per cols 8..15)
wire [15:0] sc1_cs_value_cur = sc1_half_logical ? sc1_cs_value_h1 : sc1_cs_value_h0;
wire [9:0]  sc1_cs_off = pf1_cs_en ? sc1_cs_value_cur[9:0] : 10'd0;
wire [9:0]  sc1_veff_eff = sc1_veff + sc1_cs_off;

// VRAM swizzle hardcoded:
//   8x8 (text)  = Linear        idx = {row[4:0], col[5:0]}
//   16x16 (BG)  = DECO_64x32    idx = {col[5], row[4:0], col[4:0]}
// MAME deco16ic.cpp:245 — TILEMAP_SCAN_ROWS per 8x8, deco16_scan_rows per 16x16.
wire [5:0] sc1_col_w = (PF1_TILE_SIZE == 8) ? {1'b0, sc1_hn[8:3]} : sc1_hn[9:4];
wire [4:0] sc1_row_w = (PF1_TILE_SIZE == 8) ? sc1_veff_eff[7:3]       : sc1_veff_eff[8:4];
wire [11:0] sc1_vram_idx_calc = (PF1_TILE_SIZE == 8) ?
	{1'b0, sc1_row_w, sc1_col_w[5:0]} :
	{1'b0, sc1_col_w[5], sc1_row_w, sc1_col_w[4:0]};

// VRAM read latch
reg [7:0] sc1_vram_rd_lo, sc1_vram_rd_hi;
// Read addr dirottato a ssbus.addr durante SS (renderer in pausa) per leggere la VRAM.
wire [11:0] sc1_vram_raddr = ssv1 ? ss_vram_pf1.addr[11:0] : sc1_vram_idx;
always @(posedge clk) sc1_vram_rd_lo <= pf1_vram_lo[sc1_vram_raddr];
always @(posedge clk) sc1_vram_rd_hi <= pf1_vram_hi[sc1_vram_raddr];
wire [15:0] sc1_vram_rd = {sc1_vram_rd_hi, sc1_vram_rd_lo};

// Pixel-in-tile per Y (= row dentro il tile)
wire [3:0] sc1_pix_y = (PF1_TILE_SIZE == 8) ? {1'b0, sc1_veff_eff[2:0]} : sc1_veff_eff[3:0];

// ROM addr per tile_code 15-bit + pix_y + half:
//   16x16 4bpp: byte_addr = tile_code*64 + half*32 + 2*pix_y (per region)
//                         = {tile_code, half, pix_y[3:0], 1'b0}
//   8x8  4bpp : byte_addr = tile_code*16 + 2*pix_y
//                         = {tile_code, pix_y[2:0], 1'b0}
reg sc1_half_logical;   // 0 = pixel 0..7, 1 = pixel 8..15

// Flip per-tile (MAME deco16ic.cpp:330-341 get_pf1_tile_info):
//   if (vram[15] && ctrl[6][0]) → FLIPX, colour &= 7
//   if (vram[15] && ctrl[6][1]) → FLIPY, colour &= 7
// Per pf2 (16x16): ctrl[6][8] e ctrl[6][9].
// Il bit vram[15] (= sc1_tile_word[15]) e' latched a SC_ROM_REQ.
wire pf1_flipx_ctrl = pf12_control[6][0];
wire pf1_flipy_ctrl = pf12_control[6][1];
reg  sc1_flipx_r, sc1_flipy_r;

// xhalf hardcoded (osd_xhalf_inv=0): half_base = ~half_logical (pixel 0-7 prima).
// tile_hi_rev hardcoded a 0: passthrough tile_code.
wire        sc1_half_eff  = ~sc1_half_logical ^ sc1_flipx_r;
wire [3:0]  sc1_pix_y_eff = sc1_flipy_r ?
                            ((PF1_TILE_SIZE == 8) ? (4'd7 - sc1_pix_y) : (4'd15 - sc1_pix_y)) :
                            sc1_pix_y;
wire [14:0] sc1_tile_code_eff = sc1_tile_code;

wire [23:0] sc1_rom_addr_w =
	(PF1_TILE_SIZE == 8) ? {4'd0, sc1_tile_code_eff, sc1_pix_y_eff[2:0], 1'b0} :
	                       {2'd0, sc1_tile_code_eff, sc1_half_eff, sc1_pix_y_eff[3:0], 1'b0};

// Sticky rom addr per arbiter (latch quando lo state è "TRIG", così
// tile_code è valido al momento del toggle).
reg [23:0] sc1_rom_addr_r;
always @(posedge clk) begin
	if (sc1_state == SC_ROM_TRIG || sc1_state == SC_ROM_REQ2)
		sc1_rom_addr_r <= sc1_rom_addr_w;
end
assign pf1_rom_addr = sc1_rom_addr_r;
assign pf1_rom_req  = sc1_rom_req_tgl;

// FSM scan pf1
always @(posedge clk) begin
	if (reset | fetch_rst) begin
		sc1_state <= SC_IDLE;
		sc1_rom_req_tgl <= 1'b0;
		sc1_buf_we <= 1'b0;
		sc1_buf_waddr <= 9'd0;
		sc1_flipx_r <= 1'b0;
		sc1_flipy_r <= 1'b0;
	end else begin
		sc1_buf_we <= 1'b0;
		case (sc1_state)
			SC_IDLE: begin
				if (pf1_go_latch) begin
					sc1_veff <= pf1_latched_render_y + 10'd1 + pf1_scroll_y[9:0];
					sc1_hn   <= pf1_scroll_x[9:0] + (pf1_rs_en ? pf1_rs_value[9:0] : 10'd0);
					sc1_tile <= 6'd0;
					// Sub-tile X offset: scan parte da tile-aligned, buf_waddr inizia
					// negativo (wrap 9-bit) per scartare i primi N pixel del primo
					// tile (= MAME src_x = scroll_x + render_x).
					// 16x16: sub = (scroll_x + rs)[3:0]. 8x8: sub = (scroll_x + rs)[2:0].
					begin : sub_offset_init
						reg [9:0] hn_eff;
						reg [3:0] sub;
						hn_eff = pf1_scroll_x[9:0] + (pf1_rs_en ? pf1_rs_value[9:0] : 10'd0);
						sub    = (PF1_TILE_SIZE == 8) ? {1'b0, hn_eff[2:0]} : hn_eff[3:0];
						// waddr_init = -sub (= 512 - sub mod 512, 9-bit wrap)
						sc1_buf_waddr <= 9'd0 - {5'd0, sub};
					end
					sc1_half_logical <= 1'b0;
					sc1_cs_value_h0 <= 16'd0;
					sc1_cs_value_h1 <= 16'd0;
					sc1_state <= SC_CS_R;
				end
			end
			SC_CS_R: begin
				// Colscroll RAM lookup half 0 (cols 0..7).
				sc1_state <= SC_CS_WT;
			end
			SC_CS_WT: begin
				// Latch colscroll Y per half 0.
				sc1_cs_value_h0 <= pf1_rs_value;
				sc1_state <= SC_VRAM_R;
			end
			SC_VRAM_R: begin
				// VRAM addr settato → idx_reg update fine ck → BRAM read fine ck+1
				sc1_vram_idx <= sc1_vram_idx_calc;
				sc1_state <= SC_VRAM_WT;
			end
			SC_VRAM_WT: begin
				// 1 ck wait: a fine di QUESTO ck `sc1_vram_rd_lo/hi` hanno
				// catturato pf*_vram[sc1_vram_idx_nuovo]. Nel ck successivo
				// (SC_VRAM_WT2) il valore e' stabile e si puo' campionare.
				sc1_state <= SC_VRAM_WT2;
			end
			SC_VRAM_WT2: begin
				// Extra wait per assorbire potenziali race read-during-write
				// (CPU 68K che scrive VRAM mentre scan legge stessa cella).
				// M10K Cyclone V mixed_port: output stabile dopo 2 ck dall'addr.
				sc1_state <= SC_ROM_REQ;
			end
			SC_ROM_REQ: begin
				// Aggiorna tile_code/pal dalla VRAM, NON toggle req ancora
				sc1_tile_code <= {3'd0, sc1_vram_rd[11:0]} + pf1_bank_off;
				// MAME: colour = tile[15:12], if tile[15] && flipctrl colour &= 7
				sc1_tile_pal  <= (sc1_vram_rd[15] && (pf1_flipx_ctrl | pf1_flipy_ctrl)) ?
				                 {1'b0, sc1_vram_rd[14:12]} : sc1_vram_rd[15:12];
				// Latch flip per-tile (vram[15] && ctrl bit)
				sc1_flipx_r   <= sc1_vram_rd[15] & pf1_flipx_ctrl;
				sc1_flipy_r   <= sc1_vram_rd[15] & pf1_flipy_ctrl;
				sc1_state <= SC_ROM_TRIG;
			end
			SC_ROM_TRIG: begin
				// 1 ck dopo: tile_code è valido, sc1_rom_addr_r può essere
				// aggiornato corretto. Toggle req qui.
				sc1_rom_req_tgl <= ~sc1_rom_req_tgl;
				sc1_state <= SC_ROM_WT;
			end
			SC_ROM_WT: begin
				if (pf1_rom_valid) begin
					sc1_rom_latch <= rom_perm_fresh;   // applica permutazioni 1 volta sola
					sc1_pix_cnt <= 4'd7;
					sc1_buf_we <= 1'b1;
					sc1_state <= SC_DRAW_LO;
				end
			end
			SC_DRAW_LO: begin
				// Draw 8 pixel: counter sc1_pix_cnt 7→0, estrai bit position dinamico
				sc1_buf_we <= 1'b1;
				sc1_buf_waddr <= sc1_buf_waddr + 9'd1;
				if (sc1_pix_cnt == 4'd0) begin
					sc1_buf_we <= 1'b0;
					if (PF1_TILE_SIZE == 16 && sc1_half_logical == 1'b0) begin
						// vai a half=1: lookup colscroll h1 + re-fetch VRAM
						sc1_half_logical <= 1'b1;
						sc1_state <= SC_CS_R2;
					end else begin
						// tile finito
						sc1_half_logical <= 1'b0;
						sc1_tile <= sc1_tile + 6'd1;
						sc1_hn <= sc1_hn + (PF1_TILE_SIZE == 8 ? 10'd8 : 10'd16);
						// Sub-tile offset: waddr può essere unsigned wrap (= 512-N iniziale).
						// Exit SOLO su tile count (waddr check fa exit prematura su wrap).
						if (sc1_tile >= ((PF1_TILE_SIZE == 8) ? 6'd40 : 6'd21)) begin
							sc1_state <= SC_IDLE;
						end else begin
							sc1_state <= SC_CS_R;
						end
					end
				end else begin
					sc1_pix_cnt <= sc1_pix_cnt - 4'd1;
				end
			end
			SC_CS_R2: begin
				// Colscroll RAM lookup half 1 (cols 8..15). MAME 1:1 per-pixel collapsed
				// per HALF perché cs_off è costante negli 8 px consecutivi con col_type≥8.
				sc1_state <= SC_CS_WT2;
			end
			SC_CS_WT2: begin
				// Latch colscroll Y per half 1, poi RE-FETCH VRAM (tile potenzialmente
				// diverso se cs_off h1 != cs_off h0 → veff diverso → row Y diversa).
				sc1_cs_value_h1 <= pf1_rs_value;
				sc1_state <= SC_VRAM_R;
			end
			SC_ROM_REQ2: begin
				sc1_rom_req_tgl <= ~sc1_rom_req_tgl;
				sc1_state <= SC_ROM_WT2;
			end
			SC_ROM_WT2: begin
				if (pf1_rom_valid) begin
					sc1_rom_latch <= rom_perm_fresh;
					sc1_pix_cnt <= 4'd7;
					sc1_buf_we <= 1'b1;
					sc1_state <= SC_DRAW_HI;
				end
			end
			SC_DRAW_HI: begin
				sc1_buf_we <= 1'b1;
				sc1_buf_waddr <= sc1_buf_waddr + 9'd1;
				if (sc1_pix_cnt == 4'd0) begin
					sc1_buf_we <= 1'b0;
					sc1_half_logical <= 1'b0;
					sc1_tile <= sc1_tile + 6'd1;
					sc1_hn <= sc1_hn + 10'd16;
					// SC_DRAW_HI raggiunto SOLO per PF1_TILE_SIZE=16. Exit solo su tile count.
					if (sc1_tile >= 6'd21) begin
						sc1_state <= SC_IDLE;
					end else begin
						sc1_state <= SC_CS_R;
					end
				end else begin
					sc1_pix_cnt <= sc1_pix_cnt - 4'd1;
				end
			end
			default: sc1_state <= SC_IDLE;
		endcase
	end
end

// Permutazioni OSD interne RIMOSSE — moved up for ModelSim forward decl.
// Vedi linea ~480 per uso.

// Bit pick: LSB-first hardcoded (osd_pixel_bit_msb=0 → bit_pos_base = 7-pix_cnt).
// FLIPX inverte: flipx ? pix_cnt : 7-pix_cnt.
wire [2:0] bit_pos = sc1_flipx_r ? sc1_pix_cnt[2:0] : (3'd7 - sc1_pix_cnt[2:0]);
wire [3:0] sc1_pen = {
	sc1_rom_latch[5'd24 + {2'd0, bit_pos}],   // plane bit 24 (MSB nibble)
	sc1_rom_latch[5'd16 + {2'd0, bit_pos}],
	sc1_rom_latch[5'd8  + {2'd0, bit_pos}],
	sc1_rom_latch[{2'd0, bit_pos}]            // plane bit 0 (LSB nibble)
};

always @(*) begin
	sc1_buf_wdata = {sc1_tile_pal, sc1_pen};
end

// =====================================================================
// LINE BUFFER pf1 (320 byte, 8-bit = {pal[3:0], pen[3:0]})
// Double-buffered: scrivo in "back", leggo da "front", toggle ogni linea
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] linebuf1_a [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] linebuf1_b [0:511];
integer ii_lb1;
initial for (ii_lb1=0; ii_lb1<512; ii_lb1=ii_lb1+1) begin
	linebuf1_a[ii_lb1] = 8'd0; linebuf1_b[ii_lb1] = 8'd0;
end
// lb_sel SEPARATO per pf1 e pf2: ognuno flippa quando la sua scan e' IDLE.
// Race precedente gate "entrambi IDLE": se scan PF2 5bpp e' troppo lenta a
// causa di p4 extra fetch (= raddoppia bandwidth chip0.pf2), entrambi-IDLE
// non si verifica mai → flip mancato → tremolio/spazzatura linebuf.
//
// Fix race doppio-swap: `hbl_rise` può coincidere con `sc_state == IDLE`. In
// quel ck l'always-block esegue SIA `pending <= 1` (riga "hbl_rise") SIA
// `pending <= 0` (riga "IDLE && pending"). Verilog NB: l'ULTIMO assign vince
// → pending=0 + swap. Ma il pending appena settato dall'hbl_rise viene
// **perso** → al prossimo hbl_rise rifa swap ma scan stava già scrivendo
// nel buffer "letto" → tremolio. Soluzione: condizione di swap esclude il
// ck di hbl_rise (lì il pending si setta, swap avviene 1 ck dopo se IDLE).
reg lb1_sel;   // pf1 linebuf selector
reg lb2_sel;   // pf2 linebuf selector
reg lb1_swap_pending, lb2_swap_pending;
always @(posedge clk) begin
	if (reset) begin
		lb1_sel <= 1'b0;
		lb2_sel <= 1'b0;
		lb1_swap_pending <= 1'b0;
		lb2_swap_pending <= 1'b0;
	end else begin
		if (hbl_rise) begin
			lb1_swap_pending <= 1'b1;
			lb2_swap_pending <= 1'b1;
		end else begin
			if (sc1_state == SC_IDLE && lb1_swap_pending) begin
				lb1_sel <= ~lb1_sel;
				lb1_swap_pending <= 1'b0;
			end
			if (sc2_state == SC_IDLE && lb2_swap_pending) begin
				lb2_sel <= ~lb2_sel;
				lb2_swap_pending <= 1'b0;
			end
		end
	end
end

// Write: 1 always per array → M10K safe inference. Gating waddr < 320 per
// scartare pixel out-of-range (sub-tile X offset: primi 0..15 pixel wrappano
// a 496..511 unsigned, fuori da [0..319]).
wire sc1_buf_we_g = sc1_buf_we && (sc1_buf_waddr < 9'd320);
always @(posedge clk) if (sc1_buf_we_g &&  lb1_sel == 1'b0) linebuf1_a[sc1_buf_waddr] <= sc1_buf_wdata;
always @(posedge clk) if (sc1_buf_we_g &&  lb1_sel == 1'b1) linebuf1_b[sc1_buf_waddr] <= sc1_buf_wdata;

// Read: 1 always per array, mux DOPO read → M10K safe
reg [7:0] lb1_a_rd, lb1_b_rd;
reg       lb1_sel_d;
always @(posedge clk) lb1_a_rd <= linebuf1_a[render_x[8:0]];
always @(posedge clk) lb1_b_rd <= linebuf1_b[render_x[8:0]];
always @(posedge clk) lb1_sel_d <= lb1_sel;
reg [7:0] lb1_rd;
always @(posedge clk) lb1_rd <= (lb1_sel_d == 1'b0) ? lb1_b_rd : lb1_a_rd;

// =====================================================================
// SAME for pf2 — copia identica ma su VRAM pf2, scroll pf2, region pf2
// =====================================================================
// sc2_state dichiarato all'inizio per ModelSim forward decl
reg [9:0]  sc2_veff;
reg [9:0]  sc2_hn;
reg [5:0]  sc2_tile;
reg [11:0] sc2_vram_idx;
reg [14:0] sc2_tile_code;
reg [3:0]  sc2_tile_pal;
reg        sc2_rom_req_tgl;
reg [31:0] sc2_rom_latch;
reg [3:0]  sc2_pix_cnt;
reg [8:0]  sc2_buf_waddr;
reg        sc2_buf_we;
// sc2_buf_wdata: 9-bit per supportare 4+5 (pal[3:0] + pen[4:0]) quando 5bpp.
// Quando 4bpp standard, bit 8 = 0 (= pen[4]=0 forzato).
reg [8:0]  sc2_buf_wdata;
reg        sc2_half_logical;
// 5° plane (BG1 BoogieWings): latch del dato p4 per half corrente.
reg [31:0] sc2_p4_latch;

// go_latch pf2 (idem pf1)
always @(posedge clk) begin
	if (reset) begin
		pf2_go_latch <= 1'b0;
		pf2_latched_render_y <= 10'd0;
	end else begin
		if (hbl_rise) begin
			pf2_go_latch <= 1'b1;
			pf2_latched_render_y <= render_y;
		end else if (sc2_state == SC_IDLE && pf2_go_latch) begin
			pf2_go_latch <= 1'b0;
		end
	end
end

// COLSCROLL Y latched pf2 per-half (MAME 1:1).
reg [15:0] sc2_cs_value_h0;
reg [15:0] sc2_cs_value_h1;
wire [15:0] sc2_cs_value_cur = sc2_half_logical ? sc2_cs_value_h1 : sc2_cs_value_h0;
// Colscroll: cs_value INTATTO (sottrarlo causava underflow a 1023 quando cs=0 = parte
// lenta camino -> linea nera). Il +1 di lookahead si toglie da sc2_veff sul path colscroll
// (veff >= 1 -> no underflow). Colscroll attivo: veff_eff = render_y + scroll + cs (MAME esatto).
// Colscroll spento: veff_eff = sc2_veff = render_y+1 = sc1_veff (sfondi allineati, no shift).
wire [9:0]  sc2_cs_off = pf2_cs_en ? sc2_cs_value_cur[9:0] : 10'd0;
wire [9:0]  sc2_veff_eff = sc2_veff - (pf2_cs_en ? 10'd1 : 10'd0) + sc2_cs_off;

wire [5:0] sc2_col_w = (PF2_TILE_SIZE == 8) ? {1'b0, sc2_hn[8:3]} : sc2_hn[9:4];
wire [4:0] sc2_row_w = (PF2_TILE_SIZE == 8) ? sc2_veff_eff[7:3]       : sc2_veff_eff[8:4];
wire [11:0] sc2_vram_idx_calc = (PF2_TILE_SIZE == 8) ?
	{1'b0, sc2_row_w, sc2_col_w[5:0]} :
	{1'b0, sc2_col_w[5], sc2_row_w, sc2_col_w[4:0]};

reg [7:0] sc2_vram_rd_lo, sc2_vram_rd_hi;
wire [11:0] sc2_vram_raddr = ssv2 ? ss_vram_pf2.addr[11:0] : sc2_vram_idx;
always @(posedge clk) sc2_vram_rd_lo <= pf2_vram_lo[sc2_vram_raddr];
always @(posedge clk) sc2_vram_rd_hi <= pf2_vram_hi[sc2_vram_raddr];
wire [15:0] sc2_vram_rd = {sc2_vram_rd_hi, sc2_vram_rd_lo};

wire [3:0] sc2_pix_y = (PF2_TILE_SIZE == 8) ? {1'b0, sc2_veff_eff[2:0]} : sc2_veff_eff[3:0];

// Flip per-tile pf2 (MAME deco16ic.cpp:300-311):
//   ctrl[6][8] = FLIPX, ctrl[6][9] = FLIPY (per pf2)
wire pf2_flipx_ctrl = pf12_control[6][8];
wire pf2_flipy_ctrl = pf12_control[6][9];
reg  sc2_flipx_r, sc2_flipy_r;

wire        sc2_half_eff  = ~sc2_half_logical ^ sc2_flipx_r;
wire [3:0]  sc2_pix_y_eff = sc2_flipy_r ?
                            ((PF2_TILE_SIZE == 8) ? (4'd7 - sc2_pix_y) : (4'd15 - sc2_pix_y)) :
                            sc2_pix_y;
wire [14:0] sc2_tile_code_eff = sc2_tile_code;

wire [23:0] sc2_rom_addr_w =
	(PF2_TILE_SIZE == 8) ? {4'd0, sc2_tile_code_eff, sc2_pix_y_eff[2:0], 1'b0} :
	                       {2'd0, sc2_tile_code_eff, sc2_half_eff, sc2_pix_y_eff[3:0], 1'b0};

reg [23:0] sc2_rom_addr_r;
always @(posedge clk) begin
	if (sc2_state == SC_ROM_TRIG || sc2_state == SC_ROM_REQ2)
		sc2_rom_addr_r <= sc2_rom_addr_w;
end
assign pf2_rom_addr = sc2_rom_addr_r;
assign pf2_rom_req  = sc2_rom_req_tgl;

always @(posedge clk) begin
	if (reset | fetch_rst) begin
		sc2_state <= SC_IDLE;
		sc2_rom_req_tgl <= 1'b0;
		sc2_p4_req_tgl  <= 1'b0;
		sc2_buf_we <= 1'b0;
		sc2_buf_waddr <= 9'd0;
		sc2_flipx_r <= 1'b0;
		sc2_flipy_r <= 1'b0;
		sc2_p4_latch <= 32'd0;
	end else begin
		sc2_buf_we <= 1'b0;
		case (sc2_state)
			SC_IDLE: begin
				if (pf2_go_latch) begin
					sc2_veff <= pf2_latched_render_y + 10'd1 + pf2_scroll_y[9:0];
					sc2_hn   <= pf2_scroll_x[9:0] + (pf2_rs_en ? pf2_rs_value[9:0] : 10'd0);
					sc2_tile <= 6'd0;
					// Sub-tile X offset: waddr inizia negativo (= 9-bit wrap) per scartare
					// primi N pixel del primo tile = MAME src_x pixel-by-pixel.
					begin : sub_offset_init2
						reg [9:0] hn_eff;
						reg [3:0] sub;
						hn_eff = pf2_scroll_x[9:0] + (pf2_rs_en ? pf2_rs_value[9:0] : 10'd0);
						sub    = (PF2_TILE_SIZE == 8) ? {1'b0, hn_eff[2:0]} : hn_eff[3:0];
						sc2_buf_waddr <= 9'd0 - {5'd0, sub};
					end
					sc2_half_logical <= 1'b0;
					sc2_cs_value_h0 <= 16'd0;
					sc2_cs_value_h1 <= 16'd0;
					sc2_state <= SC_CS_R;
				end
			end
			SC_CS_R: begin
				sc2_state <= SC_CS_WT;
			end
			SC_CS_WT: begin
				sc2_cs_value_h0 <= pf2_rs_value;
				sc2_state <= SC_VRAM_R;
			end
			SC_VRAM_R: begin
				sc2_vram_idx <= sc2_vram_idx_calc;
				sc2_state <= SC_VRAM_WT;
			end
			SC_VRAM_WT: begin
				sc2_state <= SC_VRAM_WT2;
			end
			SC_VRAM_WT2: begin
				sc2_state <= SC_ROM_REQ;
			end
			SC_ROM_REQ: begin
				sc2_tile_code <= {3'd0, sc2_vram_rd[11:0]} + pf2_bank_off;
				sc2_tile_pal  <= (sc2_vram_rd[15] && (pf2_flipx_ctrl | pf2_flipy_ctrl)) ?
				                 {1'b0, sc2_vram_rd[14:12]} : sc2_vram_rd[15:12];
				sc2_flipx_r   <= sc2_vram_rd[15] & pf2_flipx_ctrl;
				sc2_flipy_r   <= sc2_vram_rd[15] & pf2_flipy_ctrl;
				sc2_state <= SC_ROM_TRIG;
			end
			SC_ROM_TRIG: begin
				sc2_rom_req_tgl <= ~sc2_rom_req_tgl;
				sc2_state <= SC_ROM_WT;
			end
			SC_ROM_WT: begin
				if (pf2_rom_valid) begin
					sc2_rom_latch <= rom_perm_fresh_pf2;
					if (PF2_HAS_5BPP) begin
						// Trigger fetch p4 prima del draw
						sc2_state <= SC_P4_TRIG;
					end else begin
						sc2_pix_cnt <= 4'd7;
						sc2_buf_we <= 1'b1;
						sc2_state <= SC_DRAW_LO;
					end
				end
			end
			SC_P4_TRIG: begin
				// Toggle CANALE DEDICATO pf2_p4_req (non più condivisione con pf2_rom_req).
				sc2_p4_req_tgl <= ~sc2_p4_req_tgl;
				sc2_state <= SC_P4_WT;
			end
			SC_P4_WT: begin
				if (pf2_p4_valid) begin
					// p4 RAW byte (no tile_perm). Caricato in byte basso del latch.
					// Bit position MAME-natural: sc2_pen_p4 = p4_byte[bit_pos].
					sc2_p4_latch <= {24'd0, pf2_p4_data};
					sc2_pix_cnt <= 4'd7;
					sc2_buf_we <= 1'b1;
					// Dopo P4: vado al draw. Distinguo half_logical: 0=draw_lo, 1=draw_hi.
					sc2_state <= sc2_half_logical ? SC_DRAW_HI : SC_DRAW_LO;
				end
			end
			SC_DRAW_LO: begin
				sc2_buf_we <= 1'b1;
				sc2_buf_waddr <= sc2_buf_waddr + 9'd1;
				if (sc2_pix_cnt == 4'd0) begin
					sc2_buf_we <= 1'b0;
					if (PF2_TILE_SIZE == 16 && sc2_half_logical == 1'b0) begin
						// h1: lookup colscroll h1 + re-fetch VRAM, poi ROM_REQ2 (supporta 5bpp)
						sc2_half_logical <= 1'b1;
						sc2_state <= SC_CS_R2;
					end else begin
						sc2_half_logical <= 1'b0;
						sc2_tile <= sc2_tile + 6'd1;
						sc2_hn <= sc2_hn + (PF2_TILE_SIZE == 8 ? 10'd8 : 10'd16);
						// Sub-tile offset: exit solo su tile count (waddr wrap).
						if (sc2_tile >= ((PF2_TILE_SIZE == 8) ? 6'd40 : 6'd21)) begin
							sc2_state <= SC_IDLE;
						end else begin
							sc2_state <= SC_CS_R;
						end
					end
				end else begin
					sc2_pix_cnt <= sc2_pix_cnt - 4'd1;
				end
			end
			SC_CS_R2: begin
				// Colscroll lookup half 1 (mux pf2_rs_read_idx → pf2_cs_idx_h1)
				sc2_state <= SC_CS_WT2;
			end
			SC_CS_WT2: begin
				sc2_cs_value_h1 <= pf2_rs_value;
				sc2_state <= SC_VRAM_R_H1;
			end
			SC_VRAM_R_H1: begin
				// Re-fetch VRAM con sc2_veff_eff aggiornato (h1)
				sc2_vram_idx <= sc2_vram_idx_calc;
				sc2_state <= SC_VRAM_WT_H1;
			end
			SC_VRAM_WT_H1: begin
				sc2_state <= SC_VRAM_WT2_H1;
			end
			SC_VRAM_WT2_H1: begin
				sc2_state <= SC_ROM_LOAD_H1;
			end
			SC_ROM_LOAD_H1: begin
				// Aggiorna tile_code/pal con VRAM h1 (nuovo tile possibile), poi va a ROM_REQ2
				sc2_tile_code <= {3'd0, sc2_vram_rd[11:0]} + pf2_bank_off;
				sc2_tile_pal  <= (sc2_vram_rd[15] && (pf2_flipx_ctrl | pf2_flipy_ctrl)) ?
				                 {1'b0, sc2_vram_rd[14:12]} : sc2_vram_rd[15:12];
				sc2_flipx_r   <= sc2_vram_rd[15] & pf2_flipx_ctrl;
				sc2_flipy_r   <= sc2_vram_rd[15] & pf2_flipy_ctrl;
				sc2_state <= SC_ROM_REQ2;
			end
			SC_ROM_REQ2: begin
				sc2_rom_req_tgl <= ~sc2_rom_req_tgl;
				sc2_state <= SC_ROM_WT2;
			end
			SC_ROM_WT2: begin
				if (pf2_rom_valid) begin
					sc2_rom_latch <= rom_perm_fresh_pf2;
					if (PF2_HAS_5BPP) begin
						sc2_state <= SC_P4_TRIG;  // poi P4_WT, poi DRAW_HI (vedi half=1)
					end else begin
						sc2_pix_cnt <= 4'd7;
						sc2_buf_we <= 1'b1;
						sc2_state <= SC_DRAW_HI;
					end
				end
			end
			SC_DRAW_HI: begin
				sc2_buf_we <= 1'b1;
				sc2_buf_waddr <= sc2_buf_waddr + 9'd1;
				if (sc2_pix_cnt == 4'd0) begin
					sc2_buf_we <= 1'b0;
					sc2_half_logical <= 1'b0;
					sc2_tile <= sc2_tile + 6'd1;
					sc2_hn <= sc2_hn + 10'd16;
					// Sub-tile offset: exit solo su tile count.
					if (sc2_tile >= ((PF2_TILE_SIZE == 8) ? 6'd40 : 6'd21)) begin
						sc2_state <= SC_IDLE;
					end else begin
						sc2_state <= SC_CS_R;
					end
				end else begin
					sc2_pix_cnt <= sc2_pix_cnt - 4'd1;
				end
			end
			default: sc2_state <= SC_IDLE;
		endcase
	end
end

// pf2 perm — moved up for ModelSim forward decl.

wire [2:0] bit_pos_pf2 = sc2_flipx_r ? sc2_pix_cnt[2:0] : (3'd7 - sc2_pix_cnt[2:0]);
// 5° plane (BG1 BoogieWings) — permutazioni OSD applicate runtime.
// sc2_p4_latch = 32-bit post-tile_perm dal bridge. Default bridge mette il word
// p4 in {hi_word, lo_word=0}, tile_perm brev8 lo ribalta a [31:16] = brev8(p4).
//
// Pipeline permutazioni:
//   1) byte_pos (2-bit) : seleziona uno dei 4 byte del latch (estrazione chirurgica,
//                         no swap globale che porterebbe spazzatura altrove)
//   2) brev8            : opzionale bit-reverse del byte selezionato
//   3) bit_shift        : opzionale shift di 1 bit-position per offset test
function [7:0] brev8_p4(input [7:0] b);
	brev8_p4 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction
reg [7:0] p4_byte_sel;
always @(*) begin
	case (osd_p4_byte_pos)
		2'd0: p4_byte_sel = sc2_p4_latch[7:0];
		2'd1: p4_byte_sel = sc2_p4_latch[15:8];
		2'd2: p4_byte_sel = sc2_p4_latch[23:16];
		2'd3: p4_byte_sel = sc2_p4_latch[31:24];
	endcase
end
wire [7:0]  p4_byte = osd_p4_brev8 ? brev8_p4(p4_byte_sel) : p4_byte_sel;
wire [2:0]  p4_bit_pos = bit_pos_pf2 ^ (osd_p4_bit_shift ? 3'd1 : 3'd0);
wire        sc2_pen_p4 = (PF2_HAS_5BPP) ? p4_byte[p4_bit_pos] : 1'b0;
wire [3:0] sc2_pen_4b = {
	sc2_rom_latch[5'd24 + {2'd0, bit_pos_pf2}],
	sc2_rom_latch[5'd16 + {2'd0, bit_pos_pf2}],
	sc2_rom_latch[5'd8  + {2'd0, bit_pos_pf2}],
	sc2_rom_latch[{2'd0, bit_pos_pf2}]
};
wire [4:0] sc2_pen5 = {sc2_pen_p4, sc2_pen_4b};
// sc2_buf_wdata: 9-bit = {pal[3:0], pen[4:0]}. 5bpp usa pen5, 4bpp ha pen[4]=0.
always @(*) sc2_buf_wdata = (PF2_HAS_5BPP) ? {sc2_tile_pal, sc2_pen5}
                                            : {sc2_tile_pal, 1'b0, sc2_pen_4b};

(* ramstyle = "M10K", no_rw_check *) reg [8:0] linebuf2_a [0:511];
(* ramstyle = "M10K", no_rw_check *) reg [8:0] linebuf2_b [0:511];
integer ii_lb2;
initial for (ii_lb2=0; ii_lb2<512; ii_lb2=ii_lb2+1) begin
	linebuf2_a[ii_lb2] = 9'd0; linebuf2_b[ii_lb2] = 9'd0;
end

// Write: 1 always per array → M10K safe inference
// Gating waddr<320 (sub-tile X offset wrap fa waddr unsigned andare a 496..511).
wire sc2_buf_we_g = sc2_buf_we && (sc2_buf_waddr < 9'd320);
always @(posedge clk) if (sc2_buf_we_g &&  lb2_sel == 1'b0) linebuf2_a[sc2_buf_waddr] <= sc2_buf_wdata;
always @(posedge clk) if (sc2_buf_we_g &&  lb2_sel == 1'b1) linebuf2_b[sc2_buf_waddr] <= sc2_buf_wdata;

// Read: 1 always per array, mux DOPO read → M10K safe
reg [8:0] lb2_a_rd, lb2_b_rd;
reg       lb2_sel_d;
always @(posedge clk) lb2_a_rd <= linebuf2_a[render_x[8:0]];
always @(posedge clk) lb2_b_rd <= linebuf2_b[render_x[8:0]];
always @(posedge clk) lb2_sel_d <= lb2_sel;
reg [8:0] lb2_rd;
always @(posedge clk) lb2_rd <= (lb2_sel_d == 1'b0) ? lb2_b_rd : lb2_a_rd;

// =====================================================================
// Output pixel (pen + col + opaque)
// =====================================================================
wire [3:0] pf1_pen_raw = lb1_rd[3:0];
wire [3:0] pf1_pal_raw = lb1_rd[7:4];
// pf2: lb2_rd = {pal[3:0], pen[4:0]} (9-bit). 4bpp ha pen[4]=0 (bit 4 unused).
wire [4:0] pf2_pen_raw = lb2_rd[4:0];
wire [3:0] pf2_pal_raw = lb2_rd[8:5];

// Colour bank: static param by default; dynamic input when COL_BANK_DYN=1 (NS).
wire [4:0] pf1_col_bank_eff = (COL_BANK_DYN != 0) ? pf1_col_bank_dyn : PF1_COL_BANK;
wire [4:0] pf2_col_bank_eff = (COL_BANK_DYN != 0) ? pf2_col_bank_dyn : PF2_COL_BANK;

assign pf1_pix    = pf1_pen_raw;
assign pf1_col    = {1'b0, pf1_pal_raw & PF1_COL_MASK} + pf1_col_bank_eff;
assign pf1_opaque = pf1_enable & (|pf1_pen_raw);

assign pf2_pix    = pf2_pen_raw;
assign pf2_col    = {1'b0, pf2_pal_raw & PF2_COL_MASK} + pf2_col_bank_eff;
assign pf2_opaque = pf2_enable & (|pf2_pen_raw);

endmodule
