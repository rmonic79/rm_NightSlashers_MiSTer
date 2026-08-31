//
// sdram_sorgelig.sv  (REFERENCE ONLY — non viene compilato nel build)
//
// Modulo originale `sdram` di Sorgelig, mantenuto qui solo come riferimento
// di confronto vs `sdram_bank.sv` (il nostro modulo multiporta + burst).
// Il modulo è stato rinominato `sdram_sorgelig` per evitare collisione nomi
// se mai venisse incluso per errore.
//
// Per usarlo nel build: ripristinarlo in rtl/ e ripristinare `module sdram`.
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram_sorgelig
(

	// interface to the MT48LC16M16 chip
	inout      [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,
	output            ready,      // high when init complete (MODE_NORMAL)

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz
	input       [1:0] prio_mode,	// 00=RR equal, 01=video first, 10=CPU first, 11=video 75%

	input      [24:1] addr0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [15:0] dout0,
	input             req0,
	output reg        ack0 = 0,
	
	input      [24:1] addr1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [15:0] dout1,
	input             req1,
	output reg        ack1 = 0,
	
	input      [24:1] addr2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [15:0] dout2,
	input             req2,
	output reg        ack2 = 0,

	input      [24:1] addr3,
	input             wrl3,
	input             wrh3,
	input      [15:0] din3,
	output     [15:0] dout3,
	input             req3,
	output reg        ack3 = 0
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@96MHz (10.4ns/cycle)
localparam BURST_LENGTH   = 3'd0; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd3; // 3 for robust timing on real hardware
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

localparam STATE_IDLE  = 3'd0;             // state to check the requests
localparam STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam STATE_READY = STATE_CONT+CAS_LATENCY+1'd1;
localparam STATE_LAST  = STATE_READY;      // last state in cycle

reg  [2:0] state = 0;
reg [22:1] a;
reg [15:0] data;
reg        we;

// Forward declarations needed for ModelSim
localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;
reg [1:0] mode = MODE_RESET;
reg [12:0] reset = 13'h1fff;
reg  [1:0] ba = 0;
reg  [1:0] dqm;
reg        active = 0;
reg  [3:0] ram_req = 0;
reg  [1:0] next_port = 0;  // round-robin: 0-3
wire [3:0] wr = {wrl3|wrh3,wrl2|wrh2,wrl1|wrh1,wrl0|wrh0};

reg [15:0] dout;


assign dout0 = dout;
assign dout1 = dout;
assign dout2 = dout;
assign dout3 = dout;


// access manager
always @(posedge clk) begin
	reg [9:0] rfs_cnt;
	reg rfs, rfs2;
	
	rfs_cnt <= rfs_cnt + 1'd1;
	if (rfs_cnt == 850) begin
		rfs <= 1;
		rfs_cnt <= 0;
	end

	if (rfs_cnt == 425) rfs2 <= 1;
	
	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		if (rfs) begin
			rfs <= 0;
			rfs2 <= 0;
			rfs_cnt <= 0;
			we <= 0;
			dqm <= 2'b00;
			active <= 0;
			state <= STATE_START;
		end
		else begin : rr_arb
			// Priority-selectable arbitration via prio_mode[1:0]
			reg p0, p1, p2, p3;
			reg granted;
			p0 = (ack0 != req0);
			p1 = (ack1 != req1);
			p2 = (ack2 != req2);
			p3 = (ack3 != req3);
			granted = 0;

			case (prio_mode)
			2'd0: begin
				// MODE 0: Round-robin ports 0-2, port 3 on idle only
				if (next_port == 2'd0 ? p0 : next_port == 2'd1 ? p1 : p2) begin
					case (next_port)
						2'd0: begin {ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1; end
						2'd1: begin {ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1; end
						default: begin {ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1; end
					endcase
					next_port <= (next_port == 2'd2) ? 2'd0 : next_port + 2'd1;
					granted = 1;
				end
				else if (next_port == 2'd0 ? p1 : next_port == 2'd1 ? p2 : p0) begin
					case (next_port)
						2'd0: begin {ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1; next_port <= 2'd2; end
						2'd1: begin {ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1; next_port <= 2'd0; end
						default: begin {ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1; next_port <= 2'd1; end
					endcase
					granted = 1;
				end
				else if (next_port == 2'd0 ? p2 : next_port == 2'd1 ? p0 : p1) begin
					case (next_port)
						2'd0: begin {ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1; next_port <= 2'd0; end
						2'd1: begin {ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1; next_port <= 2'd1; end
						default: begin {ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1; next_port <= 2'd2; end
					endcase
					granted = 1;
				end
				else if (p3) begin
					{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
					granted = 1;
				end
			end

			2'd1: begin
				// MODE 1: Video first — port 0 always wins, then RR 1-2, port 3 last
				if (p0) begin
					{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
					granted = 1;
				end
				else if (p1) begin
					{ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1;
					granted = 1;
				end
				else if (p2) begin
					{ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1;
					granted = 1;
				end
				else if (p3) begin
					{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
					granted = 1;
				end
			end

			2'd2: begin
				// MODE 2: CPU first — ports 1,2 priority, then port 0, port 3 last
				if (p1) begin
					{ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1;
					granted = 1;
				end
				else if (p2) begin
					{ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1;
					granted = 1;
				end
				else if (p0) begin
					{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
					granted = 1;
				end
				else if (p3) begin
					{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
					granted = 1;
				end
			end

			2'd3: begin
				// MODE 3: Video 75% — port 0 gets 3 of every 4 slots, others share the 4th
				if (next_port != 2'd2 && p0) begin
					// Slots 0,1,2 of 4: video priority
					{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
					next_port <= (next_port == 2'd2) ? 2'd0 : next_port + 2'd1;
					granted = 1;
				end
				else begin
					// Slot 3 of 4 (or video idle): RR among ports 1,2,3
					if (p1) begin
						{ba,a} <= addr1; data <= din1; we <= wr[1]; dqm <= wr[1] ? ~{wrh1,wrl1} : 2'b00; ram_req[1] <= 1;
						granted = 1;
					end
					else if (p2) begin
						{ba,a} <= addr2; data <= din2; we <= wr[2]; dqm <= wr[2] ? ~{wrh2,wrl2} : 2'b00; ram_req[2] <= 1;
						granted = 1;
					end
					else if (p3) begin
						{ba,a} <= addr3; data <= din3; we <= wr[3]; dqm <= wr[3] ? ~{wrh3,wrl3} : 2'b00; ram_req[3] <= 1;
						granted = 1;
					end
					else if (p0) begin
						// Even in slot 3, serve video if nothing else wants it
						{ba,a} <= addr0; data <= din0; we <= wr[0]; dqm <= wr[0] ? ~{wrh0,wrl0} : 2'b00; ram_req[0] <= 1;
						granted = 1;
					end
					next_port <= 2'd0;  // reset counter
				end
			end
			endcase

			if (granted) begin
				active <= 1; rfs <= rfs2; state <= STATE_START;
			end
		end
	end

	if(state == STATE_READY && ram_req) begin
		dout <= SDRAM_DQ;
		active <= 0;
		ram_req <= 0;
		if (ram_req[0]) ack0 <= req0;
		else if (ram_req[1]) ack1 <= req1;
		else if (ram_req[2]) ack2 <= req2;
		else if (ram_req[3]) ack3 <= req3;
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
end


// initialization
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 13'd4800; // ~100us at 48MHz (4800 * 8 clk = 38400 cycles)
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 13'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

assign ready = (mode == MODE_NORMAL) && (reset == 0);

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
reg [15:0] sdram_dq_out;
reg        sdram_dq_oe;
assign SDRAM_DQ = sdram_dq_oe ? sdram_dq_out : 16'hZZZZ;

always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? ba : 2'b00;

	sdram_dq_oe <= 1'b0;
	casex({active,we,mode,state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= active ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE; sdram_dq_out <= data; sdram_dq_oe <= 1'b1; end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	if(mode == MODE_NORMAL) begin
		casex(state)
			STATE_START: SDRAM_A <= a[13:1];
			STATE_CONT:  SDRAM_A <= {dqm, 2'b10, a[22:14]};
		endcase
	end
	else if(mode == MODE_LDM && state == STATE_START) SDRAM_A <= MODE;
	else if(mode == MODE_PRE && state == STATE_START) SDRAM_A <= 13'b0010000000000;
	else SDRAM_A <= 0;
end

`ifdef SIMULATION
assign SDRAM_CLK = ~clk;
`else
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);
`endif

endmodule
