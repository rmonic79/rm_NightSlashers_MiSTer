// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

// pause_font.sv — font ROM 8x8 CONDIVISA (1 M10K) per il pause overlay.
// Istanziata UNA volta sola nel pause_overlay e servita a entrambi i pause_text
// (header + patron) via due porte read indipendenti (M10K dual-port), cosi' il
// font NON e' duplicato (2 M10K -> 1) e non ruba M10K al pool audio OKI.

module pause_font #(
	parameter FONT_FILE = "logo/font_darius.hex"
) (
	input  wire       clk,
	input  wire [9:0] addr_a,   // {ascii, row} istanza A (header)
	output reg  [7:0] q_a,
	input  wire [9:0] addr_b,   // {ascii, row} istanza B (patron)
	output reg  [7:0] q_b
);

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] font_rom [0:1023];
initial $readmemh(FONT_FILE, font_rom);

always @(posedge clk) begin
	q_a <= font_rom[addr_a];
	q_b <= font_rom[addr_b];
end

endmodule
