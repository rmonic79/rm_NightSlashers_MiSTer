// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79).
*/

//
// ns_workram_128k.sv — Night Slashers work RAM.
// 128 KB = 32K x 32-bit, byte-enabled, SINGOLA porta, 1-cycle read latency.
// Maps to 0x100000-0x11FFFF on the ARM bus. M10K-forced.
//
// NB: era stata tentata una porta B dedicata al savestate (true dual-port) per
// tenere il path di gioco senza mux, MA il TDP M10K con byte-enable NON si infera
// su Cyclone V (Quartus 276003: converte in registri -> ~1M FF -> sfora il device).
// Quindi single-port: il savestate condivide la porta via mux nel top (porta e
// savestate mai attivi insieme -> durante SS la CPU e' congelata). Il mux e' ~1 LUT;
// pattern ss_ram16_adaptor di BoogieWings (provato) esteso a 32-bit.
//
module ns_workram_128k
(
	input  wire        clk,
	input  wire [16:0] addr,    // dword index (32K dwords) — muxato gioco/SS nel top
	input  wire        we,
	input  wire [3:0]  be,      // byte enables (SS forza 1111)
	input  wire [31:0] wdata,
	output reg  [31:0] rdata
);
	(* ramstyle = "M10K", no_rw_check *) reg [7:0] b0 [0:32767];
	(* ramstyle = "M10K", no_rw_check *) reg [7:0] b1 [0:32767];
	(* ramstyle = "M10K", no_rw_check *) reg [7:0] b2 [0:32767];
	(* ramstyle = "M10K", no_rw_check *) reg [7:0] b3 [0:32767];

	always @(posedge clk) begin
		if (we) begin
			if (be[0]) b0[addr] <= wdata[7:0];
			if (be[1]) b1[addr] <= wdata[15:8];
			if (be[2]) b2[addr] <= wdata[23:16];
			if (be[3]) b3[addr] <= wdata[31:24];
		end
		rdata <= {b3[addr], b2[addr], b1[addr], b0[addr]};
	end
endmodule
