// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Darius_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// rom_cache — Instruction cache direct-mapped per CPU ROM.
// 512 entry × 16-bit: hit in 1 ciclo vs 7+ cicli da SDRAM.
// Sta tra il CPU ROM port e l'sdram_bridge. Su miss fa fetch da SDRAM,
// riempie la cache e restituisce il dato. Riduce la latenza del fetch
// del Main 68K.
//
// 512 entries × (15-bit tag + 16-bit data + 1 valid) = ~16 Kbit = 2 M10K
// Index: byte_addr[10:2] (word addr [9:1])
// Tag:   byte_addr[23:11] (word addr [23:10])

module rom_cache #(
	parameter CACHE_BITS = 9  // 2^9 = 512 entries
)
(
	input  wire        clk,
	input  wire        reset,

	// CPU side (from maincpu_map)
	input  wire [23:0] cpu_addr,     // byte address
	input  wire        cpu_req,      // rising edge = new request
	output reg  [15:0] cpu_data,
	output reg         cpu_ready,    // pulse when data valid

	// SDRAM side (to sdram_bridge)
	output reg  [23:0] sdram_addr,
	output reg         sdram_req,    // rising edge = new request
	input  wire [15:0] sdram_data,
	input  wire        sdram_ready,  // pulse when data valid
	// Debug
	output wire [1:0]  dbg_state
);

// Fix #34: reverted rom_cache to Darius 1 logic (combinatorial idx, no S_WAIT).
// The Darius 2 variant with pending_idx + S_WAIT was introduced to "fix" a
// back-to-back fetch race that in Darius 1 doesn't actually exist — and it
// introduced a new hazard on MISS fill: writing cache_data[pending_idx] while
// `rd_data <= cache_data[pending_idx]` samples on the same cycle (no_rw_check
// returns garbage). This corrupted instruction fetch during the $12B54 memtest
// on Darius 2 ROM → CPU mis-executed the compare → rescue loop $12BC2.
// Darius 1 version is proven in production.
localparam ENTRIES = 1 << CACHE_BITS;
localparam TAG_BITS = 23 - CACHE_BITS;  // word addr is [23:1], index is [CACHE_BITS:1]

// Cache storage
(* ramstyle = "M10K,no_rw_check" *) reg [15:0]          cache_data [0:ENTRIES-1];
(* ramstyle = "M10K,no_rw_check" *) reg [TAG_BITS-1:0]  cache_tag  [0:ENTRIES-1];
reg [ENTRIES-1:0] cache_valid;

// Address decomposition (word address)
wire [22:0]          word_addr = cpu_addr[23:1];
wire [CACHE_BITS-1:0] idx     = word_addr[CACHE_BITS-1:0];
wire [TAG_BITS-1:0]   tag     = word_addr[22:CACHE_BITS];

// Registered cache read on COMBINATIONAL idx (D1 logic).
// Address_A of BRAM is always `idx` (current bus addr). When state enters
// S_IDLE→pending_idx<=idx, the read issued at that cycle is already for `idx`
// which is `pending_idx` value for the next cycle → rd_* stable in S_CHECK.
reg [15:0]         rd_data;
reg [TAG_BITS-1:0] rd_tag;
reg                rd_valid;

always @(posedge clk) begin
	rd_data  <= cache_data[idx];
	rd_tag   <= cache_tag[idx];
	rd_valid <= cache_valid[idx];
end

// FSM — 2 cycles (IDLE, CHECK) with optional MISS path.
localparam S_IDLE    = 2'd0;
localparam S_CHECK   = 2'd1;
localparam S_MISS    = 2'd2;
localparam S_FILL    = 2'd3;

reg  [1:0]  state;
assign dbg_state = state;
reg         req_prev;
reg [22:0]  pending_word_addr;
reg [TAG_BITS-1:0] pending_tag;
reg [CACHE_BITS-1:0] pending_idx;

always @(posedge clk) begin
	cpu_ready  <= 1'b0;
	sdram_req  <= 1'b0;

	if (reset) begin
		state       <= S_IDLE;
		req_prev    <= 0;
		cache_valid <= {ENTRIES{1'b0}};
	end else begin
		req_prev <= cpu_req;

		case (state)
			S_IDLE: begin
				// Detect rising edge of cpu_req
				if (cpu_req && !req_prev) begin
					// Latch address and start cache lookup
					pending_word_addr <= word_addr;
					pending_tag       <= tag;
					pending_idx       <= idx;
					state             <= S_CHECK;
				end
			end

			S_CHECK: begin
				// Cache read results available (1 cycle BRAM latency)
				if (rd_valid && rd_tag == pending_tag) begin
					// HIT — return cached data immediately
					cpu_data  <= rd_data;
					cpu_ready <= 1'b1;
					state     <= S_IDLE;
				end else begin
					// MISS — fetch from SDRAM
					sdram_addr <= {pending_word_addr, 1'b0};  // back to byte address
					sdram_req  <= 1'b1;
					state      <= S_MISS;
				end
			end

			S_MISS: begin
				// Wait for SDRAM response
				if (sdram_ready) begin
					// Fill cache and return data
					cache_data[pending_idx]  <= sdram_data;
					cache_tag[pending_idx]   <= pending_tag;
					cache_valid[pending_idx] <= 1'b1;
					cpu_data  <= sdram_data;
					cpu_ready <= 1'b1;
					state     <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
