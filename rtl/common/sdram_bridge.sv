// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

/*  This file is part of BoogieWings_MiSTer.

    sdram_bridge — adattato a jtframe_sdram64 (4 banchi paralleli reali).

    Client mapping:
      FG0 (chip1.pf1, BG2 alpha) → ba0 (FSM fg0_state, HI+LO sequenziali)
      FG1 (chip1.pf2, BG2 base)  → ba1 (FSM fg1_state, HI+LO sequenziali)
      Main CPU 68K (op + data)   → ba2 (FSM main_state, single word)
      ba3                        → libero (per future migrazioni)
      Download via prog_*        → prog_ba decode da ioctl_addr range

    NOTE: chip0 (BG0 text + BG1) sta su DDR3 — non transita da SDRAM.
*/

module sdram_bridge (
	input         clk,
	input         reset,
	input         sdram_ready,

	// Download from HPS
	input         ioctl_download,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [15:0] ioctl_index,
	output        ioctl_wait,

	// FG0 client (chip1.pf1) — ba0
	input  [23:0] fg0_byte_addr,
	input  [2:0]  fg0_region_id,
	input         fg0_req,
	output [31:0] fg0_data,
	output reg    fg0_valid,

	// FG1 client (chip1.pf2) — ba1
	input  [23:0] fg1_byte_addr,
	input  [2:0]  fg1_region_id,
	input         fg1_req,
	output [31:0] fg1_data,
	output reg    fg1_valid,

	// Main CPU 68K — ba2
	input  [23:0] main_byte_addr,
	input         main_is_opcode,
	input         main_req,
	output [15:0] main_data,
	output reg    main_ready,

	// BG1 client (chip0.pf2, 5bpp) — ba3
	// 3 fetch sequenziali: MID (mbd-00) + LO (mbd-01) + p4 (mbd-02 espanso)
	// p4_data raw 8-bit (no tile_perm) per fix bug bit-pattern frammentato
	input  [23:0] bg1_byte_addr,
	input         bg1_req,            // fetch 4 plane base (output bg1_data + bg1_valid)
	input         bg1_p4_req,          // fetch plane 4 (output bg1_p4_data + bg1_p4_valid)
	output [31:0] bg1_data,
	output reg    bg1_valid,
	output  [7:0] bg1_p4_data,
	output reg    bg1_p4_valid,

	// jtframe_sdram64 per-bank interface
	output reg [21:0] ba0_addr,
	output     [15:0] ba0_din,
	output     [1:0]  ba0_dsn,
	output reg [21:0] ba1_addr,
	output     [15:0] ba1_din,
	output     [1:0]  ba1_dsn,
	output reg [21:0] ba2_addr,
	output     [15:0] ba2_din,
	output     [1:0]  ba2_dsn,
	output     [21:0] ba3_addr,
	output     [15:0] ba3_din,
	output     [1:0]  ba3_dsn,
	output reg [3:0]  ba_rd,
	output     [3:0]  ba_wr,
	input      [3:0]  ba_ack,
	input      [3:0]  ba_rdy,
	input      [3:0]  ba_dst,
	input      [3:0]  ba_dok,
	input      [15:0] sdram_dout,

	// Program (download) interface
	output reg        prog_en,
	output reg [21:0] prog_addr,
	output reg [1:0]  prog_ba,
	output reg        prog_rd,
	output reg        prog_wr,
	output     [15:0] prog_din,
	output     [1:0]  prog_dsn,
	input             prog_ack,
	input             prog_rdy,
	input             prog_dst,
	input             prog_dok,

	// Debug
	output            dbg_main_pending,
	output            dbg_download_active,

	// OSD permutazione memory mapping (legacy, lasciato per compat top)
	input  wire       osd_region_lohi_swap
);

// =========================================================================
// Costanti — SDRAM word layout BoogieWings (planar)
// Stesso schema del bridge Sorgelig precedente: tiles3 = chip1 BG2 = FG0+FG1
//   tiles3_lo (chip1 plane 2,3)  → word offset 0x000000 nel bank
//   tiles3_hi (chip1 plane 0,1)  → word offset 0x080000 nel bank
//   main op   → ba2 word offset 0x000000
//   main data → ba2 word offset 0x318000
// =========================================================================
localparam [21:0] TILES3_LO_BASE = 22'h000000;
localparam [21:0] TILES3_HI_BASE = 22'h080000;
localparam [21:0] MAIN_OP_BASE   = 22'h000000;
localparam [21:0] MAIN_DATA_BASE = 22'h318000;

// BG1 layout in ba3 (= tiles2 BoogieWings, 3 region 5bpp).
// MRA layout fisico (ioctl 0x130000-0x42FFFF, 3 MB):
//   0x000000-0x0FFFFF = mbd-01 (1MB, plane 0+1) → ba3 word offset 0x000000
//   0x100000-0x1FFFFF = mbd-00 (1MB, plane 2+3) → ba3 word offset 0x080000
//   0x200000-0x2FFFFF = mbd-02 (1MB, plane 4 expanded) → ba3 word offset 0x100000
localparam [21:0] TILES2_LO_BASE  = 22'h000000;  // mbd-01
localparam [21:0] TILES2_MID_BASE = 22'h080000;  // mbd-00
localparam [21:0] TILES2_P4_BASE  = 22'h100000;  // mbd-02

// Tutti i write-data path tied off (read-only world)
assign ba0_din = 16'd0; assign ba0_dsn = 2'b00;
assign ba1_din = 16'd0; assign ba1_dsn = 2'b00;
assign ba2_din = 16'd0; assign ba2_dsn = 2'b00;
assign ba3_din = 16'd0; assign ba3_dsn = 2'b00;
assign ba_wr = 4'b0000;

// =========================================================================
// PROGRAM (download) path — pattern jtframe_dwnld letterale.
//
// Layout MRA "_dec_jt" (con duplicazione tiles3 per parallelism FG0/FG1):
//   0x000000-0x0FFFFF   main op_view  (1 MB)   → ba2 word offset 0
//   0x100000-0x10FFFF   audiocpu      (64 KB)  → DDRAM (skip)
//   0x110000-0x12FFFF   tiles1        (128 KB) → DDRAM (skip)
//   0x130000-0x42FFFF   tiles2        (3 MB)   → DDRAM (skip)
//   0x430000-0x62FFFF   tiles3 #1     (2 MB)   → ba0 (FG0)
//   0x630000-0x82FFFF   tiles3 #2     (2 MB)   → ba1 (FG1) DUPLICATO MRA
//   0x830000-0x102FFFF  sprites       (8 MB)   → DDRAM (skip)
//   0x1030000-0x10AFFFF oki1          (512 KB) → DDRAM (skip)
//   0x10B0000-0x112FFFF oki2          (512 KB) → DDRAM (skip)
//   0x1130000-0x122FFFF main data     (1 MB)   → ba2 word offset MAIN_DATA_BASE
//
// Pattern: prog_wr resta ALTO finché non arriva prog_ack (level handshake).
// =========================================================================
// WIDE=1: ioctl_dout è una word completa 16-bit, ioctl_addr avanza di 2 in 2.
// Scriviamo word intere (entrambi i byte abilitati, DSN=00 active-low).
reg  [15:0] dl_data_word;
reg  [21:0] dl_word_addr;
reg  [1:0]  dl_target_ba;
reg         dl_accept;       // 1 se ioctl_addr è in un range SDRAM

assign prog_din = dl_data_word;
assign prog_dsn = 2'b00;  // entrambi byte abilitati (active-low)

// Address range decode (combinatorio). ioctl_addr è byte address, word = addr[22:1].
always @(*) begin
	dl_accept = 1'b0;
	dl_target_ba = 2'd0;
	dl_word_addr = 22'd0;

	// Pattern jtframe_dwnld: word_offset = (ioctl_addr_byte - region_byte_base) / 2.
	// Sottrazione byte-level (27-bit) per evitare wrap, poi shift >> 1 e add base word.
	if (ioctl_addr < 27'h100000) begin
		// main op → ba2 offset 0. word_offset = ioctl_addr/2 (max 0x7FFFF).
		dl_accept    = 1'b1;
		dl_target_ba = 2'd2;
		dl_word_addr = MAIN_OP_BASE + ioctl_addr[20:1];
	end
	else if (ioctl_addr >= 27'h430000 && ioctl_addr < 27'h630000) begin
		// tiles3 #1 → ba0. word_offset = (ioctl_addr-0x430000)/2 = 0..0xFFFFF (20 bit).
		dl_accept    = 1'b1;
		dl_target_ba = 2'd0;
		dl_word_addr = TILES3_LO_BASE + ((ioctl_addr - 27'h430000) >> 1);
	end
	else if (ioctl_addr >= 27'h630000 && ioctl_addr < 27'h830000) begin
		// tiles3 #2 (dup) → ba1. word_offset = (ioctl_addr-0x630000)/2 = 0..0xFFFFF.
		dl_accept    = 1'b1;
		dl_target_ba = 2'd1;
		dl_word_addr = TILES3_LO_BASE + ((ioctl_addr - 27'h630000) >> 1);
	end
	else if (ioctl_addr >= 27'h1130000 && ioctl_addr < 27'h1230000) begin
		// main data → ba2 offset MAIN_DATA_BASE. word_offset = (ioctl_addr-0x1130000)/2 = 0..0x7FFFF.
		dl_accept    = 1'b1;
		dl_target_ba = 2'd2;
		dl_word_addr = MAIN_DATA_BASE + ((ioctl_addr - 27'h1130000) >> 1);
	end
	// BG1 tiles2 → ba3 (3 region da 1 MB ciascuna)
	else if (ioctl_addr >= 27'h130000 && ioctl_addr < 27'h230000) begin
		// mbd-01 (LO) → ba3 word offset 0x000000. (ioctl_addr - 0x130000) >> 1 = 0..0x7FFFF
		dl_accept    = 1'b1;
		dl_target_ba = 2'd3;
		dl_word_addr = TILES2_LO_BASE + ((ioctl_addr - 27'h130000) >> 1);
	end
	else if (ioctl_addr >= 27'h230000 && ioctl_addr < 27'h330000) begin
		// mbd-00 (MID) → ba3 word offset 0x080000
		dl_accept    = 1'b1;
		dl_target_ba = 2'd3;
		dl_word_addr = TILES2_MID_BASE + ((ioctl_addr - 27'h230000) >> 1);
	end
	else if (ioctl_addr >= 27'h330000 && ioctl_addr < 27'h430000) begin
		// mbd-02 (P4, espanso) → ba3 word offset 0x100000
		dl_accept    = 1'b1;
		dl_target_ba = 2'd3;
		dl_word_addr = TILES2_P4_BASE + ((ioctl_addr - 27'h330000) >> 1);
	end
end

// FSM download: word-level write con pattern jtframe-like.
//   prog_wr alto fino a prog_ack.
//   ioctl_wait alto durante l'intera transazione.
always @(posedge clk) begin
	if (reset) begin
		prog_en      <= 1'b0;
		prog_wr      <= 1'b0;
		prog_rd      <= 1'b0;
		prog_ba      <= 2'd0;
		prog_addr    <= 22'd0;
		dl_data_word <= 16'd0;
	end else begin
		prog_en <= ioctl_download;
		prog_rd <= 1'b0;

		// Latch nuova richiesta su ioctl_wr nei range SDRAM.
		// !prog_wr: non sovrascrivere una write in volo (prog_ack multi-ck) ->
		// rete di sicurezza contro word perse. Coi wrapper combinatori ioctl_wait
		// ferma hps_io in tempo, ma questa guardia protegge comunque.
		if (ioctl_wr && ioctl_download && ioctl_index == 16'd0 && dl_accept && !prog_wr) begin
			prog_addr    <= dl_word_addr;
			prog_ba      <= dl_target_ba;
			dl_data_word <= ioctl_dout;
			prog_wr      <= 1'b1;
		end

		// Clear quando ack o quando download finisce
		if (!ioctl_download || prog_ack) begin
			prog_wr <= 1'b0;
		end
	end
end

// ioctl_wait: pending write o controller non pronto
assign ioctl_wait = prog_wr | (ioctl_download & ~sdram_ready);
assign dbg_download_active = ioctl_download;

// =========================================================================
// FG0 FSM (ba0) — chip1.pf1: 2 fetch sequenziali HI poi LO
// =========================================================================
reg  [3:0]  fg0_state;
reg  [15:0] fg0_hi_word;
reg  [15:0] fg0_lo_word;
reg         fg0_req_prev;
localparam [3:0]
	FG_IDLE    = 4'd0,
	FG_REQ_HI  = 4'd1,
	FG_WAIT_HI = 4'd2,
	FG_LATCH_HI= 4'd3,
	FG_REQ_LO  = 4'd4,
	FG_WAIT_LO = 4'd5,
	FG_LATCH_LO= 4'd6;

// Address composition (ROM pre-decrittata, BYPASS_DECRYPT è il default).
// fg0_byte_addr è 24-bit byte address (= 23-bit word). Per 2MB tiles3 servono 20 bit di word index.
// Composizione: base_region (word) + offset_word_dentro_region.
wire [22:0] fg0_word_addr = fg0_byte_addr[23:1];
wire [21:0] fg0_addr_hi   = TILES3_HI_BASE + fg0_word_addr[21:0];
wire [21:0] fg0_addr_lo   = TILES3_LO_BASE + fg0_word_addr[21:0];

always @(posedge clk) begin
	if (reset || ioctl_download) begin
		fg0_state    <= FG_IDLE;
		fg0_valid    <= 1'b0;
		fg0_req_prev <= 1'b0;
		ba0_addr     <= 22'd0;
		ba_rd[0]     <= 1'b0;
	end else begin
		fg0_valid    <= 1'b0;
		fg0_req_prev <= fg0_req;
		ba_rd[0]     <= 1'b0;

		case (fg0_state)
			FG_IDLE: begin
				// Protocollo TOGGLE: deco16ic flippa fg0_req ad ogni nuova richiesta.
				// Trigger su QUALSIASI transizione (rising O falling), non solo rising.
				if (fg0_req ^ fg0_req_prev) fg0_state <= FG_REQ_HI;
			end
			FG_REQ_HI: begin
				ba0_addr <= fg0_addr_hi;
				ba_rd[0] <= 1'b1;
				if (ba_ack[0]) fg0_state <= FG_WAIT_HI;
			end
			FG_WAIT_HI: begin
				// Sample con ba_dst[0] (data starts) per coerenza con FG1.
				// Con BURSTLEN=16: dst == rdy sincroni.
				if (ba_dst[0]) begin
					fg0_hi_word <= sdram_dout;
					fg0_state   <= FG_LATCH_HI;
				end
			end
			FG_LATCH_HI: fg0_state <= FG_REQ_LO;
			FG_REQ_LO: begin
				ba0_addr <= fg0_addr_lo;
				ba_rd[0] <= 1'b1;
				if (ba_ack[0]) fg0_state <= FG_WAIT_LO;
			end
			FG_WAIT_LO: begin
				if (ba_dst[0]) begin
					fg0_lo_word <= sdram_dout;
					fg0_state   <= FG_LATCH_LO;
				end
			end
			FG_LATCH_LO: begin
				fg0_valid <= 1'b1;
				fg0_state <= FG_IDLE;
			end
			default: fg0_state <= FG_IDLE;
		endcase
	end
end

assign fg0_data = {fg0_hi_word, fg0_lo_word};

// =========================================================================
// FG1 FSM (ba1) — chip1.pf2: identico a FG0 ma su ba1
// =========================================================================
reg  [3:0]  fg1_state;
reg  [15:0] fg1_hi_word;
reg  [15:0] fg1_lo_word;
reg         fg1_req_prev;

wire [22:0] fg1_word_addr = fg1_byte_addr[23:1];
wire [21:0] fg1_addr_hi   = TILES3_HI_BASE + fg1_word_addr[21:0];
wire [21:0] fg1_addr_lo   = TILES3_LO_BASE + fg1_word_addr[21:0];

always @(posedge clk) begin
	if (reset || ioctl_download) begin
		fg1_state    <= FG_IDLE;
		fg1_valid    <= 1'b0;
		fg1_req_prev <= 1'b0;
		ba1_addr     <= 22'd0;
		ba_rd[1]     <= 1'b0;
	end else begin
		fg1_valid    <= 1'b0;
		fg1_req_prev <= fg1_req;
		ba_rd[1]     <= 1'b0;

		case (fg1_state)
			FG_IDLE: begin
				// Protocollo TOGGLE come FG0
				if (fg1_req ^ fg1_req_prev) fg1_state <= FG_REQ_HI;
			end
			FG_REQ_HI: begin
				ba1_addr <= fg1_addr_hi;
				ba_rd[1] <= 1'b1;
				if (ba_ack[1]) fg1_state <= FG_WAIT_HI;
			end
			FG_WAIT_HI: begin
				if (ba_dst[1]) begin
					fg1_hi_word <= sdram_dout;
					fg1_state   <= FG_LATCH_HI;
				end
			end
			FG_LATCH_HI: fg1_state <= FG_REQ_LO;
			FG_REQ_LO: begin
				ba1_addr <= fg1_addr_lo;
				ba_rd[1] <= 1'b1;
				if (ba_ack[1]) fg1_state <= FG_WAIT_LO;
			end
			FG_WAIT_LO: begin
				if (ba_dst[1]) begin
					fg1_lo_word <= sdram_dout;
					fg1_state   <= FG_LATCH_LO;
				end
			end
			FG_LATCH_LO: begin
				fg1_valid <= 1'b1;
				fg1_state <= FG_IDLE;
			end
			default: fg1_state <= FG_IDLE;
		endcase
	end
end

assign fg1_data = {fg1_hi_word, fg1_lo_word};

// =========================================================================
// MAIN CPU FSM (ba2) — single word fetch (dual-view: op vs data)
// =========================================================================
reg  [1:0]  main_state;
reg  [15:0] main_data_reg;
reg         main_req_prev;
reg         main_pending;
localparam [1:0]
	M_IDLE = 2'd0,
	M_REQ  = 2'd1,
	M_WAIT = 2'd2;

wire [22:1] main_word_addr = main_byte_addr[23:1];
// NS DE156: MAME deco156_decrypt fa UNA SOLA immagine decrittata (deco156_m.cpp:127
// decrypt(buf,rom,length)), usata sia per opcode CHE per dati. Le due view separate
// (op@0x0 / data@0x318000) erano ereditate da un altro core DECO (op/data diversi) e
// SBAGLIATE per NS: la data-view NON e' mai riempita dal download (la MRA non manda
// niente a ioctl 0x1130000) -> le LDR literal leggevano data-view VUOTA -> dato zero ->
// boot rotto -> NERO. Fix: op e data leggono la STESSA view (MAIN_OP_BASE), come MAME.
wire [21:0] main_addr_v    = MAIN_OP_BASE + {1'b0, main_word_addr[20:1]};

always @(posedge clk) begin
	if (reset || ioctl_download) begin
		main_state    <= M_IDLE;
		main_ready    <= 1'b0;
		main_pending  <= 1'b0;
		main_req_prev <= 1'b0;
		ba2_addr      <= 22'd0;
		ba_rd[2]      <= 1'b0;
		main_data_reg <= 16'd0;
	end else begin
		main_ready    <= 1'b0;
		main_req_prev <= main_req;
		ba_rd[2]      <= 1'b0;

		case (main_state)
			M_IDLE: begin
				if (main_req && !main_req_prev) begin
					main_pending <= 1'b1;
					main_state   <= M_REQ;
				end
			end
			M_REQ: begin
				ba2_addr <= main_addr_v;
				ba_rd[2] <= 1'b1;
				if (ba_ack[2]) main_state <= M_WAIT;
			end
			M_WAIT: begin
				// Main funzionava con ba_rdy[2] (siamo in main loop) → mantengo
				if (ba_rdy[2]) begin
					main_data_reg <= sdram_dout;
					main_ready    <= 1'b1;
					main_pending  <= 1'b0;
					main_state    <= M_IDLE;
				end
			end
			default: main_state <= M_IDLE;
		endcase
	end
end

assign main_data = main_data_reg;
assign dbg_main_pending = main_pending;

// =========================================================================
// BG1 FSM (ba3) — chip0.pf2 5bpp:
//   4-plane base: 2 fetch (MID mbd-00, LO mbd-01) → output bg1_data 32-bit
//   p4:           1 fetch (P4 mbd-02 espanso) → output bg1_p4_data 8-bit RAW
//
// 2 FSM separate sullo stesso bank ba3 (sequenziali via arbiter cooperativo):
// quando una è in IDLE rilascia il bank, l'altra può partire.
// =========================================================================

// Arbitro semplice: BG1 base (4-plane) ha priorità su P4 perché parte prima
// nel pipeline scan (SC_ROM_TRIG → BG1 base; SC_P4_TRIG → BG1 P4).
// Non possono mai sovrapporsi perché entrambe vengono dalla stessa FSM scan
// (sequential: 4-plane first, poi p4).

reg  [3:0]  bg1_state;
reg  [15:0] bg1_hi_word;   // mbd-00 (MID), plane 2+3
reg  [15:0] bg1_lo_word;   // mbd-01 (LO), plane 0+1
reg         bg1_req_prev;
localparam [3:0]
	BG1B_IDLE     = 4'd0,
	BG1B_REQ_HI   = 4'd1,
	BG1B_WAIT_HI  = 4'd2,
	BG1B_LATCH_HI = 4'd3,
	BG1B_REQ_LO   = 4'd4,
	BG1B_WAIT_LO  = 4'd5,
	BG1B_LATCH_LO = 4'd6;

reg  [3:0]  bg1p4_state;
reg  [15:0] bg1_p4_word;
reg         bg1_p4_req_prev;
localparam [3:0]
	BG1P_IDLE     = 4'd0,
	BG1P_REQ      = 4'd1,
	BG1P_WAIT     = 4'd2,
	BG1P_LATCH    = 4'd3;

wire [22:0] bg1_word_addr = bg1_byte_addr[23:1];
wire [21:0] bg1_addr_hi   = TILES2_MID_BASE + bg1_word_addr[21:0];   // mbd-00
wire [21:0] bg1_addr_lo   = TILES2_LO_BASE  + bg1_word_addr[21:0];   // mbd-01
wire [21:0] bg1_addr_p4   = TILES2_P4_BASE  + bg1_word_addr[21:0];   // mbd-02

// ba_rd[3] e ba3_addr driven dal mux delle 2 FSM
reg bg1_rd_req, bg1p4_rd_req;
reg [21:0] bg1_ba3_addr_r;
reg [21:0] bg1p4_ba3_addr_r;
assign ba_rd[3]  = bg1_rd_req | bg1p4_rd_req;
// p4 priorità solo quando base FSM è IDLE (mutua esclusione garantita
// dalla guard in BG1P_IDLE che parte solo se bg1_state == BG1B_IDLE).
assign ba3_addr  = bg1p4_rd_req ? bg1p4_ba3_addr_r : bg1_ba3_addr_r;

// FSM 4-plane base
always @(posedge clk) begin
	if (reset || ioctl_download) begin
		bg1_state    <= BG1B_IDLE;
		bg1_valid    <= 1'b0;
		bg1_req_prev <= 1'b0;
		bg1_rd_req   <= 1'b0;
		bg1_ba3_addr_r <= 22'd0;
	end else begin
		bg1_valid    <= 1'b0;
		bg1_req_prev <= bg1_req;
		bg1_rd_req   <= 1'b0;

		case (bg1_state)
			BG1B_IDLE: begin
				if (bg1_req ^ bg1_req_prev) bg1_state <= BG1B_REQ_HI;
			end
			BG1B_REQ_HI: begin
				bg1_ba3_addr_r <= bg1_addr_hi;
				bg1_rd_req     <= 1'b1;
				if (ba_ack[3]) bg1_state <= BG1B_WAIT_HI;
			end
			BG1B_WAIT_HI: begin
				if (ba_dst[3]) begin
					bg1_hi_word <= sdram_dout;
					bg1_state   <= BG1B_LATCH_HI;
				end
			end
			BG1B_LATCH_HI: bg1_state <= BG1B_REQ_LO;
			BG1B_REQ_LO: begin
				bg1_ba3_addr_r <= bg1_addr_lo;
				bg1_rd_req     <= 1'b1;
				if (ba_ack[3]) bg1_state <= BG1B_WAIT_LO;
			end
			BG1B_WAIT_LO: begin
				if (ba_dst[3]) begin
					bg1_lo_word <= sdram_dout;
					bg1_state   <= BG1B_LATCH_LO;
				end
			end
			BG1B_LATCH_LO: begin
				bg1_valid <= 1'b1;
				bg1_state <= BG1B_IDLE;
			end
			default: bg1_state <= BG1B_IDLE;
		endcase
	end
end

assign bg1_data = {bg1_hi_word, bg1_lo_word};

// FSM P4 separata (1 fetch, raw byte)
always @(posedge clk) begin
	if (reset || ioctl_download) begin
		bg1p4_state     <= BG1P_IDLE;
		bg1_p4_valid    <= 1'b0;
		bg1_p4_req_prev <= 1'b0;
		bg1p4_rd_req    <= 1'b0;
		bg1p4_ba3_addr_r<= 22'd0;
	end else begin
		bg1_p4_valid    <= 1'b0;
		bg1_p4_req_prev <= bg1_p4_req;
		bg1p4_rd_req    <= 1'b0;

		case (bg1p4_state)
			BG1P_IDLE: begin
				// avvia solo quando la FSM base è IDLE (evita conflitto su ba3)
				if ((bg1_p4_req ^ bg1_p4_req_prev) && bg1_state == BG1B_IDLE)
					bg1p4_state <= BG1P_REQ;
			end
			BG1P_REQ: begin
				bg1p4_ba3_addr_r <= bg1_addr_p4;
				bg1p4_rd_req     <= 1'b1;
				if (ba_ack[3]) bg1p4_state <= BG1P_WAIT;
			end
			BG1P_WAIT: begin
				if (ba_dst[3]) begin
					bg1_p4_word <= sdram_dout;
					bg1p4_state <= BG1P_LATCH;
				end
			end
			BG1P_LATCH: begin
				bg1_p4_valid <= 1'b1;
				bg1p4_state  <= BG1P_IDLE;
			end
			default: bg1p4_state <= BG1P_IDLE;
		endcase
	end
end

// p4 byte raw: selezione byte HI o LO del word16 in base al bit 0 del byte addr
// LATCHED al momento del fetch (non combinatorio su bg1_byte_addr che può essere
// già cambiato quando bg1_p4_valid arriva).
reg bg1_p4_addr0_lat;
always @(posedge clk) begin
	if (bg1p4_state == BG1P_REQ)
		bg1_p4_addr0_lat <= bg1_byte_addr[0];
end
assign bg1_p4_data = bg1_p4_addr0_lat ? bg1_p4_word[7:0] : bg1_p4_word[15:8];

endmodule
