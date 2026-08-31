/*  This file is part of JT6295.

    JT6295 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

	Author: Jose Tejada Gomez. Twitter: @topapate
	Version: 1.0
	Date: 6-1-2020
	*/
// Modified for BoogieWings savestate (auto_ss instrumentation): Umberto Parisi (rmonic79)

// STAGES must be greater than 2
module jt6295_sh_rst #(parameter WIDTH=5, STAGES=32, RSTVAL=1'b0 )
(
	input					rst,
	input 					clk,
	input					clk_en /* synthesis direct_enable */,
	input		[WIDTH-1:0]	din,
   	output		[WIDTH-1:0]	drop,
	// Savestate (auto_ss, pattern F2 jt12_sh_rst): auto_ss_wr=0 -> trasparente; =1 -> load.
	input		[WIDTH*STAGES-1:0]	auto_ss_in,
	output		[WIDTH*STAGES-1:0]	auto_ss_out,
	input							auto_ss_wr
);

reg [STAGES-1:0] bits[WIDTH-1:0];

// Reset via DATO (din_mx), non via edge: cosi' l'always resta @(posedge clk) puro e lo shift
// register e' ancora inferibile come LUT-SR (ottimizzazione originale). Pattern F2 jt12_sh_rst:
// aggiungere l'auto_ss SENZA rompere l'inferenza richiede di togliere 'posedge rst'.
wire [WIDTH-1:0] din_mx = rst ? {WIDTH{RSTVAL[0]}} : din;

genvar i;
integer k;
generate
initial
	for (k=0; k < WIDTH; k=k+1) begin
		bits[k] = { STAGES{RSTVAL}};
	end
endgenerate

generate
	for (i=0; i < WIDTH; i=i+1) begin: bit_shifter
		always @(posedge clk) begin
			if(clk_en) begin
				bits[i] <= {bits[i][STAGES-2:0], din_mx[i]};
			end
			if(auto_ss_wr) begin            // restore (ultimo = priorita', come modello F2)
				bits[i] <= auto_ss_in[STAGES*i +: STAGES];
			end
		end
		assign drop[i] = rst ? RSTVAL[0] : bits[i][STAGES-1];   // reset su drop (come jt51_sh/F2)
		assign auto_ss_out[STAGES*i +: STAGES] = bits[i];
	end
endgenerate

endmodule
