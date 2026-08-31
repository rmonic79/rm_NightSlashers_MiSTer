// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.

    BoogieWings_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    BoogieWings_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with BoogieWings_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// pause_text.sv — Renderer testo BRAM-based per overlay pause.
//
// Genera un layer di char (font 8x8) su un'area rettangolare dello schermo
// (W_CHARS x H_CHARS char) leggendo da una BRAM init-da-file (.mem).
//
// Modalità:
//   SCROLL_EN=0: testo statico, BRAM contiene esattamente W_CHARS×H_CHARS byte ASCII.
//   SCROLL_EN=1: testo scrolla verticalmente bottom→top, BRAM contiene
//                W_CHARS × MSG_ROWS char ASCII (MSG_ROWS può essere > H_CHARS).
//                Velocità: 1 pixel ogni SCROLL_PERIOD frame.
//
// Output: pixel_on = 1 quando il pixel del char a (render_x, render_y) è acceso.
//         Caller mixa con palette esterna.
//
// Costo BRAM:
//   font_rom: 1024 byte = 1 M10K (condiviso tra istanze tramite parameter FONT_FILE)
//   msg_rom:  W_CHARS × MSG_ROWS byte (1 M10K se < ~4 KB)

module pause_text #(
	parameter        W_CHARS      = 41,           // larghezza area in char (8 px ciascuno)
	parameter        H_CHARS      = 18,           // altezza area visibile in char
	parameter        MSG_ROWS     = 18,           // righe totali nel buffer (>= H_CHARS)
	parameter [9:0]  ORIGIN_X     = 10'd16,       // pixel X dell'angolo top-left
	parameter [8:0]  ORIGIN_Y     = 9'd40,        // pixel Y dell'angolo top-left
	parameter        SCROLL_EN    = 0,            // 0=statico, 1=scroll verticale
	parameter        SCROLL_PERIOD = 3,           // 1 pixel ogni N frame (se SCROLL_EN=1)
	parameter        FONT_FILE    = "logo/font_darius.hex",
	parameter        MSG_FILE     = "logo/links.mem"
) (
	input  wire        clk,
	input  wire        active,        // overlay attivo (pause & ~clean)
	input  wire        vblank_pulse,  // 1 ciclo per frame, per tick scroll

	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,

	// Font ROM condivisa (esterna): questo modulo emette l'indirizzo e riceve la riga.
	output wire [9:0]  font_addr_o,   // {ascii, row} verso la font ROM condivisa
	input  wire [7:0]  font_row_i,    // riga font (8 px) dalla ROM condivisa

	output reg         pixel_on,      // 1 = pixel acceso del char
	output reg  [1:0]  pixel_tier     // tier color (0..3) per il pixel corrente
);

localparam W_PX = W_CHARS * 8;
localparam H_PX = H_CHARS * 8;

// =====================================================================
// Scroll counter: pixel offset verticale (0..MSG_ROWS*8-1, wrap continuo)
// =====================================================================
localparam MSG_PX = MSG_ROWS * 8;
localparam SCRPOSW = $clog2(MSG_PX + 1);

reg [SCRPOSW-1:0] scrpos;
reg [3:0]         scr_div;

always @(posedge clk) begin
	if (!active) begin
		scrpos  <= '0;
		scr_div <= 4'd0;
	end else if (SCROLL_EN && vblank_pulse) begin
		if (scr_div == SCROLL_PERIOD - 1) begin
			scr_div <= 4'd0;
			if (scrpos == MSG_PX - 1)
				scrpos <= '0;
			else
				scrpos <= scrpos + 1'b1;
		end else begin
			scr_div <= scr_div + 4'd1;
		end
	end
end

// =====================================================================
// Read-ahead 1 pixel su render_x per allineare pipeline BRAM
// =====================================================================
wire [9:0] x_ahead = render_x + 10'd1;

// In-bounds check (su pixel ahead)
wire in_area_ahead = active &&
	(x_ahead   >= ORIGIN_X) && (x_ahead   < ORIGIN_X + W_PX) &&
	(render_y  >= ORIGIN_Y) && (render_y  < ORIGIN_Y + H_PX);

// Pixel relativi all'area (0..W_PX-1, 0..H_PX-1)
wire [9:0] dx = x_ahead - ORIGIN_X;
wire [9:0] dy_rel = {1'b0, render_y} - {1'b0, ORIGIN_Y};

// Y effettiva (con scroll wrap)
// SCROLL_EN=1: dy_eff = (dy_rel + scrpos) mod MSG_PX
// SCROLL_EN=0: dy_eff = dy_rel (sempre nel buffer di H_CHARS×8)
wire [SCRPOSW-1:0] dy_sum   = dy_rel[SCRPOSW-1:0] + scrpos;
wire [SCRPOSW-1:0] dy_wrap  = (dy_sum >= MSG_PX) ? (dy_sum - MSG_PX) : dy_sum;
wire [SCRPOSW-1:0] dy_eff   = SCROLL_EN ? dy_wrap : dy_rel[SCRPOSW-1:0];

// Char column / pixel column (within char)
wire [$clog2(W_CHARS+1)-1:0] char_col = dx[$clog2(W_CHARS*8+1)-1:3];
wire [2:0]                    pix_col = dx[2:0];

// Char row / pixel row (within char)
wire [$clog2(MSG_ROWS+1)-1:0] char_row = dy_eff[SCRPOSW-1:3];
wire [2:0]                    pix_row = dy_eff[2:0];

// =====================================================================
// MSG ROM: W_CHARS × MSG_ROWS word, 9-bit per char (2 bit tier + 7 bit ASCII)
// =====================================================================
localparam MSG_DEPTH = W_CHARS * MSG_ROWS;
localparam MSG_AW    = $clog2(MSG_DEPTH);

(* ramstyle = "M10K" *) reg [8:0] msg_rom [0:MSG_DEPTH-1];
initial $readmemh(MSG_FILE, msg_rom);

wire [MSG_AW-1:0] msg_addr = char_row * W_CHARS + char_col;
reg  [8:0] msg_q;
always @(posedge clk) msg_q <= msg_rom[msg_addr];

wire [1:0] msg_tier  = msg_q[8:7];
wire [6:0] msg_ascii = msg_q[6:0];

// =====================================================================
// FONT ROM CONDIVISA (esterna, 1 M10K per tutto il pause overlay).
// Questo modulo emette font_addr_o e riceve font_row_i (registrata dalla ROM).
// =====================================================================
// pix_row deve essere ritardato 1 ciclo per allinearsi con msg_q
reg [2:0] pix_row_d;
reg [2:0] pix_col_d;
reg       in_area_d;
always @(posedge clk) begin
	pix_row_d <= pix_row;
	pix_col_d <= pix_col;
	in_area_d <= in_area_ahead;
end

assign font_addr_o = {msg_ascii, pix_row_d};
wire [7:0] font_row = font_row_i;   // riga font gia' registrata dalla ROM condivisa
reg  [1:0] tier_d;
always @(posedge clk) begin
	tier_d   <= msg_tier;
end

// pix_col va ritardato di 2 cicli totali (msg_q→font_addr→font_row)
reg [2:0] pix_col_dd;
reg       in_area_dd;
reg [1:0] tier_dd;
always @(posedge clk) begin
	pix_col_dd <= pix_col_d;
	in_area_dd <= in_area_d;
	tier_dd    <= tier_d;
end

// Output: bit pix_col_dd del font_row corrente, gated da in_area
always @(posedge clk) begin
	pixel_on   <= in_area_dd && font_row[7 - pix_col_dd];
	pixel_tier <= tier_dd;
end

endmodule
