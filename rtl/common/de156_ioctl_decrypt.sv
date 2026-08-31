// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original algorithm: MAME project (deco156.cpp).
    RTL port: Umberto Parisi (rmonic79)
*/

//
// de156_ioctl_decrypt.sv
// Transparent wrapper on the ioctl stream that decrypts the DE156 maincpu ARM
// ROM DURING DOWNLOAD, producing the already-decrypted image in SDRAM so the
// bridge stays IDENTICAL (reads plain ROM).
//
// The DE156 decrypt is PER-DWORD (32-bit). The download stream delivers the
// physical image as consecutive 16-bit halves:
//   physical dword s: byte addr s*4+0 = low half [15:0], s*4+2 = high half [31:16].
// The two halves of a dword arrive in consecutive ioctl_wr cycles
// (ioctl_addr_in[1] selects the half, 0=low / 1=high; ioctl_addr_in[0]==0).
//
// ADDRESS SCRAMBLE (deco156): the remap is per-dword and the byte-offset bit is
// NOT scrambled. logical dword a = scr_inv(s), affine over GF(2):
//   x = s[15:0] ^ 0x92c6 ;  a[15:0] = XOR_b ( x[b] ? MINV[b] : 0 ) ;
//   a[17:16] = s[17:16] (high bits pass through).  (MINV from gen_scramble_inv.py)
// The decrypted low half goes to logical byte addr a*4+0, the high half to a*4+2;
// only the dword index is remapped, the half-offset bit passes through unchanged.
//
// PACING (de102-proven rule, see de102_ioctl_decrypt.sv lines 124-130): the
// stream must NEVER be gated. We emit EXACTLY one output write per input write
// (ioctl_wr_out = ioctl_wr_in). To do that while the decrypt needs the full
// 32 bits (only available on the high-half cycle), we use a 1-cycle SKID:
//   - on the high-half input cycle  -> emit THIS dword's decrypted LOW  half;
//   - on the next low-half input cycle -> emit the prior dword's decrypted HIGH half.
// Every input strobe carries exactly one valid output write. The only edge case
// is the region's final high half, which strands one register; it is flushed on
// the first non-consecutive / non-main strobe that follows.
//

module de156_ioctl_decrypt
(
	input  wire        clk,
	input  wire [26:0] ioctl_addr_in,
	input  wire [15:0] ioctl_dout_in,
	input  wire        ioctl_wr_in,
	input  wire [15:0] ioctl_index_in,
	input  wire        ioctl_download_in,

	output wire [26:0] ioctl_addr_out,
	output wire [15:0] ioctl_dout_out,
	output wire        ioctl_wr_out,
	output wire [15:0] ioctl_index_out,
	output wire        ioctl_download_out,

	// TIMING 2026-08-10: alto quando questo stadio PILOTA l'uscita, cioe' o siamo
	// nel range main, oppure c'e' una meta' alta appesa da scaricare (il flush che
	// dirotta anche uno strobe di ALTRA regione). Serve al mux a PRIORITA' del
	// download in Template.sv per riprodurre esattamente l'ordine della vecchia
	// cascata in serie. Quando e' basso, out_addr/out_dout = ingresso grezzo.
	output wire        drives_out
);

	// ── maincpu region: index 0, byte range 0x000000..0x0FFFFF (0x40000 dwords) ─
	localparam [26:0] MAIN_BASE = 27'h0000000;
	localparam [26:0] MAIN_END  = 27'h0100000;   // 1 MB

	wire is_rom_dl = ioctl_download_in & (ioctl_index_in == 16'd0);
	// 2026-07-09 decrypt RIATTIVATO dopo la prima luce (bypass provato ok).
	// L'MRA fornisce l'immagine FISICA crittata LINEARE (main_phys_enc.bin,
	// stessa del TB 0/524288): niente interleave = niente incognita map.
	wire is_main   = is_rom_dl
	               & (ioctl_addr_in >= MAIN_BASE)
	               & (ioctl_addr_in <  MAIN_END);

	// physical dword index s = addr[19:2]; half = addr[1] (0=low,1=high)
	wire [17:0] s        = ioctl_addr_in[19:2];
	wire        half_hi  = ioctl_addr_in[1];

	// ── Inverse affine scramble: a = scr_inv(s) (combinational, GF(2) XORs) ────
	// a[15:0] = MINV * (s[15:0] ^ 0x92c6) ; a[17:16] = s[17:16] passthrough.
	wire [15:0] x = s[15:0] ^ 16'h92c6;
	wire [15:0] a_lo =
		({16{x[ 0]}} & 16'hde2f) ^ ({16{x[ 1]}} & 16'h23ea) ^
		({16{x[ 2]}} & 16'h18f5) ^ ({16{x[ 3]}} & 16'h6c0f) ^
		({16{x[ 4]}} & 16'hbe7e) ^ ({16{x[ 5]}} & 16'h8f70) ^
		({16{x[ 6]}} & 16'h800e) ^ ({16{x[ 7]}} & 16'haffc) ^
		({16{x[ 8]}} & 16'hb3f1) ^ ({16{x[ 9]}} & 16'h9e07) ^
		({16{x[10]}} & 16'h0091) ^ ({16{x[11]}} & 16'h3fbb) ^
		({16{x[12]}} & 16'hc890) ^ ({16{x[13]}} & 16'h7361) ^
		({16{x[14]}} & 16'h31c1) ^ ({16{x[15]}} & 16'h5f06);
	wire [17:0] a = {s[17:16], a_lo};

	// logical byte address of the dword (low half): base + a*4
	wire [26:0] a_byte = MAIN_BASE + {7'd0, a, 2'b00};

	// ── DE156 per-dword data decrypt ───────────────────────────────────────────
	// 16 conditional XORs on bits of a, then a[1:0]-selected XOR + bitswap.
	function [31:0] bswap0(input [31:0] d);
		bswap0 = {d[1],d[4],d[7],d[28],d[22],d[18],d[20],d[9],d[16],d[10],d[30],d[2],d[31],d[24],d[19],d[29],d[6],d[21],d[23],d[11],d[12],d[13],d[5],d[0],d[8],d[26],d[27],d[15],d[14],d[17],d[25],d[3]};
	endfunction
	function [31:0] bswap1(input [31:0] d);
		bswap1 = {d[14],d[23],d[28],d[29],d[6],d[24],d[10],d[1],d[5],d[16],d[7],d[2],d[30],d[8],d[18],d[3],d[31],d[22],d[25],d[20],d[17],d[0],d[19],d[27],d[9],d[12],d[21],d[15],d[26],d[13],d[4],d[11]};
	endfunction
	function [31:0] bswap2(input [31:0] d);
		bswap2 = {d[19],d[30],d[21],d[4],d[2],d[18],d[15],d[1],d[12],d[25],d[8],d[0],d[24],d[20],d[17],d[23],d[22],d[26],d[28],d[16],d[9],d[27],d[6],d[11],d[31],d[10],d[3],d[13],d[14],d[7],d[29],d[5]};
	endfunction
	function [31:0] bswap3(input [31:0] d);
		bswap3 = {d[30],d[6],d[15],d[0],d[31],d[18],d[26],d[22],d[14],d[23],d[19],d[17],d[10],d[8],d[11],d[20],d[1],d[28],d[2],d[4],d[9],d[24],d[25],d[27],d[7],d[21],d[13],d[29],d[5],d[3],d[16],d[12]};
	endfunction

	function [31:0] data_decrypt(input [31:0] dword, input [17:0] aa);
		reg [31:0] v;
		begin
			v = dword;
			if (aa & 18'h00004) v = v ^ 32'h04400000;
			if (aa & 18'h00008) v = v ^ 32'h40000004;
			if (aa & 18'h00010) v = v ^ 32'h00048000;
			if (aa & 18'h00020) v = v ^ 32'h00000280;
			if (aa & 18'h00040) v = v ^ 32'h00200040;
			if (aa & 18'h00080) v = v ^ 32'h09000000;
			if (aa & 18'h00100) v = v ^ 32'h00001100;
			if (aa & 18'h00200) v = v ^ 32'h20002000;
			if (aa & 18'h00400) v = v ^ 32'h00000022;
			if (aa & 18'h00800) v = v ^ 32'h000a0000;
			if (aa & 18'h01000) v = v ^ 32'h10004000;
			if (aa & 18'h02000) v = v ^ 32'h00010400;
			if (aa & 18'h04000) v = v ^ 32'h80000010;
			if (aa & 18'h08000) v = v ^ 32'h00000009;
			if (aa & 18'h10000) v = v ^ 32'h02100000;
			if (aa & 18'h20000) v = v ^ 32'h00800800;
			case (aa[1:0])
				2'd0: data_decrypt = bswap0(v ^ 32'hec63197a);
				2'd1: data_decrypt = bswap1(v ^ 32'h58a5a55f);
				2'd2: data_decrypt = bswap2(v ^ 32'he3a65f16);
				2'd3: data_decrypt = bswap3(v ^ 32'h28d93783);
			endcase
		end
	endfunction

	// ── Skid holding registers ─────────────────────────────────────────────────
	reg [15:0] raw_lo_r;     // raw low 16 bits captured on the Lo cycle
	reg [15:0] dec_hi_r;     // decrypted high half, to emit on the NEXT Lo cycle
	reg [26:0] addr_hi_r;    // logical byte addr for that pending high half (a*4+2)
	reg        hi_pending_r; // 1 while a decrypted high half awaits emission

	// On the high-half cycle the full dword is available -> decrypt now.
	wire [31:0] dword_full = {ioctl_dout_in, raw_lo_r};
	wire [31:0] dec_full   = data_decrypt(dword_full, a);

	// Does the current strobe continue the pending dword's stream?
	// The pending high half belongs to dword (addr_hi_r-2-MAIN_BASE)/4; it is the
	// "previous" dword whose low strobe is the current Lo cycle of consecutive s.
	// We emit the pending high half on any main Lo cycle, and also flush it on the
	// first non-main strobe that follows (region end / index change / download end).

	// ── Output mux (combinational) ─────────────────────────────────────────────
	reg [26:0] out_addr;
	reg [15:0] out_dout;

	always @(*) begin
		// default: transparent passthrough
		out_addr = ioctl_addr_in;
		out_dout = ioctl_dout_in;

		if (is_main) begin
			if (!half_hi) begin
				// Lo cycle: emit the PREVIOUS dword's decrypted high half (skid).
				if (hi_pending_r) begin
					out_addr = addr_hi_r;
					out_dout = dec_hi_r;
				end else begin
					// boot edge of a region: no pending high yet -> passthrough.
					out_addr = ioctl_addr_in;
					out_dout = ioctl_dout_in;
				end
			end else begin
				// Hi cycle: emit THIS dword's decrypted LOW half.
				out_addr = a_byte;          // a*4 + 0
				out_dout = dec_full[15:0];
			end
		end else begin
			// Non-main strobe: if a region high half is stranded, flush it here.
			if (hi_pending_r) begin
				out_addr = addr_hi_r;
				out_dout = dec_hi_r;
			end
		end
	end

	// ── Register updates on every input write ──────────────────────────────────
	always @(posedge clk) begin
		if (ioctl_wr_in) begin
			if (is_main) begin
				if (!half_hi) begin
					// Lo cycle: capture raw low half; the pending high half (if any)
					// is emitted this cycle, so it is now consumed.
					raw_lo_r     <= ioctl_dout_in;
					hi_pending_r <= 1'b0;
				end else begin
					// Hi cycle: latch decrypted high half for the next Lo cycle.
					dec_hi_r     <= dec_full[31:16];
					addr_hi_r    <= a_byte + 27'd2;   // a*4 + 2
					hi_pending_r <= 1'b1;
				end
			end else begin
				// Non-main strobe consumed any stranded high half (flushed in mux).
				hi_pending_r <= 1'b0;
			end
		end
	end

	// ── 1:1 pacing: NEVER gate the stream (de102 lost-words rule) ──────────────
	assign ioctl_addr_out     = out_addr;
	assign ioctl_dout_out     = out_dout;
	assign ioctl_wr_out       = ioctl_wr_in;
	assign ioctl_index_out    = ioctl_index_in;
	assign ioctl_download_out = ioctl_download_in;
	assign drives_out         = is_main | hi_pending_r;

endmodule
