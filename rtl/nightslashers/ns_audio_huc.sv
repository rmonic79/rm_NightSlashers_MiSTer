// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)

    Instantiated cores keep their own authorship in their own source files.
*/

//
// ns_audio_huc.sv — audio Night Slashers (set USA nslasheru): HuC6280 + YM2151 + 2x OKI.
//
// STANDALONE, SEPARATE block from ns_audio_z80.sv (mutually exclusive: the top
// enables only ONE via region_us). NO Z80 code here, no Z80/HuC mux.
//
// MAME deco32.cpp nslasheru: the US release uses HuC6280 instead of the Z80.
//   h6280_sound_map: 000000-00FFFF ROM(64K), 110000/1 YM2151, 120000/1 OKI0,
//                    130000/1 OKI1, 140000 soundlatch_r (DECO104), 1F0000-1F1FFF RAM(8K).
//   IRQ: soundlatch->IRQ1_N, YM2151->IRQ2_N (as BoogieWings, proven on hardware).
//   HuC clock: CE_IN = frac_cen 16.11 MHz; firmware CSH -> /6 = 2.685 MHz MAME-exact.
//   HuC internal PSG NOT used (MAME: internal sound unused).
//
// Peripherals (jt51 / 2x jt6295 / OKI DDR prefetch / Q4.4 mixer / OSD gains) IDENTICAL
// to ns_audio_z80.sv (same hardware-proven structure).
//

module ns_audio_huc (
	input  wire        clk,             // clk_sys (96 MHz)
	input  wire        reset,
	input  wire        pause,           // paused_safe|~region_us: freezes the HuC (CE_IN)
	input  wire        ce_huc,          // 24 MHz pulse -> CE_IN HuC (core /6 = 4.0 MHz = MAME)
	input  wire        ce_ym,           // 96/27 = 3.556 MHz (jt51 cen)
	input  wire        ce_ym_p1,        // 96/54 (jt51 cen_p1)
	input  wire        ce_oki0,         // ~1.0 MHz
	input  wire        ce_oki1,         // ~2.0 MHz

	// Soundlatch from DECO104
	input  wire [7:0]  soundlatch_data,
	input  wire        soundlatch_irq_pulse,

	// HuC audio ROM download (02.l18, 64 KB @ ioctl 0x100000)
	// ROM sonora CONDIVISA (ns_audio_rom nel top): qui solo indirizzo out e dati in.
	// Le due catene non girano mai insieme -> una sola copia da 64 KB. Latenza
	// identica a prima (read registrata dentro ns_audio_rom).
	output wire [14:0] rom_rd_addr,
	input  wire [7:0]  rom_even_rd,
	input  wire [7:0]  rom_odd_rd,

	// OKI DDR3 sample ROM (top ddram ports rd5/rd6)
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

	// -- Savestate (catena USA/HuC - speculare a ns_audio_z80) -----------------
	// A SS spento: tutti gli *_ss_wr=0 e ram_ss_sel=0 -> tutto inerte.
	output wire [297:0]  huc_ss_out,
	input  wire [297:0]  huc_ss_in,
	input  wire          huc_ss_wr,
	output wire [31:0]   bus_ss_out,
	input  wire [31:0]   bus_ss_load,
	input  wire          bus_ss_wr,
	input  wire          ram_ss_sel,
	input  wire          ram_ss_we,
	input  wire [13:0]   ram_ss_addr,   // 0..8191 = RAM 8K, 8192..8447 = shadow YM
	input  wire [7:0]    ram_ss_wd,
	output wire [7:0]    ram_ss_rd
);

// -- OSD gain (identical to ns_audio_z80) ------------------------------------
localparam [9:0] DEF_GAIN_FM   = 10'h004;
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

// -- Audio ROM 64 KB (even/odd, written from download) ----------------------
// ROM 64KB spostata in ns_audio_rom (condivisa fra le due catene).
reg       cpu_addr0_d;


// -- HuC6280 (PCEngine core; here CPU only, internal PSG unused) -------------
// CE_IN = ce_huc (24 MHz, pulse 1/4 ck) gated da ~pause. Il core divide /6
// (CPU_CLK_CNT 0..5) -> ciclo macchina = 24/6 = 4.0 MHz = clock HuC MAME
// (4.0275 MHz = 32.22/8). VALIDATO coi numeri MAME (screenshot): YM/OKI corretti
// (<1%), solo l'HuC era fuori. Prima CE_IN=~pause (96 MHz) -> 96/6 = 16 MHz = 4x
// troppo veloce -> timer interno + sync IRQ YM disallineati (instabilita' storica,
// "cose a caso al reset"). I due tentativi passati (ce_audio 8MHz->1.3MHz LENTO,
// frac 16MHz->veloce) erano ENTRAMBI frequenze sbagliate. Il Z80 (che funziona)
// e' CE-paced a ce_ym (3.58 MHz, giusto): stesso metodo qui alla freq HuC reale.
wire [20:0] cpu_addr;
wire  [7:0] cpu_dout;
wire        cpu_wr_n, cpu_rd_n;
wire        cpu_ce_pulse;   // .CE = valid bus for 1 ck
reg   [7:0] cpu_din;
wire        irq1_n, irq2_n;

HUC6280 u_cpu (
	.SS_DO (huc_ss_out),
	.SS_DI (huc_ss_in),
	.SS_WR (huc_ss_wr),
	.CLK   (clk),
	.CE_IN (ce_huc & ~pause),
	.RST_N (~reset),
	// WAIT_N basso per tutto il replay: e' l'equivalente del WAIT dello Z80 in
	// Raiden 2. Senza, la HuC riparte quando ss_arm rilascia la pausa mentre
	// l'automa sta ancora riscrivendo i 256 registri, e i due si contendono il
	// bus del jt51.
	.WAIT_N(~rp_active),
	.SX    (),
	.A     (cpu_addr),
	.DI    (cpu_din),
	.DO    (cpu_dout),
	.WR_N  (cpu_wr_n),
	.RD_N  (cpu_rd_n),
	.RDY   (1'b1),
	.NMI_N (1'b1),
	.IRQ1_N(irq1_n),
	.IRQ2_N(irq2_n),
	.CE    (cpu_ce_pulse),
	.CEK_N (),
	.CE7_N (),
	.CER_N (),
	.PRE_RD(),
	.PRE_WR(),
	.HSM   (),
	.O     (),
	.K     (8'h00),
	.VDCNUM(1'b0),
	.AUD_LDATA(),
	.AUD_RDATA()
	// Savestate ATTIVO (298 bit): SS_DO/SS_DI/SS_WR collegati in testa all'istanza.
	// CRITICO (nota storica): SS_WR non deve MAI restare floating, farebbe fare al
	// core un RESTORE continuo -> CPU bloccata. Ora lo pilota bits_wr dell'adaptor.
);

// -- Decode h6280_sound_map — STRETTO, identico alla build che suonava
// (brjbx8300 ricostruita): periferiche su finestre 16 byte come la mappa
// MAME (110000-110001 ecc.), NON pagine intere 64K (pattern BW).
wire is_rom = (cpu_addr[20:16] == 5'h00);           // 000000-00FFFF (64K)
// TIMING: i quattro confronti a 17 bit condividono la stessa meta' bassa
// (cpu_addr[15:4] == 0). Fattorizzata: un confronto a 12 bit in comune piu'
// quattro a 5 bit, invece di quattro a 17 bit indipendenti. Identico per
// costruzione, ma la coda del cammino indirizzo->cpu_din perde un livello.
wire perip_lo = (cpu_addr[15:4] == 12'h000);
wire is_ym  = perip_lo & (cpu_addr[20:16] == 5'h11);   // 110000-11000F
wire is_ok0 = perip_lo & (cpu_addr[20:16] == 5'h12);   // 120000-12000F
wire is_ok1 = perip_lo & (cpu_addr[20:16] == 5'h13);   // 130000-13000F
wire is_snd = perip_lo & (cpu_addr[20:16] == 5'h14);   // 140000-14000F
wire is_ram = (cpu_addr[20:13] == 8'hF8);           // 1F0000-1F1FFF (8K)

// ALL writes qualified by cpu_ce_pulse (.CE = bus valid 1 ck). CE_IN is full clk
// (96 MHz), so ~cpu_wr_n stays high for many ck -> a raw level would write the same
// cell repeatedly (dirty OKI/RAM). The working NS config gates every write with the
// bus-valid pulse; the read-mux stays continuous (unqualified). NOT BW's level model
// (BW clocks its HuC differently). One signal for OKI/RAM/YM.
wire wr_now = ~cpu_wr_n & cpu_ce_pulse;      // pulse bus-valid (RAM: path M10K corto, resta diretto)

// -- Stage registrato CPU->CHIP (fix timing 2026-07-15) ----------------------
// Il report formale (diag_setup_worst) nomina il worst path violato del chip:
// HUC6280_CPU|MCODE/PCr -> jt51_mmr (setup -0.355/-0.259): il cono microcodice
// ->decode->dato verso i flop del jt51 non chiude a 96 MHz -> le write di
// arming del timer B (0x12/0x14 all'init) possono catturare corrotte =
// timer mai armato = primo IRQ2 mai = muto finche' una write fortunata passa
// (race osservato sul ferro). Un flop spezza il cono (FF->FF corto).
// Semantica invariata: il bus HuC tiene addr/dato per l'intero ciclo (6 clk);
// la write raggiunge il chip 1 clk dopo, sempre dentro la finestra bus.
reg        wr_q;
reg        is_ym_q, is_ok0_q, is_ok1_q, a0_q;
reg [7:0]  dout_q;
always @(posedge clk) begin
	wr_q     <= wr_now;
	is_ym_q  <= is_ym;
	is_ok0_q <= is_ok0;
	is_ok1_q <= is_ok1;
	a0_q     <= cpu_addr[0];
	dout_q   <= cpu_dout;
end

// -- ROM read pipeline (1 ck, even/odd, delayed select aligned) -------------
assign rom_rd_addr = cpu_addr[15:1];   // -> ns_audio_rom (dato al ck dopo)
always @(posedge clk) cpu_addr0_d <= cpu_addr[0];
wire [7:0] rom_rd_r = cpu_addr0_d ? rom_odd_rd : rom_even_rd;

// -- RAM 8 KB (level, BW) ---------------------------------------------------
// CLEAR HARDWARE al reset: la M10K non si azzera col bitstream in modo garantito
// tra soft-reset (conserva il garbage del gameplay). Il firmware HuC ASSUME RAM=0
// (come MAME .ram() power-on clear): il suo TAI init la azzera, ma sul ferro il
// timing puo' far saltare la sincronizzazione -> RAM indefinita -> avvio a caso a
// ogni reset (dimostrato sul ferro). Azzeriamo qui cella per cella durante il reset
// (reset-hold 0x1FFFF ck >> 8192): l'avvio diventa DETERMINISTICO ad ogni reset.
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_mem [0:8191];
reg [7:0] ram_rd_r;
reg [12:0] ram_clr_idx;
// Porta RAM muxata gioco/savestate (identico a ns_audio_z80: durante SS la CPU
// e' congelata, quindi il dirottamento e' trasparente). A SS spento ram_ss_sel=0
// -> esattamente il comportamento precedente.
wire        ram_we_eff   = ram_sel_lo ? ram_ss_we   : (is_ram & wr_now & ~pause);
// Il gate ~pause e' la protezione provata su BoogieWings: se la pausa cade a meta'
// di una write RAM, una write stantia riscriverebbe ogni ck il byte appena
// restaurato dal chunk HUC_RAM (che precede HUC_CPU, che riallinea gli strobe).
// Qui wr_now e' gia' qualificato da cpu_ce_pulse (azzerato fuori dal gate CE_IN),
// quindi e' ridondante: resta perche' costa nulla e non dipende da quel dettaglio.
wire        ram_sel_lo   = ram_ss_sel & ~ram_ss_addr[13];   // chunk: parte RAM
wire [12:0] ram_addr_eff = ram_sel_lo ? ram_ss_addr[12:0] : cpu_addr[12:0];
wire [7:0]  ram_wd_eff   = ram_sel_lo ? ram_ss_wd   : cpu_dout;
// il chunk restituisce la RAM sotto 8192 e la shadow YM sopra (latenza 1 ck per
// entrambe: la selezione e' registrata insieme al dato).
reg ram_sel_hi_d;
always @(posedge clk) ram_sel_hi_d <= ram_ss_addr[13];
assign ram_ss_rd = ram_sel_hi_d ? ymsh_q : ram_rd_r;

always @(posedge clk) begin
	if (reset) begin
		ram_mem[ram_clr_idx] <= 8'h00;
		ram_clr_idx <= ram_clr_idx + 13'd1;   // wrap 0..8191, riparte da 0 al fronte reset
	end else begin
		if (ram_we_eff) ram_mem[ram_addr_eff] <= ram_wd_eff;
	end
	ram_rd_r <= ram_mem[ram_addr_eff];
end

// -- Soundlatch MAME-exact — LATCH SINGOLO, non FIFO (2026-07-14) -------------
// La build che SUONAVA sul ferro (brjbx8300, ricostruita bit-exact dagli
// archivi di sessione) usava QUESTO schema: un byte (ultima write vince) +
// flag IRQ level, CLEAR alla read. La FIFO 16 (pattern BW) era il delta
// logico residuo delle build MUTE. Stessa lezione gia' pagata sullo Z80
// (read di pulizia del driver + FIFO = comandi persi). Blocco copiato
// VERBATIM da ns_audio_z80.sv (provato sul ferro), solo strobe adattato.
reg  [7:0] sndlatch_byte;
reg        sndlatch_irq_r;
reg        sl_pulse_d, sl_rd_d;
wire       sl_rd_lvl = is_snd & ~cpu_rd_n;

always @(posedge clk) begin
	sl_pulse_d <= soundlatch_irq_pulse;
	sl_rd_d    <= sl_rd_lvl;
	if (reset) begin
		sndlatch_byte  <= 8'h00;
		sndlatch_irq_r <= 1'b0;
	end else begin
		if (bus_ss_wr) begin                     // restore stato bus (savestate)
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

// -- IRQ — provato sul BINARIO 02.l18 (disasm handler con MMU risolta):
//    IRQ1_N (vect FFF8->E207): JSR $F4FF -> LDA fisico 0x140000 = SOUNDLATCH.
//    IRQ2_N (vect FFF6->E174): scritture fisiche 0x110000/1 = YM2151.
//    Level dal latch singolo (come la build che suonava). -----------------------
assign irq1_n = ~sndlatch_irq_r;

// -- YM2151 (jt51) - write pulse (jt51_mmr samples every posedge) -----------
reg  ym_wr_lvl_d;
wire ym_wr_lvl   = is_ym_q & wr_q;
always @(posedge clk) ym_wr_lvl_d <= ym_wr_lvl;
wire ym_wr_pulse = ym_wr_lvl & ~ym_wr_lvl_d;

wire        ym_cs_n = ~is_ym_q;   // solo write-qual (la read del dout jt51 e' un assign incondizionato)
wire        ym_wr_n = ~ym_wr_pulse;
wire [7:0]  ym_dout_raw;
wire        ym_irq_n;

// busy back-pressure (identical to ns_audio_z80)
localparam [12:0] YM_BUSY_TICKS = 13'd7680;  // ~80us @96MHz (busy YM2151 reale). Era
                                             // 1836 (~19us, 4x troppo corto) -> il driver
                                             // in polling scriveva note ravvicinate -> jt51
                                             // perde update KC/KF -> pitch FM stonato.
                                             // Fix BoogieWings 52e78dc (mancava qui).
reg [12:0] ym_busy_cnt;
wire ym_data_wr = ym_wr_pulse & a0_q;
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
	.cs_n   (rp_active ? ~rp_wr : ym_cs_n),
	.wr_n   (rp_active ? ~rp_wr : ym_wr_n),
	.a0     (rp_active ? rp_a0  : a0_q),
	.din    (rp_active ? rp_din : dout_q),
	.dout   (ym_dout_raw),
	.ct1    (),
	.ct2    (),
	.irq_n  (ym_irq_n),
	.sample (),
	.left   (),
	.right  (),
	.xleft  (ym_left),
	.xright (ym_right),
	// SCOLLEGATI di proposito: istrumentare i 3300 registri del jt51 costa ~1500
	// ALM di soli mux di carico, e ALM non ce ne sono. Lo stato FM/ADPCM del set
	// USA non entra nel savestate; CPU HuC, RAM 8K (M10K) e stato bus si'.
	.auto_ss_in ('0),
	.auto_ss_out(),
	.auto_ss_wr (1'b0)
);

// -- Shadow dei 256 registri YM2151 + REPLAY al ripristino ------------------
// Portato da Raiden 2 (Raiden2_audio_z80.sv:607). Il jt51 NON e' istrumentato:
// lo stato che conta e' il suo file di 256 registri (timbri, KC/KF = nota e
// ottava, key-on, timer). Si tiene la copia in M10K, scritta dallo stesso
// strobe che il driver usa gia' (snoop), e al restore un automa la riversa nel
// chip sul bus normale con la HuC ferma. Zero istrumentazione, zero mux larghi.
// Il chunk e' la coda di SS_IDX_HUC_RAM: indirizzi 8192..8447.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ym_shadow [0:255];
reg  [7:0] ymsh_q;
reg        rp_active, rp_pre, rp_final;
reg  [7:0] rp_reg;
reg  [1:0] rp_ph;
reg  [6:0] rp_wait;

wire       ymsh_sel   = ram_ss_sel & ram_ss_addr[13];
wire       ymsh_ss_rd = ymsh_sel & ~ram_ss_we;
wire [7:0] ymsh_waddr = ymsh_sel ? ram_ss_addr[7:0] : ym_last_reg;
wire       ymsh_we    = ymsh_sel ? ram_ss_we : ym_data_wr;
wire [7:0] ymsh_wdata = ymsh_sel ? ram_ss_wd : dout_q;
// porta di lettura UNICA: durante il replay legge rp_reg, altrimenti l'indirizzo
// del chunk. La lettura di save esclude il replay, se no la prima word esce sfasata.
wire [7:0] ymsh_raddr = (rp_active && !ymsh_ss_rd) ? rp_reg : ymsh_waddr;
always @(posedge clk) begin
	if (ymsh_we) ym_shadow[ymsh_waddr] <= ymsh_wdata;
	ymsh_q <= ym_shadow[ymsh_raddr];
end

// Trigger: bus_ss_wr e' il commit del chunk AUDIO_BUS (indice 25), che arriva
// DOPO HUC_RAM (16) e HUC_CPU (20) -> quando parte, la shadow e' gia' tornata.
always @(posedge clk) begin
	if (reset) begin
		rp_active <= 1'b0; rp_pre <= 1'b0; rp_final <= 1'b0;
		rp_reg    <= 8'd0; rp_ph  <= 2'd0; rp_wait  <= 7'd0;
	end else if (bus_ss_wr) begin
		rp_active <= 1'b1; rp_pre <= 1'b1; rp_final <= 1'b0;
		rp_reg    <= 8'd0; rp_ph  <= 2'd0; rp_wait  <= 7'd0;
	end else if (rp_active && ymsh_ss_rd) begin
		rp_active <= 1'b0;   // save partito durante il replay: si abortisce
	end else if (rp_active && ce_ym) begin
		case (rp_ph)
			2'd0: begin rp_ph <= 2'd1; rp_wait <= 7'd8;   end
			2'd1: begin
				if (|rp_wait) rp_wait <= rp_wait - 1'b1;
				else if (rp_final) rp_active <= 1'b0;
				else               rp_ph     <= 2'd2;
			end
			2'd2: begin rp_ph <= 2'd3; rp_wait <= 7'd100; end
			2'd3: begin
				if (|rp_wait) rp_wait <= rp_wait - 1'b1;
				else begin
					rp_ph <= 2'd0;
					if (rp_pre) rp_pre <= 1'b0;
					else begin
						rp_reg <= rp_reg + 1'b1;
						if (rp_reg == 8'd255) rp_final <= 1'b1;
					end
				end
			end
		endcase
	end
end

// Passo iniziale: registro $14 (controllo timer/IRQ) con i bit F Reset A/B a 1,
// per azzerare i flag di timer rimasti. Passo finale: rimette l'address latch.
wire       rp_wr  = rp_active && (rp_ph == 2'd0 || rp_ph == 2'd2);
wire       rp_a0  = (rp_ph == 2'd2);
wire [7:0] rp_din = rp_a0  ? (rp_pre ? 8'h30 : ymsh_q) :
                    rp_pre ? 8'h14 :
                    rp_final ? ym_last_reg : rp_reg;

assign irq2_n = ym_irq_n;   // YM2151 -> IRQ2_N (binario 02.l18: handler E174)

// -- OKI bank via YM reg 0x1B (CT1/CT2) - same as ns_audio_z80 --------------
reg [7:0] ym_last_reg;
always @(posedge clk) begin
	if (bus_ss_wr)                 ym_last_reg <= bus_ss_load[29:22];
	else if (ym_wr_pulse && ~a0_q) ym_last_reg <= dout_q;
end
reg [1:0] oki_bank_bits;
always @(posedge clk) begin
	if (reset) oki_bank_bits <= 2'd0;
	else if (bus_ss_wr) oki_bank_bits <= bus_ss_load[31:30];
	else if (ym_wr_pulse && a0_q && ym_last_reg == 8'h1B)
		oki_bank_bits <= dout_q[7:6];
end
wire oki0_bank = oki_bank_bits[0];
wire oki1_bank = oki_bank_bits[1];

// -- OKI #0/#1 (jt6295) - write as LEVEL (BW) --------------------------------
wire        oki0_wrn = ~(is_ok0_q & wr_q);
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
	.din        (dout_q),
	.dout       (oki0_dout),
	.rom_addr   (oki0_rom_addr),
	.rom_data   (oki0_rom_data),
	.rom_ok     (oki0_rom_ok_w),
	.sound      (oki0_sound),
	.sample     (),
	.auto_ss_in ('0),
	.auto_ss_out(),
	.auto_ss_wr (1'b0)
);

wire        oki1_wrn = ~(is_ok1_q & wr_q);
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
	.din        (dout_q),
	.dout       (oki1_dout),
	.rom_addr   (oki1_rom_addr),
	.rom_data   (oki1_rom_data),
	.rom_ok     (oki1_rom_ok_w),
	.sound      (oki1_sound),
	.sample     (),
	.auto_ss_in ('0),
	.auto_ss_out(),
	.auto_ss_wr (1'b0)
);

// -- OKI0 DDR prefetch (verbatim from ns_audio_z80) -------------------------
reg [17:0] oki0_addr_pending;
reg [15:0] oki0_word_addr, oki0_word_n_addr;
reg [31:0] oki0_word, oki0_word_n;
reg        oki0_req_toggle, oki0_fetch_busy, oki0_fetch_is_next, oki0_rom_ok;
wire       oki0_ddr_ack_match = (oki0_ddr_ack == oki0_req_toggle);
wire [15:0] oki0_cur_widx  = oki0_rom_addr[17:2];
wire [15:0] oki0_next_widx = oki0_rom_addr[17:2] + 16'd1;
wire       oki0_word_hit   = (oki0_word_addr   == oki0_cur_widx);
wire       oki0_word_n_hit = (oki0_word_n_addr == oki0_cur_widx);
always @(posedge clk) begin
	if (reset) begin
		oki0_addr_pending<=18'h0; oki0_word_addr<=16'hFFFF; oki0_word_n_addr<=16'hFFFF;
		oki0_word<=32'd0; oki0_word_n<=32'd0; oki0_req_toggle<=1'b0;
		oki0_fetch_busy<=1'b0; oki0_fetch_is_next<=1'b0; oki0_rom_ok<=1'b0;
	end else begin
		if (oki0_fetch_busy && oki0_ddr_ack_match) begin
			if (oki0_fetch_is_next) begin oki0_word_n<=oki0_ddr_data; oki0_word_n_addr<=oki0_addr_pending[17:2]; end
			else                    begin oki0_word  <=oki0_ddr_data; oki0_word_addr  <=oki0_addr_pending[17:2]; end
			oki0_fetch_busy<=1'b0;
		end
		if (!oki0_fetch_busy && !oki0_word_hit && oki0_word_n_hit) begin
			oki0_word<=oki0_word_n; oki0_word_addr<=oki0_word_n_addr; oki0_word_n_addr<=16'hFFFF;
		end
		oki0_rom_ok <= (oki0_word_hit || oki0_word_n_hit) && !oki0_fetch_busy;
		if (!oki0_fetch_busy) begin
			if (!oki0_word_hit && !oki0_word_n_hit) begin
				oki0_addr_pending<=oki0_rom_addr; oki0_fetch_is_next<=1'b0; oki0_req_toggle<=~oki0_req_toggle; oki0_fetch_busy<=1'b1;
			end else if (oki0_word_hit && (oki0_word_n_addr != oki0_next_widx)) begin
				oki0_addr_pending<={oki0_next_widx[15:0],2'b00}; oki0_fetch_is_next<=1'b1; oki0_req_toggle<=~oki0_req_toggle; oki0_fetch_busy<=1'b1;
			end
		end
	end
end
wire [31:0] oki0_word_sel = oki0_word_hit ? oki0_word : oki0_word_n;
assign oki0_rom_data = oki0_word_sel[{oki0_rom_addr[1:0], 3'b000} +:8];
assign oki0_ddr_addr = 28'h5500000 + {9'd0, oki0_bank, oki0_addr_pending};
assign oki0_ddr_req  = oki0_req_toggle;
assign oki0_rom_ok_w = oki0_rom_ok;

// -- OKI1 DDR prefetch (verbatim from ns_audio_z80) -------------------------
reg [17:0] oki1_addr_pending;
reg [15:0] oki1_word_addr, oki1_word_n_addr;
reg [31:0] oki1_word, oki1_word_n;
reg        oki1_req_toggle, oki1_fetch_busy, oki1_fetch_is_next, oki1_rom_ok;
wire       oki1_ddr_ack_match = (oki1_ddr_ack == oki1_req_toggle);
wire [15:0] oki1_cur_widx  = oki1_rom_addr[17:2];
wire [15:0] oki1_next_widx = oki1_rom_addr[17:2] + 16'd1;
wire       oki1_word_hit   = (oki1_word_addr   == oki1_cur_widx);
wire       oki1_word_n_hit = (oki1_word_n_addr == oki1_cur_widx);
always @(posedge clk) begin
	if (reset) begin
		oki1_addr_pending<=18'h0; oki1_word_addr<=16'hFFFF; oki1_word_n_addr<=16'hFFFF;
		oki1_word<=32'd0; oki1_word_n<=32'd0; oki1_req_toggle<=1'b0;
		oki1_fetch_busy<=1'b0; oki1_fetch_is_next<=1'b0; oki1_rom_ok<=1'b0;
	end else begin
		if (oki1_fetch_busy && oki1_ddr_ack_match) begin
			if (oki1_fetch_is_next) begin oki1_word_n<=oki1_ddr_data; oki1_word_n_addr<=oki1_addr_pending[17:2]; end
			else                    begin oki1_word  <=oki1_ddr_data; oki1_word_addr  <=oki1_addr_pending[17:2]; end
			oki1_fetch_busy<=1'b0;
		end
		if (!oki1_fetch_busy && !oki1_word_hit && oki1_word_n_hit) begin
			oki1_word<=oki1_word_n; oki1_word_addr<=oki1_word_n_addr; oki1_word_n_addr<=16'hFFFF;
		end
		oki1_rom_ok <= (oki1_word_hit || oki1_word_n_hit) && !oki1_fetch_busy;
		if (!oki1_fetch_busy) begin
			if (!oki1_word_hit && !oki1_word_n_hit) begin
				oki1_addr_pending<=oki1_rom_addr; oki1_fetch_is_next<=1'b0; oki1_req_toggle<=~oki1_req_toggle; oki1_fetch_busy<=1'b1;
			end else if (oki1_word_hit && (oki1_word_n_addr != oki1_next_widx)) begin
				oki1_addr_pending<={oki1_next_widx[15:0],2'b00}; oki1_fetch_is_next<=1'b1; oki1_req_toggle<=~oki1_req_toggle; oki1_fetch_busy<=1'b1;
			end
		end
	end
end
wire [31:0] oki1_word_sel = oki1_word_hit ? oki1_word : oki1_word_n;
assign oki1_rom_data = oki1_word_sel[{oki1_rom_addr[1:0], 3'b000} +:8];
assign oki1_ddr_addr = 28'h5580000 + {9'd0, oki1_bank, oki1_addr_pending};
assign oki1_ddr_req  = oki1_req_toggle;
assign oki1_rom_ok_w = oki1_rom_ok;

// -- HuC DIN mux (pure memory-mapped, no I/O space) -------------------------
always @(*) begin
	if      (is_rom) cpu_din = rom_rd_r;
	else if (is_ram) cpu_din = ram_rd_r;
	else if (is_snd) cpu_din = sndlatch_reg;
	else if (is_ym ) cpu_din = ym_dout;
	else if (is_ok0) cpu_din = oki0_dout;
	else if (is_ok1) cpu_din = oki1_dout;
	else             cpu_din = 8'hFF;
end

// -- Q4.4 mixer (identical to ns_audio_z80) ---------------------------------
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

// -- Savestate: pack stato bus (layout IDENTICO a ns_audio_z80) --------------
assign bus_ss_out = {oki_bank_bits, ym_last_reg, ym_busy_cnt, sndlatch_irq_r, sndlatch_byte};

endmodule
