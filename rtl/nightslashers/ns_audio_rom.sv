// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

//
// ns_audio_rom.sv — ROM sonora 64 KB CONDIVISA fra le due catene audio.
//
// PERCHE' (2026-08-10): ns_audio_z80 e ns_audio_huc avevano OGNUNO la propria
// copia interna di rom_even/rom_odd (32K x 8 ciascuna = 64 KB per catena), e il
// download del top scriveva lo STESSO stream in tutte e due. Ma le due CPU audio
// non girano mai insieme (una e' sempre in pause secondo il set), quindi una
// delle due copie era sempre piena degli stessi byte senza che nessuno la
// leggesse: 64 blocchi M10K su 553 buttati in una fotocopia.
// Misurato nel fit report: ogni meta' di ROM = 32 M10K / 262.144 bit.
//
// Qui la ROM e' UNA sola: la write resta quella del download (identica), la read
// ha l'indirizzo muxato nel top sulla catena attiva (region_us). Il dato va a
// entrambe le catene; quella ferma legge byte che non guarda nessuno.
//
// Una ROM dopo il download e' SOLA LETTURA: nessuno stato, niente savestate,
// niente da desincronizzare. La latenza e' identica a prima (read registrata,
// 1 ck), quindi il comportamento della catena attiva non cambia di un ciclo.
//
module ns_audio_rom
(
	input  wire        clk,

	// Download (dal top: audio_rom_we_lo/hi + waddr/wdata) — identico a prima
	input  wire        we_lo,
	input  wire        we_hi,
	input  wire [15:0] waddr_lo,
	input  wire [15:0] waddr_hi,
	input  wire [7:0]  wdata_lo,
	input  wire [7:0]  wdata_hi,

	// Lettura: indirizzo WORD (= cpu_addr[15:1]) muxato nel top sulla catena attiva
	input  wire [14:0] rd_addr,
	output reg  [7:0]  even_rd,
	output reg  [7:0]  odd_rd
);

(* ramstyle = "M10K", no_rw_check *) reg [7:0] rom_even [0:32767];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] rom_odd  [0:32767];

always @(posedge clk) if (we_lo) rom_even[waddr_lo[15:1]] <= wdata_lo;
always @(posedge clk) if (we_hi) rom_odd [waddr_hi[15:1]] <= wdata_hi;

always @(posedge clk) even_rd <= rom_even[rd_addr];
always @(posedge clk) odd_rd  <= rom_odd [rd_addr];

endmodule
