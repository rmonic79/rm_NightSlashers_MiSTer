// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

//============================================================================
//  ss_ddr_gate — Gate DDR del savestate, TRASPARENTE per costruzione.
//
//  Modulo generico cross-core (estratto da boogwings_top.sv, verificato HW).
//  Multiplexa i segnali DDRAM_* tra il MASTER DEL GIOCO (arbitro/ddram_4port) e
//  il MASTER DEL SAVESTATE (memory_stream), concedendo il bus al SS solo a
//  confine pulito e restituendolo senza perdere transazioni.
//
//  === REGOLA DI TRASPARENZA (invariante, NON violare) ===
//  A SS inattivo (ss_busy=0) il modulo e' INERTE: hold/grant restano 0 e il MUX
//  da' sempre il bus al gioco -> comportamento bit-identico al baseline.
//  La DISCESA di hold/grant dipende SOLO da segnali INTERNI al SS
//  (ss_busy, ss_tx_inflight), MAI dal traffico DDR del gioco. Cablare la discesa
//  sul traffico del gioco (bus-quiet) affama i client DDR (es. OKI) perche' a
//  gioco normale il bus non e' mai quiet -> grant latchato (bug effetti sonori).
//
//  ss_bus_quiet (traffico gioco) e' ammesso SOLO sulla SALITA del grant: serve a
//  drenare l'arbitro PRIMA di prendere il bus (latch-on-drain), immune al
//  deadlock cold-boot (sotto hold l'arbitro non azzera i rd_req pendenti, quindi
//  attendere rd_ack==rd_req appenderebbe il restore al primo cache-miss).
//
//  NB: stesso dominio di clock di DDRAM (DDRAM_CLK = clk). Nessun CDC.
//============================================================================

`timescale 1ns / 1ps

module ss_ddr_gate #(
	parameter integer AW       = 29,  // larghezza DDRAM_ADDR
	parameter integer DRAIN_TH = 3    // cicli di bus fermo richiesti prima del grant
) (
	input  wire           clk,
	input  wire           reset,

	// Stato savestate (segnali INTERNI al SS — gli unici trigger ammessi)
	input  wire           ss_busy,        // memory_stream busy (save_state_data.busy)
	input  wire           ss_tx_inflight, // transazione SS in volo (ss_ddr.read | ss_ddr.write)

	// Master GIOCO (arbitro/ddram_4port)
	input  wire [7:0]     game_burstcnt,
	input  wire [AW-1:0]  game_addr,
	input  wire           game_rd,
	input  wire [63:0]    game_din,
	input  wire [7:0]     game_be,
	input  wire           game_we,

	// Master SAVESTATE (memory_stream via ss_ddr)
	input  wire [7:0]     ss_burstcnt,
	input  wire [AW-1:0]  ss_addr,
	input  wire           ss_rd,
	input  wire [63:0]    ss_din,
	input  wire [7:0]     ss_be,
	input  wire           ss_we,

	// Stato fisico del bus DDR (per il drenaggio e il rilascio pulito)
	input  wire           DDRAM_BUSY,

	// Uscite verso il controller DDR3 (mux'd)
	output wire [7:0]     DDRAM_BURSTCNT,
	output wire [AW-1:0]  DDRAM_ADDR,
	output wire           DDRAM_RD,
	output wire [63:0]    DDRAM_DIN,
	output wire [7:0]     DDRAM_BE,
	output wire           DDRAM_WE,

	// Controllo verso l'arbitro / memory_stream
	output reg            ss_hold,        // 1: blocca l'emissione dell'arbitro
	output reg            ss_ddr_grant    // 1: il MUX devia DDRAM_* al SS
);

// "bus quiet" = NESSUNA transazione DDR fisica in volo. Letto post-MUX: con grant=0
// DDRAM_RD/WE valgono game_* (l'arbitro) -> riflette le transazioni del gioco da drenare.
wire ss_bus_quiet = ~DDRAM_RD & ~DDRAM_WE & ~DDRAM_BUSY;

reg [3:0] ss_drain_cnt = 4'd0;

always @(posedge clk) begin
	if (reset) begin
		ss_hold      <= 1'b0;
		ss_ddr_grant <= 1'b0;
		ss_drain_cnt <= 4'd0;
	end else begin
		// HOLD: alto per tutta la richiesta SS (blocca l'emissione dell'arbitro; le richieste
		// client restano pendenti, NON congelate a meta'). Scende appena il SS non e' piu' attivo
		// e non ha transazioni raw in volo. NON dipende dal traffico DDR del gioco.
		if (ss_busy) ss_hold <= 1'b1;
		else if (~ss_tx_inflight) ss_hold <= 1'b0;

		// DRAIN: con hold alto e SS non ancora concesso, conto i cicli di bus fermo. Se riparte
		// una transazione (l'arbitro stava finendo un burst lanciato prima dell'hold), ricomincio.
		// Saturo alla soglia (no wrap). Qui ss_bus_quiet e' lecito: drena l'arbitro del gioco.
		if (ss_hold & ~ss_ddr_grant & ss_busy)
			ss_drain_cnt <= ss_bus_quiet ? (ss_drain_cnt == DRAIN_TH[3:0] ? DRAIN_TH[3:0] : ss_drain_cnt + 4'd1) : 4'd0;
		else
			ss_drain_cnt <= 4'd0;

		// GRANT (LATCH): si alza quando il bus del gioco e' drenato stabile, poi RESTA alto fino a
		// fine SS. Scende SOLO quando il SS non e' piu' attivo e non ha transazioni raw in volo —
		// NON dipende da ss_bus_quiet (a gioco normale non arriva mai -> client DDR affamati). A
		// SS-inattivo: ss_busy=0 & ss_tx_inflight=0 -> grant cade e resta 0 -> MUX sempre al gioco.
		if (ss_hold & ss_busy & (ss_drain_cnt >= DRAIN_TH[3:0])) ss_ddr_grant <= 1'b1;
		else if (~ss_busy & ~ss_tx_inflight) ss_ddr_grant <= 1'b0;
	end
end

assign DDRAM_BURSTCNT = ss_ddr_grant ? ss_burstcnt : game_burstcnt;
assign DDRAM_ADDR     = ss_ddr_grant ? ss_addr     : game_addr;
assign DDRAM_RD       = ss_ddr_grant ? ss_rd       : game_rd;
assign DDRAM_DIN      = ss_ddr_grant ? ss_din      : game_din;
assign DDRAM_BE       = ss_ddr_grant ? ss_be       : game_be;
assign DDRAM_WE       = ss_ddr_grant ? ss_we       : game_we;

endmodule
