// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

//
// nightslashers_top.sv
// Top Night Slashers (Data East, 1994) — fork di boogwings_top.sv (stesso autore).
//
// Hardware MAME (deco32.cpp; boogwing.cpp per l'ossatura condivisa):
//   Main CPU:    M68000 @ 14 MHz (28/2)         — DE102 encrypted opcodes
//   Sound CPU:   H6280  @ 8.055 MHz (32.22/4)
//   Tilemap:     DECO16IC × 2  (4 BG layer totali)
//   Sprite:      DECO_SPRITE × 2 (alpha-blend)
//   Palette:     DECO_ACE (palette + alpha)
//   I/O+protect: DECO104PROT
//   Audio:       YM2151 @ 3.58 MHz + OKIM6295 × 2 (1 MHz e 2 MHz)
//
// Memory map main (boogwing.cpp:504):
//   0x000000-0x0FFFFF  ROM (1MB, encrypted)
//   0x200000-0x20FFFF  work RAM (64KB)
//   0x220000           priority_w
//   0x240000/0x244000  spriteram DMA trigger
//   0x242000/0x246000  spriteram1/2 (2KB ciascuno)
//   0x24E000-0x24EFFF  DECO104 protection RAM + I/O
//   0x260000-0x267FFF  deco16ic[0] control + pf1 + pf2
//   0x268000-0x26AFFF  rowscroll pf1/pf2
//   0x270000-0x277FFF  deco16ic[1] control + pf1 + pf2
//   0x278000-0x27AFFF  rowscroll pf3/pf4
//   0x282008           palette DMA trigger
//   0x284000-0x285FFF  palette RAM (8KB)
//   0x3C0000-0x3C004F  deco_ace control (ACE alpha)
//
// Memory map audio H6280 (boogwing.cpp:547):
//   0x000000-0x00FFFF  ROM (64KB)
//   0x110000           YM2151 r/w
//   0x120000           OKI1 r/w
//   0x130000           OKI2 r/w
//   0x140000           sound latch read
//   0x1F0000-0x1F1FFF  work RAM (8KB)
//
// IRQ:
//   Main IRQ6 = VBLANK (irq6_line_hold)
//   H6280 IRQ0 = sound latch (DECO104 soundlatch_irq_cb)
//   H6280 IRQ2 = YM2151 IRQ
//

module nightslashers_top
(
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,

	// Savestate trigger (da savestate_ui nel sys)
	input  wire        ss_save,
	input  wire        ss_load,
	input  wire [3:0]  ss_slot,   // 16 slot: [3:2]=regione (file .ss1-.ss4), [1:0]=sotto-slot

	// Inputs MAME-mapping BoogieWings (vedi docs/99_discovery_log.md):
	//   inputs_port = INPUTS (16-bit, P1+P2 joy+button+start, active LOW)
	//   system_port = SYSTEM (16-bit, coin+service+vblank, active LOW eccetto vblank)
	//   dsw_port    = DSW    (16-bit DIP switches)
	input  wire [15:0] inputs_port,
	input  wire [15:0] system_port,
	input  wire [15:0] dsw_port,
	input  wire        region_xm,     // set select (mod byte MRA): 0=Korea 1=Jap/Ovs -> marker EEPROM
	input  wire        region_us,     // set USA (nslasheru): 1 -> audio HuC6280 invece di Z80 (default 0)
	input  wire        violence,      // Violence ON (jap/overseas) -> word4 bit8 del blocco EEPROM
	input  wire        service_req,   // trigger OSD "Service Menu" (T[36])

	// SDRAM ROM interface (via sdram_bridge)
	// TODO: porte main/tile/sub (sub non c'è in boogwings — solo main+tile)
	output wire [23:0] main_rom_addr,
	output wire        main_rom_is_opcode,   // dual-view fetch (bypass decrypt)
	output wire        main_rom_req,
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,

	output wire [23:0] tilerom_addr,
	output wire [2:0]  tilerom_region_id,  // RID_* selettore region planar
	output wire        tilerom_req,
	input  wire [31:0] tilerom_data,
	input  wire        tilerom_valid,

	// Tile ROM PORT B (chip1 BG2): port 3 SDRAM dedicata (legacy, lasciata cablata)
	output wire [23:0] tilerom2_addr,
	output wire [2:0]  tilerom2_region_id,
	output wire        tilerom2_req,
	input  wire [31:0] tilerom2_data,
	input  wire        tilerom2_valid,

	// Tile ROM FG0 (chip1.pf1) — ba0 jtframe diretto, no arbiter
	output wire [23:0] tilerom_fg0_addr,
	output wire [2:0]  tilerom_fg0_region_id,
	output wire        tilerom_fg0_req,
	input  wire [31:0] tilerom_fg0_data,
	input  wire        tilerom_fg0_valid,

	// Tile ROM FG1 (chip1.pf2) — ba1 jtframe diretto, no arbiter
	output wire [23:0] tilerom_fg1_addr,
	output wire [2:0]  tilerom_fg1_region_id,
	output wire        tilerom_fg1_req,
	input  wire [31:0] tilerom_fg1_data,
	input  wire        tilerom_fg1_valid,

	// Tile ROM BG1 (chip0.pf2 5bpp) — ba3 SDRAM dedicato (4 plane base + P4 dedicato)
	output wire [23:0] tilerom_bg1_addr,
	output wire        tilerom_bg1_req,
	input  wire [31:0] tilerom_bg1_data,
	input  wire        tilerom_bg1_valid,
	output wire        tilerom_bg1_p4_req,
	input  wire  [7:0] tilerom_bg1_p4_data,
	input  wire        tilerom_bg1_p4_valid,

	// ioctl (ROM download)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [26:0] ioctl_addr_raw,   // pre-de156: download audio (02.l18 non crittato)
	input  wire [15:0] ioctl_dout_raw,
	input  wire        ioctl_wr_raw,     // wr raw allineato ad addr/dout raw
	input  wire [15:0] ioctl_index,
	output wire        ioctl_wait,

	// Video pixel interface
	input  wire [9:0]  render_x,
	input  wire [9:0]  render_y,
	input  wire        hblank_in,
	input  wire        vblank_in,
	input  wire        ce_pix,
	input  wire        ce_audio,    // ~8 MHz, per H6280 audio CPU
	input  wire        ce_huc,      // 24 MHz -> CE_IN HuC (core /6 = 4.0 MHz = MAME)
	input  wire        ce_ym,       // ~3.58 MHz, per YM2151
	input  wire        ce_ym_p1,    // ~1.79 MHz, half rate per jt51
	input  wire        ce_oki0,     // ~1.01 MHz, per OKI #0
	input  wire        ce_oki1,     // ~2.00 MHz, per OKI #1
	// Savestate fase contatori ce (da/verso Template): in = save, out + load_wr = restore.
	input  wire [3:0]  ce_audio_cnt_in,
	input  wire [4:0]  ce_ym_cnt_in,
	input  wire        ce_ym_toggle_in,
	input  wire [6:0]  ce_oki0_cnt_in,
	input  wire [5:0]  ce_oki1_cnt_in,
	output wire [3:0]  ce_audio_cnt_load,
	output wire [4:0]  ce_ym_cnt_load,
	output wire        ce_ym_toggle_load,
	output wire [6:0]  ce_oki0_cnt_load,
	output wire [5:0]  ce_oki1_cnt_load,
	output wire        ce_cnt_load_wr,
	// OSD audio sel (4 bit each) — Default/MAME hardcoded dentro boogwings_audio
	input  wire [3:0]  osd_sel_fm,
	input  wire [3:0]  osd_sel_oki0,
	input  wire [3:0]  osd_sel_oki1,
	output wire [23:0] rgb_out,

	// Audio
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	output wire        paused_safe,    // gating frame-aligned per i contatori ce in Template.sv

	// DDRAM HPS pins (per audio ROM, OKI samples, sprite ROM)
	input  wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	// === Layer enable OSD (runtime mask) ===
	input  wire        layer_bg0_en,   // chip0 pf1 (text)
	input  wire        layer_bg1_en,   // chip0 pf2 (BG1)
	input  wire        layer_spr_en,   // sprite
	input  wire        layer_fg0_en,   // chip1 pf1+pf2 (BG2)

	// === Layer FG1 (chip1.pf2 separato da FG0) ===
	input  wire        layer_fg1_en,


	// Tile permutation toggles (16 = 4 perm × 4 layer bg0/bg1/fg0/fg1) + sprite
	input  wire        osd_bg0_swap_hl,
	input  wire        osd_bg0_brev8,
	input  wire        osd_bg0_nibsw,
	input  wire        osd_bg0_bs_ab,
	input  wire        osd_bg1_swap_hl,
	input  wire        osd_bg1_brev8,
	input  wire        osd_bg1_nibsw,
	input  wire        osd_bg1_bs_ab,
	input  wire        osd_fg0_swap_hl,
	input  wire        osd_fg0_brev8,
	input  wire        osd_fg0_nibsw,
	input  wire        osd_fg0_bs_ab,
	input  wire        osd_fg1_swap_hl,
	input  wire        osd_fg1_brev8,
	input  wire        osd_fg1_nibsw,
	input  wire        osd_fg1_bs_ab,
	input  wire        osd_spr_swap_hl,
	input  wire        osd_spr_brev8,
	input  wire        osd_spr_nibsw,
	input  wire        osd_spr_bs_ab,
	input  wire        osd_spr_msb_first,
	input  wire        osd_spr_half_inv,
	input  wire        osd_spr_half_eff_inv,
	input  wire        osd_spr_row_inv,
	input  wire        osd_spr_plane_inv,
	// 2026-07-09: leve P4 sprite (5o bitplane = pen bit4, fuori dai 9 toggle)
	input  wire        osd_spr_p4_off,     // 1 = forza pen bit4 = 0 (diagnosi colori)
	input  wire        osd_spr_p4_lane,    // XOR sul byte-lane DDR del fetch P4
	input  wire        osd_spr_p4_brev8,   // bit-reverse del byte P4
	// 2026-07-10: velocita' CPU da OSD (0=7.08 originale, 1=10.8, 2=14.1, 3=28.3)
	input  wire [1:0]  osd_cpu_speed,
	input  wire [1:0]  osd_spr_p0_src,
	input  wire [1:0]  osd_spr_p1_src,
	input  wire [1:0]  osd_spr_p2_src,
	input  wire [1:0]  osd_spr_p3_src,
	input  wire [1:0]  osd_spr_chip_filter,  // 00=both, 01=chip0, 10=chip1, 11=none
	input  wire        osd_spr_w_swap_pos,          // w-mode: scambia posizione 1°/2° blocco
	input  wire        osd_spr_w_offset_first,      // w-mode: applica offset al 1° blocco (debug X assoluta)
	input  wire        osd_spr_w_code_swap,         // w-mode: swap code primo/secondo
	input  wire signed [3:0] osd_spr_w_offset,      // w-mode: offset X signed (step 16)

	// BG1 p4 (plane 4 mbd-02) permutation toggles
	input  wire [1:0]  osd_bg1_p4_byte_pos,
	input  wire        osd_bg1_p4_brev8,
	input  wire        osd_bg1_p4_bit_shift
);

// GFX debug permutazioni RIMOSSE 2026-05-21: hardcoded ai valori di default.
wire [4:0] osd_tile_decode_mode = 5'd0;
wire       osd_pixel_bit_msb    = 1'b0;
wire       osd_plane_rev32      = 1'b0;
wire       osd_nibble_swap      = 1'b0;
wire       osd_byte_swap_ab     = 1'b0;
wire       osd_xhalf_inv        = 1'b0;
wire       osd_tile_hi_rev      = 1'b0;
wire [1:0] osd_vram_swizzle     = 2'd0;

// =====================================================================
// MAIN CPU — Data East DECO 156 (encrypted ARM, ARMv2a) @ 28.322/4 = 7.0805 MHz
// (Night Slashers). Replaces the BoogieWings FX68K/68000 plane.
//
// The ARM core (rtl/cpu_arm/arm_cpu_wrapper) presents a 32-bit arcade bus
// (bus_addr[25:0]/bus_req/bus_we/bus_be/bus_wdata/bus_rdata/bus_ready). The
// reused DECO chips (deco16ic_jt, deco_ace, sprites, deco104) are 16-bit
// 68000-style, so an ADAPTER (built in a later step) derives cpu_addr /
// cpu_rd / cpu_wr / cpu_wdata[15:0] / cpu_dsn for them and reassembles
// cpu_rdata back into the 32-bit bus_rdata. Pacing = ce_cpu (no DTACK).
// =====================================================================

// ce_cpu: 7.0805 MHz from clk_sys (96 MHz). 7.0805/96 ~= 17/231; a
// jtframe_frac_cen drives it. (Exact ratio tuned at video integration; for the
// isolated boot milestone any ~7 MHz tick is fine.)
localparam [9:0] CPU_NUM = 10'd17;
localparam [9:0] CPU_DEN = 10'd231;

wire        cpu_cen;          // 7.08 MHz ARM tick (was cpu_cen/cpu_cenb for 68K)

// ── Reused-chip 16-bit bus (driven by the ARM->16bit adapter, later step) ──
wire [23:0] cpu_addr;         // chip-facing address (68000-style word space)
wire        cpu_rd, cpu_wr;
wire [15:0] cpu_wdata;
wire [1:0]  cpu_dsn;          // byte selects (active low), from bus_be
wire [15:0] cpu_rdata;        // 16-bit read mux from the chips

// ── ARM 32-bit arcade bus (to/from arm_cpu_wrapper) ──
wire [25:0] arm_addr;
wire        arm_req, arm_we;
wire [3:0]  arm_be;
wire [31:0] arm_wdata;
wire [31:0] arm_rdata;
wire        arm_ready;

// Address decoder forward declarations (per ModelSim 10.5b senza forward ref)
wire is_prio, is_spr1, is_spr2, is_sprdma1, is_sprdma2;
wire is_prot, is_pf0, is_pf1, is_paldma, is_pal, is_ace;
// Mirror DECO16IC chip 0 control (range 0x24C000-0x24CFFF, scoperto da
// disassembly main 0xA94: scrive ctrl regs via $24C100..$24C600 stride 0x100).
// Il chip 0 decodifica parzialmente: cpu_addr[10:8] = ctrl index.
wire is_pf0_mirror;
// Noprw range MAME (boogwing.cpp:510, 534, 535) — devono produrre DTACK ma
// scrittura/lettura senza effetti (read=FFFF, write=ignorata).

// ── ce_cpu: ARM clock-enable from clk_sys (jtframe_frac_cen) ──────
// The ARM is paced by ce_cpu; bus wait states come from arm_ready (the bus
// handshake), NOT from a DTACK-stretching cen like the 68000 used. So a plain
// fractional cen is correct here.
// 2026-07-10 CPU SPEED OSD: la quantizzazione dei tick (LDR/STR=2 tick,
// branch=3-4) porta l'effettivo a ~70-75% di MAME -> sforamenti frame nelle
// scene piene = rallentoni dove l'originale non li ha. I giochi DECO sono
// frame-locked sul vblank: alzare il cen NON accelera il gameplay, elimina
// solo gli sforamenti. 4 livelli live da OSD, default = 7.08 originale.
reg [9:0] cpu_num_sel;
always @(*) begin
	case (osd_cpu_speed)
		2'd0: cpu_num_sel = 10'd17;   //  7.08 MHz (28.322/4, originale)
		2'd1: cpu_num_sel = 10'd26;   // 10.8  MHz
		2'd2: cpu_num_sel = 10'd34;   // 14.1  MHz
		2'd3: cpu_num_sel = 10'd68;   // 28.3  MHz (quarzo pieno)
	endcase
end
wire [1:0] cpu_cen2;
jtframe_frac_cen #(.W(2)) u_cpu_cen (
	.clk    (clk),
	.cen_in (1'b1),
	.n      (cpu_num_sel),
	.m      (CPU_DEN),
	.cen    (cpu_cen2),
	.cenb   ()
);
assign cpu_cen = cpu_cen2[0];

// === VBlank-synced pause (frame-aligned, pattern Ninja Warriors / F2 obj_paused) ===
// pause raw asincrono (commuta sul tasto a meta' frame) → paused_safe registrato che
// cambia SOLO al rising edge vblank (frame boundary). Evita race a meta' bus-cycle /
// scanline / DDR3. Usato su CPU (cen) + audio (YM/OKI cen + HUC via RDY). Lo sprite
// si congela da solo: il renderer disegna il buffer, e il DMA copia la live RAM ferma
// (la CPU che la scrive e' in pausa) -> immagine sprite statica.
reg vblank_pp_d;
reg paused_safe_r;
// SS-68K NEUTRALIZZATO (2026-07-09): ss_m68k e' il driver savestate del 68000
// BoogieWings; su NS (ARM) il suo handshake non completa MAI (save mai riusciti
// sul ferro) e i suoi output wedged possono: congelare la CPU (ss_pause latch),
// tenere il bus DDR3 (ss_busy->grant: regioni sprite MISURATE vuote sul ferro),
// resettare la CPU (ss_reset), forzare IRQ (ss_irq). Mascherati alla radice:
// il gioco torna al comportamento baseline, il SS resta inerte.
// APPROCCIO B (ss_arm): ss_pause_gate = ss_pause (da ss_arm) -> il save/restore alza
// paused_safe_r al confine frame come F2. A SS off ss_pause=0 -> comportamento originale.
wire ss_pause;   // da ss_arm (dichiarato/pilotato all'istanza piu' sotto)
wire ss_pause_gate = ss_pause;
always @(posedge clk) begin
	if (reset) begin
		vblank_pp_d   <= 1'b0;
		paused_safe_r <= 1'b0;
	end else begin
		vblank_pp_d <= vblank_in;
		// paused_safe_r = pausa REALE frame-aligned (= obj_paused di F2). UNA sola assegnazione, chiara:
		//   - SALITA: solo al rising vblank, se (pause | ss_pause) -> il SAVE cattura a confine frame,
		//     mai a meta' (video/audio puliti).
		//   - MANTENIMENTO durante SS: se ss_pause e' alto e paused_safe_r e' gia' alto, RESTA alto
		//     (non aspetta il prossimo vblank). FIX RACE: senza, se un confine vblank cade mentre
		//     memory_stream scrive i chip audio (idx 20-25, ultimi), i ce_ym/ce_oki ripartirebbero a
		//     META' scatter -> chip riceve registri mentre il contatore gira -> a volte muta a volte
		//     glitcha (fase casuale = non deterministico, subito al restore). F2 usa obj_paused continuo.
		//   - DISCESA: durante SS scende SUBITO quando ss_pause cade (restore finito) -> HuC+68k+chip
		//     ripartono nello STESSO ciclo (come F2 obj_paused). Pausa utente: discesa al vblank.
		// Trasparente a SS spento (ss_pause=0): si comporta come l'originale (salita/discesa al vblank).
		if (ss_pause_gate & paused_safe_r)
			paused_safe_r <= 1'b1;                          // mantieni alto per tutta la durata del SS
		else if (vblank_in & ~vblank_pp_d)
			paused_safe_r <= pause | ss_pause_gate;         // SALITA frame-aligned su pause|ss_pause (= F2);
			                                               // DISCESA: a SS off ss_pause=0 -> torna a pause

	end
end
// Pausa effettiva = SOLO il safe-pause REGISTRATO al vblank (paused_safe_r). Sia pausa utente
// che savestate passano per il campionamento frame-aligned (riga 321: paused_safe_r campiona
// pause|ss_pause al rising vblank). NIENTE OR con ss_pause combinatorio: quello faceva fermare
// il savestate a META' FRAME (bypassando il vblank) -> VRAM/palette/sprite/audio catturati a
// meta' transizione -> sfondi/palette corrotti, audio glitch. Ora TUTTO si ferma SOLO al vblank,
// uguale alla pausa utente (che gia' freeza pulito). Come F2 obj_paused (frame-aligned).
// paused_safe e' un output port (gata i contatori ce in Template.sv, gating dentro il contatore
// come F2 .cen_in, non AND esterno sul pulse).
assign paused_safe = paused_safe_r;

// Pause: gating ce (NON reset). APPROCCIO B: durante il SS la CPU e' FERMA (niente
// mini-handler da eseguire — i registri si leggono/scrivono via scan diretto). ss_pause
// (da ss_arm) ferma la CPU per tutta la durata di save/restore, garantendo lo scan-in a
// CPU quiescente (spec validata: scan-in DOPO reset, CPU non deve fetchare).
// COAST-TO-BOUNDARY (FIX savestate incompleto, PROVATO in sim). Il savestate approccio B
// salva solo i 21 registri architetturali; se la CPU viene congelata a META' di un'istruzione
// multi-ciclo (LDM/STR/MEM_WAIT), lo stato in volo NON e' nei 21 registri -> restore corrotto
// -> "il restore fa reset". FIX: quando serve pausa/SS la CPU NON si ferma subito, ma CONTINUA
// finche' non raggiunge un confine PULITO (cpu_at_boundary = EXECUTE che resta EXECUTE), poi
// PARCHEGGIA. Cosi' lo snapshot cade SEMPRE a confine inter-istruzione. PROVATO: freeze a
// MEM_WAIT -> 16 righe corrotte; freeze a EXECUTE -> restore bit-identico.
wire        cpu_at_boundary;
wire        want_pause = paused_safe | ss_pause;
reg         cpu_parked;
always @(posedge clk)
	if (reset)                cpu_parked <= 1'b0;
	else if (~want_pause)     cpu_parked <= 1'b0;
	else if (cpu_at_boundary) cpu_parked <= 1'b1;
wire cpu_run    = ~want_pause | ~(cpu_parked | cpu_at_boundary);
// TIMING 2026-08-10: paused_real verso ss_arm REGISTRATO qui. Il percorso
// a23_execute|status_bits_flags/control_state -> o_exec_boundary (combinatorio)
// -> cpu_at_boundary -> paused_real -> FSM ss_arm era il gruppo dominante delle
// violazioni setup (84 path su 100, worst -0.838): una catena lunga che STA
// pretende in UN ciclo, mentre la CPU avanza a ce_cpu (~13.5 ck). Invece di
// promettere un multicycle a Quartus, la catena si SPEZZA fisicamente con un
// flip-flop: la violazione sparisce davvero. Costo: il save parte 1 ck dopo,
// innocuo perche' a quel punto la CPU e' gia' parcheggiata (cpu_parked latcha e
// cpu_run va basso) e resta ferma fino a fine savestate.
reg  paused_real_r;
always @(posedge clk) paused_real_r <= paused_safe_r & (cpu_parked | cpu_at_boundary);
wire cpu_cen_g  = cpu_cen  & cpu_run;

// IRQ (DECO 156): single VBLANK IRQ, level-held until the CPU acks it by
// WRITING the vblank-ack register at 0x140000. The Amber core does NOT auto-
// clear the IRQ, so we clear arm_irq on that write (arm_vbl_ack, driven by the
// address decoder in a later step). irq6_pending is reused as "arm_irq pending"
// so the existing savestate MISC slot keeps working unchanged.
wire arm_vbl_ack;   // pulse: CPU wrote 0x140000 (set by the ARM decoder, step 3)
reg vblank_d;
reg irq6_pending;   // = ARM vblank IRQ pending (held until ack write)
always @(posedge clk) begin
	vblank_d <= vblank_in;
	if (reset) irq6_pending <= 1'b0;
	// PAUSA SAFE (2026-07-22): niente set in pausa — la CPU parcheggiata non acka,
	// il pending resterebbe quello DELLA PAUSA (non del gioco) nello snapshot MISC
	// e al fronte di risalita partirebbe un IRQ spurio. Congelato = fotografia fedele.
	else if (vblank_in & ~vblank_d & ~paused_safe) irq6_pending <= 1'b1;  // rising edge VBLANK
	else if (arm_vbl_ack)           irq6_pending <= 1'b0;  // CPU wrote 0x140000
	else if (misc_ss_wr)            irq6_pending <= misc_irq6_load;   // restore (trasparente)
end
// SS-68K NEUTRALIZZATO: niente IRQ forzato dal mini-handler (vedi sopra).
wire arm_irq = irq6_pending;

// ── DECO 156 main CPU = Amber 'amber23' ARM via arm_cpu_wrapper ──────────────
// Savestate ARM (approccio B): ss_arm pilota lo scan dei registri fisici + ss_reset.
wire        ss_arm_load;
wire [4:0]  ss_arm_idx;
wire [31:0] ss_arm_wdata;
wire [31:0] ss_arm_rdata;   // scan-out del core all'indice ss_arm_idx
arm_cpu_wrapper u_maincpu (
	.clk       (clk),
	.ce_cpu    (cpu_cen_g),
	.reset     (reset | ss_reset),   // ss_reset: re-priming pipeline al restore (approccio B)
	.i_irq     (arm_irq),
	.i_firq    (1'b0),
	.bus_addr  (arm_addr),
	.bus_req   (arm_req),
	.bus_we    (arm_we),
	.bus_be    (arm_be),
	.bus_wdata (arm_wdata),
	.bus_rdata (arm_rdata),
	.bus_ready (arm_ready),
	// savestate scan
	.ss_load   (ss_arm_load),
	.ss_idx    (ss_arm_idx),
	.ss_wdata  (ss_arm_wdata),
	.ss_rdata  (ss_arm_rdata),
	.cpu_at_boundary (cpu_at_boundary)
);

// =====================================================================
// ARM (32-bit) -> reused-chip (16-bit) BUS ADAPTER + NS address decoder
// =====================================================================
// The DE156 ROM is decrypted in the download path (de156_ioctl_decrypt), so the
// runtime ROM read is a plain pass-through — no address scramble, no runtime
// decrypt here.
//
// NS ARM memory map (bytes), from MAME deco32.cpp nslasher_map:
//   0x000000-0x0FFFFF  ROM (SDRAM)            32-bit
//   0x100000-0x11FFFF  work RAM 128KB         32-bit
//   0x140000-0x140003  vblank ack (write)
//   0x150000           EEPROM (CS/CLK/DI=6/5/4) ; 0x150001 volume
//   0x163000-0x16309F  DECO_ACE regs          (lower 16)
//   0x164000/4/8       tilemap/spr1/spr2 color bank (byte)
//   0x168000-0x169FFF  buffered palette       (32-bit)
//   0x16C008           palette DMA
//   0x170000-0x171FFF  spriteram bank0 ; 0x174010 buffer trigger
//   0x178000-0x179FFF  spriteram bank1 ; 0x17C010 buffer trigger
//   0x182000/0x184000  tilegen0 pf1/pf2 ; 0x1A0000 ctrl ; 0x192000/0x194000 rowscroll
//   0x1C2000/0x1C4000  tilegen1 pf1/pf2 ; 0x1E0000 ctrl ; 0x1D2000/0x1D4000 rowscroll
//   0x200000-0x207FFF  DECO104 protection/IO  (UPPER 16, umask 0xFFFF0000)
//
// MMILESTONE SCOPE: only ROM / RAM / vblank-ack / DECO104 are live; every other
// range is decoded but treated as NOP (read 0xFFFFFFFF, write ignored, ready=1)
// so the CPU can boot through the DECO104 handshake without hanging. The full
// video/audio wiring (cpu_addr/cpu_wdata/cpu_dsn to the chips) is added next.

wire [25:0] aa = arm_addr;            // ARM byte address [25:0]

// ── NS range decode (on the ARM address) ──
wire ns_is_rom   = (aa[25:20] == 6'h00);                       // 0x000000-0x0FFFFF
wire ns_is_ram   = (aa >= 26'h100000) && (aa < 26'h120000);    // 0x100000-0x11FFFF
wire ns_is_vback = (aa >= 26'h140000) && (aa < 26'h140004);    // 0x140000-0x140003
wire ns_is_eeprom= (aa >= 26'h150000) && (aa < 26'h150004);    // 0x150000 EEPROM+pri
wire ns_is_prot  = (aa >= 26'h200000) && (aa < 26'h208000);    // 0x200000-0x207FFF

// nslasher_debug_r (0x200000 lower 16) = 0xFFFF fisso (come MAME nslasher_debug_r()).
wire [15:0] ns_debug_reg = 16'hFFFF;

// NS priority register m_pri: deco32_v.cpp eeprom_w (the 0x150000 write) calls
// pri_w(data & 0x07). So m_pri = bits[2:0] of the byte written to 0x150000:
//   bit0 = layer priority toggle, bit1 = BG2/3 8bpp joint, bit2 = colour fade.
// 0x150000 is on the LOWER byte (umask, byte 0) -> arm_wdata[7:0].
reg [2:0] ns_pri_reg;
always @(posedge clk) begin
	if (reset) ns_pri_reg <= 3'd0;
	else if (misc_ss_wr) ns_pri_reg <= misc_ns_pri_load;   // restore (CPU congelata)
	else if (ns_is_eeprom & arm_req & arm_we & (aa[1:0]==2'd0))
		ns_pri_reg <= arm_wdata[2:0];
end

// ── EEPROM 93C46 seriale (NS) ───────────────────────────────────────────────
// MAME deco32.cpp eeprom_w (0x150000 byte): bit6=CS, bit5=CLK, bit4=DI.
// port_b_cb = eeprom->do_read() lshift 0 -> il DO va in port_b bit0 del DECO146.
// Latch del byte scritto a 0x150000 (le linee CS/CLK/DI sono livelli, non pulse).
reg [7:0] eeprom_ctrl;
always @(posedge clk) begin
	if (reset) eeprom_ctrl <= 8'd0;
	else if (ns_is_eeprom & arm_req & arm_we & (aa[1:0]==2'd0))
		eeprom_ctrl <= arm_wdata[7:0];
end
wire eeprom_do;
eeprom_93c46 u_eeprom (
	.clk   (clk),
	.reset (reset),
	.cs    (eeprom_ctrl[6]),
	.sk    (eeprom_ctrl[5]),
	.di    (eeprom_ctrl[4]),
	.dout  (eeprom_do),
	.dip       (dsw_port),   // DIP MRA -> blocco settings iniettato al reset
	.region_xm (region_xm),  // set select (mod byte) -> marker EEPROM OC/XM
	.violence  (violence)    // Violence ON -> word4 bit8
);
// port_b verso il DECO146: bit0 = EEPROM DO, resto = system_port originale.
// (NS: MAME port_b = eeprom do_read lshift 0. I coin NS NON sono in port_b.)
// FIX STALLO 2026-07-03: system_port[3] dal Template e' VBlank (layout SYSTEM
// BoogieWings) ma per il firmware NS bit3 = tasto SERVICE active-LOW (MAME IN1,
// deco32.cpp): col VBlank il gioco vede SERVICE premuto per il ~92% di ogni frame,
// sfarfallante a 60Hz -> flusso post-boot inchiodato nella gestione service
// (golden: 1 solo frame-advance in 420k istr contro 9 del flusso pulito).
// bit3 forzato idle-HIGH (tasto non premuto) su ENTRAMBE le porte.
// bit 15..4 IDLE fissi: da quando system_port[15:8] porta il P3 (Template
// 2026-07-11), il port_b NON deve vederlo — MAME port_b = solo EEPROM DO.
wire [15:0] prot_port_b = {12'hFFF, 1'b1, system_port[2:1], eeprom_do};

// ── Service/Test switch (trigger OSD "Service Menu"): impulso 8 vblank ──────
// Il firmware testa il FRONTE del test switch (edge byte RAM 0x100014,
// tst #8 @0x9f0): serve un press di qualche frame durante gioco/attract,
// NON un livello fisso (provato nel golden: 4 frame bastano, l'edge di un
// livello tenuto dal boot viene consumato al primo poll e ignorato).
reg [3:0] svc_cnt;
reg       svc_req_d;
always @(posedge clk) begin
	if (reset) begin
		svc_cnt <= 4'd0; svc_req_d <= 1'b0;
	end else begin
		svc_req_d <= service_req;
		if (service_req & ~svc_req_d)                       svc_cnt <= 4'd8;
		else if (svc_cnt != 4'd0 && vblank_in && !vblank_d) svc_cnt <= svc_cnt - 4'd1;
	end
end
wire test_sw_n = (svc_cnt == 4'd0);   // active LOW: 0 = test premuto

// port_c verso il DECO146 = IN1 (MAME deco32.cpp:2021 port_c_cb=IN1, def riga 1554):
//   bit0=COIN1, bit1=COIN2, bit2=SERVICE1, bit3=SERVICE(no-toggle),
//   bit4 (0x0010) = VBLANK **active-HIGH** (PORT_READ_LINE screen vblank),
//   bit8-10/12-14 = BUTTON4-6 P1/P2 (non mappati NS -> idle HIGH).
// CAUSA NERO: prima port_c=dsw_port (DIP statici) -> l'handler IRQ a 0x3AC
// (ldr[0x200988]; lsr#16; tst#0x10; bne) aspettava bit4=VBLANK che con i DIP non
// si azzerava mai -> handler bloccato -> [0x100000] mai pulito -> CPU ferma a
// 0x9c4 -> nero. Provato bit-exact in golden MAME + co-sim RTL (work/arm_decrypt).
// Coin/service dai bit bassi di system_port (Template: bit0=COIN1 bit1=COIN2 bit2=SERVICE).
//
// POLARITA' bit4 (co-sim RTL): l'handler IRQ scatta sul RISING edge del vblank
// (irq6_pending, :343) e gira MENTRE vblank_in e' ancora 1. Se bit4=vblank_in
// diretto, il gate 0x3AC (spin while bit4==1) non esce finche' il vblank non
// finisce fisicamente -> con la CPU ce-paced si impappina -> nero. Il golden
// (che boota) usa bit4=0 mentre l'IRQ e' pending. Quindi bit4 = ~irq6_pending:
// 0 nella finestra in cui l'handler gira (esce subito, ack, pulisce [0x100000]),
// 1 a riposo. Legato al LIVELLO che l'ack 0x140000 consuma -> deterministico
// rispetto a dove cade la read DECO146 2ck nel raster (piu' robusto di ~vblank_in).
// bit3 = TEST switch (PORT_SERVICE_NO_TOGGLE): idle HIGH, impulso LOW dal
// trigger OSD (test_sw_n sopra) per aprire il service menu vero.
// 2026-08-29 — DIMOSTRATO DALLA ROM (non da MAME: il difetto del boss c'e' anche
// li', quindi come oracolo non vale). Ciclo di sincronizzazione di quadro del
// gioco, ROM decrittata a 0x0003ac:
//     0003ac  LDR  r12,[pc,#0x70]   ; 0x00200988 = porta C
//     0003b0  LDR  r12,[r12]
//     0003b4  MOV  r12, r12, LSR #16
//     0003b8  TST  r12, #0x10       ; bit 4
//     0003bc  BNE  0x0003ac         ; ALTO -> RIPETE
//     0003c0  MOV  r12, #0x140000
//     0003c4  STR  r0,[r12]         ; ack del vblank
// Il gioco CICLA finche' il bit 4 e' ALTO: quindi bit4 alto = vblank IN CORSO, e
// aspetta che FINISCA prima di ackare e iniziare il quadro. Con ~irq6_pending il
// bit e' 0 proprio durante il vblank -> il ciclo non aspetta la fine ma l'INIZIO,
// e la sincronizzazione di quadro risulta sfasata di un intero vblank.
// Vecchia riga (fase invertita), tenuta per riferimento:
//   wire [15:0] prot_port_c = {system_port[15:5], ~irq6_pending, test_sw_n, system_port[2:0]};
wire [15:0] prot_port_c = {system_port[15:5], vblank_in, test_sw_n, system_port[2:0]};

// vblank-ack pulse: CPU writes 0x140000 -> clear arm_irq (consumed by IRQ block).
assign arm_vbl_ack = ns_is_vback & arm_req & arm_we;

// ── ROM bridge: l'ARM legge DWORD 32-bit, ma il main_rom (bridge ba2) e' 16-bit.
//    Servono 2 fetch (word bassa @aa, word alta @aa+2) per assemblare il dword.
//    In sim il TB dava 32-bit pieni; su HW serve questa FSM o l'ARM esegue meta'
//    istruzione + 0xFFFF -> codice rotto -> schermo nero. ──
// La CPU e' ce-paced: il bus deve TENERE ready+dword finche' l'accesso non
// cambia (non un pulse di 1 ciclo, o la CPU lo perde). rom_dword_valid resta
// alto in ROM_DONE finche' l'indirizzo resta lo stesso; riparte solo quando aa
// cambia. La FSM fa 2 fetch 16-bit e assembla il dword 32-bit.
reg [23:0] main_rom_addr_r;
reg        main_rom_req_r;
reg [2:0]  rom_st;
reg [15:0] rom_lo_r;
reg [31:0] rom_dword_r;
reg        rom_dword_valid;
reg [25:0] rom_served_aa;     // indirizzo del dword attualmente servito
// PREFETCH SEQUENZIALE 2026-07-10 (prestazioni: ~1/3 IPS senza): mentre la CPU
// consuma il dword N, la FSM scarica in ombra N+4 (pf_*). Fetch sequenziale
// successivo = PROMOTE in 1 ciclo (nessun round-trip SDRAM). Branch = drain
// pulito della fase in volo, poi miss normale. UNA sola transazione bridge
// in volo SEMPRE (stesso protocollo req-pulse/ready provato sul ferro).
reg [25:0] pf_aa;
reg [31:0] pf_dword;
reg        pf_valid;
localparam ROM_IDLE=3'd0, ROM_LO=3'd1, ROM_HI=3'd2, ROM_DONE=3'd3,
           ROM_PF_LO=3'd4, ROM_PF_HI=3'd5;
wire rom_access = ns_is_rom & arm_req & ~arm_we;
// nuovo accesso = ROM richiesta a un indirizzo diverso da quello gia' servito
wire rom_new     = rom_access & (~rom_dword_valid | (aa != rom_served_aa));
// la CPU chiede PROPRIO il dword in prefetch (catch-up mid-flight)
wire pf_hit_req  = rom_access & (aa == pf_aa);
// la CPU chiede ALTRO (branch) mentre il prefetch e' in volo
wire pf_miss_req = rom_new & (aa != pf_aa);
always @(posedge clk) begin
	// FIX FREEZE RESTORE (savestate ARM): resetta la FSM ROM anche su ss_reset. Senza,
	// al restore la FSM resta nello stato in cui era stata CONGELATA (magari a meta' fetch
	// in ROM_LO/ROM_HI, in attesa di main_rom_ready) e al risveglio si appende -> freeze.
	// Con ss_reset riparte da ROM_IDLE e rifa il fetch pulito dal PC ripristinato (la CPU
	// e' resettata nello stesso momento, quindi nessuna transazione orfana).
	if (reset | ss_reset) begin
		rom_st <= ROM_IDLE; main_rom_req_r <= 1'b0; rom_dword_valid <= 1'b0;
		main_rom_addr_r <= 24'd0; rom_lo_r <= 16'd0; rom_dword_r <= 32'd0;
		rom_served_aa <= 26'h3FFFFFF;
		pf_aa <= 26'h3FFFFFF; pf_dword <= 32'd0; pf_valid <= 1'b0;
	end else begin
		main_rom_req_r <= 1'b0;   // default basso (bridge triggera sul rising edge)
		case (rom_st)
			ROM_IDLE: if (rom_new) begin
				rom_dword_valid <= 1'b0;
				pf_valid        <= 1'b0;
				main_rom_addr_r <= {2'd0, aa[21:0]};        // byte addr, word bassa
				main_rom_req_r  <= 1'b1;
				rom_served_aa   <= aa;
				rom_st <= ROM_LO;
			end
			ROM_LO: if (main_rom_ready) begin
				rom_lo_r <= main_rom_rdata;
				main_rom_addr_r <= {2'd0, rom_served_aa[21:0]} + 24'd2;
				main_rom_req_r  <= 1'b1;
				rom_st <= ROM_HI;
			end
			ROM_HI: if (main_rom_ready) begin
				rom_dword_r     <= {main_rom_rdata, rom_lo_r};
				rom_dword_valid <= 1'b1;                       // TIENE alto fin qui
				rom_st <= ROM_DONE;
			end
			// ROM_DONE: ready+dword stabili per il dword servito. Da qui:
			//  - hit sul prefetch  -> PROMOTE in 1 ciclo (resta in DONE);
			//  - miss              -> fetch CPU diretto (LO);
			//  - niente da fare    -> avvia il prefetch di served+4.
			ROM_DONE: begin
				if (rom_new) begin
					if (pf_valid && (aa == pf_aa)) begin
						rom_dword_r   <= pf_dword;    // PROMOTE: hit sequenziale
						rom_served_aa <= aa;          // ready si riallinea al nuovo aa
						pf_valid      <= 1'b0;        // slot libero -> nuovo prefetch
					end else begin
						rom_dword_valid <= 1'b0;
						pf_valid        <= 1'b0;
						main_rom_addr_r <= {2'd0, aa[21:0]};
						main_rom_req_r  <= 1'b1;
						rom_served_aa   <= aa;
						rom_st <= ROM_LO;
					end
				end else if (!pf_valid) begin
					pf_aa           <= rom_served_aa + 26'd4;
					main_rom_addr_r <= ({2'd0, rom_served_aa[21:0]} + 24'd4);
					main_rom_req_r  <= 1'b1;
					rom_st <= ROM_PF_LO;
				end
			end
			// Prefetch in volo. pf_hit_req = la CPU ha raggiunto il dword in
			// prefetch: lo si promuove a fetch CPU (served=pf_aa, valid gia' 0
			// per quell'aa dal punto di vista di ready). pf_miss_req (branch):
			// si DRENA la fase corrente (aspetta ready) e si riparte in miss.
			ROM_PF_LO: begin
				if (pf_hit_req) begin
					rom_served_aa   <= pf_aa;
					rom_dword_valid <= 1'b0;
				end
				if (main_rom_ready) begin
					if (pf_miss_req) begin
						rom_dword_valid <= 1'b0;
						pf_valid        <= 1'b0;
						main_rom_addr_r <= {2'd0, aa[21:0]};
						main_rom_req_r  <= 1'b1;
						rom_served_aa   <= aa;
						rom_st <= ROM_LO;
					end else begin
						rom_lo_r        <= main_rom_rdata;
						main_rom_addr_r <= {2'd0, pf_aa[21:0]} + 24'd2;
						main_rom_req_r  <= 1'b1;
						rom_st <= ROM_PF_HI;
					end
				end
			end
			ROM_PF_HI: begin
				if (pf_hit_req) begin
					rom_served_aa   <= pf_aa;
					rom_dword_valid <= 1'b0;
				end
				if (main_rom_ready) begin
					if (pf_miss_req) begin
						rom_dword_valid <= 1'b0;
						pf_valid        <= 1'b0;
						main_rom_addr_r <= {2'd0, aa[21:0]};
						main_rom_req_r  <= 1'b1;
						rom_served_aa   <= aa;
						rom_st <= ROM_LO;
					end else if (rom_served_aa == pf_aa) begin
						// la CPU lo stava gia' aspettando: servito direttamente
						rom_dword_r     <= {main_rom_rdata, rom_lo_r};
						rom_dword_valid <= 1'b1;
						rom_st <= ROM_DONE;
					end else begin
						pf_dword <= {main_rom_rdata, rom_lo_r};
						pf_valid <= 1'b1;
						rom_st <= ROM_DONE;
					end
				end
			end
			default: rom_st <= ROM_IDLE;
		endcase
	end
end
assign main_rom_addr = main_rom_addr_r;
assign main_rom_req  = main_rom_req_r;
// DE156 ha una sola immagine decrittata. Il de156_ioctl_decrypt scrive il main
// decrittato in MAIN_OP_BASE (ioctl 0x000000-0x100000 -> ba2 offset 0). La CPU
// deve leggere DA LI' -> is_opcode=1 (= MAIN_OP_BASE nel bridge). Niente 2a copia.
assign main_rom_is_opcode = 1'b1;

// ── Work RAM 128KB: keep the existing BW RAM (declared below) but on the ARM
//    address. cpu_addr/cpu_rd/cpu_wr/cpu_wdata/cpu_dsn are produced here so the
//    rest of the file (chips) keeps working. For the milestone, the chip-facing
//    decode (is_*) is stubbed to 0 except prot; the RAM is driven directly. ──
assign cpu_addr  = {aa[23:1], 1'b0};              // 16-bit word address view for chips

// DECO104 address (Night Slashers). MAME deco32.cpp ioprot_r/w:
//   deco146_addr = (BIT(real,14,4)<<11) | BIT(real,0,11), real = in-region byte addr.
// Verified numerically (work/arm_decrypt/deco146_map.py): the 11 LOW bits used by
// MAME ioprot_r (deco32.cpp:711-714): offset = byte_addr>>2 (umask32 0xffff0000,
// one 16-bit prot word per 32-bit dword); real_address = offset*2 = byte_addr>>1;
// deco146_addr = (BIT(real,14,4)<<11)|BIT(real,0,11) = byte_addr[11:1] (single
// region, high cs bits = 0). Then read_data() does address>>1 before the scramble,
// so the scramble/lookup INDEX = byte_addr>>2. deco146_base scrambles cpu_addr[11:1],
// so we must feed cpu_addr[11:1] = aa>>2. => prot_addr = {aa[12:2], 1'b0}.
wire [11:0] prot_addr = {aa[12:2], 1'b0};
assign cpu_rd    = arm_req & ~arm_we;
assign cpu_wr    = arm_req &  arm_we;
// DECO104 lives on the UPPER 16 bits (umask 0xFFFF0000); all other 16-bit chips
// use the LOWER half. For the milestone only prot is live, so select upper for
// prot, lower otherwise.
assign cpu_wdata = ns_is_prot ? arm_wdata[31:16] : arm_wdata[15:0];
assign cpu_dsn   = ns_is_prot ? ~arm_be[3:2]     : ~arm_be[1:0];

// ── NS video range decode (on the ARM byte address aa) ──
// Tilegen0 (DECO16IC #0): pf1 0x182000, pf2 0x184000, rowscroll 0x192000/0x194000,
// control 0x1a0000. Each data/rowscroll window is 8KB; control is 0x20 bytes.
wire ns_pf0_pf1  = (aa >= 26'h182000) && (aa < 26'h184000);
wire ns_pf0_pf2  = (aa >= 26'h184000) && (aa < 26'h186000);
wire ns_pf0_rs1  = (aa >= 26'h192000) && (aa < 26'h194000);
wire ns_pf0_rs2  = (aa >= 26'h194000) && (aa < 26'h196000);
wire ns_pf0_ctrl = (aa >= 26'h1a0000) && (aa < 26'h1a0020);

// Tilegen1 (DECO16IC #1): pf1 0x1c2000, pf2 0x1c4000, rowscroll 0x1d2000/0x1d4000,
// control 0x1e0000 (deco32.cpp nslasher_map). Same 8KB windows / 0x20 ctrl as #0.
wire ns_pf1_pf1  = (aa >= 26'h1c2000) && (aa < 26'h1c4000);
wire ns_pf1_pf2  = (aa >= 26'h1c4000) && (aa < 26'h1c6000);
wire ns_pf1_rs1  = (aa >= 26'h1d2000) && (aa < 26'h1d4000);
wire ns_pf1_rs2  = (aa >= 26'h1d4000) && (aa < 26'h1d6000);
wire ns_pf1_ctrl = (aa >= 26'h1e0000) && (aa < 26'h1e0020);

// ── Chip-facing decode. DECO104 live; tilegen0 now wired; rest NOP (milestone). ──
assign is_prio       = 1'b0;
// NS sprites: spriteram0 0x170000-0x171FFF (8KB=4096 words), spriteram1 0x178000.
// Buffer triggers at 0x174010 / 0x17c010 (buffer_spriteram_w). The actual buffer
// copy is done at vblank (MAME buffered_spriteram), the trigger write is a NOP here.
assign is_spr1       = (aa >= 26'h170000) && (aa < 26'h172000);
assign is_spr2       = (aa >= 26'h178000) && (aa < 26'h17a000);
assign is_sprdma1    = (aa >= 26'h174010) && (aa < 26'h174014);
assign is_sprdma2    = (aa >= 26'h17c010) && (aa < 26'h17c014);
assign is_prot       = ns_is_prot;
assign is_pf0        = ns_pf0_pf1 | ns_pf0_pf2 | ns_pf0_rs1 | ns_pf0_rs2 | ns_pf0_ctrl;
assign is_pf1        = ns_pf1_pf1 | ns_pf1_pf2 | ns_pf1_rs1 | ns_pf1_rs2 | ns_pf1_ctrl;
// NS palette/ACE (deco32.cpp nslasher_map):
//   ACE 'Ace' RAM   0x163000-0x16309F (ace_r/ace_w, 40 words)
//   color banks     0x164000 / 0x164004 / 0x164008 (tilemap / spr1 / spr2)
//   buffered palette 0x168000-0x169FFF (8KB = 4096 words = 2048 RGB entries)
//   palette DMA      0x16C008-0x16C00B (palette_dma_w)
assign is_paldma     = (aa >= 26'h16c008) && (aa < 26'h16c00c);
assign is_pal        = (aa >= 26'h168000) && (aa < 26'h16a000);
assign is_ace        = (aa >= 26'h163000) && (aa < 26'h1630a0);
assign is_pf0_mirror = 1'b0;   // NS writes ctrl directly at 0x1a0000 (no $24Cxxx mirror)

// ── Synthetic cpu_addr for tilegen0: remap the scattered NS regions onto the
//    deco16ic_jt internal decode (pf1=[15:13]==010, pf2==011, rs1=[15:12]==8,
//    rs2==A, ctrl=[15:4]==0). cpu_addr==={aa[23:1],1'b0} so cpu_addr[13:1]=aa[13:1]
//    is the in-region word offset (8KB window = 4096 words = bits [12:1]). ──
// STRIDE FIX (causa NERO provata bit-exact via golden): il DECO156 e' ARM 32-bit,
// MAME mappa il video con handler _dword_w => indice = byteaddr>>2 (÷4). Qui prima
// si usava aa[..:1] (÷2, ereditato 68000/BoogieWings) -> le scritture dword finivano
// solo negli indici pari e gli indici dispari (1,3,5,7) erano IRRAGGIUNGIBILI. In
// particolare il master-enable tilemap (ctrl idx 5, byte 0x1a0014 = 0x8080 = pf1|pf2
// enable) veniva RIFIUTATO (is_ctrl=False) -> pf1_enable=pf2_enable=0 -> tutti i 4
// tilemap opaque=0 -> mixer su backdrop ovunque -> schermo nero. Fix: ÷4 = aa[..:2].
//   pf data: chip legge synth[12:1] = dword idx -> aa[13:2]
//   rowscroll: chip legge synth[11:1] -> aa[12:2]
//   ctrl: chip legge synth[3:1] (con synth[15:4]==0) -> aa[4:2]
wire [15:0] d16_0_cpu_addr_ns =
      ns_pf0_pf1  ? {3'b010, 1'b0, cpu_addr[12:2], 1'b0}   // pf1 data (11-bit dword idx; base bit13 escluso)
    : ns_pf0_pf2  ? {3'b011, 1'b0, cpu_addr[12:2], 1'b0}   // pf2 data
    : ns_pf0_rs1  ? {4'h8,   cpu_addr[12:2], 1'b0}   // pf1 rowscroll
    : ns_pf0_rs2  ? {4'hA,   cpu_addr[12:2], 1'b0}   // pf2 rowscroll
    : ns_pf0_ctrl ? {12'd0,  cpu_addr[4:2],  1'b0}   // control idx (dword)
    :               16'd0;

// Same remap for tilegen1 onto the deco16ic_jt internal decode.
wire [15:0] d16_1_cpu_addr_ns =
      ns_pf1_pf1  ? {3'b010, 1'b0, cpu_addr[12:2], 1'b0}   // pf1 data (11-bit dword idx; base bit13 escluso)
    : ns_pf1_pf2  ? {3'b011, 1'b0, cpu_addr[12:2], 1'b0}   // pf2 data
    : ns_pf1_rs1  ? {4'h8,   cpu_addr[12:2], 1'b0}   // pf1 rowscroll
    : ns_pf1_rs2  ? {4'hA,   cpu_addr[12:2], 1'b0}   // pf2 rowscroll
    : ns_pf1_ctrl ? {12'd0,  cpu_addr[4:2],  1'b0}   // control idx (dword)
    :               16'd0;

// ── Read data assembly back to the 32-bit ARM bus ──
// 16-bit chips return data in the lower half with a 0xFFFF0000 endianness XOR
// (MAME deco16ic/deco32 dword readers). DECO104 returns in the UPPER half.
wire [31:0] ram_dword;        // from u_workram (declared below, used in the mux)
wire [15:0] prot_cpu_rd;      // from DECO104 (u_prot, instantiated below)
// 16-bit video chips return their word in the LOWER half with upper=0xFFFF
// (this IS the MAME 0xFFFF0000 dword XOR, same as the ROM line).
wire [31:0] arm_rdata_mux =
	  ns_is_rom  ? rom_dword_r               // ARM 32-bit instruction (2x 16-bit fetch)
	: ns_is_ram  ? ram_dword                 // 32-bit work RAM
	: ns_is_prot ? {prot_cpu_rd, ns_debug_reg} // DECO104 upper half; lower = debug reg
	: is_pf0     ? {16'hFFFF, c0_mirror_rdata} // tilegen0 readback (pf data mirror / ctrl)
	: is_pf1     ? {16'hFFFF, d16_1_cpu_rdata} // tilegen1 readback
	: is_spr1    ? {16'hFFFF, spr1_cpu_rd}     // spriteram0 readback
	: is_spr2    ? {16'hFFFF, spr2_cpu_rd}     // spriteram1 readback
	: is_pal     ? {8'h00, pal_cpu_cpurd24}    // buffered palette readback (entry VERA — RMW alba liv.3)
	: is_ace     ? {16'hFFFF, ace_cpu_rd}      // ACE reg readback
	:              32'hFFFFFFFF;             // NOP ranges
assign arm_rdata = arm_rdata_mux;

// u_workram (128KB 32-bit) e' istanziato PIU' SOTTO (dopo la dichiarazione di ssb[]), con
// l'adaptor savestate interposto su SS_IDX_WORKRAM. ram_dword (wire dichiarato sopra) e'
// guidato da li'. Spostato perche' l'adaptor referenzia ssb[], dichiarato dopo.

// ── bus_ready (DTACK-equivalent) ──
// ROM: ready when the SDRAM cache has the word. RAM/prot/NOP: 1-cycle latency
// (BRAM/DECO104 registered dout). arm_addr is held stable by the ARM core while
// an access is pending (system_rdy stall in arm_cpu_wrapper), so arm_rdata_mux
// is aligned to the access. The 1-cycle ready_d gives the BRAM/DECO104 dout one
// clock to settle before completing the transfer — this is what fixed the
// LDR-literal corruption seen in the boot sim (the read data was being sampled
// the same cycle the address presented, before dout was valid).
// ready_d: 1 ck dopo arm_req (RAM/video/NOP). ready_d2: 2 ck dopo arm_req (DECO104).
// Il DECO104 (deco146_base) ha latenza READ = 2 ck (s1_* stage1 reg + cpu_rdata stage3 reg).
// BoogieWings (FUNZIONA sul ferro) da' al prot 2 ck di attesa: wait1 del jtframe_68kdtack_cen
// + prot_busy_r (boogwings_top.sv:277-295). NS aveva buttato via il dtack_cen (giusto, e' ARM)
// ma cosi' dava al prot solo 1 ck -> la read di 0x2006b4 completa con prot_cpu_rd STALE ->
// busy-poll EEPROM (sub_3E9A8) infinito -> CPU mai a 0xF64 -> schermo NERO. Fix = allinea a BW:
// 2 ck per ns_is_prot, 1 ck per il resto. (Distingue ns_is_prot, NON tocca il latch della protez.)
// BUG BOOT-FATAL (nero, provato numericamente dall'audit bus): ready_d era un TOGGLE
// (arm_req & ~ready_d) -> arm_ready era un IMPULSO di 1 ciclo che si auto-cancellava
// anche con arm_req ancora alto. La CPU e' ce-paced (ce_cpu ~1/13.6 clk): se il tick
// ce_cpu non coincideva con l'impulso di ready, l'accesso non completava -> latenza
// patologica/stall -> boot rotto -> NERO. (Il TB che "validava" usava un ack a LIVELLO,
// quindi non vedeva il bug.) FIX: ready come LIVELLO -> resta alto finche' arm_req e'
// alto (1 ck di latenza per RAM/video, 2 ck per DECO104), cosi' il tick ce_cpu lo trova
// sempre e l'accesso completa. Si abbassa quando arm_req cade (accesso consumato).
// ── bus completion NON-ROM: served-latch (fix race write-MMIO, loop instr=5) ──
// Il vecchio ready_d era un LIVELLO legato ad arm_req CONTINUO: su una WRITE la
// CPU e' ce-paced e arm_req OSCILLA tra i tick ce (req 1->0->1); quando cade,
// ready_d cade con lui -> nel ciclo in cui ce_cpu avanza l'execute, arm_ready=0
// -> execute non retira -> la write viene RI-EMESSA -> loop, nero. Fix: latch che,
// servito l'accesso, TIENE arm_ready alto finche' arm_req non presenta un accesso
// GENUINAMENTE nuovo (addr o we diversi da quello servito), robusto all'oscillazione.
reg        ready_lvl;
reg        busy, busy2, busy3;
reg        served_v;
reg [25:0] served_addr;
reg        served_we;
reg [25:0] req_addr_r;
reg        req_we_r;

wire is_rom_rd  = arm_req & ~arm_we & ns_is_rom;
wire new_access = arm_req & ~is_rom_rd &
                  (~served_v | (aa != served_addr) | (arm_we != served_we));

always @(posedge clk) begin
	if (reset) begin
		busy<=0; busy2<=0; busy3<=0; ready_lvl<=0; served_v<=0;
	end else if (is_rom_rd) begin
		ready_lvl <= 1'b0;
		busy      <= 1'b0;
		served_v  <= 1'b0;
	end else if (new_access & ~busy) begin
		busy<=1; busy2<=0; busy3<=0; ready_lvl<=0; served_v<=0;
		req_addr_r <= aa;
		req_we_r   <= arm_we;
	end else if (busy & ns_is_prot & ~req_we_r & ~busy2) begin
		busy2 <= 1;                         // DECO104 read: 1o ck extra (ex ready_d2)
	end else if (busy & ns_is_prot & ~req_we_r & busy2 & ~busy3) begin
		busy3 <= 1;                         // DECO104 read: 2o ck extra
	end else if (busy) begin
		busy<=0; busy2<=0;
		ready_lvl   <= 1'b1;                // livello: resta alto finche' new_access
		served_v    <= 1'b1;
		served_addr <= req_addr_r;
		served_we   <= req_we_r;
	end
end
// ROM ready SOLO se il dword servito e' per QUESTO indirizzo (aa==rom_served_aa).
// Altrimenti la CPU legge il dword VECCHIO per il nuovo addr -> istruzione rotta ->
// salto a indirizzo morto -> blocco -> schermo nero. (Bug riprodotto e fixato in
// sim/tb/tb_ns_boot.sv: con questa guard la CPU boota fino a maxpc 0x3ece8.)
assign arm_ready = ns_is_rom  ? (rom_dword_valid & (aa == rom_served_aa))
                              : ready_lvl;   // non-ROM: latch servito, ce-safe

// === SAVESTATE — dichiarazioni bus (devono precedere il primo adaptor) ===
// SS_IDX_* = indice univoco di ogni blocco di stato. SS_NSLAVES = numero di slave.
localparam SS_IDX_WORKRAM    = 0;
localparam SS_IDX_SPR1       = 1;
localparam SS_IDX_SPR2       = 2;
localparam SS_IDX_PAL_CPU    = 3;
localparam SS_IDX_C1_PF1_MIR = 4;
localparam SS_IDX_C1_PF2_MIR = 5;
// chip0 (u_deco16_0): VRAM pf1/pf2, rowscroll pf1/pf2, control
localparam SS_IDX_C0_VRAM_PF1 = 6;
localparam SS_IDX_C0_VRAM_PF2 = 7;
localparam SS_IDX_C0_RS_PF1   = 8;
localparam SS_IDX_C0_RS_PF2   = 9;
localparam SS_IDX_C0_CTRL     = 10;
// chip1 (u_deco16_1): VRAM pf1/pf2, rowscroll pf1/pf2, control
localparam SS_IDX_C1_VRAM_PF1 = 11;
localparam SS_IDX_C1_VRAM_PF2 = 12;
localparam SS_IDX_C1_RS_PF1   = 13;
localparam SS_IDX_C1_RS_PF2   = 14;
localparam SS_IDX_C1_CTRL     = 15;
localparam SS_IDX_HUC_RAM     = 16;
localparam SS_IDX_GLOBAL      = 17;   // SSP del 68000 (modulo ss_m68k)
// chip0 VRAM shadow mirror (readback CPU pf1/pf2) — vedi blocco mirror chip0 sotto
localparam SS_IDX_C0_PF1_MIR  = 18;
localparam SS_IDX_C0_PF2_MIR  = 19;
localparam SS_IDX_HUC_CPU     = 20;   // stato interno HUC6280 (auto_ss, 246 bit)
localparam SS_IDX_OKI0        = 21;   // stato interno OKI #0 (jt6295, auto_ss 359 bit)
localparam SS_IDX_OKI1        = 22;   // stato interno OKI #1 (jt6295, auto_ss 359 bit)
localparam SS_IDX_YM          = 23;   // stato interno YM2151 (jt51, auto_ss 2774 bit)
localparam SS_IDX_ACE         = 24;   // DECO ACE register file (blend/alpha/fade, 64x16)
localparam SS_IDX_AUDIO_BUS   = 25;   // stato persistente wrapper audio (FIFO sndlatch + YM/OKI ctrl, 161 bit)
localparam SS_IDX_MISC        = 26;   // sprite DMA + palette DMA + priority_reg + irq6_pending (74 bit)
localparam SS_IDX_DECO104     = 27;   // DECO104 reg protezione (xor/nand/bank/latch/soundlatch, 70 bit)
localparam SS_IDX_DC_RB0      = 28;   // DECO104 rambank0 (RAM protezione 128x16)
localparam SS_IDX_DC_RB1      = 29;   // DECO104 rambank1 (RAM protezione 128x16)
localparam SS_IDX_Z80_REGS    = 30;   // T80 registri (REG/DIR nativi, 212 bit)
localparam SS_IDX_Z80_RAM     = 31;   // Z80 sound RAM 2KB
localparam SS_NSLAVES         = 32;
// memory_stream COUNT (>= SS_NSLAVES, potenza di 2). Con SS_NSLAVES>16 serve COUNT>=32.
localparam SS_MS_COUNT        = 32;
ssbus_if ssbus();
ssbus_if ssb[SS_NSLAVES]();

// ── WORK RAM (128KB 32-bit) + ADAPTOR SAVESTATE (FIX: chunk MANCANTE) ─────────────
// BUG trovato dai DATI (.ss slot1: chunk idx0 WORKRAM VUOTO) + codice (adaptor mai aggiunto).
// BoogieWings salva la work RAM con workram_ss (ss_ram16_adaptor); NS non lo faceva -> al
// restore la RAM di gioco (liste oggetti/sprite/stato) restava quella corrente incoerente ->
// corruzione totale su restore in gameplay. Adaptor interposto (pattern ss_ram16_adaptor ma
// 32-bit con byte-enable): durante SS dirotta addr/we/wdata verso ssb[SS_IDX_WORKRAM],
// forzando be=1111 (word piena). width=2 = 32-bit (log2 dei byte: 0=8b,1=16b,2=32b,3=64b).
// Porta A = SOLO gioco: path addr/we/be/wdata IDENTICO al pre-savestate (zero mux,
// zero logica ssbus nei path critici -> timing di gioco ripristinato).
// Porta B = savestate (true dual port M10K), lato ssbus REGISTRATO: il master
// (memory_stream) tiene addr/data/write stabili finche' non vede l'ack, quindi lo
// stadio registrato e' sicuro e la fabric ssbus resta fuori dai path della BRAM.
// SINGLE-PORT + MUX (il TDP byte-enabled non si infera su Cyclone V). Handshake
// REGISTRATO validato dal collega (rd_d/rd_d2 = 2 cicli; write registrata insieme).
// Il select del mux (wr_ss_port) e' REGISTRATO -> durante il gioco e' 0 stabile,
// il path addr di gioco ha solo ~1 LUT di mux. Il gioco e' congelato durante SS.
wire        wr_ss_sel = ssb[SS_IDX_WORKRAM].access(SS_IDX_WORKRAM);
reg  [14:0] wr_ss_addr_r;
reg  [31:0] wr_ss_wdata_r;
reg         wr_ss_we_r;
reg         wr_ss_rd_d, wr_ss_rd_d2;
// finestra in cui il savestate usa la porta (write o read in volo): mux -> SS
wire        wr_ss_port   = wr_ss_we_r | wr_ss_rd_d | wr_ss_rd_d2;
wire [16:0] wr_addr_mux  = wr_ss_port ? {2'd0, wr_ss_addr_r} : aa[18:2];
wire        wr_we_mux    = wr_ss_port ? wr_ss_we_r : (ns_is_ram & arm_req & arm_we);
wire [31:0] wr_wdata_mux = wr_ss_port ? wr_ss_wdata_r : arm_wdata;
wire [3:0]  wr_be_mux    = wr_ss_port ? 4'b1111 : arm_be;
ns_workram_128k u_workram (
	.clk    (clk),
	.addr   (wr_addr_mux),
	.we     (wr_we_mux),
	.be     (wr_be_mux),
	.wdata  (wr_wdata_mux),
	.rdata  (ram_dword)
);
always @(posedge clk) begin
	ssb[SS_IDX_WORKRAM].setup(SS_IDX_WORKRAM, 32'd32768, 2);  // 32K word 32-bit
	wr_ss_addr_r  <= ssb[SS_IDX_WORKRAM].addr[14:0];
	wr_ss_wdata_r <= ssb[SS_IDX_WORKRAM].data[31:0];
	wr_ss_we_r    <= wr_ss_sel & ssb[SS_IDX_WORKRAM].write;
	wr_ss_rd_d    <= wr_ss_sel & ssb[SS_IDX_WORKRAM].read;
	wr_ss_rd_d2   <= wr_ss_rd_d;
	if (wr_ss_sel & ssb[SS_IDX_WORKRAM].write) ssb[SS_IDX_WORKRAM].write_ack(SS_IDX_WORKRAM);
	// read_response legge ram_dword (uscita porta unica): a rd_d2 la RAM ha gia'
	// prodotto mem[wr_ss_addr_r] (addr muxato al ciclo rd_d, latenza 1 ck).
	if (wr_ss_rd_d2) ssb[SS_IDX_WORKRAM].read_response(SS_IDX_WORKRAM, {32'd0, ram_dword});
end

// ROM bus: decrittato a monte (de156 al download)
// Forward decl per ModelSim 10.5b (prot_cpu_rd declared earlier in the adapter)
wire [15:0] spr1_cpu_rd, spr2_cpu_rd, ace_cpu_rd, d16_0_cpu_rdata, d16_1_cpu_rdata;

// =====================================================================
// Chip1 VRAM shadow mirror (pattern Darius2 NinjaWarriors).
// MAME boogwing.cpp:529-530: chip1 pf1/pf2 mappati con `.ram().w(deco16ic)`.
// = scrittura va sia a RAM shadow CPU sia al deco16ic interno.
// CPU readback DEVE leggere lo shadow (non il deco16ic shared con scan).
// Senza mirror: CPU read torna 0/FFFF → bug logica gioco (AI, path, collision).
// Range:
//   $274000-$275FFF (pf1, 8 KB = 4096 word)
//   $276000-$277FFF (pf2, 8 KB = 4096 word)
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf1_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf1_mirror_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf2_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf2_mirror_hi [0:4095];
integer ii_c1m;
initial begin
	for (ii_c1m = 0; ii_c1m < 4096; ii_c1m = ii_c1m + 1) begin
		c1_pf1_mirror_lo[ii_c1m] = 8'd0; c1_pf1_mirror_hi[ii_c1m] = 8'd0;
		c1_pf2_mirror_lo[ii_c1m] = 8'd0; c1_pf2_mirror_hi[ii_c1m] = 8'd0;
	end
end
// NS: tilegen1 pf1/pf2 data windows are the scattered ranges 0x1c2000/0x1c4000,
// so the mirror-write flags use the NS sub-range decode (like chip0), not raw bits.
wire c1_is_pf1_data = ns_pf1_pf1;
wire c1_is_pf2_data = ns_pf1_pf2;
wire [11:0] c1_mirror_idx = cpu_addr[13:2];   // in-region DWORD offset (ARM ÷4 stride, vedi fix sopra)

// Savestate adaptor in serie sui mirror chip1 (ZERO BRAM aggiunta).
wire c1m1_we_lo_cpu = c1_is_pf1_data && cpu_wr && ~cpu_dsn[0];
wire c1m1_we_hi_cpu = c1_is_pf1_data && cpu_wr && ~cpu_dsn[1];
wire c1m2_we_lo_cpu = c1_is_pf2_data && cpu_wr && ~cpu_dsn[0];
wire c1m2_we_hi_cpu = c1_is_pf2_data && cpu_wr && ~cpu_dsn[1];
wire c1m1_we_lo, c1m1_we_hi, c1m2_we_lo, c1m2_we_hi;
wire [11:0] c1m1_idx, c1m2_idx;
wire [15:0] c1m1_wdata_eff, c1m2_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C1_PF1_MIR)) c1m1_ss (
	.clk(clk),
	.we_lo_in(c1m1_we_lo_cpu), .we_hi_in(c1m1_we_hi_cpu), .addr_in(c1_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c1m1_we_lo), .we_hi_out(c1m1_we_hi), .addr_out(c1m1_idx), .wdata_out(c1m1_wdata_eff),
	.q_in(c1_pf1_mirror_rd), .ssbus(ssb[SS_IDX_C1_PF1_MIR])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C1_PF2_MIR)) c1m2_ss (
	.clk(clk),
	.we_lo_in(c1m2_we_lo_cpu), .we_hi_in(c1m2_we_hi_cpu), .addr_in(c1_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c1m2_we_lo), .we_hi_out(c1m2_we_hi), .addr_out(c1m2_idx), .wdata_out(c1m2_wdata_eff),
	.q_in(c1_pf2_mirror_rd), .ssbus(ssb[SS_IDX_C1_PF2_MIR])
);
always @(posedge clk) if (c1m1_we_lo) c1_pf1_mirror_lo[c1m1_idx] <= c1m1_wdata_eff[ 7:0];
always @(posedge clk) if (c1m1_we_hi) c1_pf1_mirror_hi[c1m1_idx] <= c1m1_wdata_eff[15:8];
always @(posedge clk) if (c1m2_we_lo) c1_pf2_mirror_lo[c1m2_idx] <= c1m2_wdata_eff[ 7:0];
always @(posedge clk) if (c1m2_we_hi) c1_pf2_mirror_hi[c1m2_idx] <= c1m2_wdata_eff[15:8];
reg [7:0] c1_pf1_mr_lo_r, c1_pf1_mr_hi_r, c1_pf2_mr_lo_r, c1_pf2_mr_hi_r;
always @(posedge clk) c1_pf1_mr_lo_r <= c1_pf1_mirror_lo[c1m1_idx];
always @(posedge clk) c1_pf1_mr_hi_r <= c1_pf1_mirror_hi[c1m1_idx];
always @(posedge clk) c1_pf2_mr_lo_r <= c1_pf2_mirror_lo[c1m2_idx];
always @(posedge clk) c1_pf2_mr_hi_r <= c1_pf2_mirror_hi[c1m2_idx];
reg c1_pf1_rd_d, c1_pf2_rd_d;
always @(posedge clk) begin
	c1_pf1_rd_d <= c1_is_pf1_data;
	c1_pf2_rd_d <= c1_is_pf2_data;
end
wire [15:0] c1_pf1_mirror_rd = {c1_pf1_mr_hi_r, c1_pf1_mr_lo_r};
wire [15:0] c1_pf2_mirror_rd = {c1_pf2_mr_hi_r, c1_pf2_mr_lo_r};
wire [15:0] c1_mirror_rdata  = c1_pf2_rd_d ? c1_pf2_mirror_rd :
                                c1_pf1_rd_d ? c1_pf1_mirror_rd :
                                d16_1_cpu_rdata;

// =====================================================================
// Chip0 VRAM shadow mirror (stesso pattern chip1 sopra, FUNZIONANTE su HW).
// CAUSA bug YES/NO: deco16ic_jt mux cpu_rdata (460-463) NON serve is_pf1_data/
// is_pf2_data -> le letture VRAM dati del chip0 ($264000/$266000) tornano 0x0000.
// La routine 0x16AFC fa read-modify-write sui glifi YES/NO (BG0): legge 0 ->
// azzera i tile-code -> testo invisibile. "1P" sopravvive (riscritto plain).
// Range: $264000-$265FFF (pf1, [15:13]==010) / $266000-$267FFF (pf2, ==011).
// Gating su is_pf0 (NON is_pf0_mirror=$24Cxxx, che e' ctrl remap).
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf1_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf1_mirror_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf2_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf2_mirror_hi [0:4095];
integer ii_c0m;
initial begin
	for (ii_c0m = 0; ii_c0m < 4096; ii_c0m = ii_c0m + 1) begin
		c0_pf1_mirror_lo[ii_c0m] = 8'd0; c0_pf1_mirror_hi[ii_c0m] = 8'd0;
		c0_pf2_mirror_lo[ii_c0m] = 8'd0; c0_pf2_mirror_hi[ii_c0m] = 8'd0;
	end
end
// NS: the pf1/pf2 data windows are the scattered ranges 0x182000/0x184000, so
// the mirror-write flags use the NS sub-range decode (not raw cpu_addr bits).
wire c0_is_pf1_data = ns_pf0_pf1;
wire c0_is_pf2_data = ns_pf0_pf2;
wire [11:0] c0_mirror_idx = cpu_addr[13:2];   // in-region DWORD offset (ARM ÷4 stride, vedi fix sopra)
wire c0m1_we_lo_cpu = c0_is_pf1_data && cpu_wr && ~cpu_dsn[0];
wire c0m1_we_hi_cpu = c0_is_pf1_data && cpu_wr && ~cpu_dsn[1];
wire c0m2_we_lo_cpu = c0_is_pf2_data && cpu_wr && ~cpu_dsn[0];
wire c0m2_we_hi_cpu = c0_is_pf2_data && cpu_wr && ~cpu_dsn[1];
wire c0m1_we_lo, c0m1_we_hi, c0m2_we_lo, c0m2_we_hi;
wire [11:0] c0m1_idx, c0m2_idx;
wire [15:0] c0m1_wdata_eff, c0m2_wdata_eff;
wire [15:0] c0_pf1_mirror_rd, c0_pf2_mirror_rd;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C0_PF1_MIR)) c0m1_ss (
	.clk(clk),
	.we_lo_in(c0m1_we_lo_cpu), .we_hi_in(c0m1_we_hi_cpu), .addr_in(c0_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c0m1_we_lo), .we_hi_out(c0m1_we_hi), .addr_out(c0m1_idx), .wdata_out(c0m1_wdata_eff),
	.q_in(c0_pf1_mirror_rd), .ssbus(ssb[SS_IDX_C0_PF1_MIR])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C0_PF2_MIR)) c0m2_ss (
	.clk(clk),
	.we_lo_in(c0m2_we_lo_cpu), .we_hi_in(c0m2_we_hi_cpu), .addr_in(c0_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c0m2_we_lo), .we_hi_out(c0m2_we_hi), .addr_out(c0m2_idx), .wdata_out(c0m2_wdata_eff),
	.q_in(c0_pf2_mirror_rd), .ssbus(ssb[SS_IDX_C0_PF2_MIR])
);
always @(posedge clk) if (c0m1_we_lo) c0_pf1_mirror_lo[c0m1_idx] <= c0m1_wdata_eff[ 7:0];
always @(posedge clk) if (c0m1_we_hi) c0_pf1_mirror_hi[c0m1_idx] <= c0m1_wdata_eff[15:8];
always @(posedge clk) if (c0m2_we_lo) c0_pf2_mirror_lo[c0m2_idx] <= c0m2_wdata_eff[ 7:0];
always @(posedge clk) if (c0m2_we_hi) c0_pf2_mirror_hi[c0m2_idx] <= c0m2_wdata_eff[15:8];
reg [7:0] c0_pf1_mr_lo_r, c0_pf1_mr_hi_r, c0_pf2_mr_lo_r, c0_pf2_mr_hi_r;
always @(posedge clk) c0_pf1_mr_lo_r <= c0_pf1_mirror_lo[c0m1_idx];
always @(posedge clk) c0_pf1_mr_hi_r <= c0_pf1_mirror_hi[c0m1_idx];
always @(posedge clk) c0_pf2_mr_lo_r <= c0_pf2_mirror_lo[c0m2_idx];
always @(posedge clk) c0_pf2_mr_hi_r <= c0_pf2_mirror_hi[c0m2_idx];
reg c0_pf1_rd_d, c0_pf2_rd_d;
always @(posedge clk) begin
	c0_pf1_rd_d <= c0_is_pf1_data;
	c0_pf2_rd_d <= c0_is_pf2_data;
end
assign c0_pf1_mirror_rd = {c0_pf1_mr_hi_r, c0_pf1_mr_lo_r};
assign c0_pf2_mirror_rd = {c0_pf2_mr_hi_r, c0_pf2_mr_lo_r};
wire [15:0] c0_mirror_rdata  = c0_pf2_rd_d ? c0_pf2_mirror_rd :
                                c0_pf1_rd_d ? c0_pf1_mirror_rd :
                                d16_0_cpu_rdata;

// Chip-side 16-bit read mux. For the milestone only is_prot is live; the other
// chips are wired in later steps. The ARM bus read assembly (arm_rdata_mux in
// the adapter) consumes prot_cpu_rd / ram_dword directly, so this
// cpu_rdata is currently only the chip-facing convenience mux.
assign cpu_rdata = is_spr1        ? spr1_cpu_rd    :
                    is_spr2        ? spr2_cpu_rd    :
                    is_ace         ? ace_cpu_rd     :
                    is_pf0         ? c0_mirror_rdata:
                    is_pf0_mirror  ? d16_0_cpu_rdata:
                    is_pf1         ? c1_mirror_rdata:
                    is_prot        ? prot_cpu_rd    :
                    16'hFFFF;

// =====================================================================
// DECO104 protection / IO mux (stub minimale — vedi rtl/common/deco104.sv)
// =====================================================================
// Stub minimale che mappa i 4 indirizzi noti del main (da disassembly):
//   $24E138 → SYSTEM     (system_port)
//   $24E150 → soundlatch write (→ H6280 IRQ0 quando audio sarà istanziato)
//   $24E344 → INPUTS     (inputs_port)
//   $24E6C0 → DSW        (dsw_port)
// Tutti gli altri offset ritornano FFFF (sufficiente per il boot, no
// check di magic value protezione attivi ai primi cicli).

wire  [7:0] sndlatch_data;
wire        sndlatch_irq_main_pulse;   // pulse main scrive nuovo latch
// Savestate DECO104: adaptor sui 70 bit di reg protezione (xor/nand/bank/latch/soundlatch).
wire [68:0] dc_ss_out, dc_ss_in;
wire        dc_ss_wr;
auto_save_adaptor #(.N_BITS(69), .SS_IDX(SS_IDX_DECO104)) u_deco104_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_DECO104]),
	.bits_in(dc_ss_out), .bits_out(dc_ss_in), .bits_wr(dc_ss_wr)
);
deco104 #(
	.SS_RB0_IDX(SS_IDX_DC_RB0), .SS_RB1_IDX(SS_IDX_DC_RB1),
	.ADDR_SCRAMBLE_P(2'd2),              // NS: set_interface_scramble_interleave
	.MAGIC_READ_ADDR_XOR_P(16'h02a4),    // DECO104 magic xor value (deco104.cpp ctor)
	.MAGIC_XOR_ENABLED_P(1'b0)           // nslasher does NOT call set_use_magic_read_address_xor

) u_prot (
	.clk             (clk),
	.reset           (reset),
	.cpu_addr        (prot_addr),       // NS: in-region word offset of 0x200000
	.cpu_cs          (is_prot),
	.cpu_rd          (cpu_rd),
	.cpu_wr          (cpu_wr),
	.cpu_wdata       (cpu_wdata),
	.cpu_dsn         (cpu_dsn),
	.cpu_rdata       (prot_cpu_rd),
	.port_a          (inputs_port),
	.port_b          (prot_port_b),    // NS: bit0 = EEPROM DO (lshift 0), resto system_port
	.port_c          (prot_port_c),    // NS: IN1 = coin/service + bit4 VBLANK (MAME), NON i DIP
	.soundlatch_data (sndlatch_data),
	.soundlatch_irq  (sndlatch_irq_main_pulse),
	.soundlatch_rd   (1'b0),             // H6280 non istanziata → mai legge
	.soundlatch_dout (),
	.dc_ss_in        (dc_ss_in),
	.dc_ss_out       (dc_ss_out),
	.dc_ss_wr        (dc_ss_wr),
	.ss_rb0          (ssb[SS_IDX_DC_RB0]),
	.ss_rb1          (ssb[SS_IDX_DC_RB1])
);

// =====================================================================
// Savestate: sprite DMA FSM + palette DMA FSM + priority_reg + irq6_pending (74 bit)
// =====================================================================
// 2026-08-09 — i registri di CONFIG VIDEO scritti dalla CPU non stavano in
// NESSUN chunk: al restore restavano quelli della sessione corrente (sfondo/
// ascensore mancanti caricando un .ss di un'altra scena). Appesi IN TESTA
// (bit [104:78]); il layout storico [77:0] resta intoccato.
localparam integer MISC_SS_BITS = 105;
wire [MISC_SS_BITS-1:0] misc_ss_out, misc_ss_in;
wire                   misc_ss_wr;
auto_save_adaptor #(.N_BITS(MISC_SS_BITS), .SS_IDX(SS_IDX_MISC)) u_misc_ss_adaptor (
	.clk     (clk),
	.ssbus   (ssb[SS_IDX_MISC]),
	.bits_in (misc_ss_out),
	.bits_out(misc_ss_in),
	.bits_wr (misc_ss_wr)
);
// SAVE: concatena in ordine (save = restore ordine identico)
//  [77:62] priority_reg  [61] irq6_pending  [60:48] dma_rd_idx(13)  [47:36] dma_wr_idx(12)  [35] dma_which
//  [34] dma2_active  [33] dma1_active  [32] pal_dma_active  [31:19] pal_dma_rd_idx  [18:8] pal_dma_wr_idx
//  [7:0] pal_dma_b_lat
// [77:62] = probe_flags al posto di priority_reg (sempre 0 su NS; layout intatto)
assign misc_ss_out = {ns_pri_reg, tilemap_cbank_reg, spr1_cbank_reg, spr2_cbank_reg,
                      probe_flags, irq6_pending, dma_rd_idx, dma_wr_idx, dma_which, dma2_active, dma1_active,
                      pal_dma_active, pal_dma_rd_idx, pal_dma_wr_idx, pal_dma_b_lat};
// RESTORE: estrai con lo stesso ordine (endianness identica al save)
wire [2:0]  misc_ns_pri_load          = misc_ss_in[104:102];
wire [7:0]  misc_tm_cbank_load        = misc_ss_in[101:94];
wire [7:0]  misc_spr1_cbank_load      = misc_ss_in[93:86];
wire [7:0]  misc_spr2_cbank_load      = misc_ss_in[85:78];
wire        misc_irq6_load            = misc_ss_in[61];
wire [12:0] misc_dma_rd_idx_load      = misc_ss_in[60:48];
wire [11:0] misc_dma_wr_idx_load      = misc_ss_in[47:36];
wire        misc_dma_which_load       = misc_ss_in[35];
wire        misc_dma2_load            = misc_ss_in[34];
wire        misc_dma1_load            = misc_ss_in[33];

// =====================================================================
// Priority register (0x220000) — write da CPU, usato dal video mixer (TODO)
// =====================================================================
reg [15:0] priority_reg;
always @(posedge clk) begin
	if (reset) priority_reg <= 16'd0;
	else if (is_prio & cpu_wr) begin
		if (~cpu_dsn[0]) priority_reg[7:0]  <= cpu_wdata[7:0];
		if (~cpu_dsn[1]) priority_reg[15:8] <= cpu_wdata[15:8];
	end
	// FIX restore (2026-07-22): NIENTE load dal MISC — il lato save mette
	// probe_flags in quei bit (garbage per un load) e bit3 garbage = top_is_raw
	// globale = fade morto post-restore. NS non scrive mai priority_reg
	// (is_prio=0): al restore si azzera come al reset.
	else if (misc_ss_wr) priority_reg <= 16'd0;
end

// =====================================================================
// NS colour bank registers (0x164000/4/8) — deco32_v.cpp tilemap/sprite_color_bank_w
//   0x164000 tilemap_color_bank_w: tilegen1 pf1 bank = ((d>>0)&7)<<4,
//                                  tilegen1 pf2 bank = ((d>>3)&7)<<4
//   0x164004 sprite1_color_bank_w: sprgen0 colorbase = (d&7)<<8
//   0x164008 sprite2_color_bank_w: sprgen1 colorbase = (d&7)<<8
// These land on byte 0 (umask 0x0000FFFF lower half, like the other 16-bit chips).
// =====================================================================
wire is_cbank = (aa >= 26'h164000) && (aa < 26'h16400c);
reg [7:0] tilemap_cbank_reg;   // 0x164000 data
reg [7:0] spr1_cbank_reg;      // 0x164004 data
reg [7:0] spr2_cbank_reg;      // 0x164008 data
always @(posedge clk) begin
	if (reset) begin
		tilemap_cbank_reg <= 8'd0;
		spr1_cbank_reg    <= 8'd0;
		spr2_cbank_reg    <= 8'd0;
	end else if (misc_ss_wr) begin       // restore (CPU congelata)
		tilemap_cbank_reg <= misc_tm_cbank_load;
		spr1_cbank_reg    <= misc_spr1_cbank_load;
		spr2_cbank_reg    <= misc_spr2_cbank_load;
	end else if (is_cbank & cpu_wr & ~cpu_dsn[0]) begin
		case (aa[3:2])
			2'd0: tilemap_cbank_reg <= cpu_wdata[7:0];   // 0x164000
			2'd1: spr1_cbank_reg    <= cpu_wdata[7:0];   // 0x164004
			2'd2: spr2_cbank_reg    <= cpu_wdata[7:0];   // 0x164008
			default: ;
		endcase
	end
end
// Decoded fields (raw, consumed by the NS mixer in the palette-index step):
//   tilegen1 pf1 bank field = data[2:0], pf2 bank field = data[5:3] (MAME <<4)
//   sprite0/1 colorbase field = data[2:0] (MAME <<8)
// Step 1 only CAPTURES these registers; the exact bit-weighting is applied in the
// mixer (Step 4) where the final palette index is built. tilegen1 stays on its
// static col-bank param for now (no functional change until the mixer uses these).
wire [2:0] tg1_pf1_cbank_field = tilemap_cbank_reg[2:0];
wire [2:0] tg1_pf2_cbank_field = tilemap_cbank_reg[5:3];
wire [2:0] spr1_colorbase_sel  = spr1_cbank_reg[2:0];
wire [2:0] spr2_colorbase_sel  = spr2_cbank_reg[2:0];

// =====================================================================
// SOUND CPU H6280 @ 8.055 MHz (32.22/4)
// =====================================================================
// TODO: istanziare HUC6280 + memory map audio BoogieWings
//   - ROM da DDRAM (64KB)
//   - YM2151 @ 0x110000
//   - OKIM6295 #1 @ 0x120000
//   - OKIM6295 #2 @ 0x130000
//   - soundlatch @ 0x140000 (read da DECO104)
//   - IRQ0 = soundlatch_irq_cb, IRQ2 = YM2151 IRQ
//   - RAM 8KB @ 0x1F0000

// =====================================================================
// DECO16IC × 2 (tilemap engine, 4 BG layer totali)
// =====================================================================
// Tilegen[0]: pf1+pf2 (BG 1+2), CS @ 0x260000-0x26AFFF
// Tilegen[1]: pf1+pf2 (BG 3+4), CS @ 0x270000-0x27AFFF
// Tile ROM da SDRAM: tilerom_req via tile_rom_arbiter (TODO)
wire [3:0]  d16_0_pf1_pix;
wire [4:0]  d16_0_pf2_pix;     // 5-bit per BG1 5bpp (BoogieWings)
wire [4:0]  d16_0_pf1_col,  d16_0_pf2_col;
wire        d16_0_pf1_opq,  d16_0_pf2_opq;
wire        flip_screen;        // chip0 ctrl[0] bit 7 (MAME boogwing.cpp:419)
// Render x/y flippati quando flip_screen=1 (MAME flip_screen_set).
// Schermo BoogieWings: hcnt 0..441 attivo 0..319 → x flip = 319-x.
// vcnt 0..273 attivo 8..247 (240 row visibili) → y flip = (8+247)-y = 255-y.
// Template.sv: render_x=hcnt, render_y=vcnt[8:0]. render_y arriva 10-bit
// (estesa con {1'b0, render_y[8:0]}). Mantengo formula MAME-coerente.
wire [9:0] render_x_flip = flip_screen ? (10'd319 - render_x) : render_x;
wire [9:0] render_y_flip = flip_screen ? (10'd255 - render_y) : render_y;
wire [3:0]  d16_1_pf1_pix;
wire [4:0]  d16_1_pf2_pix;     // 5-bit interfaccia ma 4bpp (bit 4 sempre 0)
wire [4:0]  d16_1_pf1_col,  d16_1_pf2_col;
wire        d16_1_pf1_opq,  d16_1_pf2_opq;
wire [23:0] d16_0_pf1_rom_addr, d16_0_pf2_rom_addr;
wire [2:0]  d16_0_pf1_rid, d16_0_pf2_rid;
wire        d16_0_pf1_rom_req,  d16_0_pf2_rom_req;
wire [31:0] d16_0_pf1_rom_data, d16_0_pf2_rom_data;
wire        d16_0_pf1_rom_valid,d16_0_pf2_rom_valid;
wire        d16_0_pf2_p4_req;
wire  [7:0] d16_0_pf2_p4_data;
wire        d16_0_pf2_p4_valid;
wire [23:0] d16_1_pf1_rom_addr, d16_1_pf2_rom_addr;
wire [2:0]  d16_1_pf1_rid, d16_1_pf2_rid;
wire        d16_1_pf1_rom_req,  d16_1_pf2_rom_req;
wire [31:0] d16_1_pf1_rom_data, d16_1_pf2_rom_data;
wire        d16_1_pf1_rom_valid,d16_1_pf2_rom_valid;
// d16_0_cpu_rdata/d16_1_cpu_rdata già forward-declarate sopra

// BoogieWings bank callbacks (boogwing.cpp:749, 761):
//   tilegen[0]: bank1=none, bank2=bank_callback (mode 1)
//   tilegen[1]: bank1=bank_callback2, bank2=bank_callback2 (mode 2)
// GFX base address SDRAM (tile_byte_addr relativo a TILE_BASE):
//   tiles1 (text)  @ 0x000000  (128KB)
//   tiles2 (BG1)   @ 0x020000  (3MB)
//   tiles3 (BG2)   @ 0x320000  (2MB)
// (d16_0_cpu_addr_eff removed — NS uses the synthetic d16_0_cpu_addr_ns built
//  in the adapter; the $24Cxxx ctrl mirror was a Boogie Wings artifact.)

// Chip 0: pf1 = text 8x8 (tiles1), pf2 = BG1 16x16 (tiles2)
// Modulo: deco16ic_jt (scanline-based, ispirato Jotego BAC06).
// Vecchio deco16ic istanza COMMENTATA — file vecchio resta nel qsf.
deco16ic_jt #(
	.BANK1_MODE(2'd0),
	.BANK2_MODE(2'd1),
	.PF1_COL_BANK(5'd0), .PF1_COL_MASK(4'hF),
	.PF2_COL_BANK(5'd0), .PF2_COL_MASK(4'hF),
	.PF1_TILE_SIZE(8),   .PF2_TILE_SIZE(16),
	.PF1_REGION_ID(3'd0),
	.PF2_REGION_ID(3'd2),
	// NS: chip0.pf2 (BG) e' 4bpp (deco32.cpp tilelayout, verificato max pen 0xF),
	// NON 5bpp come il BG1 di BoogieWings. Niente fetch del 5o piano.
	.PF2_HAS_5BPP(0),
	.PF2_REGION_ID_P4(3'd4),
	.SS_VRAM_PF1_IDX(SS_IDX_C0_VRAM_PF1),
	.SS_VRAM_PF2_IDX(SS_IDX_C0_VRAM_PF2),
	.SS_RS_PF1_IDX(SS_IDX_C0_RS_PF1),
	.SS_RS_PF2_IDX(SS_IDX_C0_RS_PF2),
	.SS_CTRL_IDX(SS_IDX_C0_CTRL)
) u_deco16_0 (
	.clk(clk), .reset(reset),
	.fetch_rst(ss_reset | boot_spr_rst),
	.cpu_addr(d16_0_cpu_addr_ns),
	.cpu_cs(is_pf0),
	.cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
	.cpu_wdata(cpu_wdata), .cpu_dsn(cpu_dsn),
	.cpu_rdata(d16_0_cpu_rdata),
	.render_x(render_x_flip), .render_y(render_y_flip),
	.hblank_in(hblank_in), .vblank_in(vblank_in), .ce_pix(ce_pix),
	.pf1_pix(d16_0_pf1_pix), .pf2_pix(d16_0_pf2_pix),
	.pf1_col(d16_0_pf1_col), .pf2_col(d16_0_pf2_col),
	.pf1_opaque(d16_0_pf1_opq), .pf2_opaque(d16_0_pf2_opq),
	.flip_screen(flip_screen),
	.pf1_rom_addr(d16_0_pf1_rom_addr), .pf1_region_id(d16_0_pf1_rid),
	.pf1_rom_req(d16_0_pf1_rom_req),
	.pf1_rom_data(d16_0_pf1_rom_data), .pf1_rom_valid(d16_0_pf1_rom_valid),
	.pf2_rom_addr(d16_0_pf2_rom_addr), .pf2_region_id(d16_0_pf2_rid),
	.pf2_rom_req(d16_0_pf2_rom_req),
	.pf2_rom_data(d16_0_pf2_rom_data), .pf2_rom_valid(d16_0_pf2_rom_valid),
	.pf2_p4_req  (d16_0_pf2_p4_req),
	.pf2_p4_data (d16_0_pf2_p4_data),
	.pf2_p4_valid(d16_0_pf2_p4_valid),
	.osd_tile_decode_mode(osd_tile_decode_mode),
	.osd_pixel_bit_msb(osd_pixel_bit_msb),
	.osd_plane_rev32(osd_plane_rev32),
	.osd_nibble_swap(osd_nibble_swap),
	.osd_byte_swap_ab(osd_byte_swap_ab),
	.osd_xhalf_inv(osd_xhalf_inv),
	.osd_tile_hi_rev(osd_tile_hi_rev),
	.osd_vram_swizzle(osd_vram_swizzle),
	.osd_p4_byte_pos (osd_bg1_p4_byte_pos),
	.osd_p4_brev8    (osd_bg1_p4_brev8),
	.osd_p4_bit_shift(osd_bg1_p4_bit_shift),
	.combine_mode    (1'b0),
	.ss_vram_pf1(ssb[SS_IDX_C0_VRAM_PF1]),
	.ss_vram_pf2(ssb[SS_IDX_C0_VRAM_PF2]),
	.ss_rs_pf1  (ssb[SS_IDX_C0_RS_PF1]),
	.ss_rs_pf2  (ssb[SS_IDX_C0_RS_PF2]),
	.ss_ctrl    (ssb[SS_IDX_C0_CTRL])
);

// Chip 1: pf1 + pf2 entrambi BG2 16x16 (tiles3). pf2 col_bank=16.
deco16ic_jt #(
	.BANK1_MODE(2'd2),
	.BANK2_MODE(2'd2),
	.PF1_COL_BANK(5'd0),  .PF1_COL_MASK(4'hF),
	.PF2_COL_BANK(5'd16), .PF2_COL_MASK(4'hF),
	.PF1_TILE_SIZE(16),   .PF2_TILE_SIZE(16),
	.PF1_REGION_ID(3'd5),
	.PF2_REGION_ID(3'd5),
	.COL_BANK_DYN(1),          // NS: tilegen1 colour banks set at runtime (0x164000)
	.SS_VRAM_PF1_IDX(SS_IDX_C1_VRAM_PF1),
	.SS_VRAM_PF2_IDX(SS_IDX_C1_VRAM_PF2),
	.SS_RS_PF1_IDX(SS_IDX_C1_RS_PF1),
	.SS_RS_PF2_IDX(SS_IDX_C1_RS_PF2),
	.SS_CTRL_IDX(SS_IDX_C1_CTRL)
) u_deco16_1 (
	.clk(clk), .reset(reset),
	.fetch_rst(ss_reset | boot_spr_rst),
	.cpu_addr(d16_1_cpu_addr_ns),
	.cpu_cs(is_pf1),
	.cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
	.cpu_wdata(cpu_wdata), .cpu_dsn(cpu_dsn),
	.cpu_rdata(d16_1_cpu_rdata),
	.render_x(render_x_flip), .render_y(render_y_flip),
	.hblank_in(hblank_in), .vblank_in(vblank_in), .ce_pix(ce_pix),
	.pf1_pix(d16_1_pf1_pix), .pf2_pix(d16_1_pf2_pix),
	.pf1_col(d16_1_pf1_col), .pf2_col(d16_1_pf2_col),
	.pf1_opaque(d16_1_pf1_opq), .pf2_opaque(d16_1_pf2_opq),
	.flip_screen(),
	.pf1_rom_addr(d16_1_pf1_rom_addr), .pf1_region_id(d16_1_pf1_rid),
	.pf1_rom_req(d16_1_pf1_rom_req),
	.pf1_rom_data(d16_1_pf1_rom_data), .pf1_rom_valid(d16_1_pf1_rom_valid),
	.pf2_rom_addr(d16_1_pf2_rom_addr), .pf2_region_id(d16_1_pf2_rid),
	.pf2_rom_req(d16_1_pf2_rom_req),
	.pf2_rom_data(d16_1_pf2_rom_data), .pf2_rom_valid(d16_1_pf2_rom_valid),
	.pf2_p4_req  (),       // chip1 no 5bpp
	.pf2_p4_data (8'd0),
	.pf2_p4_valid(1'b0),
	.osd_tile_decode_mode(osd_tile_decode_mode),
	.osd_pixel_bit_msb(osd_pixel_bit_msb),
	.osd_plane_rev32(osd_plane_rev32),
	.osd_nibble_swap(osd_nibble_swap),
	.osd_byte_swap_ab(osd_byte_swap_ab),
	.osd_xhalf_inv(osd_xhalf_inv),
	.osd_tile_hi_rev(osd_tile_hi_rev),
	.osd_vram_swizzle(osd_vram_swizzle),
	.osd_p4_byte_pos (2'd0),
	.osd_p4_brev8    (1'b0),
	.osd_p4_bit_shift(1'b0),
	.combine_mode    (ns_pri_reg[1]),   // NS: m_pri bit1 = BG2/3 joint 8bpp combine
	// FIX 2026-07-03: bank sommato nel MIXER a 12 bit (bg2a/bg2b_bank, <<8 entry);
	// qui il campo raw 3-bit sommava +2/+3 COLORI (troncato, doppio conteggio).
	.pf1_col_bank_dyn(5'd0),
	.pf2_col_bank_dyn(5'd0),
	.ss_vram_pf1(ssb[SS_IDX_C1_VRAM_PF1]),
	.ss_vram_pf2(ssb[SS_IDX_C1_VRAM_PF2]),
	.ss_rs_pf1  (ssb[SS_IDX_C1_RS_PF1]),
	.ss_rs_pf2  (ssb[SS_IDX_C1_RS_PF2]),
	.ss_ctrl    (ssb[SS_IDX_C1_CTRL])
);

// TODO: tile ROM arbiter tra deco16_0, deco16_1, (text)
// Per ora collego deco16_0 al SDRAM tile bridge (priorità singola)
// Riferimento Verilog: reference/jt/cop/hdl/jtcop_bac06.v

// =====================================================================
// DECO_SPRITE × 2 (sprite engine)
// =====================================================================
// Sprite RAM 2KB ciascuno (0x242000-0x2427FF, 0x246000-0x2467FF)
// Doppio buffer: CPU scrive in sprite_ram_cpu[N], DMA trigger su 0x240000/
// 0x244000 copia in sprite_ram_buf[N] che alimenta il renderer.
// Sprite RAM 2KB. Doppio buffer: cpu (CPU rw + DMA read) → buf (renderer read).
// 2 BRAM ognuna, 2 porte ognuna. DMA pipelinato:
//   - rd_idx: legge da cpu (via mux con spr_idx CPU)
//   - 1 ck dopo: scrive in buf con index = rd_idx-1
//   - dma_active resta su 1025 cicli (1024 read + 1 drain)
// NS Sprite RAM 8KB (4096×16) each. 8-bit lane split for clean M10K inference
// (1 write port CPU + 1 read port CPU readback).
// CPU-side RAM (CPU rw + DMA read source)
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_hi [0:4095];
// Buffer side (DMA write dest + renderer read source) — buffered_spriteram MAME-style
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_buf_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_buf_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_buf_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_buf_hi [0:4095];
integer ii_spr;
initial for (ii_spr=0; ii_spr<4096; ii_spr=ii_spr+1) begin
	spr1_lo[ii_spr] = 8'd0; spr1_hi[ii_spr] = 8'd0;
	spr2_lo[ii_spr] = 8'd0; spr2_hi[ii_spr] = 8'd0;
	spr1_buf_lo[ii_spr] = 8'd0; spr1_buf_hi[ii_spr] = 8'd0;
	spr2_buf_lo[ii_spr] = 8'd0; spr2_buf_hi[ii_spr] = 8'd0;
end
wire [11:0] spr_idx = cpu_addr[13:2];   // ARM ÷4 dword stride (vedi STRIDE FIX)

reg dma1_active, dma2_active;
reg [12:0] dma_rd_idx;          // 0..4096 (NS spriteram = 4096 words)
wire dma_active = dma1_active | dma2_active;

// FIX BOSS FINALE (2026-07-22): il vecchio gate `& ~dma_active` (ereditato BW)
// BUTTAVA le write CPU durante la copia live->buffer (~8200 clk dal vblank).
// MAME (buffer_spriteram_w = memcpy istantanea) non perde MAI una write. Con
// la CPU al ~70-75% di MAME le scene piene sforano il frame -> la build della
// lista nuova parte mentre la copia gira -> prime entry (boss) droppate =
// pezzi col frame vecchio = movimenti nervosi. Write-through sempre: la copia
// prende vecchio-o-nuovo per word (jitter +/-77us, MAME-legale). La protezione
// vera contro lo stiramento (copy solo a lista completa) e' il trigger latch
// spr_trig_pending, che resta.
wire spr1_we_lo_cpu = is_spr1 & cpu_wr & ~cpu_dsn[0];
wire spr1_we_hi_cpu = is_spr1 & cpu_wr & ~cpu_dsn[1];
wire spr2_we_lo_cpu = is_spr2 & cpu_wr & ~cpu_dsn[0];
wire spr2_we_hi_cpu = is_spr2 & cpu_wr & ~cpu_dsn[1];

// Savestate adaptor in serie sulla porta CPU sprite (ZERO BRAM aggiunta).
wire spr1_we_lo, spr1_we_hi, spr2_we_lo, spr2_we_hi;
wire [11:0] spr1_idx, spr2_idx;
wire [15:0] spr1_wdata_eff, spr2_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_SPR1)) spr1_ss (
	.clk(clk),
	.we_lo_in(spr1_we_lo_cpu), .we_hi_in(spr1_we_hi_cpu), .addr_in(spr_idx), .wdata_in(cpu_wdata),
	.we_lo_out(spr1_we_lo), .we_hi_out(spr1_we_hi), .addr_out(spr1_idx), .wdata_out(spr1_wdata_eff),
	.q_in(spr1_cpu_rd), .ssbus(ssb[SS_IDX_SPR1])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_SPR2)) spr2_ss (
	.clk(clk),
	.we_lo_in(spr2_we_lo_cpu), .we_hi_in(spr2_we_hi_cpu), .addr_in(spr_idx), .wdata_in(cpu_wdata),
	.we_lo_out(spr2_we_lo), .we_hi_out(spr2_we_hi), .addr_out(spr2_idx), .wdata_out(spr2_wdata_eff),
	.q_in(spr2_cpu_rd), .ssbus(ssb[SS_IDX_SPR2])
);

always @(posedge clk) if (spr1_we_lo) spr1_lo[spr1_idx] <= spr1_wdata_eff[ 7:0];
always @(posedge clk) if (spr1_we_hi) spr1_hi[spr1_idx] <= spr1_wdata_eff[15:8];
always @(posedge clk) if (spr2_we_lo) spr2_lo[spr2_idx] <= spr2_wdata_eff[ 7:0];
always @(posedge clk) if (spr2_we_hi) spr2_hi[spr2_idx] <= spr2_wdata_eff[15:8];

reg [7:0] spr1_rd_lo, spr1_rd_hi, spr2_rd_lo, spr2_rd_hi;
always @(posedge clk) spr1_rd_lo <= spr1_lo[spr1_idx];
always @(posedge clk) spr1_rd_hi <= spr1_hi[spr1_idx];
always @(posedge clk) spr2_rd_lo <= spr2_lo[spr2_idx];
always @(posedge clk) spr2_rd_hi <= spr2_hi[spr2_idx];
assign spr1_cpu_rd = {spr1_rd_hi, spr1_rd_lo};
assign spr2_cpu_rd = {spr2_rd_hi, spr2_rd_lo};

// Sprite renderer read port — legge dal BUFFER (= snapshot dopo DMA).
// boogwings_sprites.sram0_addr e' 10-bit (scandisce 1024 sprite); il buffer NS e'
// 4096 word, indicizzato con i 2 bit alti a 0 — il renderer (funzionante su HW)
// resta invariato. Quando servira' la scansione NS completa si adatta nel modulo.
wire [9:0]  spr_render_addr;
reg  [7:0]  spr1_rd_render_lo, spr1_rd_render_hi;
always @(posedge clk) spr1_rd_render_lo <= spr1_buf_lo[{2'b00, spr_render_addr}];
always @(posedge clk) spr1_rd_render_hi <= spr1_buf_hi[{2'b00, spr_render_addr}];
wire [15:0] spr_render_data = {spr1_rd_render_hi, spr1_rd_render_lo};

// Sprite chip1 (sprites2) renderer read port — buffer.
wire [9:0]  spr2_render_addr;
reg  [7:0]  spr2_rd_render_lo, spr2_rd_render_hi;
always @(posedge clk) spr2_rd_render_lo <= spr2_buf_lo[{2'b00, spr2_render_addr}];
always @(posedge clk) spr2_rd_render_hi <= spr2_buf_hi[{2'b00, spr2_render_addr}];
wire [15:0] spr2_render_data = {spr2_rd_render_hi, spr2_rd_render_lo};

// DMA controller: copy LIVE -> BUFFER al VBlank rise, entrambi i chip in sequenza.
reg [11:0] dma_wr_idx;
reg dma_wr_en;
reg dma_which;
reg vblank_in_d;
always @(posedge clk) vblank_in_d <= vblank_in;
wire vblank_rise = vblank_in & ~vblank_in_d;

// ── FIX STIRAMENTO 2026-07-19 (correla con rallentamenti CPU) ──
// MAME (deco32.cpp:842 buffer_spriteram_w): il copy live->buffer avviene SOLO quando
// la CPU scrive 0x174010/0x17c010 (= lista sprite COMPLETA). Il nostro DMA copiava a
// OGNI vblank ignorando il trigger CPU. In SLOWDOWN la CPU e' a meta' scrittura della
// lista al vblank -> copia PARZIALE (tile di un oggetto alto a Y miste vecchie/nuove)
// = STIRAMENTO verticale. Non e' timing (succede anche con slack positivo).
// Fix: latch del trigger CPU; il DMA a vblank scatta SOLO se la CPU ha triggerato dal
// vblank precedente. In slowdown (CPU non finisce -> non triggera) si SALTA il copy ->
// resta l'ultimo buffer COMPLETO (frame fermo, come il cabinato) -> niente parziale.
reg spr_trig_pending;
always @(posedge clk) begin
	if (reset) spr_trig_pending <= 1'b0;
	else begin
		if (cpu_wr & (is_sprdma1 | is_sprdma2)) spr_trig_pending <= 1'b1;
		else if (vblank_rise & ~paused_safe)    spr_trig_pending <= 1'b0;
	end
end

always @(posedge clk) begin
	if (reset) begin
		dma1_active <= 1'b0;
		dma2_active <= 1'b0;
		dma_rd_idx  <= 13'd0;
		dma_wr_idx  <= 12'd0;
		dma_wr_en   <= 1'b0;
		dma_which   <= 1'b0;
	end else if (misc_ss_wr) begin   // restore DMA sprite FSM (trasparente a SS spento)
		dma1_active <= misc_dma1_load;
		dma2_active <= misc_dma2_load;
		dma_rd_idx  <= misc_dma_rd_idx_load;
		dma_wr_idx  <= misc_dma_wr_idx_load;
		dma_which   <= misc_dma_which_load;
	end else if (vblank_rise & ~paused_safe & spr_trig_pending) begin
		// copy LIVE -> BUFFER a VBlank rise, SOLO se la CPU ha triggerato (0x174010/
		// 0x17c010 = lista completa, MAME buffer_spriteram_w). In slowdown senza
		// trigger si salta -> niente copia parziale = niente stiramento.
		dma1_active <= 1'b1;
		dma2_active <= 1'b1;
		dma_rd_idx  <= 13'd0;
		dma_wr_en   <= 1'b0;
		dma_which   <= 1'b0;
	end else if (dma_active) begin
		// FIX OFFSET-1 confermato matematicamente:
		//   - dma1_rd_lo_r in ck Y = spr1_lo[rd_idx_at_ck_(Y-1)]
		//   - write event a posedge Y+1 usa valori di ck Y.
		//   - Per scrivere buf[K]<=spr1_lo[K] serve: rd_idx_Y-1=K (perche' dma1_rd_lo_r_Y=spr1_lo[K])
		//     AND wr_idx_Y=K. Quindi wr_idx = rd_idx[K_prev] = K = (rd_idx_Y - 1 - 1)+1 = rd_idx_Y-1...
		//   - Equivalente: wr_idx setting "wr_idx <= rd_idx_current" da' wr_idx_(Y+1)=rd_idx_Y.
		//   - Per K: serve wr_idx in ck Y = K, dma1_rd_lo_r in ck Y = spr1_lo[K] (rd_idx_Y-1=K, rd_idx_Y=K+1).
		//   - wr_idx_Y = (assegnato a posedge Y) = (rd_idx in ck Y-1) = K (perche' rd_idx_Y-1 = K).
		//   - Quindi formula: wr_idx <= rd_idx[9:0]  (NO -1). Funziona per rd_idx 0..1023 (writes K=0..1023).
		// Loop fino a 1025: rd_idx 0,1,...,1024,1025. Write usa rd_idx 0..1023 -> wr_idx_Y registered 1..1024(=0 overflow ignorato).
		// FIX 2026-07-03: '>=' come per il DMA palette (stessa classe: il ferro
		// mostrava dma1/dma2 attivi insieme = FSM scavallata). Termina da
		// qualunque stato corrotto.
		if (dma_rd_idx >= 13'd4097 && dma_which == 1'b1) begin
			dma1_active <= 1'b0;
			dma2_active <= 1'b0;
			dma_wr_en   <= 1'b0;
		end else if (dma_rd_idx >= 13'd4097 && dma_which == 1'b0) begin
			dma_rd_idx  <= 13'd0;
			dma_which   <= 1'b1;
			dma_wr_en   <= 1'b0;
		end else begin
			dma_wr_en  <= (dma_rd_idx <= 13'd4095);
			dma_wr_idx <= dma_rd_idx[11:0];
			dma_rd_idx <= dma_rd_idx + 13'd1;
		end
	end else begin
		dma_wr_en <= 1'b0;
	end
end

// DMA read port: durante dma_active, la CPU readback NON e' usata, quindi spr_idx
// e' libera di puntare a dma_rd_idx per leggere il source RAM. Mux il bus.
// 1 ck latency: dato letto al ck successivo al cambio addr -> dma_wr_idx = dma_rd_idx-1.
wire [11:0] dma_rd_addr = dma_rd_idx[11:0];
reg [7:0] dma1_rd_lo_r, dma1_rd_hi_r, dma2_rd_lo_r, dma2_rd_hi_r;
always @(posedge clk) dma1_rd_lo_r <= spr1_lo[dma_rd_addr];
always @(posedge clk) dma1_rd_hi_r <= spr1_hi[dma_rd_addr];
always @(posedge clk) dma2_rd_lo_r <= spr2_lo[dma_rd_addr];
always @(posedge clk) dma2_rd_hi_r <= spr2_hi[dma_rd_addr];

// DMA write port: scrive nel buffer all'indice dma_wr_idx quando dma_wr_en
always @(posedge clk) if (dma_wr_en && dma_which == 1'b0) spr1_buf_lo[dma_wr_idx] <= dma1_rd_lo_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b0) spr1_buf_hi[dma_wr_idx] <= dma1_rd_hi_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b1) spr2_buf_lo[dma_wr_idx] <= dma2_rd_lo_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b1) spr2_buf_hi[dma_wr_idx] <= dma2_rd_hi_r;

// TODO: 2 istanze decospr renderer che leggono sprite_ram_buf1/2 + sprite ROM
// Riferimento Verilog: reference/jt/cop/hdl/jtcop_obj{,_buffer,_draw}.v

// =====================================================================
// DECO_ACE (palette + alpha blend mixer)
// =====================================================================
// Palette RAM 8KB = 4096 colori × 16-bit. Doppio buffer (buffered_palette16):
// CPU scrive in pal_cpu, DMA su 0x282008 copia in pal_buf usato dal mixer.
// ACE control register file: 0x3C0000-0x3C004F = 80 byte (40 word) di
// configurazione alpha/blend.
// Palette RAM 4096×16. pal_cpu (CPU rw + DMA read) → pal_buf (renderer read).
// 2 BRAM, 2 porte ognuna. DMA pipelinato a 2 stadi (BRAM lat 1).
// Palette RAM 4096×16. 8-bit lane split. CPU readback NON serve (write-only
// dal punto di vista di MAME boogwing: il chip è palette device, leggere è
// debug). DMA legge sempre, write CPU non collide.
// Init esplicito BRAM palette: senza init alcune M10K partono con garbage
// che il CPU non riesce mai a clearare se non scrive TUTTA la palette al boot.
// Pattern ActFancer "palette non inizializzata = monnezza" → fix preventivo.
// Palette DECO_ACE 24-bit RGB888 (MAME deco_ace.cpp):
//   m_paletteram[2048] è uint32: bits 23:16 = B byte, 15:8 = G byte, 7:0 = R byte.
//   CPU word16 access: offset even → uint32[31:16] (= 0x00BB), odd → uint32[15:0] (= 0xGGRR).
//   $284000-$285FFF (8KB) = 4096 word16 = 2048 entries.
// Il vecchio decoder (xBGR_444) era SBAGLIATO → colori storti per livello (ogni livello
// scrive byte diversi che venivano interpretati come nibble → palette wrong).
// no_rw_check: durante CPU write + DMA read concorrenti su pal_cpu_*, e durante
// DMA write + renderer read concorrenti su pal_buf, M10K mixed_port deve
// tornare valore vecchio (no glitch). Senza l'attributo Quartus infer NEW_DATA
// = output X transitorio = impurità flicker sui pixel renderizzati durante DMA.
// FIX DWORD (causa nero): NS scrive 1 DWORD32 {00,B,G,R} per entry a 0x168000+entry*4
// (verificato golden: 2048 dword, tutti accessi 32-bit). MAME deco_ace.cpp:131/177:
// m_paletteram[entry]=data; b=d[23:16] g=d[15:8] r=d[7:0]. Il vecchio modello word16
// (lo/hi 8-bit su 4096 + DMA che ricompone B+GR) era BoogieWings: prendeva solo
// arm_wdata[15:0] (B PERSO) a stride /2 -> palette nera/storta. Ora: pal_cpu = 1 entry
// 24-bit {B,G,R}, scritta diretta dal dword CPU.
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_cpu_ent [0:2047];
// pal_buf duplicato: pal_buf_top per lookup top_pal_idx, pal_buf_bot per bot_pal_idx.
// Permette 2 read paralleli senza conflitto port M10K (max 2 porte: 1 write DMA + 1 read).
// DMA scrive in entrambi in parallelo → contenuto identico, niente coerenza problema.
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_top [0:2047];   // {B,G,R} 8-bit
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_bot [0:2047];
// 3a copia per lo stage-2 alpha-tilemap NS (lookup parallelo at_idx_r)
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_at  [0:2047];
integer init_i;
initial begin
	for (init_i = 0; init_i < 2048; init_i = init_i + 1) begin
		pal_cpu_ent[init_i] = 24'd0;
		pal_buf_top[init_i] = 24'd0;
		pal_buf_bot[init_i] = 24'd0;
		pal_buf_at[init_i]  = 24'd0;
	end
end
wire [10:0] pal_idx = aa[12:2];   // DWORD entry index (÷4, 0..2047)

reg pal_dma_active;
reg        pal_dma_cmd_d;      // (is_paldma&cpu_wr) registrato, per edge-detect
wire       pal_dma_trig = (is_paldma & cpu_wr) & ~pal_dma_cmd_d;  // pulse 1 ck
reg [12:0] pal_dma_rd_idx;     // 0..4096 (legge 4096 word CPU = 2048 entries × 2)
reg [10:0] pal_dma_wr_idx;     // 0..2047 entry idx
reg        pal_dma_wr_en;
reg [7:0]  pal_dma_b_lat;      // byte B catturato da word even
reg [23:0] pal_dma_wr_data;    // dato da scrivere (latched 1 ck prima per matchare wr_en)

// CPU write: 1 DWORD per entry. byte-enable dword arm_be (B=be[2],G=be[1],R=be[0]).
// pal_wdata_full = arm_wdata[23:0] = {B,G,R}. (cpu_wdata e' 16-bit, qui serve il dword
// pieno -> uso arm_wdata direttamente.)
wire pal_we_cpu = is_pal & arm_req & arm_we;
// Savestate adaptor 32-bit sulla porta WRITE (entry dword). Durante SS write dirottata
// al ssbus; a SS idle trasparente. Read SS via pal_cpu_rd24 (porta DMA).
wire        pal_we;
wire [10:0] pal_idx_w;
wire [23:0] pal_wdata_eff;
wire        pal_ss_sel = ssb[SS_IDX_PAL_CPU].access(SS_IDX_PAL_CPU);
ss_ram_adaptor #(.WIDTH(24), .WIDTHAD(11), .SS_IDX(SS_IDX_PAL_CPU)) pal_ss (
	.clk(clk),
	.wren_in(pal_we_cpu), .addr_in(pal_idx), .wdata_in(arm_wdata[23:0]),
	.wren_out(pal_we), .addr_out(pal_idx_w), .wdata_out(pal_wdata_eff),
	.q_in(pal_cpu_rd24), .ssbus(ssb[SS_IDX_PAL_CPU])
);
always @(posedge clk) if (pal_we) pal_cpu_ent[pal_idx_w] <= pal_wdata_eff;

// CPU READBACK VERO (MAME buffered_palette_r) — copia dedicata: le 2 porte di
// pal_cpu_ent sono gia' occupate (write CPU/SS + read DMA). Il firmware alla
// transizione notte->giorno (fine liv.3) fa READ-modify-write per-entry sulla
// palette: senza readback vero leggeva {16'hFFFF, entry stantia del DMA} e
// riscriveva {FF, pal[0].G, pal[0].R} = 0xFF5200 piatto su tutte le righe
// del paesaggio = SFONDO BLU (provato al byte su ss3: 96 entry = 0xFF5200).
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_cpu_ent2 [0:2047];
initial begin
	for (init_i = 0; init_i < 2048; init_i = init_i + 1)
		pal_cpu_ent2[init_i] = 24'd0;
end
always @(posedge clk) if (pal_we) pal_cpu_ent2[pal_idx_w] <= pal_wdata_eff;
reg [23:0] pal_cpu_cpurd24;
always @(posedge clk) pal_cpu_cpurd24 <= pal_cpu_ent2[pal_idx];

// DMA read port (BRAM lat=1). DWORD per entry: legge pal_cpu_ent[entry] (24-bit {B,G,R}).
// Durante SS il read indirizza ssbus.addr (DMA fermo in pausa).
wire [10:0] pal_rd_idx = pal_ss_sel ? ssb[SS_IDX_PAL_CPU].addr[10:0] : pal_dma_rd_idx[10:0];
reg [23:0] pal_cpu_rd24;
always @(posedge clk) pal_cpu_rd24 <= pal_cpu_ent[pal_rd_idx];

// FSM DMA: copia 1:1 entry 0..2047 da pal_cpu_ent -> pal_buf (lat 1 ck). Niente piu'
// ricomposizione B+GR word16 (il dato e' gia' un dword {B,G,R} per entry).
reg pal_dma_rd_valid_d;  // c'era una read valida al ck precedente
always @(posedge clk) begin
	pal_dma_cmd_d <= is_paldma & cpu_wr;   // per edge-detect del trigger
	if (reset) begin
		pal_dma_active   <= 1'b0;
		pal_dma_rd_idx   <= 13'd0;
		pal_dma_wr_idx   <= 11'd0;
		pal_dma_wr_en    <= 1'b0;
		pal_dma_wr_data  <= 24'd0;
		pal_dma_rd_valid_d <= 1'b0;
		pal_dma_cmd_d    <= 1'b0;
	end else if (misc_ss_wr) begin   // restore palette DMA FSM (trasparente a SS spento)
		// FIX 2026-07-04: MAI ricaricare 'active/rd_idx' dal savestate — e' l'unico
		// percorso che inietta stato arbitrario nella FSM (il ferro mostrava
		// rd_idx=8168 attivo = DMA eterno = pal_buf distrutto = NERO). Il restore
		// ri-triggera comunque il DMA pulito via ss_restore_done: ricaricare una
		// copia "a meta'" non serve a niente ed e' solo un vettore di corruzione.
		pal_dma_active <= 1'b0;
		pal_dma_rd_idx <= 13'd0;
		pal_dma_wr_idx <= 11'd0;
	end else if (pal_dma_trig | ss_restore_done | (vblank_rise & ~pal_dma_active & ~pal_ss_sel & ~paused_safe)) begin
		// FIX sfondo BLU transizione notte->giorno (2026-07-22). La scena alba e'
		// l'UNICO punto che fa ~260 copie DMA in ~260 frame mentre la CPU riscrive
		// pal_cpu (fade software 0x13C4C, provato bit-exact golden==Amber): una
		// copia persa/corrotta li' resta PERMANENTE (il gioco non ri-triggera mai
		// piu' -> pal_buf congelata = campo blu; visto anche post-restore). Questa
		// FSM ha gia' un precedente di fragilita' su ferro (fix '>=' del 2026-07-03,
		// "DMA eterno rd_idx=8168"). RESYNC AUTOMATICO a ogni vblank: col protocollo
		// del gioco (upload -> flag bit15 -> trigger al vblank) e' EQUIVALENTE al
		// trigger, ma si auto-ripara al frame successivo da qualunque copia mancata
		// (restore incluso). Gated su ~active: mai riarmo a meta' copia.
		// BUG ce-paced: la CPU tiene (is_paldma & cpu_wr) alto ~13 ck per UN accesso.
		// A livello, il DMA si ri-armava (rd_idx<=0) ogni ck e NON avanzava finche'
		// cpu_wr non scendeva. FIX: trigger = pulse di 1 ck (rising edge), come MAME.
		pal_dma_active   <= 1'b1;
		pal_dma_rd_idx   <= 13'd0;
		pal_dma_wr_en    <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end else if (pal_dma_active) begin
		pal_dma_wr_en <= 1'b0;
		pal_dma_rd_valid_d <= (pal_dma_rd_idx < 13'd2048);
		// dato della read del ck precedente (rd_idx-1) pronto in pal_cpu_rd24
		if (pal_dma_rd_valid_d) begin
			pal_dma_wr_en   <= 1'b1;
			pal_dma_wr_data <= pal_cpu_rd24;                 // {B,G,R} dword
			pal_dma_wr_idx  <= pal_dma_rd_idx[10:0] - 11'd1; // entry servita
		end
		// FIX 2026-07-03 (PROVATO DAL FERRO, savestate 15:39: pal_dma_active=1,
		// rd_idx=8168, wr_idx incoerente): il check '==' secco puo' essere
		// scavalcato sul silicio -> DMA eterno con stato corrotto che inonda
		// pal_buf -> ogni lookup del mixer (backdrop incluso) = 0 -> NERO TOTALE
		// con macchina viva. '>=' termina da QUALUNQUE stato; il trigger
		// successivo del gioco rifa' la copia pulita.
		if (pal_dma_rd_idx >= 13'd2048) begin
			pal_dma_active <= 1'b0;
		end else begin
			pal_dma_rd_idx <= pal_dma_rd_idx + 13'd1;
		end
	end else begin
		pal_dma_wr_en <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end
end

// Pattern M10K saving: 1 always block per array, scritto separatamente.
always @(posedge clk) if (pal_dma_wr_en) pal_buf_top[pal_dma_wr_idx] <= pal_dma_wr_data;
always @(posedge clk) if (pal_dma_wr_en) pal_buf_bot[pal_dma_wr_idx] <= pal_dma_wr_data;
always @(posedge clk) if (pal_dma_wr_en) pal_buf_at [pal_dma_wr_idx] <= pal_dma_wr_data;

// ACE control register file (0x3C0000-0x3C004F = 40 word). MLAB inferito.
(* ramstyle = "MLAB" *) reg [15:0] ace_regs [0:63];
// FIX 2026-07-03 stride ACE: MAME umask32 (deco32.cpp:630) = 1 reg per DWORD ->
// idx = aa[7:2]. Il vecchio cpu_addr[6:1] (stride word + wrap 6-bit) rendeva i
// reg fade/alpha letti dal mixer (0x1f/0x21/0x23/0x25) irraggiungibili dalla CPU.
wire [5:0] ace_idx = cpu_addr[7:2];
// Init a 0 (power-up deterministico anche in sim; fade/alpha neutri al reset).
integer ace_i;
initial for (ace_i = 0; ace_i < 64; ace_i = ace_i + 1) ace_regs[ace_i] = 16'd0;

// Savestate adaptor su ace_regs (blend/alpha/fade). Byte-split lo/hi via dsn, come la palette.
// Durante SS (gioco in pausa) la porta write e' dirottata al ssbus; a SS idle: trasparente.
wire        ace_we_lo_cpu = is_ace & cpu_wr & ~cpu_dsn[0];
wire        ace_we_hi_cpu = is_ace & cpu_wr & ~cpu_dsn[1];
wire        ace_we_lo, ace_we_hi;
wire [5:0]  ace_idx_w;
wire [15:0] ace_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(6), .SS_IDX(SS_IDX_ACE)) ace_ss (
	.clk(clk),
	.we_lo_in(ace_we_lo_cpu), .we_hi_in(ace_we_hi_cpu), .addr_in(ace_idx), .wdata_in(cpu_wdata),
	.we_lo_out(ace_we_lo), .we_hi_out(ace_we_hi), .addr_out(ace_idx_w), .wdata_out(ace_wdata_eff),
	.q_in(ace_ss_q), .ssbus(ssb[SS_IDX_ACE])
);
// FIX chunk ACE letto shiftato +1 (strumento bugiardo, documentato): q_in era
// ace_cpu_rd = doppio-registrato (idx mux + ace_cpu_rd_r) = latenza 2 vs
// read_delay 1 dell'adaptor -> chunk[k] = reg[k-1]. Lettura COMBINATORIA
// dedicata allo scan (regfile MLAB/LUT, zero BRAM): latenza 0, dato giusto.
wire [15:0] ace_ss_q = ace_regs[ssb[SS_IDX_ACE].addr[5:0]];
// FIX fade blu liv.3 (2026-07-22, dati ss3/ss4): sul ferro OGNI write ace_regs
// atterrava al registro +1 (anche le STR semplici: mode 0x1100 trovato a 0x27)
// mentre palette/colorbank sulla stessa aa atterrano giuste -> difetto LOCALE
// alla porta write di questa MLAB, scritta ogni clk direttamente dal cono
// combinatorio lungo di aa (ace_idx dentro path violati in STA, fanout ~186).
// Porta REGISTRATA: we/idx/data campionati in FF, MLAB scritta dal registro un
// clk dopo (finestra write = decine di clk, latenza invisibile; copre anche il
// path savestate del ss_ram16_adaptor). Sim bit-exact: stesso idx/dato, +1 clk.
reg        ace_we_lo_r, ace_we_hi_r;
reg [5:0]  ace_idx_wr;
reg [15:0] ace_wdata_r;
always @(posedge clk) begin
	ace_we_lo_r <= ace_we_lo;
	ace_we_hi_r <= ace_we_hi;
	ace_idx_wr  <= ace_idx_w;
	ace_wdata_r <= ace_wdata_eff;
	if (ace_we_lo_r) ace_regs[ace_idx_wr][7:0]  <= ace_wdata_r[7:0];
	if (ace_we_hi_r) ace_regs[ace_idx_wr][15:8] <= ace_wdata_r[15:8];
end
reg [15:0] ace_cpu_rd_r;
// La read SS usa la porta di lettura: durante SS il renderer e' fermo, l'idx e' dirottato.
wire [5:0] ace_rd_idx = ssb[SS_IDX_ACE].access(SS_IDX_ACE) ? ssb[SS_IDX_ACE].addr[5:0] : ace_idx;
always @(posedge clk) ace_cpu_rd_r <= ace_regs[ace_rd_idx];
assign ace_cpu_rd = ace_cpu_rd_r;

// Pixel mixer alpha-blend DECO_ACE implementato sotto (~riga 1100+).

// =====================================================================
// DECO104PROT (I/O + protection MCU simulato)
// =====================================================================
// TODO: deco104 protection device
//   - Port A: INPUTS (p1+p2)
//   - Port B: SYSTEM (coin+start)
//   - Port C: DSW
//   - soundlatch_irq_cb → H6280 IRQ0
//   - interface_scramble_reverse + magic_read_address_xor
// Riferimento Verilog: reference/jt/cop/hdl/jtcop_prot.v (deco104 simile)

// =====================================================================
// YM2151 @ 3.58 MHz (32.22/9)
// =====================================================================
// TODO: jt51 istanza (rtl/jt51/jt51.v)
//   - IRQ → H6280 IRQ2
//   - port_write → sound bankswitch
//   - mix 32% nel master volume

// =====================================================================
// OKIM6295 × 2
// =====================================================================
// TODO: 2 istanze jt6295 (rtl/jt6295/jt6295.v)
//   - OKI1 @ 1.007 MHz (32.22/32) PIN7_HIGH → mix 56%
//   - OKI2 @ 2.014 MHz (32.22/16) PIN7_HIGH → mix 12%
//   - Sample ROM da DDRAM (port read audio)

// =====================================================================
// VIDEO MIXER — 4 tile layer, sprite TODO
// =====================================================================
// Priority semplice: primo layer opaque vince. Vero priorità BoogieWings ha
// priority_w (0x220000) che determina ordine layer. Per ora ordine fisso:
//   sprite > deco16_1 pf1 > deco16_1 pf2 > deco16_0 pf1 > deco16_0 pf2 > bg
// (sprite non implementato → salta direttamente ai tile)
//
// Palette index base (boogwing.cpp:gfx_boogwing entries):
//   tiles1 (text 8×8)   = palette base 0x800
//   tiles2 (deco16_0)   = palette base 0x100
//   tiles3 (deco16_1)   = palette base 0x300
//
// Per ora pf1/pf2 di ogni chip usano stessa base (l'col_bank è applicato esterno):
//   deco16_0 pf*: base 0x100
//   deco16_1 pf*: base 0x300 / 0x300+16*16 per col_bank=16 (pf2)
//
// pen 4-bit + colour 4-bit (top) → 8-bit index nella palette banca

// Priority mixer: priority encoder + 8-bit pen index registrati.
// Layer base palette: deco16_0 = 0x100, deco16_1 pf1 = 0x300, pf2 = 0x400.
// Palette index per layer (MAME gfx_boogwing boogwing.cpp:671):
//   tiles1 (text)  → base 0x800, 16 set × 16 col (4bpp)
//   tiles2 (BG1)   → base 0x100, 16 set × 32 col (5bpp → ora 4bpp,
//                                upper half vuota finché plane 4 non impl)
//   tiles3 (BG2)   → base 0x300, 32 set × 16 col (4bpp)
// Formula: pal_idx = base + (set * Ncol) + pix
//   tiles1: pal_idx = 0x800 + col * 16 + pix
//   tiles2: pal_idx = 0x100 + col * 32 + pix
//   tiles3: pal_idx = 0x300 + col * 16 + pix
// Priority: top → bottom (default MAME boogwing.cpp:467-472 else case):
//   1. text       (chip0 pf1, palette 0x800)         ← TOP
//   2. BG1        (chip0 pf2, palette 0x100, tiles2)
//   3. BG2 alpha  (chip1 pf1, palette 0x300, tiles3)
//   4. BG2 base   (chip1 pf2, palette 0x300+16, tiles3, col_bank=16)
//   5. background pen 0
//
// La logica MAME ha 5 modi diversi via priority_reg[2:0] (vedi screen_update);
// per ora implemento solo l'ordine default. priority_reg salvato ma non usato.
// (col_bank di chip1 pf2 è già dentro d16_1_pf2_col → non sommato qui)
// Palette base per layer — MAME GFXDECODE (boogwing.cpp:672-674):
//   MAME gfx_nslasher (deco32.cpp:1870): text(tiles1 charlayout)=0x800,
//   BG1(tiles1 tilelayout)=0x000, BG2/3(tiles2 tilelayout)=0x000. I vecchi
//   0x100/0x300 erano BoogieWings (mai adattati a NS): la CPU scrive le palette
//   in 0x000-0x1FF (provato golden: 250 entry @0x000, 232 @0x100, 0 @0x300/0x800)
//   -> con base 0x300 BG2/3 leggevano palette VUOTA = nero. Base NS = 0x000 + color
//   bank runtime (0x164000) sommato sopra, come MAME deco16_tilemap_colour_bank.
wire [11:0] pal_bg0_base = 12'h800;   // text (resta 0x800)
wire [11:0] pal_bg1_base = 12'h000;   // BG1  (MAME tiles1 tilelayout base 0)
wire [11:0] pal_bg2_base = 12'h000;   // BG2  (MAME tiles2 tilelayout base 0)
wire [11:0] pal_bg3_base = 12'h000;   // BG3

// =====================================================================
// Layer mixer con priority register MAME-compliant (5 modi).
// Riferimento: boogwing.cpp:417-477 screen_update.
// =====================================================================
//
// Componenti pixel:
//   text  = chip0.pf1 (sempre TOP, drawn dopo mix sprite)
//   bg1   = chip0.pf2
//   bg2a  = chip1.pf1 (BG2 alpha)
//   bg2b  = chip1.pf2 (BG2 base)
//   bg2c  = combine 8bpp di chip1 (pf1 nibble basso + pf2 nibble alto)
//
// Modi priority[2:0]:
//   0/6/7 (default): bg2b (BOT) | bg2a (mid) | bg1 (top)        | text
//   1, 2           : bg2b (BOT) | bg1 (mid)  | bg2a (top)       | text
//   3              : come 1/2 (alpha shadow non implementato)  | text
//   4              : bg2c (BOT, combine)     | bg1 (top)        | text
//   5              : bg1  (BOT)              | bg2c (top combine)| text

// NS priority comes from ns_pri_reg (0x150000 bits[2:0]), NOT the BW priority_reg
// (0x220000, unused on NS). bit0=layer priority, bit1=BG2/3 8bpp joint, bit2=fade.
// FIX 2026-07-03 (MAME deco32.cpp:1152 + deco32_v.cpp:492): i modi sono BIT,
// non valori: bit0=ordine layer, bit1=BG2/3 joint 8bpp, bit2=fade. Il vecchio
// decode (pri==4||pri==5) teneva il mixer in combine-mode con pri=4 runtime,
// dove MAME (m_pri&2=0) disegna i layer SEPARATI.


// Combine BG2 (per modi 4/5). chip1 e' 4bpp: prendo solo [3:0] di pf2_pix.
wire [3:0]  bg2c_pen_hi = d16_1_pf2_opq ? d16_1_pf2_pix[3:0] : 4'd0;
wire        bg2c_opq    = d16_1_pf1_opq | d16_1_pf2_opq;
// FIX 2026-07-03 COLOR BANK (MAME deco32.cpp:2326 pf2_col_bank=0x10 statico su
// chip0; deco32_v.cpp:56-59 cbank runtime <<4 colori = <<8 entry su chip1):
// il fix di giugno "basi a 0x000" era incompleto — i BG indicizzano a
// +0x100/+0x200/+0x300 entry. Bank sommati QUI nel mixer (12 bit), le porte
// dyn del chip restano legate (il campo raw 3-bit nel chip sommava +2/+3
// colori: sbagliato).
wire [11:0] bg2a_bank = {1'b0, tg1_pf1_cbank_field, 8'd0};   // (cbank&7)<<8 entry
wire [11:0] bg2b_bank = {1'b0, tg1_pf2_cbank_field, 8'd0};   // ((cbank>>3)&7)<<8 entry
wire [11:0] bg2c_pal_pre = pal_bg2_base + bg2a_bank + {3'd0, d16_1_pf1_col, d16_1_pf1_pix};
wire [11:0] bg2c_pal_idx = {bg2c_pal_pre[11:8], bg2c_pal_pre[7:4] | bg2c_pen_hi, bg2c_pal_pre[3:0]};

// Pal_idx singoli (per modi separati)
// BG1 (chip0.pf2): bank statico MAME 0x10 (=+0x100 entry) + stride 4bpp col*16
// (il vecchio col<<5 era eredita' 5bpp BoogieWings).
wire [11:0] bg1_pal_idx  = pal_bg1_base + 12'h100 + {3'd0, d16_0_pf2_col, d16_0_pf2_pix[3:0]};
wire [11:0] bg2a_pal_idx = pal_bg2_base + bg2a_bank + {3'd0, d16_1_pf1_col, d16_1_pf1_pix};
// chip1.pf2 e' 4bpp (pen[3:0]). pf2_pix arriva 5-bit ma bit 4 sempre 0.
// MAME formula: pal_idx = base + bank + col_5b * 16 + pen[3:0].
wire [11:0] bg2b_pal_idx = pal_bg3_base + bg2b_bank + {3'd0, d16_1_pf2_col, d16_1_pf2_pix[3:0]};
wire [11:0] text_pal_idx = pal_bg0_base + {3'd0, d16_0_pf1_col, d16_0_pf1_pix};

// Forward decl per ModelSim 10.5b (Quartus accetta inline forward use).
// Definizione effettiva dei segnali sotto vicino a u_sprites.
wire [12:0] sprite_pxl;   // chip0 5bpp: {color[7:0], pen[4:0]}
wire [11:0] sprite2_pxl;  // chip1 4bpp: {color[7:0], pen[3:0]}

// NS sprite palette (mix_nslasher, ns_video.cpp:346/395):
//   chip0 (5bpp, gfx0): col0 = (color[4:0] % 16) * granularity(32); base = colorbase
//     = sprite1_color_bank_w (data&7)<<8. pal_idx = base + coloffs + col0 + pen[4:0].
//   coloffs = ((m_pri & 4)==0) ? 0x800 : 0  (NS, vs BW (priority&8)).
// NS chip0 is 5bpp: pen[4:0], color in [12:5].
wire [4:0]  spr_pen   = sprite_pxl[4:0];
wire [7:0]  spr_color = sprite_pxl[12:5];
wire chip0_visible = (osd_spr_chip_filter == 2'b00) || (osd_spr_chip_filter == 2'b01);
wire chip1_visible = (osd_spr_chip_filter == 2'b00) || (osd_spr_chip_filter == 2'b10);
wire        spr_opq   = (spr_pen != 5'd0);
wire [11:0] ns_coloffs = (ns_pri_reg[2] == 1'b0) ? 12'h800 : 12'h000;
// chip0: colorbase = spr1_colorbase_sel<<8; col0 = color[3:0]*32 (16 banks * 32).
wire [11:0] spr_pal_idx = {1'd0, spr1_colorbase_sel, 8'd0} + ns_coloffs
                        + {3'd0, spr_color[3:0], 5'd0} + {7'd0, spr_pen};

// chip1 (4bpp, gfx1): col1 = (color[3:0] % 16) * granularity(16); base = colorbase
//   = sprite2_color_bank_w (data&7)<<8. pal_idx = base + coloffs + col1 + pen[3:0].
wire [3:0]  spr2_pen   = sprite2_pxl[3:0];
wire [7:0]  spr2_color = sprite2_pxl[11:4];
wire        spr2_opq   = (spr2_pen != 4'd0);

// ============================================================
// NS MIX — FEDELE a mix_nslasher (reference/ns_video.cpp:322-462) +
// screen_update_nslasher (:464-522). Sostituisce lo schema BOOGWING
// (spri 2/8/32, bg_pri 8/32, mode3-shadow) rimasto dal fork: era la
// causa di ombre/effetti ACE sbagliati (priorita' sprite non dinamiche
// e tabella alpha sbagliata).
// ============================================================
// get_alpha (deco_ace.cpp): regval>0x20 -> 0x80; else clamp(255 - reg<<3).
function [7:0] ace_alpha_of(input [7:0] regval);
	reg [10:0] sh, sub;
	begin
		sh  = {3'd0, regval} << 3;
		sub = 11'd255 - sh;
		ace_alpha_of = (regval > 8'h20) ? 8'h80
		             : (sub[10] ? 8'd0 : sub[7:0]);
	end
endfunction

// Attributi sprite (bit del temp-word MAME priColAlphaPal0/1):
wire [1:0] ns_pri0   = {spr_color[6],  spr_color[5]};   // (s0 & 0x6000) >> 13
wire [1:0] ns_pri1   = {spr2_color[6], spr2_color[5]};  // (s1 & 0x6000) >> 13
wire       ns_alpha1 = spr2_color[7];                   // s1 & 0x8000
wire       ns_alpha2 = ~spr2_color[4];                  // !(s1 & 0x1000)

// alphaTilemap enable (screen_update :466-470): ace[0x17]!=0 && (m_pri & 3)
wire ns_at_en = (ace_regs[6'h17][7:0] != 8'd0) && (ns_pri_reg[1:0] != 2'd0);

// Pixel sprite non-zero (s & 0xff) con gli enable OSD:
wire s0_nz = layer_spr_en && chip0_visible && spr_opq;
wire s1_nz = layer_spr_en && chip1_visible && spr2_opq;

// Composite tilemap + priority bitmap NS (screen_update :50-63):
//   m_pri&2: combined 8bpp (primask 1) sotto, BG1 (primask 4) sopra.
//   else:    FG1 (primask 1) sotto;
//     m_pri&1: BG1 (2), FG0 (4 -> alpha bitmap se ns_at_en, NIENTE priority)
//     else:    FG0 (2), BG1 (4 -> alpha bitmap se ns_at_en)
// BACKDROP = pen 0x300 (deco32_v.cpp:476). ns_tm_pri = tilemapPri MAME (4/2/1/0).
localparam [11:0] PAL_BACKDROP = 12'h300;
reg [2:0]  ns_tm_pri;
reg [11:0] tmap_pal_idx;
reg [7:0]  ns_at_p;        // pixel layer alpha {col[3:0],pen[3:0]} (0 = nulla)
reg [11:0] ns_at_idx;      // pal idx del layer alpha
always @(*) begin
	ns_at_p      = 8'd0;
	ns_at_idx    = PAL_BACKDROP;
	ns_tm_pri    = 3'd0;
	tmap_pal_idx = PAL_BACKDROP;
	if (ns_pri_reg[1]) begin
		if      (layer_bg1_en && d16_0_pf2_opq)           begin tmap_pal_idx = bg1_pal_idx;  ns_tm_pri = 3'd4; end
		else if ((layer_fg0_en|layer_fg1_en) && bg2c_opq) begin tmap_pal_idx = bg2c_pal_idx; ns_tm_pri = 3'd1; end
	end else if (ns_pri_reg[0]) begin
		if (ns_at_en && layer_fg0_en) begin
			ns_at_p   = {d16_1_pf1_col[3:0], d16_1_pf1_pix[3:0]};
			ns_at_idx = bg2a_pal_idx;
		end
		if      (!ns_at_en && layer_fg0_en && d16_1_pf1_opq) begin tmap_pal_idx = bg2a_pal_idx; ns_tm_pri = 3'd4; end
		else if (layer_bg1_en && d16_0_pf2_opq)              begin tmap_pal_idx = bg1_pal_idx;  ns_tm_pri = 3'd2; end
		else if (layer_fg1_en && d16_1_pf2_opq)              begin tmap_pal_idx = bg2b_pal_idx; ns_tm_pri = 3'd1; end
	end else begin
		if (ns_at_en && layer_bg1_en) begin
			ns_at_p   = {d16_0_pf2_col[3:0], d16_0_pf2_pix[3:0]};
			ns_at_idx = bg1_pal_idx;
		end
		if      (!ns_at_en && layer_bg1_en && d16_0_pf2_opq) begin tmap_pal_idx = bg1_pal_idx;  ns_tm_pri = 3'd4; end
		else if (layer_fg0_en && d16_1_pf1_opq)              begin tmap_pal_idx = bg2a_pal_idx; ns_tm_pri = 3'd2; end
		else if (layer_fg1_en && d16_1_pf2_opq)              begin tmap_pal_idx = bg2b_pal_idx; ns_tm_pri = 3'd1; end
	end
end

// --- Sprite0 (chip0): regole pri0 vs tilemapPri (mix :354-385) ---
wire s0_draw = s0_nz && (
      (ns_pri0 == 2'd0) || (ns_pri0 == 2'd1)
   || ((ns_pri0 == 2'd2) && (ns_at_en || (ns_tm_pri < 3'd4)))
   || ((ns_pri0 == 2'd3) && (ns_tm_pri < 3'd2)) );

// --- Sprite1 (chip1): alpha NS (object table 0x00-0x05, mix :390) ---
wire [5:0] ns_aidx = spr2_color[3] ? (6'd4 + {5'd0, spr2_color[1]})
                                   : {4'd0, spr2_color[2:1]};
wire [7:0] ns_s1_alpha = ((~ns_alpha1) | ns_alpha2)
                       ? ace_alpha_of(ace_regs[ns_aidx][7:0]) : 8'hff;

// --- Sprite1: regole di draw (mix :397-441, fedeli TODO inclusi) ---
reg s1_draw_c;
always @(*) begin
	s1_draw_c = 1'b0;
	if (s1_nz) begin
		if (ns_alpha1) begin
			case (ns_pri1)
				2'd0: s1_draw_c = ((!s0_nz) || (ns_pri0 == 2'd3))
				               && ((!ns_pri_reg[0]) || (ns_tm_pri < 3'd4)
				                   || (ns_at_en && (ns_at_p[3:0] == 4'd0)));
				2'd1: s1_draw_c = ((!ns_pri_reg[0]) || (ns_tm_pri < 3'd4))
				               && ((!s0_nz) || ((ns_pri0 != 2'd0) && (ns_pri0 != 2'd1)
				                   && ((!ns_pri_reg[0]) || (ns_pri0 != 2'd2))));
				default: s1_draw_c = 1'b1;
			endcase
		end else begin
			case (ns_pri1)
				2'd0: s1_draw_c = (!s0_nz) || (ns_pri0 != 2'd0);
				default: s1_draw_c = 1'b1;
			endcase
		end
	end
end
wire s1_draw = s1_draw_c;

// coloffs del ramo sprite1 e alpha-tilemap (mix :387): 0x800 SOLO se (m_pri&4)==0
// E sprite0 ha disegnato (il nome MAME 'sprite1_drawn' = s0 drew, fuorviante).
wire [11:0] ns_coloffs_s1   = ((~ns_pri_reg[2]) && s0_draw) ? 12'h800 : 12'd0;
wire [11:0] spr2_pal_idx_ns = {1'd0, spr2_colorbase_sel, 8'd0} + ns_coloffs_s1
                            + {4'd0, spr2_color[3:0], 4'd0} + {8'd0, spr2_pen};

// --- Alpha tilemap stage (mix :443-459): blend del layer alpha SOPRA il resto ---
wire at_gate_s0 = (!s0_nz) || (ns_pri0 == 2'd2) || (ns_pri0 == 2'd3);
wire at_gate_s1 = (!s1_nz) || (ns_pri1 == 2'd2) || (ns_pri1 == 2'd3) || ns_alpha1;
wire ns_at_hit  = ns_at_en && (ns_at_p[3:0] != 4'd0) && at_gate_s0 && at_gate_s1;
wire [7:0]  ns_at_alpha = ace_alpha_of(ace_regs[6'h17 + {3'd0, ns_at_p[7:5]}][7:0]);
wire [11:0] ns_at_idx_f = ns_at_idx + ns_coloffs_s1;

// (Blocco alpha BOOGWING rimosso 2026-07-10: tabella 0x10-0x1b e pix2_* non
// sono di NS — l'alpha NS e' ns_s1_alpha qui sopra, object table 0x00-0x05.)

// ============================================================
// Pipeline NS a 3 sorgenti (mix_nslasher): TEXT sempre sopra |
// sprite1 (blend NS) | sprite0 | composite tilemap — piu' lo
// stage-2 alpha-tilemap (at_*). sub_blend non esiste nel mix NS:
// resta a 0 (il blender a valle lo ignora).
// ============================================================
reg [11:0] top_pal_idx_r;
reg [11:0] bot_pal_idx_r;
reg        blend_en_r;
reg        sub_blend_r;
reg [7:0]  pixel_alpha_r;
reg [11:0] at_idx_r;
reg        at_en_r;
reg [7:0]  at_alpha_r;
always @(posedge clk) begin
	blend_en_r    <= 1'b0;
	sub_blend_r   <= 1'b0;
	bot_pal_idx_r <= PAL_BACKDROP;
	pixel_alpha_r <= ns_s1_alpha;
	at_en_r       <= 1'b0;
	at_idx_r      <= ns_at_idx_f;
	at_alpha_r    <= ns_at_alpha;
	if (layer_bg0_en && d16_0_pf1_opq) begin
		// TEXT: MAME lo disegna ULTIMO, sopra tutto (screen_update :65)
		top_pal_idx_r <= text_pal_idx;
	end else begin
		at_en_r <= ns_at_hit;
		if (s1_draw) begin
			// sprite1 sopra (blend se alpha<255): sotto c'e' sprite0 se
			// disegnato, altrimenti il composite tilemap (mix :415/:433)
			top_pal_idx_r <= spr2_pal_idx_ns;
			blend_en_r    <= (ns_s1_alpha != 8'hff);
			bot_pal_idx_r <= s0_draw ? spr_pal_idx : tmap_pal_idx;
		end else if (s0_draw) begin
			top_pal_idx_r <= spr_pal_idx;
		end else begin
			top_pal_idx_r <= tmap_pal_idx;
		end
	end
end

// DECO_ACE RGB888 lookup. pal_buf duplicato in 2 M10K (top + bot) per consentire
// 2 read paralleli senza conflitto port. DMA scrive in entrambi.
reg [23:0] top_color_raw;   // {B,G,R}
reg [23:0] bot_color_raw;
always @(posedge clk) top_color_raw <= pal_buf_top[top_pal_idx_r[10:0]];
always @(posedge clk) bot_color_raw <= pal_buf_bot[bot_pal_idx_r[10:0]];
// Stage-2 alpha-tilemap: 3o lookup parallelo + pipeline dei controlli (1 ck,
// allineato a top/bot_color_raw).
reg [23:0] at_color_raw;
reg        at_en_d;
reg [7:0]  at_alpha_d;
reg        at_raw_d;
always @(posedge clk) at_color_raw <= pal_buf_at[at_idx_r[10:0]];
always @(posedge clk) at_en_d      <= at_en_r;
always @(posedge clk) at_alpha_d   <= at_alpha_r;
always @(posedge clk) at_raw_d     <= at_idx_r[11];

// === DECO_ACE FADE (deco_ace.cpp:165-199) — ESATTO, identico a MAME bit-per-bit.
//   mult (0x1100): c = clamp(0,255, c + ((fadept - c) * fadeps) / 255)
//   add  (0x1000): c = min(c + fadeps, 255)
// /255 esatto = (|prod| * 32897) >> 23 (0 mismatch su tutto il range, verificato). Niente
// approssimazione >>8. Il menu scelta player (fine gioco) scrive $3C0040 (ace_regs 0x20-0x26).
// Gioco azzera il fade in init (0x76D6) -> con fadeps=0 il fade non altera nulla.
wire [7:0]  fade_pt_r = ace_regs[6'h20][7:0];
wire [7:0]  fade_pt_g = ace_regs[6'h21][7:0];
wire [7:0]  fade_pt_b = ace_regs[6'h22][7:0];
wire [7:0]  fade_st_r = ace_regs[6'h23][7:0];
wire [7:0]  fade_st_g = ace_regs[6'h24][7:0];
wire [7:0]  fade_st_b = ace_regs[6'h25][7:0];
wire [15:0] fade_mode = ace_regs[6'h26];
wire        fade_active = (fade_st_r | fade_st_g | fade_st_b) != 8'd0;
wire        fade_add    = (fade_mode == 16'h1000);   // additive; altrimenti multiplicative

function [7:0] fade8(input [7:0] c, input [7:0] pt, input [7:0] st, input add);
	reg signed [16:0] prod;       // (pt-c)*st, signed, range [-65025, 65025]
	reg        [15:0] mag;        // |prod|
	reg        [31:0] qmul;       // mag * 32897
	reg signed [9:0]  q;          // quoziente con segno (trunc verso zero)
	reg signed [9:0]  res;
	reg        [9:0]  asum;
	begin
		if (add) begin
			asum  = {2'd0, c} + {2'd0, st};
			fade8 = asum[9:8] != 2'd0 ? 8'hFF : asum[7:0];
		end else begin
			prod = ($signed({1'b0, pt}) - $signed({1'b0, c})) * $signed({1'b0, st});
			mag  = prod[16] ? (~prod[15:0] + 16'd1) : prod[15:0];   // |prod|
			qmul = mag * 32'd32897;
			q    = prod[16] ? -$signed({1'b0, qmul[31:23]}) : $signed({1'b0, qmul[31:23]});
			res  = $signed({2'b0, c}) + q;
			fade8 = res[9] ? 8'd0 : (res > 10'sd255 ? 8'hFF : res[7:0]);
		end
	end
endfunction

// Fade COMBINATORIO (0 stage extra): top_color/bot_color restano allo stesso stage del lookup
// pal_buf -> NON aggiunge ritardo pipeline -> NESSUNO shift dei layer. (La versione registrata
// aggiungeva +1 stage non compensato dal timing video -> shiftava BG1/FG0/FG1 di 1 pixel.)
//
// Palette RAW vs FADED (deco_ace.cpp:175-198): la palette deco_ace ha 4096 pen:
//   0x000-0x7FF = palette CON fade (set_pen_color(i)).
//   0x800-0xFFF = stesse entry RAW, SENZA fade (set_pen_color(i+2048)).
// MAME indicizza con paldata[pal_idx]: se pal_idx >= 0x800 -> RAW (no fade). Il TEXT (chip0 pf1,
// GFXDECODE base 0x800) usa SEMPRE le raw -> il testo non e' MAI fadato. Gli sprite/BG (base <0x800)
// vanno raw solo col calculated_coloffs (priority bit3 -> +0x800, boogwing.cpp:355).
// Nel core: pal_buf e' una sola copia [0:2047]; il lookup tronca [10:0] (= indice raw corretto).
// Il bit 11 dell'indice (0x800) marca "raw" = bypass del fade, PER-PIXEL su top e bot separati
// (come MAME: l'offset 0x800 e' per-sorgente, NON globale). Senza questo il testo (idx >=0x800)
// veniva fadato -> annerito/confuso con lo sfondo -> yes/no invisibile.
wire top_is_raw = top_pal_idx_r[11] | priority_reg[3];
wire bot_is_raw = bot_pal_idx_r[11] | priority_reg[3];
reg [23:0] top_color, bot_color;
always @(*) begin
	if (fade_active && !top_is_raw) begin
		top_color = {fade8(top_color_raw[23:16], fade_pt_b, fade_st_b, fade_add),
		             fade8(top_color_raw[15:8],  fade_pt_g, fade_st_g, fade_add),
		             fade8(top_color_raw[7:0],   fade_pt_r, fade_st_r, fade_add)};
	end else begin
		top_color = top_color_raw;
	end
	if (fade_active && !bot_is_raw) begin
		bot_color = {fade8(bot_color_raw[23:16], fade_pt_b, fade_st_b, fade_add),
		             fade8(bot_color_raw[15:8],  fade_pt_g, fade_st_g, fade_add),
		             fade8(bot_color_raw[7:0],   fade_pt_r, fade_st_r, fade_add)};
	end else begin
		bot_color = bot_color_raw;
	end
end

// Blend stage: dst = src*alpha + dst*(255-alpha) (per canale, /256).
// blend_en_r ritardato 1 ck per allinearsi al lookup pal_buf (il fade ora e' combinatorio,
// non aggiunge stage -> 1 ck come prima del fade).
reg        blend_en_d;
reg        sub_blend_d;
reg [7:0]  alpha_d;
always @(posedge clk) blend_en_d  <= blend_en_r;
always @(posedge clk) sub_blend_d <= sub_blend_r;
always @(posedge clk) alpha_d     <= pixel_alpha_r;

// MAME alpha_blend_r32 convention: result = (src * alpha + dst * (256 - alpha)) >> 8.
// Quando alpha=255: result = (src*255 + dst*1) / 256 ≈ src (quasi opaque).
// Quando alpha=0:   result = dst (fully transparent → strato sotto).
// a_inv è 9-bit per gestire 256 (alpha=0 → a_inv=256, src=0, dst*256 >> 8 = dst).
function [7:0] blend8(input [7:0] src, input [7:0] dst, input [7:0] a);
	reg [16:0] s, d, sum;
	reg [8:0]  a_inv;
	begin
		a_inv = 9'd256 - {1'b0, a};
		s = src * a;
		d = dst * a_inv;
		sum = s + d;
		blend8 = sum[15:8];
	end
endfunction

// MAME sub_blend_r32 (boogwing.cpp:180-188): INVERTE la source (s ^= 0xffffff), poi
// blend tra src_invertita e dst con shift >>9:
//   result = (inv_src * level + dst * (256 - level)) >> 9    (level = alpha)
// Output SEMPRE in range, mai sotto zero (la sottrazione pura clampava a NERO -> macchie
// nere sul fumo/ombra dove src chiaro). Questa replica MAME 1:1.
function [7:0] sub_blend8(input [7:0] src, input [7:0] dst, input [7:0] a);
	reg [7:0]  inv;
	reg [16:0] s, d, sum;
	begin
		inv = 8'hff - src;                      // source invertita
		s   = inv * a;                          // src_inv * level
		d   = dst * (9'd256 - {1'b0, a});       // dst * (256 - level)
		sum = s + d;
		sub_blend8 = sum[16:9];                 // >> 9
	end
endfunction

// dst = top_color (= BG sotto), src = bot_color (= ombra layer sopra) — wait,
// re-check: in mio "top_pal_idx_r = bg2a_pal_idx" (= FG0 ombra) e "bot = BG1".
// In MAME line 408: alpha_blend_r32(dstline[x] = BG, pix3 = FG0). dst=BG, src=FG0.
// Mio mapping: dst = bot_color (= BG1), src = top_color (= FG0 ombra). Quindi
// sub_blend8(src=top, dst=bot, a).
wire [7:0] mix_b = blend_en_d ? (sub_blend_d ? sub_blend8(top_color[23:16], bot_color[23:16], alpha_d)
                                              : blend8    (top_color[23:16], bot_color[23:16], alpha_d))
                              : top_color[23:16];
wire [7:0] mix_g = blend_en_d ? (sub_blend_d ? sub_blend8(top_color[15:8],  bot_color[15:8],  alpha_d)
                                              : blend8    (top_color[15:8],  bot_color[15:8],  alpha_d))
                              : top_color[15:8];
wire [7:0] mix_r = blend_en_d ? (sub_blend_d ? sub_blend8(top_color[7:0],   bot_color[7:0],   alpha_d)
                                              : blend8    (top_color[7:0],   bot_color[7:0],   alpha_d))
                              : top_color[7:0];

// rgb_out: {R, G, B} (video_r = rgb[23:16]). Solo il mixer — niente overlay diagnostico.
// FIX 2026-07-04 USCITA REGISTRATA (allineamento a BoogieWings funzionante):
// prima rgb_out era COMBINATORIO dalla BRAM palette ai pin (cono 30.7ns, path
// peggiore del chip a -21.4ns); BW registra l'uscita (+7.98ns, immagine ok).
// Campiono su ce_pix: il cono ha 145ns (14 clk) per assestarsi tra un pixel e
// l'altro -> il framework riceve un valore stabile e deterministico.
// Stage-2 alpha-tilemap (mix :443-459): blend del layer alpha SOPRA il
// risultato sprite/tilemap. Fade sul colore at (stessa formula, raw-exempt
// su idx bit11) — il fade e' affine: commuta col blend convesso, quindi
// l'ordine fade->blend qui equivale al MAME (pen gia' fadate).
wire [23:0] at_color_f = (fade_active && !(at_raw_d | priority_reg[3]))
	? {fade8(at_color_raw[23:16], fade_pt_b, fade_st_b, fade_add),
	   fade8(at_color_raw[15:8],  fade_pt_g, fade_st_g, fade_add),
	   fade8(at_color_raw[7:0],   fade_pt_r, fade_st_r, fade_add)}
	: at_color_raw;
wire [7:0] fin_b = at_en_d ? blend8(at_color_f[23:16], mix_b, at_alpha_d) : mix_b;
wire [7:0] fin_g = at_en_d ? blend8(at_color_f[15:8],  mix_g, at_alpha_d) : mix_g;
wire [7:0] fin_r = at_en_d ? blend8(at_color_f[7:0],   mix_r, at_alpha_d) : mix_r;

reg [23:0] rgb_out_q;
always @(posedge clk) if (ce_pix) rgb_out_q <= {fin_r, fin_g, fin_b};
assign rgb_out = rgb_out_q;

// PROBE savestate (vedi MISC_SS_BITS): campiona la tripletta pixel al centro
// dello schermo, una volta per frame. Solo osservazione, zero effetti sul video.
// PROBE FLAGS 2026-07-04: 16 bit STICKY (si accendono al primo evento, mai piu'
// giu') = mappa di vita della pipeline pixel. Viaggiano nel campo priority_reg
// del chunk MISC (sempre 0 su NS, provato nei dump): layout save INVARIATO,
// stesso identico meccanismo che ha gia' prodotto file (08:23/13:38).
reg [15:0] probe_flags;
wire probe_active_px = (render_x < 10'd320) && (render_y >= 10'd8) && (render_y < 10'd248);
always @(posedge clk) begin
	if (reset) probe_flags <= 16'd0;
	else begin
		if (probe_active_px && ce_pix) begin
			if ({mix_r, mix_g, mix_b} != 24'd0)      probe_flags[0]  <= 1'b1; // rgb_out vivo
			if (top_color_raw != 24'd0)              probe_flags[1]  <= 1'b1; // pal_buf legge colore
			if (top_pal_idx_r[10:0] != 11'h300)      probe_flags[2]  <= 1'b1; // mixer sceglie un layer (non backdrop)
			if (d16_0_pf1_pix != 0)                  probe_flags[3]  <= 1'b1; // pen TEXT vivo
			if (d16_0_pf2_pix != 0)                  probe_flags[4]  <= 1'b1; // pen BG1 vivo
			if (d16_1_pf1_pix != 0)                  probe_flags[5]  <= 1'b1; // pen FG0 vivo
			if (d16_1_pf2_pix != 0)                  probe_flags[6]  <= 1'b1; // pen FG1 vivo
			if (sprite_pxl[4:0] != 5'd0)             probe_flags[7]  <= 1'b1; // pen sprite vivo
		end
		if (pal_dma_trig)                            probe_flags[8]  <= 1'b1; // trigger DMA visto
		if (pal_dma_wr_en)                           probe_flags[9]  <= 1'b1; // DMA ha scritto pal_buf
		if (pal_dma_active && pal_dma_rd_idx > 13'd2048) probe_flags[10] <= 1'b1; // FSM oltre capolinea (corrotta)
		if (d16_0_pf1_rom_valid)                     probe_flags[11] <= 1'b1; // fetch text risponde
		if (d16_0_pf2_rom_valid)                     probe_flags[12] <= 1'b1; // fetch BG1 risponde
		if (irq6_pending)                            probe_flags[13] <= 1'b1; // vblank IRQ armato
		if (is_pal & cpu_wr)                         probe_flags[14] <= 1'b1; // CPU scrive palette
		if (probe_active_px & ce_pix)                probe_flags[15] <= 1'b1; // raster attraversa l'area attiva
	end
end

// =====================================================================
// AUDIO subsystem (boogwings_audio.sv)
// =====================================================================
// Audiocpu ROM download: ioctl_dout è 16-bit (word), ROM è byte-addressed.
// ioctl_addr step 2 (= byte units), low byte = [7:0], high byte = [15:8].
// Per ogni ioctl_wr scrivo 2 byte sequenziali: byte 0 a addr N, byte 1 a addr N+1.
// Approach: faccio 2 cicli write con un piccolo flag toggle.
reg        audio_rom_we_lo, audio_rom_we_hi;
reg [15:0] audio_rom_waddr_lo, audio_rom_waddr_hi;
reg [7:0]  audio_rom_wdata_lo, audio_rom_wdata_hi;
reg        ioctl_wr_prev_aud;
always @(posedge clk) begin
	audio_rom_we_lo <= 1'b0;
	audio_rom_we_hi <= 1'b0;
	ioctl_wr_prev_aud <= ioctl_wr_raw;
	if (ioctl_wr_raw && !ioctl_wr_prev_aud && is_audio_dl) begin
		// RAW (pre-de156): 02.l18 NON e' crittato -> il download audio bypassa il de156,
		// che al confine main->audio DIROTTA il 1o strobe audio (flush high-half stranded
		// del main) e PERDE 02.l18[0:1] (=0x78 SEI, prima istr reset). Provato in sim.
		audio_rom_we_lo    <= 1'b1;
		audio_rom_waddr_lo <= ioctl_addr_raw[15:0] - AUDIO_DL_LO[15:0];
		audio_rom_wdata_lo <= ioctl_dout_raw[7:0];
		audio_rom_we_hi    <= 1'b1;
		audio_rom_waddr_hi <= (ioctl_addr_raw[15:0] - AUDIO_DL_LO[15:0]) + 16'd1;
		audio_rom_wdata_hi <= ioctl_dout_raw[15:8];
	end
end

// Mux per scrivere 2 byte in 1 ck: serve dual-port o write seq. Faccio dual writes
// con priority hi (= scrive entrambi insieme; modulo audio gestisce con 2 write port).
// Versione semplice: combino in 1 we + waddr/wdata wide (= modulo audio gestisce 2 byte).
// → Per ora uso solo we_lo + waddr seq con +0/+1 toggle in stesso modulo.
// Modifico: passo word16 al modulo che internamente splitta byte.


wire [27:0] oki0_ddr_addr_w, oki1_ddr_addr_w;
wire        oki0_ddr_req_w, oki1_ddr_req_w;
wire [31:0] oki0_ddr_data_w, oki1_ddr_data_w;     // 32-bit port (port 5/6 con prefetch)
wire        oki0_ddr_ack_w, oki1_ddr_ack_w;

// Audio cen: gating frame-aligned DENTRO i contatori di Template.sv (i contatori congelano
// quando paused_safe, NON taglio del pulse via AND esterno). Ripresa pulita al frame boundary,
// come F2 .cen_in(~obj_paused). I ce_* arrivano gia' fermati durante pausa/SS.

// SET US/HuC6280: TENTATO 2026-07-11 col trapianto di boogwings_audio in
// dual-instance — NON FITTA (LAB 4400/4191: quel modulo duplica YM+OKI+mixer,
// non e' solo la CPU). La via giusta = HuC DENTRO ns_audio_z80 con YM/OKI/
// mixer CONDIVISI e mux del solo bus CPU (vedi memoria roadmap). Rimandato.

// 2026-07-10 AUDIO VERO (set World/Korea/Japan): Z80 (T80pa) + YM2151 (jt51)
// + 2x OKI (jt6295) secondo MAME deco32.cpp z80_sound_map/nslasher config.
assign ce_audio_cnt_load  = 4'd0;
assign ce_ym_cnt_load     = 5'd0;
assign ce_ym_toggle_load  = 1'b0;
assign ce_oki0_cnt_load   = 7'd0;
assign ce_oki1_cnt_load   = 6'd0;
assign ce_cnt_load_wr     = 1'b0;

// Due blocchi audio PARALLELI e MUTUAMENTE ESCLUSIVI: ns_audio_z80 (World/Korea/
// Jap/Ovs) e ns_audio_huc (USA nslasheru). region_us seleziona quale blocco e'
// attivo (pause dell'altro) e quale uscita/DDR-OKI va al top. Nessun mux interno
// ai blocchi: la selezione e' TUTTA qui, alle porte.
wire signed [15:0] z80_audio_l, z80_audio_r, huc_audio_l, huc_audio_r;
wire [27:0] z80_oki0_ddr_addr, z80_oki1_ddr_addr, huc_oki0_ddr_addr, huc_oki1_ddr_addr;
wire        z80_oki0_ddr_req,  z80_oki1_ddr_req,  huc_oki0_ddr_req,  huc_oki1_ddr_req;

// Savestate audio: ns_audio_z80 esporta SOLO fili piatti; gli adaptor stanno
// QUI NEL TOP come tutti gli altri (pal/spr/ace/deco104/misc) — nessuna
// interfaccia ssbus attraverso moduli di gioco (area flaky Quartus17, sospetto
// causa del nero build 23:05). Catena Z80 = set World/Korea/OverSea; USA/HuC
// = fase 2.
// ── ROM sonora 64 KB CONDIVISA fra le due catene (2026-08-10) ───────────────
// Prima ogni catena aveva la SUA copia interna e il download le riempiva
// entrambe con lo stesso stream: 64 blocchi M10K sprecati in una fotocopia
// (le due CPU audio non girano mai insieme). Ora una sola ROM: la write e'
// quella del download, la read ha l'indirizzo della catena ATTIVA.
// Sola lettura dopo il download -> nessuno stato, nessun savestate, latenza
// invariata (read registrata dentro ns_audio_rom, come prima).
wire [14:0] z80_rom_rd_addr, huc_rom_rd_addr;
wire [7:0]  arom_even_rd, arom_odd_rd;
ns_audio_rom u_audio_rom (
	.clk      (clk),
	.we_lo    (audio_rom_we_lo),
	.we_hi    (audio_rom_we_hi),
	.waddr_lo (audio_rom_waddr_lo),
	.waddr_hi (audio_rom_waddr_hi),
	.wdata_lo (audio_rom_wdata_lo),
	.wdata_hi (audio_rom_wdata_hi),
	.rd_addr  (region_us ? huc_rom_rd_addr : z80_rom_rd_addr),
	.even_rd  (arom_even_rd),
	.odd_rd   (arom_odd_rd)
);

ns_audio_z80 u_audio_z80 (
	.clk      (clk),
	.reset    (reset),
	.pause    (paused_safe | region_us),   // fermo se set USA (HuC attivo)
	.fetch_rst(ss_reset),                  // re-prime prefetch OKI al restore
	.ce_ym    (ce_ym),
	.ce_ym_p1 (ce_ym_p1),
	.ce_oki0  (ce_oki0),
	.ce_oki1  (ce_oki1),
	.soundlatch_data      (sndlatch_data),
	.soundlatch_irq_pulse (sndlatch_irq_main_pulse),
	.rom_rd_addr  (z80_rom_rd_addr),
	.rom_even_rd  (arom_even_rd),
	.rom_odd_rd   (arom_odd_rd),
	.oki0_ddr_addr (z80_oki0_ddr_addr),
	.oki0_ddr_req  (z80_oki0_ddr_req),
	.oki0_ddr_data (oki0_ddr_data_w),
	.oki0_ddr_ack  (oki0_ddr_ack_w),
	.oki1_ddr_addr (z80_oki1_ddr_addr),
	.oki1_ddr_req  (z80_oki1_ddr_req),
	.oki1_ddr_data (oki1_ddr_data_w),
	.oki1_ddr_ack  (oki1_ddr_ack_w),
	.osd_sel_fm    (osd_sel_fm),
	.osd_sel_oki0  (osd_sel_oki0),
	.osd_sel_oki1  (osd_sel_oki1),
	.audio_l  (z80_audio_l),
	.audio_r  (z80_audio_r),
	.z80_ss_out (az_z80_ss_out),  .z80_ss_in (az_z80_ss_in),  .z80_ss_wr (az_z80_ss_wr),
	.ym_ss_out  (az_ym_ss_out),   .ym_ss_in  (az_ym_ss_in),   .ym_ss_wr  (az_ym_ss_wr),
	.oki0_ss_out(az_oki0_ss_out), .oki0_ss_in(az_oki0_ss_in), .oki0_ss_wr(az_oki0_ss_wr),
	.oki1_ss_out(az_oki1_ss_out), .oki1_ss_in(az_oki1_ss_in), .oki1_ss_wr(az_oki1_ss_wr),
	.bus_ss_out (az_bus_ss_out),  .bus_ss_load(az_bus_ss_load), .bus_ss_wr(az_bus_ss_wr),
	.ram_ss_sel (az_ram_ss_sel),  .ram_ss_we (az_ram_ss_we),
	.ram_ss_addr(az_ram_ss_addr), .ram_ss_wd (az_ram_ss_wd),  .ram_ss_rd (az_ram_ss_rd)
);

// ── ADAPTOR SAVESTATE AUDIO (nel top, pattern degli adaptor esistenti) ──
wire [357:0]  az_z80_ss_out, az_z80_ss_in;
wire          az_z80_ss_wr;
wire [2819:0] az_ym_ss_out, az_ym_ss_in;
wire          az_ym_ss_wr;
wire [358:0]  az_oki0_ss_out, az_oki0_ss_in, az_oki1_ss_out, az_oki1_ss_in;
wire          az_oki0_ss_wr, az_oki1_ss_wr;
wire [31:0]   az_bus_ss_out, az_bus_ss_load;
wire          az_bus_ss_wr;
wire          az_ram_ss_we;
wire [10:0]   az_ram_ss_addr;
wire [7:0]    az_ram_ss_wd, az_ram_ss_rd;
wire          az_ram_ss_sel = ssb[SS_IDX_Z80_RAM].access(SS_IDX_Z80_RAM);

// -- SAVESTATE catena USA/HuC --------------------------------------------------
// Prima i chip della catena HuC avevano l'istrumentazione SCOLLEGATA
// (auto_ss_in='0 / auto_ss_out() / auto_ss_wr=0): sul set USA, dopo un restore
// la musica non ripartiva perche' non c'era NULLA da ripristinare.
// REGOLA DI COSTO (ordine utente 2026-08-30): il savestate deve stare in M10K,
// NON in ALM. Quindi la HuC salva: RAM 8K (M10K, porta di lettura UNICA muxata =
// zero logica), stato CPU (298 bit) e stato bus (32 bit). I chip jt51/OKI della
// catena HuC restano SCOLLEGATI: istrumentarli costava ~2000 ALM di mux di carico
// piu' ~2460 ALM per il mux a 3538 bit sul lato save, e il fit falliva (107%).
// Il chunk AUDIO_BUS (32 bit) e' condiviso: save dalla catena attiva, load a
// entrambe. CPU e RAM hanno chunk propri (indici 20 e 16).
wire [297:0]  ah_huc_ss_out, ah_huc_ss_in;
wire          ah_huc_ss_wr;
wire [31:0]   ah_bus_ss_out;
wire          ah_ram_ss_we;
wire [13:0]   ah_ram_ss_addr;
wire [7:0]    ah_ram_ss_wd, ah_ram_ss_rd;
wire          ah_ram_ss_sel = ssb[SS_IDX_HUC_RAM].access(SS_IDX_HUC_RAM);

// CPU HuC: 298 bit = CPU_CLK_CNT(5)+IO_CLK_CNT(3) + core/AG/CS/SavedC/MI(252) + top(38)
auto_save_lean_adaptor #(.N_BITS(298), .SS_IDX(SS_IDX_HUC_CPU)) u_huc_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_HUC_CPU]),
	.bits_in(ah_huc_ss_out), .bits_out(ah_huc_ss_in), .bits_wr(ah_huc_ss_wr)
);

// RAM 8KB HuC: slave hand-written (stesso pattern della RAM Z80 qui sotto).
reg ah_ram_rd_d;
always @(posedge clk) begin
	// 8192 byte di RAM + 256 byte di shadow dei registri YM2151 in coda
	// (8192..8447): il chunk e' della sola catena HuC, quindi non serve un indice
	// nuovo e la catena Z80 resta intatta.
	ssb[SS_IDX_HUC_RAM].setup(SS_IDX_HUC_RAM, 32'd8448, 0);   // 8448 byte, width 0 = 8 bit
	ah_ram_rd_d <= ah_ram_ss_sel & ssb[SS_IDX_HUC_RAM].read;
	if (ah_ram_ss_sel & ssb[SS_IDX_HUC_RAM].write) ssb[SS_IDX_HUC_RAM].write_ack(SS_IDX_HUC_RAM);
	if (ah_ram_rd_d) ssb[SS_IDX_HUC_RAM].read_response(SS_IDX_HUC_RAM, {56'b0, ah_ram_ss_rd});
end
assign ah_ram_ss_we   = ah_ram_ss_sel & ssb[SS_IDX_HUC_RAM].write;
assign ah_ram_ss_addr = ssb[SS_IDX_HUC_RAM].addr[13:0];
assign ah_ram_ss_wd   = ssb[SS_IDX_HUC_RAM].data[7:0];

// bits_in = catena ATTIVA (save); bits_out/bits_wr vanno a entrambe (load).
auto_save_lean_adaptor #(.N_BITS(358), .SS_IDX(SS_IDX_Z80_REGS)) u_z80_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_Z80_REGS]),
	.bits_in(az_z80_ss_out), .bits_out(az_z80_ss_in), .bits_wr(az_z80_ss_wr)
);
auto_save_lean_adaptor #(.N_BITS(2820), .SS_IDX(SS_IDX_YM)) u_ym_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_YM]),
	.bits_in(az_ym_ss_out), .bits_out(az_ym_ss_in), .bits_wr(az_ym_ss_wr)
);
auto_save_lean_adaptor #(.N_BITS(359), .SS_IDX(SS_IDX_OKI0)) u_oki0_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_OKI0]),
	.bits_in(az_oki0_ss_out), .bits_out(az_oki0_ss_in), .bits_wr(az_oki0_ss_wr)
);
auto_save_lean_adaptor #(.N_BITS(359), .SS_IDX(SS_IDX_OKI1)) u_oki1_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_OKI1]),
	.bits_in(az_oki1_ss_out), .bits_out(az_oki1_ss_in), .bits_wr(az_oki1_ss_wr)
);
auto_save_lean_adaptor #(.N_BITS(32), .SS_IDX(SS_IDX_AUDIO_BUS)) u_abus_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_AUDIO_BUS]),
	.bits_in(region_us ? ah_bus_ss_out : az_bus_ss_out), .bits_out(az_bus_ss_load), .bits_wr(az_bus_ss_wr)
);
// RAM 2KB Z80: slave hand-written nel top (pattern F2/BW; il modulo espone la
// porta muxata). read_delay 1 = latenza BRAM di ram_rd_r.
reg az_ram_rd_d;
always @(posedge clk) begin
	ssb[SS_IDX_Z80_RAM].setup(SS_IDX_Z80_RAM, 32'd2048, 0);  // 2048 byte, width 0 = 8 bit
	az_ram_rd_d <= az_ram_ss_sel & ssb[SS_IDX_Z80_RAM].read;
	if (az_ram_ss_sel & ssb[SS_IDX_Z80_RAM].write) ssb[SS_IDX_Z80_RAM].write_ack(SS_IDX_Z80_RAM);
	if (az_ram_rd_d) ssb[SS_IDX_Z80_RAM].read_response(SS_IDX_Z80_RAM, {56'b0, az_ram_ss_rd});
end
assign az_ram_ss_we   = az_ram_ss_sel & ssb[SS_IDX_Z80_RAM].write;
assign az_ram_ss_addr = ssb[SS_IDX_Z80_RAM].addr[10:0];
assign az_ram_ss_wd   = ssb[SS_IDX_Z80_RAM].data[7:0];

ns_audio_huc u_audio_huc (
	.clk      (clk),
	.reset    (reset),
	.pause    (paused_safe | ~region_us),  // fermo se NON set USA (Z80 attivo)
	.ce_huc   (ce_huc),                    // 24 MHz -> CE_IN HuC (core /6 = 4.0 MHz = MAME)
	.ce_ym    (ce_ym),
	.ce_ym_p1 (ce_ym_p1),
	.ce_oki0  (ce_oki0),
	.ce_oki1  (ce_oki1),
	.soundlatch_data      (sndlatch_data),
	.soundlatch_irq_pulse (sndlatch_irq_main_pulse),
	.rom_rd_addr  (huc_rom_rd_addr),
	.rom_even_rd  (arom_even_rd),
	.rom_odd_rd   (arom_odd_rd),
	.oki0_ddr_addr (huc_oki0_ddr_addr),
	.oki0_ddr_req  (huc_oki0_ddr_req),
	.oki0_ddr_data (oki0_ddr_data_w),
	.oki0_ddr_ack  (oki0_ddr_ack_w),
	.oki1_ddr_addr (huc_oki1_ddr_addr),
	.oki1_ddr_req  (huc_oki1_ddr_req),
	.oki1_ddr_data (oki1_ddr_data_w),
	.oki1_ddr_ack  (oki1_ddr_ack_w),
	.osd_sel_fm    (osd_sel_fm),
	.osd_sel_oki0  (osd_sel_oki0),
	.osd_sel_oki1  (osd_sel_oki1),
	.audio_l  (huc_audio_l),
	.audio_r  (huc_audio_r),
	.huc_ss_out (ah_huc_ss_out),  .huc_ss_in (ah_huc_ss_in),  .huc_ss_wr (ah_huc_ss_wr),
	.bus_ss_out (ah_bus_ss_out),  .bus_ss_load(az_bus_ss_load), .bus_ss_wr(az_bus_ss_wr),
	.ram_ss_sel (ah_ram_ss_sel),  .ram_ss_we (ah_ram_ss_we),
	.ram_ss_addr(ah_ram_ss_addr), .ram_ss_wd (ah_ram_ss_wd),  .ram_ss_rd (ah_ram_ss_rd)
);

// MUX uscite su region_us (fuori dai blocchi)
assign audio_l          = region_us ? huc_audio_l      : z80_audio_l;
assign audio_r          = region_us ? huc_audio_r      : z80_audio_r;
assign oki0_ddr_addr_w  = region_us ? huc_oki0_ddr_addr : z80_oki0_ddr_addr;
assign oki0_ddr_req_w   = region_us ? huc_oki0_ddr_req  : z80_oki0_ddr_req;
assign oki1_ddr_addr_w  = region_us ? huc_oki1_ddr_addr : z80_oki1_ddr_addr;
assign oki1_ddr_req_w   = region_us ? huc_oki1_ddr_req  : z80_oki1_ddr_req;

// =====================================================================
// TILEMAP ROM arbiter (4 client = 2 chip × 2 layer)
//   r0 = deco16_0 pf1  → region TILES2_LO  (BG1 baseline plane 1..4)
//   r1 = deco16_0 pf2  → region TILES2_LO  (idem chip 0 pf2)
//   r2 = deco16_1 pf1  → region TILES3_LO  (BG2 plane 0..3)
//   r3 = deco16_1 pf2  → region TILES3_LO  (idem chip 1 pf2)
//   r4 = unused (riservato per text/FG futuro)
//
// Region IDs propagati dai deco16ic via wire d16_*_pf*_rid (parameter-driven).
// =====================================================================
// 2 arbiter SEPARATI: ognuno serve 2 client su una porta SDRAM dedicata.
// Arbiter A (port 0 → bridge tile_*): chip0.pf1 + chip0.pf2 (text + BG1).
// Arbiter B (port 3 → bridge tile2_*): chip1.pf1 + chip1.pf2 (BG2 chip1).
// Schema NinjaWarriors: 2 trans SDRAM concurrent invece di 1 → bandwidth x2.
wire        tilerom_req_w;
wire [23:0] tilerom_addr_w;
wire [2:0]  tilerom_rid_w;
// ARBITER chip0 RIMOSSO: text chip0.pf1 ora ha DDR3 port 8 (txt_ddr_bridge sopra).
// chip0.pf2 (BG1) ha DDR3 port 5 (bg1_ddr_bridge sopra). Nessun client SDRAM chip0.
assign tilerom_addr      = 24'd0;
assign tilerom_region_id = 3'd0;

// Bypass u_arb_b: chip1.pf1 → tilerom_fg0_* (ba0), chip1.pf2 → tilerom_fg1_* (ba1).
// Niente round-robin: 2 porte SDRAM indipendenti = parallelism reale.
assign tilerom_fg0_addr      = d16_1_pf1_rom_addr;
assign tilerom_fg0_region_id = d16_1_pf1_rid;
assign tilerom_fg0_req       = d16_1_pf1_rom_req;
wire [31:0] bg2a_arb_data  = tilerom_fg0_data;
wire        bg2a_arb_valid = tilerom_fg0_valid;

assign tilerom_fg1_addr      = d16_1_pf2_rom_addr;
assign tilerom_fg1_region_id = d16_1_pf2_rid;
assign tilerom_fg1_req       = d16_1_pf2_rom_req;
wire [31:0] bg2b_arb_data  = tilerom_fg1_data;
wire        bg2b_arb_valid = tilerom_fg1_valid;

// Legacy tilerom2 (port arbiter) — non più usato, tied off
assign tilerom2_addr      = 24'd0;
assign tilerom2_region_id = 3'd0;
assign tilerom2_req       = 1'b0;
assign tilerom_req        = tilerom_req_w;

// =====================================================================
// DDRAM 4-port instance
//   Port wr  : sprite ROM ioctl download (+ audio rom + OKI samples TODO)
//   Port rd1 : H6280 ROM (TODO)
//   Port rd2 : OKI1 samples (TODO)
//   Port rd3 : OKI2 samples (TODO)
//   Port rd4 : sprite ROM 32-bit (bridge inline)
// =====================================================================
// Sprite chip0 (sprites1) — bridge inline NO cache (risparmio LAB).
wire [23:0] sprite_romaddr;
wire        sprite_romreq;
reg  [31:0] sprite_romdata;
reg         sprite_romvalid;
reg  [27:0] sprite_ddr_rdaddr;
reg         sprite_ddr_rd_req;
wire [31:0] sprite_ddr_dout;
wire        sprite_ddr_rd_ack;
// NS sprite DDR3 regions (must match the download bases below). chip0 main = 4
// planes (4 bytes/group); chip0 P4 = 5th plane (1 byte/group); chip1 = 4bpp.
// FIX 2026-07-09: mbh-05/03 scrivono a MAIN+0x400000..+0x4FFFFF -> MAIN occupa
// 0x0400000-0x08FFFFF. Il vecchio P4=0x0800000 ci si SOVRAPPONEVA (mbh-06
// cancellava mbh-05/03) e SPR1=0x0A00000 toccava la coda P4. Regioni disgiunte:
localparam [27:0] DDR_SPR0_MAIN = 28'h0400000;   // 0x0400000-0x08FFFFF (5 MB)
localparam [27:0] DDR_SPR0_P4   = 28'h0A00000;   // 0x0A00000-0x0B3FFFF (1.25 MB)
localparam [27:0] DDR_SPR1      = 28'h0C00000;   // 0x0C00000-0x0CFFFFF (1 MB)
// chip0 5th-plane (P4) bridge signals
wire [23:0] sprite_p4_addr;
wire        sprite_p4_req;
reg  [7:0]  sprite_p4_data;
reg         sprite_p4_valid;
reg  [27:0] sprite_p4_ddr_rdaddr;
reg         sprite_p4_ddr_rd_req;
wire [31:0] sprite_p4_ddr_dout;
wire        sprite_p4_ddr_rd_ack;

// BOOT-KICK renderer (2026-07-22): stesso wedge S_ROM_WAIT curato da ss_reset al
// restore, ma innescato al BOOT: il bridge DDR si resetta solo su pll_locked e
// arriva al rilascio del gioco coi residui del traffico download -> il primo
// contatto del renderer puo' beccare un ack orfano = sprite assenti (lotteria
// per-boot; il restore li resuscitava perche' ss_reset rifa' il primo contatto
// a bridge quieto). One-shot di reset ~11ms dopo il release (2^20 ck @96MHz),
// a bridge in regime — invisibile (siamo nel boot logo).
// 2026-08-04 BOOT DETERMINISTICO: il kick ora resetta ANCHE gli adapter DDR
// client (spr1/sprp4/spr2/txt) = reset ATOMICO richiedente+adapter, stessa
// semantica di ss_reset (l'unico path che guariva sempre).
reg [19:0] boot_kick_cnt = 20'hFFFFF;
always @(posedge clk) begin
	if (reset) boot_kick_cnt <= 20'hFFFFF;
	else if (boot_kick_cnt != 20'd0) boot_kick_cnt <= boot_kick_cnt - 20'd1;
end
wire boot_spr_rst = (boot_kick_cnt == 20'd1);

// BOOT RESET bridge DDR a inizio sessione (fronte ioctl_download): ddram_4port
// non ha altro reset e MiSTer NON riprogramma l'FPGA sui reload caldi (stesso
// RBF, MRA diverso) -> stato/parita'/cache della sessione precedente
// sopravvivrebbero. Impulso di UN SOLO ciclo sul fronte: dentro, il bridge
// ALLINEA le parita' ack ai req correnti (non azzera: vedi ddram_4port) ->
// zero pendenti fantasma e zero transazioni inghiottite (un toggle nello
// stesso ciclo campiona il req vecchio = pending preservato).
reg dl_rise_d = 0;
always @(posedge clk) dl_rise_d <= ioctl_download;
wire ddr_boot_rst = ioctl_download & ~dl_rise_d;

reg [1:0] spr1_state;
localparam SPR1_IDLE = 2'd0, SPR1_WAIT = 2'd1;
reg spr1_req_prev;
always @(posedge clk) begin
	if (reset | ss_reset | boot_spr_rst) begin
		spr1_state        <= SPR1_IDLE;
		spr1_req_prev     <= 0;
		sprite_ddr_rd_req <= 0;
		sprite_romvalid   <= 0;
	end else begin
		spr1_req_prev   <= sprite_romreq;
		sprite_romvalid <= 0;
		case (spr1_state)
			SPR1_IDLE: if (sprite_romreq & ~spr1_req_prev) begin
				// Download interleave 2x: 1 byte source -> 2 byte DDR3.
				// sprite_romaddr e' in spazio MAME (= source 4MB).
				// DDR3 = 8MB interleavato -> shift left 1.
				sprite_ddr_rdaddr <= DDR_SPR0_MAIN + {3'd0, sprite_romaddr, 1'b0};
				sprite_ddr_rd_req <= ~sprite_ddr_rd_req;
				spr1_state <= SPR1_WAIT;
			end
			SPR1_WAIT: if (sprite_ddr_rd_ack == sprite_ddr_rd_req) begin
				sprite_romdata  <= sprite_ddr_dout;
				sprite_romvalid <= 1'b1;
				spr1_state <= SPR1_IDLE;
			end
			default: spr1_state <= SPR1_IDLE;
		endcase
	end
end

// Sprite chip0 5th-plane (P4) bridge — 1 byte/group, region DDR_SPR0_P4.
// The renderer's rom0_p4_addr is the group index. DDR3 download wrote 1 byte/
// group linearly, but the download interleaves 1 src byte → 2 DDR3 bytes (the
// 2× DDR3 layout), so the byte we want is at P4_base + group*2, low byte.
reg [1:0] sprp4_state;
localparam SPRP4_IDLE = 2'd0, SPRP4_WAIT = 2'd1;
reg sprp4_req_prev;
always @(posedge clk) begin
	if (reset | ss_reset | boot_spr_rst) begin
		sprp4_state          <= SPRP4_IDLE;
		sprp4_req_prev       <= 0;
		sprite_p4_ddr_rd_req <= 0;
		sprite_p4_valid      <= 0;
	end else begin
		sprp4_req_prev  <= sprite_p4_req;
		sprite_p4_valid <= 0;
		case (sprp4_state)
			SPRP4_IDLE: if (sprite_p4_req & ~sprp4_req_prev) begin
				// P4 is 1 byte/group, written LINEARLY by the download (byte i ->
				// DDR[i]). rom0_p4_addr is the group index = byte address (no <<1).
				// Proven by ns_download_sim.py (read at G, DIFF=0).
				sprite_p4_ddr_rdaddr <= DDR_SPR0_P4 + {4'd0, sprite_p4_addr};
				sprite_p4_ddr_rd_req <= ~sprite_p4_ddr_rd_req;
				sprp4_state <= SPRP4_WAIT;
			end
			SPRP4_WAIT: if (sprite_p4_ddr_rd_ack == sprite_p4_ddr_rd_req) begin
				// DDR3 read returns 32-bit; the byte we want is at rdaddr's byte
				// position. addr&1 selects which byte of the 16-bit word.
				// FIX 2026-07-09: dout della porta 32-bit = 4 byte; il select
				// usava SOLO addr[0] (perdeva addr[1]: byte 2,3 irraggiungibili).
				// Byte = addr[1:0] (+ lane XOR OSD su bit0 per debug).
				sprite_p4_data  <= sprite_p4_ddr_dout[{sprite_p4_ddr_rdaddr[1:0]
				                     ^ {1'b0, osd_spr_p4_lane}, 3'b000} +: 8];
				sprite_p4_valid <= 1'b1;
				sprp4_state <= SPRP4_IDLE;
			end
			default: sprp4_state <= SPRP4_IDLE;
		endcase
	end
end

// Sprite chip1 (sprites2) — bridge inline NO cache (risparmio LAB).
// req_pulse → toggle DDR3 → wait ack → resp_valid pulse.
wire [23:0] sprite2_romaddr;
wire        sprite2_romreq;
reg  [31:0] sprite2_romdata;
reg         sprite2_romvalid;
reg  [27:0] sprite2_ddr_rdaddr;
reg         sprite2_ddr_rd_req;
wire [31:0] sprite2_ddr_dout;
wire        sprite2_ddr_rd_ack;
// chip1 region = DDR_SPR1 (defined above). chip0 main=0x400000, P4=0x800000.

reg [1:0] spr2_state;
localparam SPR2_IDLE = 2'd0, SPR2_REQ = 2'd1, SPR2_WAIT = 2'd2, SPR2_DONE = 2'd3;
reg spr2_req_prev;
always @(posedge clk) begin
	if (reset | ss_reset | boot_spr_rst) begin
		spr2_state       <= SPR2_IDLE;
		spr2_req_prev    <= 0;
		sprite2_ddr_rd_req <= 0;
		sprite2_romvalid <= 0;
	end else begin
		spr2_req_prev    <= sprite2_romreq;
		sprite2_romvalid <= 0;
		case (spr2_state)
			SPR2_IDLE: if (sprite2_romreq & ~spr2_req_prev) begin
				// Download interleave 2x: shift left 1 (vedi SPR1).
				sprite2_ddr_rdaddr <= DDR_SPR1 + {3'd0, sprite2_romaddr, 1'b0};
				sprite2_ddr_rd_req <= ~sprite2_ddr_rd_req;
				spr2_state <= SPR2_WAIT;
			end
			SPR2_WAIT: if (sprite2_ddr_rd_ack == sprite2_ddr_rd_req) begin
				sprite2_romdata  <= sprite2_ddr_dout;
				sprite2_romvalid <= 1'b1;
				spr2_state <= SPR2_IDLE;
			end
			default: spr2_state <= SPR2_IDLE;
		endcase
	end
end

// Sprite + Tile2 ROM ioctl download → DDR3 write port (MUX-ato).
// BoogieWings MRA layout:
//   0x130000-0x42FFFF tile2 (3 MB, BG1 5bpp = mbd-01+00+02_remap)
//   0x630000-0xE2FFFF sprite (8 MB)
// Tile2 va a DDR3 base 0x05000000 (80 MB offset).
// Sprite a DDR3 base 0x04000000.
// MRA layout (BoogieWings_dec_jt.mra):
//   0x630000-0x82FFFF = tiles3 #2 (duplicato per SDRAM ba1 FG1, NON sprite!)
//   0x830000-0x102FFFF = sprite (8 MB, dest DDR3 chip0+chip1)
// NS sprite download is handled by the dl_mbh*/is_spr*_dl logic below (per the NS
// .mra offsets). The old BoogieWings SPRITE_DL_LO/SZ block was removed.
// NS tile layout (deco32.cpp): only 2 regions, both 2MB, both 4bpp.
//   tiles1 (mbh-00) = text 8x8 (chip0.pf1) AND tiles 16x16; @ ioctl 0x110000.
//   tiles2 (mbh-01) = BG 16x16 (chip0.pf2);                  @ ioctl 0x310000.
// Both are RGN_FRAC(1,2) = LO half + HI half. chip1 (pf1/pf2) also uses these
// (gfx_nslasher: tiles1 for both pf via the same region). See the bridges below.
// Audiocpu ROM (H6280): 64 KB BRAM, dest interno modulo audio
localparam [26:0] AUDIO_DL_LO  = 27'h100000;
localparam [26:0] AUDIO_DL_SZ  = 27'h010000;
// RAW (pre-de156): il download audio usa ioctl_addr_raw perche' il de156 dirotta il
// 1o strobe audio al confine (perde 02.l18[0:1]). L'audio non e' crittato -> raw = corretto.
wire is_audio_dl  = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr_raw >= AUDIO_DL_LO)
                     && (ioctl_addr_raw <  AUDIO_DL_LO + AUDIO_DL_SZ);
// OKI1/OKI2 (512 KB ciascuna) → DDR3 base 0x5500000 / 0x5580000
// OKI offsets aligned to the .mra stream (after sprites): oki1 0xF70000, oki2 0xFF0000.
localparam [26:0] OKI1_DL_LO  = 27'hF70000;
localparam [26:0] OKI1_DL_SZ  = 27'h0080000;
localparam [26:0] OKI2_DL_LO  = 27'hFF0000;
localparam [26:0] OKI2_DL_SZ  = 27'h0080000;
localparam [27:0] DDR_OKI1_BASE = 28'h5500000;
localparam [27:0] DDR_OKI2_BASE = 28'h5580000;
// Text chip0.pf1 in DDR3 (2026-07-11): regione UNICA INTERLEAVED — per ogni
// gruppo G (word idx) il download scrive lo a 4G+0..1 e hi a 4G+2..3: un
// gruppo = UNA lettura 32-bit ({hi,lo} nelle lane giuste automaticamente).
localparam [27:0] DDR_TXT_BASE  = 28'h5600000;   // 128 KB (32K gruppi x 4 byte)
// (DDR_SPR0_MAIN / DDR_SPR0_P4 / DDR_SPR1 defined above near the bridges.)
wire is_oki1_dl  = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= OKI1_DL_LO)
                    && (ioctl_addr <  OKI1_DL_LO + OKI1_DL_SZ);
wire is_oki2_dl  = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= OKI2_DL_LO)
                    && (ioctl_addr <  OKI2_DL_LO + OKI2_DL_SZ);
// Text chip0.pf1 → DDR3 (2026-07-11): LO 0x110000-0x11FFFF, HI 0x120000-0x12FFFF.
// Offset in region = ioctl_addr[15:0] (le basi hanno i 16 bit bassi a zero).
wire is_txt_lo_dl = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= 27'h110000) && (ioctl_addr < 27'h120000);
wire is_txt_hi_dl = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= 27'h120000) && (ioctl_addr < 27'h130000);
reg  [27:0] ddr_dl_waddr;
reg  [15:0] ddr_dl_wdata;
reg         ddr_dl_we_req;
wire        ddr_dl_we_ack;
reg         ioctl_wr_prev_ddr;
// Sprite download interleave: layout MAME tile_16x16_layout richiede
// plane 0,1 da LO region, plane 2,3 da HI region. Il bridge sprite legge 4 byte
// consecutivi. Interleavo durante download cosi' DDR3 ha 4 byte = [LO+0, LO+1, HI+0, HI+1].
//
// Source layout (ioctl_addr - SPRITE_DL_LO):
//   0..2MB = chip0 LO (mbd-06)
//   2..4MB = chip0 HI (mbd-05)
//   4..6MB = chip1 LO (mbd-08)
//   6..8MB = chip1 HI (mbd-07)
// Destination layout in DDR3 (a partire da 0x04000000):
//   chip0 occupa 0..4MB (4 byte per ogni 2 byte source)
//   chip1 occupa 4..8MB
// Per ogni word16 source (2 byte) a offset rel:
//   se rel < 2MB: chip=0, region=LO, dst_base=0          , dst_off=2*rel
//   se rel < 4MB: chip=0, region=HI, dst_base=2          , dst_off=2*(rel-2MB)
//   se rel < 6MB: chip=1, region=LO, dst_base=0+4MB      , dst_off=2*(rel-4MB)
//   se rel < 8MB: chip=1, region=HI, dst_base=2+4MB      , dst_off=2*(rel-6MB)
// ── NS sprite download split (proven by sim/scripts/ns_download_sim.py, DIFF=0).
// chip0 = 5bpp: 4 normal planes -> MAIN region (renderer 32-bit fetch); 5th plane
// -> separate P4 region (8-bit fetch). ioctl offsets from the NS .mra (verified):
// Offsets ALIGNED to the .mra stream (after the SDRAM tile ranges). Verified by
// parsing the .mra (mister_sim mra_parser): sprites start at 0x830000.
localparam [26:0] MBH04_LO = 27'h830000, MBH02_LO = 27'hA30000;
localparam [26:0] MBH05_LO = 27'hC30000, MBH03_LO = 27'hCB0000;
localparam [26:0] MBH06_LO = 27'hD30000, MBH07_LO = 27'hE30000;
localparam [26:0] MBH08_LO = 27'hE70000, MBH09_LO = 27'hEF0000;
wire dl_mbh04 = ioctl_addr >= MBH04_LO && ioctl_addr < MBH04_LO + 27'h200000;
wire dl_mbh02 = ioctl_addr >= MBH02_LO && ioctl_addr < MBH02_LO + 27'h200000;
wire dl_mbh05 = ioctl_addr >= MBH05_LO && ioctl_addr < MBH05_LO + 27'h080000;
wire dl_mbh03 = ioctl_addr >= MBH03_LO && ioctl_addr < MBH03_LO + 27'h080000;
wire dl_mbh06 = ioctl_addr >= MBH06_LO && ioctl_addr < MBH06_LO + 27'h100000;
wire dl_mbh07 = ioctl_addr >= MBH07_LO && ioctl_addr < MBH07_LO + 27'h040000;
wire dl_mbh08 = ioctl_addr >= MBH08_LO && ioctl_addr < MBH08_LO + 27'h080000;
wire dl_mbh09 = ioctl_addr >= MBH09_LO && ioctl_addr < MBH09_LO + 27'h080000;
wire dl_active = ioctl_download && (ioctl_index == 16'd0);
wire is_spr0_main_dl = dl_active & (dl_mbh04 | dl_mbh02 | dl_mbh05 | dl_mbh03);
wire is_spr0_p4_dl   = dl_active & (dl_mbh06 | dl_mbh07);
wire is_spr1_dl      = dl_active & (dl_mbh08 | dl_mbh09);
// Word-based download (ddram_4port we_byte=0 writes the 16-bit din to {waddr,
// waddr+1}). ioctl processes 2 source bytes per write (ioctl_dout). Proven
// exactly by ns_download_sim.py (DIFF=0). For source WORD G (ioctl byte 2G):
//   MAIN region: mbh04 word G -> dest 4G (bytes 0,1); mbh02 word G -> dest 4G+2.
//     The assembled bytes need the source word BYTE-SWAPPED (DDR[4G+0]=mbh04[2G+1],
//     DDR[4G+1]=mbh04[2G]) -> use spr_dl_wdata = byte-swapped ioctl_dout.
//   P4 region: mbh06 written LINEARLY (byte i -> DDR[i]); waddr = group byte addr.
//   chip1: same scheme as MAIN (mbh08 -> 4G, mbh09 -> 4G+2).
// Source word index G = (ioctl_addr - base) >> 1.
wire [19:0] spr_G04 = (ioctl_addr[20:0] - MBH04_LO[20:0]) >> 1;
wire [19:0] spr_G02 = (ioctl_addr[20:0] - MBH02_LO[20:0]) >> 1;
wire [17:0] spr_G05 = (ioctl_addr[18:0] - MBH05_LO[18:0]) >> 1;
wire [17:0] spr_G03 = (ioctl_addr[18:0] - MBH03_LO[18:0]) >> 1;
// HALF-ADIACENTE (2026-07-11, prestazioni): gruppo dest = {code, row, half}
// invece di {code, half, row} — rotazione dei 5 bit bassi. Le meta' A/B di
// una riga sprite cadono nella STESSA linea DDR da 8 byte: il fetch B e'
// cache-hit nell'arbitro = transazioni main dimezzate. Il renderer chiede
// {code, row_use, half_use} (boogwings_sprites S_ROM_REQ + prefetch).
// Algebra verificata offline su 100k tuple (swz(Gsrc)==Gnew, stessa linea).
wire [19:0] spr_G04s = {spr_G04[19:5], spr_G04[3:0], spr_G04[4]};
wire [19:0] spr_G02s = {spr_G02[19:5], spr_G02[3:0], spr_G02[4]};
wire [17:0] spr_G05s = {spr_G05[17:5], spr_G05[3:0], spr_G05[4]};
wire [17:0] spr_G03s = {spr_G03[17:5], spr_G03[3:0], spr_G03[4]};
// MAIN dest (word-aligned byte addr): mbh04/05 -> 4G+0; mbh02/03 -> 4G+2.
// high-range ROMs (mbh05/03) continue after 0x100000 groups = 0x400000 bytes.
// TIMING 2026-08-10: gli indirizzi DDR si formano per CONCATENAZIONE, non per
// somma. Prima erano TRE catene di riporto in serie per ramo (sottrazione ->
// +2 / +0x400000 -> DDR_BASE + dst): con le basi allineate rispetto all'offset
// tutte le somme sono OR su bit disgiunti, quindi resta la sola sottrazione.
// Identita' verificata ESAUSTIVAMENTE su 4.161.536 indirizzi, 0 differenze
// (sim/tb/tb_ddr_decode.sv, vecchie espressioni contro nuove).
wire [20:0] p4_off06 = ioctl_addr[20:0] - MBH06_LO[20:0];
wire [17:0] p4_off07 = ioctl_addr[17:0] - MBH07_LO[17:0];
wire [26:0] oki1_off = ioctl_addr - OKI1_DL_LO;
wire [26:0] oki2_off = ioctl_addr - OKI2_DL_LO;
// chip1 (4bpp): mbh08 -> 4G+0, mbh09 -> 4G+2 (same MAIN scheme).
// HALF-ADIACENTE anche qui (stessa rotazione 5 bit bassi).
wire [18:0] spr_G08 = (ioctl_addr[19:0] - MBH08_LO[19:0]) >> 1;
wire [18:0] spr_G09 = (ioctl_addr[19:0] - MBH09_LO[19:0]) >> 1;
wire [18:0] spr_G08s = {spr_G08[18:5], spr_G08[3:0], spr_G08[4]};
wire [18:0] spr_G09s = {spr_G09[18:5], spr_G09[3:0], spr_G09[4]};
// byte-swapped download data for MAIN/chip1 (assembled bytes need source word
// reversed). P4 is linear (no swap).
wire [15:0] spr_main_wdata = {ioctl_dout[7:0], ioctl_dout[15:8]};

// Write diretta DDR3 download (no pending queue).
// Pre-fix `23ac95a` aveva pending queue: causa race su `ddr_dl_we_ack` lento.
//
// TIMING 2026-08-10: gli indirizzi si formano per CONCATENAZIONE (vedi sopra),
// non piu' con sottrazione + somma + somma in serie. Il taglio del cammino lungo
// e' fatto A MONTE, in Template.sv, con lo stadio di registro su
// ioctl_addr/ioctl_dout: qui il decode riparte da un registro vicino, quindi
// resta combinatorio allo strobe come nell'originale (nessuno stadio in piu',
// altrimenti si leggerebbe l'indirizzo della word precedente).
always @(posedge clk) begin
	ioctl_wr_prev_ddr <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev_ddr) begin
		if (is_spr0_main_dl) begin
			// chip0 4 normal planes -> MAIN region (word-swapped data)
			ddr_dl_waddr  <= dl_mbh04 ? {5'd0, 1'b1,         spr_G04s, 2'b00}
			               : dl_mbh02 ? {5'd0, 1'b1,         spr_G02s, 2'b10}
			               : dl_mbh05 ? {4'd0, 1'b1, 3'b000, spr_G05s, 2'b00}
			               :            {4'd0, 1'b1, 3'b000, spr_G03s, 2'b10};
			ddr_dl_wdata  <= spr_main_wdata;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_spr0_p4_dl) begin
			// chip0 5th plane -> P4 region (linear, no swap)
			ddr_dl_waddr  <= dl_mbh06 ? {8'h0A, p4_off06[19:0]}
			               :            {8'h0B, 2'b00, p4_off07};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_spr1_dl) begin
			// chip1 4bpp -> chip1 region @ DDR_SPR1 (word-swapped data, like chip0)
			ddr_dl_waddr  <= dl_mbh08 ? {4'd0, 2'b11, 1'b0, spr_G08s, 2'b00}
			               :            {4'd0, 2'b11, 1'b0, spr_G09s, 2'b10};
			ddr_dl_wdata  <= spr_main_wdata;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_oki1_dl) begin
			ddr_dl_waddr  <= {DDR_OKI1_BASE[27:19], oki1_off[18:0]};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_oki2_dl) begin
			ddr_dl_waddr  <= {DDR_OKI2_BASE[27:19], oki2_off[18:0]};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_txt_lo_dl) begin
			// text INTERLEAVED: gruppo G = word idx; lo -> 4G+0..1, hi -> 4G+2..3
			ddr_dl_waddr  <= {DDR_TXT_BASE[27:17], ioctl_addr[15:1], 2'b00};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_txt_hi_dl) begin
			ddr_dl_waddr  <= {DDR_TXT_BASE[27:17], ioctl_addr[15:1], 2'b10};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end
	end
end

// =====================================================================
// tile_perm: 4 toggle indipendenti per debug HW (run-time).
// =====================================================================
function [7:0] brev8(input [7:0] b);
	brev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction

function [31:0] tile_perm(input [15:0] hi_w, input [15:0] lo_w,
                          input swap_hl, input brev_en, input nibsw_en, input bs_ab_en);
	reg [31:0] w0, w1, w2, w3;
	begin
		w0 = swap_hl ? {lo_w, hi_w} : {hi_w, lo_w};
		w1 = bs_ab_en ?
			{w0[23:16], w0[31:24], w0[7:0],  w0[15:8]} :
			w0;
		w2 = nibsw_en ?
			{w1[27:24], w1[31:28], w1[19:16], w1[23:20],
			 w1[11:8],  w1[15:12], w1[3:0],   w1[7:4]} :
			w1;
		w3 = brev_en ?
			{brev8(w2[31:24]), brev8(w2[23:16]), brev8(w2[15:8]), brev8(w2[7:0])} :
			w2;
		tile_perm = w3;
	end
endfunction

// =====================================================================
// BG1 chip0.pf2 5bpp → SDRAM ba3 (jtframe_sdram64).
// Bridge SDRAM (in sdram_bridge.sv) gestisce 3 region: mbd-01/mbd-00/mbd-02.
// - 4 plane base: 2 fetch sequenziali (MID+LO) → tilerom_bg1_data 32-bit
// - p4 (mbd-02): canale dedicato → tilerom_bg1_p4_data 8-bit RAW (no tile_perm)
// =====================================================================
// Layout IDENTICO a BoogieWings: chip0.pf2 → bg1 port (ba3). chip0.pf1 (text) ha
// il suo path dedicato (sotto). Nessun arbitro.
assign tilerom_bg1_addr   = d16_0_pf2_rom_addr;
assign tilerom_bg1_req    = d16_0_pf2_rom_req;
assign tilerom_bg1_p4_req = 1'b0;   // NS pf2 e' 4bpp, no p4 fetch

assign d16_0_pf2_rom_data  = tile_perm(tilerom_bg1_data[31:16], tilerom_bg1_data[15:0],
                                         osd_bg1_swap_hl, osd_bg1_brev8,
                                         osd_bg1_nibsw,   osd_bg1_bs_ab);
assign d16_0_pf2_rom_valid = tilerom_bg1_valid;
assign d16_0_pf2_p4_data   = tilerom_bg1_p4_data;
assign d16_0_pf2_p4_valid  = tilerom_bg1_p4_valid;

// FG0/FG1 (chip1.pf1/pf2): tile fetch via SDRAM (sdram_bridge, porte fg0/fg1).
// I vecchi bridge DDR3 bg2a/bg2b (port 6/7) erano DEAD CODE (ack mai pilotato,
// porte 6/7 = OKI): rimossi 2026-08-04.

// Data 32-bit da arbiter B (= SDRAM). Switch DDR3→SDRAM richiede swap HI/LO
// (regola dogma utente convalidata HW).
assign d16_1_pf1_rom_data  = tile_perm(bg2a_arb_data[15:0], bg2a_arb_data[31:16],
                                         osd_fg0_swap_hl, osd_fg0_brev8,
                                         osd_fg0_nibsw,   osd_fg0_bs_ab);
assign d16_1_pf1_rom_valid = bg2a_arb_valid;

assign d16_1_pf2_rom_data  = tile_perm(bg2b_arb_data[15:0], bg2b_arb_data[31:16],
                                         osd_fg1_swap_hl, osd_fg1_brev8,
                                         osd_fg1_nibsw,   osd_fg1_bs_ab);
assign d16_1_pf2_rom_valid = bg2b_arb_valid;

// =====================================================================
// Text chip0.pf1 → DDR3 port 8 (2026-07-11, ordine utente: libera 128 M10K).
// Regioni LO/HI separate in DDR3 (word16 raw come stavano in BRAM: la
// coppia write/read ddram e' auto-consistente, nessuno swap).
// Bridge = stesso pattern BG2 (port 6/7): 2 fetch HI/LO per gruppo con
// toggle req/ack; il deco16ic tollera la latenza (BG1/BG2/BG3 gia' cosi').
// Priorita' arbitro: port 8 sopra gli sprite (traffico piccolo ~80
// transazioni/linea, deadline di linea dura).
// =====================================================================
// DDR_TXT_BASE dichiarata sopra vicino a DDR_OKI (serve al blocco ddr_dl).
// Download: ioctl 0x110000-0x11FFFF (LO) / 0x120000-0x12FFFF (HI) → DDR3
// interleaved 4G+0/4G+2 (branch nel blocco ddr_dl, is_txt_lo/hi_dl).
// Un gruppo = UNA lettura 32-bit: dout[15:0]=lo, dout[31:16]=hi (le lane
// del write word16 ddram combaciano con lo slice 32-bit del read).

localparam TXT_IDLE = 2'd0;
localparam TXT_REQ  = 2'd1;
localparam TXT_WAIT = 2'd2;

wire [27:0] txt_ddr_rdaddr;
wire [31:0] txt_ddr_dout;
wire        txt_ddr_rd_req;
wire        txt_ddr_rd_ack;

reg [1:0]  txt_state;
reg [15:0] txt_hi_word, txt_lo_word;
reg        txt_req_prev;
reg        txt_ddr_req_r;
reg [27:0] txt_ddr_addr_r;
reg        txt_valid_r;
assign txt_ddr_rdaddr = txt_ddr_addr_r;
assign txt_ddr_rd_req = txt_ddr_req_r;

// gruppo G = byte addr [15:1] -> DDR addr = BASE + 4G (32-bit aligned).
wire [27:0] txt_addr_full = DDR_TXT_BASE + {11'd0, d16_0_pf1_rom_addr[15:1], 2'b00};

always @(posedge clk) begin
	if (reset | ss_reset | boot_spr_rst) begin
		txt_state      <= TXT_IDLE;
		txt_req_prev   <= 0;
		txt_ddr_req_r  <= 0;
		txt_ddr_addr_r <= 28'd0;
		txt_hi_word    <= 16'd0;
		txt_lo_word    <= 16'd0;
		txt_valid_r    <= 0;
	end else begin
		txt_req_prev <= d16_0_pf1_rom_req;
		txt_valid_r  <= 1'b0;
		case (txt_state)
			TXT_IDLE: if (d16_0_pf1_rom_req ^ txt_req_prev) txt_state <= TXT_REQ;
			TXT_REQ: begin
				txt_ddr_addr_r <= txt_addr_full;
				txt_ddr_req_r  <= ~txt_ddr_req_r;
				txt_state      <= TXT_WAIT;
			end
			TXT_WAIT: if (txt_ddr_rd_ack == txt_ddr_req_r) begin
				txt_lo_word <= txt_ddr_dout[15:0];
				txt_hi_word <= txt_ddr_dout[31:16];
				txt_valid_r <= 1'b1;
				txt_state   <= TXT_IDLE;
			end
			default: txt_state <= TXT_IDLE;
		endcase
	end
end

// Stesso contratto dati del bridge BRAM: data32 = {hi_word, lo_word} raw.
assign d16_0_pf1_rom_data  = tile_perm(txt_hi_word, txt_lo_word,
                                         osd_bg0_swap_hl, osd_bg0_brev8,
                                         osd_bg0_nibsw,   osd_bg0_bs_ab);
assign d16_0_pf1_rom_valid = txt_valid_r;

// === Savestate DDR MUX (gated su ss_ddr_grant, con QUIESCENZA latch-on-drain) ===
// Il MUX NON commuta su ss_busy raw: lo farebbe mentre ddram_4port ha fetch sprite/OKI in
// volo -> i DDRAM_DOUT_READY del savestate verrebbero mangiati dalla FSM dell'arbitro ->
// OKI/sprite corrotti o appesi. ss_ddr_grant si ALZA solo dopo che il bus DDR e' fisicamente
// DRENATO (nessuna transazione in volo, stabile per N cicli) e poi RESTA latchato fino a fine
// SS. NON dipende da rd_ack==rd_req: sotto hold l'arbitro non serve i rd_req di sprite/OKI,
// quindi attendere quella quiescenza appenderebbe il restore a COLD BOOT (cache-miss iniziale
// non servito). Equivalente del ddr_mux / RESTORE_WAIT_PAUSE di F2. Vedi blocco hold/grant sotto.
wire  [7:0] d4_DDRAM_BURSTCNT;
wire [28:0] d4_DDRAM_ADDR;
wire        d4_DDRAM_RD;
wire [63:0] d4_DDRAM_DIN;
wire  [7:0] d4_DDRAM_BE;
wire        d4_DDRAM_WE;

ddr_if ss_ddr();   // dichiarata qui (prima del MUX che usa ss_ddr.read/write)
// ss_hold: appena il SS chiede il bus (ss_busy), BLOCCA l'emissione di ddram_4port (resta in
// state 0, richieste pendenti). Cosi' l'arbitro non emette read mentre il SS ha/prende il bus.
// ss_ddr_grant: il MUX devia DDRAM_* al SS solo dopo che l'arbitro e' diventato idle (ss_idle).
// Al termine (ss_busy basso & SS senza transazioni in volo) si rilascia tutto: ss_hold scende,
// l'arbitro riprende a servire le richieste accumulate. NESSUNA read persa.
// Gate DDR savestate estratto in modulo generico cross-core (rtl/common/ss_ddr_gate.sv).
// La REGOLA DI TRASPARENZA (discesa hold/grant solo su segnali interni SS, drain-on-rise)
// vive nel modulo: il core la eredita istanziandolo, non la re-implementa. Vedi ss_ddr_gate.sv.
wire ss_hold, ss_ddr_grant;
wire ss_tx_inflight = ss_ddr.read | ss_ddr.write;   // transazione del SOLO savestate in volo
ss_ddr_gate #(.AW(29), .DRAIN_TH(3)) u_ss_ddr_gate (
	.clk            (clk),
	.reset          (reset),
	.ss_busy        (ss_busy),   // APPROCCIO B (ss_arm attivo): grant DDR al memory_stream
	                             // durante save/restore. A SS idle ss_busy=0 -> bus al gioco.
	.ss_tx_inflight (ss_tx_inflight),
	// master gioco (arbitro)
	.game_burstcnt  (d4_DDRAM_BURSTCNT),
	.game_addr      (d4_DDRAM_ADDR),
	.game_rd        (d4_DDRAM_RD),
	.game_din       (d4_DDRAM_DIN),
	.game_be        (d4_DDRAM_BE),
	.game_we        (d4_DDRAM_WE),
	// master savestate (memory_stream)
	.ss_burstcnt    (ss_DDRAM_BURSTCNT),
	.ss_addr        (ss_DDRAM_ADDR),
	.ss_rd          (ss_DDRAM_RD),
	.ss_din         (ss_DDRAM_DIN),
	.ss_be          (ss_DDRAM_BE),
	.ss_we          (ss_DDRAM_WE),
	.DDRAM_BUSY     (DDRAM_BUSY),
	// uscite mux'd verso il controller DDR3
	.DDRAM_BURSTCNT (DDRAM_BURSTCNT),
	.DDRAM_ADDR     (DDRAM_ADDR),
	.DDRAM_RD       (DDRAM_RD),
	.DDRAM_DIN      (DDRAM_DIN),
	.DDRAM_BE       (DDRAM_BE),
	.DDRAM_WE       (DDRAM_WE),
	.ss_hold        (ss_hold),
	.ss_ddr_grant   (ss_ddr_grant)
);

ddram_4port u_ddram (
	.DDRAM_CLK       (DDRAM_CLK),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (d4_DDRAM_BURSTCNT),
	.DDRAM_ADDR      (d4_DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (d4_DDRAM_RD),
	.DDRAM_DIN       (d4_DDRAM_DIN),
	.DDRAM_BE        (d4_DDRAM_BE),
	.DDRAM_WE        (d4_DDRAM_WE),

	// Write port: sprite + tile2 download (MUX-ato sopra in ddr_dl_*)
	.wraddr (ddr_dl_waddr),
	.din    (ddr_dl_wdata),
	.we_byte(1'b0),
	.we_req (ddr_dl_we_req),
	.we_ack (ddr_dl_we_ack),

	// Read port 1: NON USATA (H6280 ROM ora in BRAM rom_even/rom_odd)
	.rdaddr (28'd0), .dout (), .rd_req(1'b0), .rd_ack(),
	// Read port 2: NON USATA (OKI #0 spostato a port 5 32-bit con prefetch)
	.rdaddr2(28'd0), .dout2(), .rd_req2(1'b0), .rd_ack2(),
	// Read port 3: NON USATA (OKI #1 spostato a port 6 32-bit con prefetch)
	.rdaddr3(28'd0), .dout3(), .rd_req3(1'b0), .rd_ack3(),

	// Read port 4: sprite ROM 32-bit
	.rdaddr4(sprite_ddr_rdaddr),
	.dout4  (sprite_ddr_dout),
	.rd_req4(sprite_ddr_rd_req),
	.rd_ack4(sprite_ddr_rd_ack),

	// Read port 5: OKI #0 samples (512 KB @ DDR3 0x5500000, 32-bit + prefetch)
	.rdaddr5(oki0_ddr_addr_w), .dout5(oki0_ddr_data_w),
	.rd_req5(oki0_ddr_req_w),  .rd_ack5(oki0_ddr_ack_w),

	// Read port 6: OKI #1 samples (512 KB @ DDR3 0x5580000, 32-bit + prefetch)
	.rdaddr6(oki1_ddr_addr_w), .dout6(oki1_ddr_data_w),
	.rd_req6(oki1_ddr_req_w),  .rd_ack6(oki1_ddr_ack_w),

	// Read port 7: sprite chip0 P4 (5o bitplane) — FIX 2026-07-09: il canale
	// era ORFANO (req/ack non cablati): FSM appesa al 1o fetch -> pen bit4
	// sempre 0 -> sprite che usano il 5o piano MAI sistemabili via permutazioni.
	.rdaddr7(sprite_p4_ddr_rdaddr),
	.dout7  (sprite_p4_ddr_dout),
	.rd_req7(sprite_p4_ddr_rd_req),
	.rd_ack7(sprite_p4_ddr_rd_ack),

	// Read port 8: NON USATA (text ora in BRAM tile1_lo/hi)
	.rdaddr8(txt_ddr_rdaddr), .dout8(txt_ddr_dout), .rd_req8(txt_ddr_rd_req), .rd_ack8(txt_ddr_rd_ack),

	// Read port 9: sprites2 chip1 ROM (DDR3 0x4400000-0x47FFFFF, 4 MB)
	.rdaddr9(sprite2_ddr_rdaddr),
	.dout9  (sprite2_ddr_dout),
	.rd_req9(sprite2_ddr_rd_req),
	.rd_ack9(sprite2_ddr_rd_ack),

	// Copy port non usato
	.cpaddr(28'd0), .cpdout(), .cpwr(), .cpreq(1'b0), .cpbusy(),
	.ss_idle(ddram_ss_idle),
	.ss_hold(ss_hold),
	.boot_rst(ddr_boot_rst)   // reset di sessione (fronte download): bridge come al power-on
);
wire ddram_ss_idle;

// =====================================================================
// SAVESTATE — infrastruttura (DORMIENTE finché ss_save/ss_load arrivano).
// memory_stream (dentro save_state_data) parla ddr_if; lo adatto ai segnali raw
// ss_DDRAM_* che il MUX sopra instrada verso DDRAM_* quando ss_busy.
// ss_save/ss_load per ora = 0 → ss_busy=0 → MUX dà sempre il DDR al gioco (baseline).
// =====================================================================
wire        ss_busy;
wire  [7:0] ss_DDRAM_BURSTCNT;
wire [28:0] ss_DDRAM_ADDR;
wire        ss_DDRAM_RD;
wire [63:0] ss_DDRAM_DIN;
wire  [7:0] ss_DDRAM_BE;
wire        ss_DDRAM_WE;

// === SS-ARM (ss_arm): savestate CPU ARM via estrazione diretta reg fisici (approccio B) ===
// Trigger reali dalla UI: ss_save/ss_load (input del top). Lo slot (ss_slot) -> regione DDR.
// Sostituisce ss_m68k (68000, mai funzionato su NS). NON usa iniezione/IRQ/mode-switch:
// ss_arm legge/scrive i registri fisici del core via la porta di scan (ss_arm_*).
wire        ss_reset;   // ss_pause dichiarato sopra (usato da paused_safe_r)
wire        ss_do_save, ss_do_load;   // pulse verso memory_stream
wire        ss_slot_empty;            // load su sotto-slot mai scritto -> restore annullato
wire        ss_restore_done;          // pulse: restore finito -> riavvia DMA palette

ss_arm #(.SS_GLOB_IDX(SS_IDX_GLOBAL)) u_ss_arm (
	.clk          (clk),
	.do_save      (ss_save),
	.do_restore   (ss_load),
	.paused_real  (paused_real_r),   // pausa frame-aligned E CPU parcheggiata a confine PULITO (registrato: vedi nota timing)
	.ss_mem_write (ss_do_save),
	.ss_mem_read  (ss_do_load),
	.ss_busy      (ss_busy),
	.slot_empty   (ss_slot_empty),
	.ss_glob      (ssb[SS_IDX_GLOBAL]),
	.ss_load      (ss_arm_load),     // -> scan-in reg fisici (wrapper)
	.ss_idx       (ss_arm_idx),
	.ss_wdata     (ss_arm_wdata),
	.ss_rdata     (ss_arm_rdata),    // <- scan-out del core
	.ss_reset     (ss_reset),
	.ss_pause     (ss_pause),
	.ss_restore_done (ss_restore_done)
);

// ddr_if del savestate <-> segnali raw ss_DDRAM_* (ss_ddr dichiarata sopra, prima del MUX)
assign ss_DDRAM_ADDR     = ss_ddr.addr[31:3];
assign ss_DDRAM_DIN      = ss_ddr.wdata;
assign ss_DDRAM_RD       = ss_ddr.read;
assign ss_DDRAM_WE       = ss_ddr.write;
assign ss_DDRAM_BURSTCNT = ss_ddr.burstcnt;
assign ss_DDRAM_BE       = ss_ddr.byteenable;
assign ss_ddr.rdata      = DDRAM_DOUT;
// Finche' il MUX non concede il bus al SS (ss_ddr_grant), memory_stream deve STALLARE:
// busy=1 (non emette transazioni che andrebbero perse) e rdata_ready=0 (non campiona i
// DOUT del gioco). Col grant vede i veri DDRAM_*.
assign ss_ddr.rdata_ready= ss_ddr_grant & DDRAM_DOUT_READY;
assign ss_ddr.busy       = ~ss_ddr_grant | DDRAM_BUSY;

// ssbus/ssb dichiarati in alto (prima del primo adaptor RAM). Qui: mux + master.
ssbus_mux #(.COUNT(SS_NSLAVES)) ss_mux (
	.clk     (clk),
	.slave   (ssbus),
	.masters (ssb)
);

// COUNT = SS_MS_COUNT (potenza di 2 >= SS_NSLAVES). CHUNK_BITS=$clog2(COUNT). NON usare 1
// (CHUNK_BITS=0 rompe i bit-select di memory_stream). I chunk oltre SS_NSLAVES restano vuoti
// (timeout query) → save/load auto-coerenti. Costo trascurabile.
save_state_data #(.COUNT(SS_MS_COUNT)) u_save_state (
	.clk        (clk),
	.reset      (reset),
	.ddr        (ss_ddr),
	.read_start (ss_do_load),
	.write_start(ss_do_save),
	.index      (ss_slot),
	.busy       (ss_busy),
	.slot_empty (ss_slot_empty),
	.ssbus      (ssbus)
);

// 2026-07-10 SCAN PARALLELO (fix bubbling): DUE istanze, una per chip, come
// i due DECO SPRITE veri — la scansione seriale (chip0 poi chip1) raddoppiava
// il tempo per riga e sulle righe affollate sforava la finestra -> sprite
// mancanti/instabili. Ogni istanza usa SOLO le sue porte; i buffer/logica
// dell'altro chip vengono spazzati in sintesi (pxl non connesso, chip_idx
// costante).
// BOOT-KICK renderer: blocco SPOSTATO sopra gli adapter DDR (prima del primo
// uso, ModelSim 10.5b non ama i forward-ref). Vedi commento la'.

ns_sprites #(.SPR0_5BPP(1), .CHIP_ONLY(2'b01)) u_sprites (
	// FIX sprite spariti post-restore (casuale): ss_reset resetta i BRIDGE DDR ma il
	// renderer con una fetch in volo restava in S_ROM_WAIT per sempre (ack orfano).
	// Stesso pattern dei 7 FSM bridge esteso al client (nessuno stato di gioco dentro).
	.clk(clk), .reset(reset | ss_reset | boot_spr_rst),
	.sram0_addr(spr_render_addr),
	.sram0_data(spr_render_data),
	.sram1_addr(),
	.sram1_data(16'd0),
	.rom0_addr (sprite_romaddr),
	.rom0_req  (sprite_romreq),
	.rom0_data (sprite_romdata),
	.rom0_valid(sprite_romvalid),
	.rom1_addr (),
	.rom1_req  (),
	.rom1_data (32'd0),
	.rom1_valid(1'b0),
	.rom0_p4_addr (sprite_p4_addr),
	.rom0_p4_req  (sprite_p4_req),
	// 2026-07-09: leve P4 da OSD — off (pen bit4=0), brev8 sul byte
	.rom0_p4_data (osd_spr_p4_off   ? 8'd0 :
	               osd_spr_p4_brev8 ? brev8(sprite_p4_data) : sprite_p4_data),
	.rom0_p4_valid(sprite_p4_valid),
	.render_x  (render_x_flip), .render_y(render_y_flip),
	.hblank_in (hblank_in),
	.vblank_in (vblank_in),
	.ce_pix    (ce_pix),
	.pause_in  (paused_safe),
	.flip_screen(flip_screen),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),
	.pxl0      (sprite_pxl),
	.pxl1      ()
);

ns_sprites #(.SPR0_5BPP(0), .CHIP_ONLY(2'b10)) u_sprites_c1 (
	.clk(clk), .reset(reset | ss_reset | boot_spr_rst),   // idem: client del bridge spr2, stessa classe
	.sram0_addr(),
	.sram0_data(16'd0),
	.sram1_addr(spr2_render_addr),
	.sram1_data(spr2_render_data),
	.rom0_addr (),
	.rom0_req  (),
	.rom0_data (32'd0),
	.rom0_valid(1'b0),
	.rom1_addr (sprite2_romaddr),
	.rom1_req  (sprite2_romreq),
	.rom1_data (sprite2_romdata),
	.rom1_valid(sprite2_romvalid),
	.rom0_p4_addr (),
	.rom0_p4_req  (),
	.rom0_p4_data (8'd0),
	.rom0_p4_valid(1'b0),
	.render_x  (render_x_flip), .render_y(render_y_flip),
	.hblank_in (hblank_in),
	.vblank_in (vblank_in),
	.ce_pix    (ce_pix),
	.pause_in  (paused_safe),
	.flip_screen(flip_screen),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),
	.pxl0      (),
	.pxl1      (sprite2_pxl)
);

// ioctl_wait: backpressure verso HPS durante DDR3 write.
// Pattern Raiden (sdram_bridge.sv:242): wait pendente + stretch counter post-write.
// Stretch serve a dare margine al cross-clock domain (clk_sys vs DDRAM_CLK) e a
// completare refresh/cacheline. Senza stretch: race su toggle req/ack → scritture
// scartate → DDR3 corrotta → sprite con buchi e silhouette monochrome.
wire ddr_dl_we_pending = (ddr_dl_we_req != ddr_dl_we_ack);
reg [7:0] ddr_dl_stretch;
reg       ddr_dl_pending_d;
always @(posedge clk) begin
	if (reset) begin
		ddr_dl_stretch   <= 0;
		ddr_dl_pending_d <= 0;
	end else begin
		ddr_dl_pending_d <= ddr_dl_we_pending;
		// Falling edge di pending → carica stretch (64 ck = ~670 ns @ 96 MHz)
		if (ddr_dl_pending_d & ~ddr_dl_we_pending)
			ddr_dl_stretch <= 8'd64;
		else if (ddr_dl_stretch != 0)
			ddr_dl_stretch <= ddr_dl_stretch - 8'd1;
	end
end
assign ioctl_wait = ddr_dl_we_pending | (ddr_dl_stretch != 0);

endmodule
