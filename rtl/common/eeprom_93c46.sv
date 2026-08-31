// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Author: Umberto Parisi (rmonic79)
*/

//
// eeprom_93c46.sv — Serial EEPROM 93C46 (16-bit org), Microwire. Per Night Slashers.
//
// 64 word x 16 bit. Comando = start(1) + opcode(2) + addr(6) [+ data(16) WRITE].
//   opcode 10=READ, 01=WRITE, 11=ERASE, 00=EWEN/EWDS (per addr[5:4]).
//   READ: dopo 9 bit comando, shifta OUT 1 dummy 0 + 16 bit dato (MSB first) su DO.
//   WRITE: dopo 9 bit comando, raccoglie 16 bit dato poi scrive (se write enable).
//   Dopo WRITE/ERASE: il 93C46 con CS rialzato segnala DO=ready(1) (write-cycle istantaneo).
//
// Pilotaggio (MAME deco32.cpp eeprom_w): cs/clk/di = 0x150000 bit 6/5/4. DO -> port_b bit0.
// NS parte VERGINE -> mem init 0xFFFF. Struttura FSM (start/op/addr separati) come il modello
// TB che superava la READ init; + gestione busy/ready post-write per il poll WRITE del firmware.
//

module eeprom_93c46
(
	input  wire clk,
	input  wire reset,
	input  wire cs,            // chip select (0x150000 bit6)
	input  wire sk,            // serial clock (0x150000 bit5)
	input  wire di,            // serial data in (0x150000 bit4)
	output wire dout,          // serial data out -> port_b bit0

	// DIP dall'MRA (dsw_port, ioctl index 254). Durante il reset il blocco
	// settings viene INIETTATO in mem[] (formato + checksum del firmware,
	// algoritmo estratto da 0x3e9a8 e validato bit-exact sul golden):
	// il gioco al boot trova un blocco valido coi valori scelti in OSD.
	// [2:0] lives-1 (raw 0-4 = 1-5 vite)   [3] screen rotation
	// [4] start=shot  [5] attract sound    [6] free play
	// [7] 2 coin credit  [8] credit counter individual
	// [11:9] difficulty 0-7   [13:12] life value 0-2   [14] 3p simultaneous
	// [15]=shot (via Player Number bits 14,15).  dip = solo DIP standard (index 254).
	input  wire [15:0] dip,
	// SET SELECT (dal mod byte MRA index=1, NON dai DIP): robusto, Korea non lo tocca.
	input  wire        region_xm,   // 0=Korea (marker "OC"), 1=Japan/Overseas ("XM")
	input  wire        violence     // Violence ON (jap/overseas); su Korea sempre 0
);

	reg [15:0] mem [0:63];
	integer i;
	initial for (i=0;i<64;i=i+1) mem[i] = 16'hFFFF;

	// ── Blocco settings generato dai DIP ────────────────────────────────────
	// word0: {2'b11, counter, 2coin, freeplay, attract, shot, rotation, 5'b0, lives}
	// word1: {6'b0, lifeval, 5'b0, difficulty}   word2: {7'b0, 3p, 8'b0}
	// word4 = 0x5000 (volume 80 fisso)  word10/11 = marker "02" + region
	// checksum (0x3e9a8): sum = somma dei 64 BYTE del blocco con chk1=FFFF e
	// chk2=0000 precaricati (= somma byte utili + 0x1FE), mask 16 bit;
	// word1E = sum byte-swapped; word1F = {FF-sum[15:8], FF-sum[7:0]}.
	// Costante 0x342 = 0x1FE + byte marker (30+32+4f+43=F4) + volume (50).
	//
	// REGION (input dal mod byte MRA): marker word11 = Korea "OC"(0x4f43), Jap/Ovs "XM"(0x584d).
	// Il marker entra nel checksum: XM -> costante 0x342 -> 0x355.
	wire [15:0] gen_mark11 = region_xm ? 16'h584d : 16'h4f43;
	wire [15:0] gen_ck_const = region_xm ? 16'h0355 : 16'h0342;
	wire [2:0]  dip_lraw  = dip[2:0];
	wire [2:0]  gen_lives = (dip_lraw > 3'd4) ? 3'd5 : (dip_lraw + 3'd1);
	wire [1:0]  gen_lval  = (dip[13:12] == 2'd3) ? 2'd2 : dip[13:12];
	// shot (start=Attack button) rimappato da dip[4] a dip[15]: cosi' l'MRA puo'
	// accoppiarlo a Players (bit14) in una voce DIP unica "Player Selection" con
	// bit adiacenti (14,15), forzando Shot in 3P e mostrandolo allineato nell'OSD.
	wire [15:0] gen_w0 = {2'b11, dip[8], dip[7], dip[6], dip[5], dip[15], dip[3], 5'b00000, gen_lives};
	wire [15:0] gen_w1 = {6'd0, gen_lval, 5'd0, dip[11:9]};
	wire [15:0] gen_w2 = {7'd0, dip[14], 8'd0};
	// Violence (jap/ovs): word4 BIT0 (Soft=0, Hard=1). Provato: jap default=0x5001 (Hard/gore),
	// overseas=0x5000 (Soft). Il byte ALTO di word4 e' il volume (0x50=80), NON Violence.
	// Su Korea (region OC) = 0. word4 = volume 0x5000 | violence(bit0).
	wire        gen_viol = region_xm & violence;
	wire [15:0] gen_w4 = {8'b01010000, 7'b0000000, gen_viol};
	wire [15:0] gen_sum = {8'd0, gen_w0[15:8]} + {8'd0, gen_w0[7:0]}
	                    + {8'd0, gen_w1[15:8]} + {8'd0, gen_w1[7:0]}
	                    + {8'd0, gen_w2[15:8]} + gen_ck_const + {15'd0, gen_viol};
	wire [15:0] gen_chk1 = {gen_sum[7:0], gen_sum[15:8]};
	wire [15:0] gen_chk2 = {8'hFF - gen_sum[15:8], 8'hFF - gen_sum[7:0]};

	reg  [5:0]  init_idx;          // sweep 0..63 durante il reset (blocco + specchio)
	reg  [15:0] gen_w;
	always @* begin
		case (init_idx[4:0])
			5'h00:   gen_w = gen_w0;
			5'h01:   gen_w = gen_w1;
			5'h02:   gen_w = gen_w2;
			5'h04:   gen_w = gen_w4;
			5'h10:   gen_w = 16'h3032;
			5'h11:   gen_w = gen_mark11;
			5'h1E:   gen_w = gen_chk1;
			5'h1F:   gen_w = gen_chk2;
			default: gen_w = 16'h0000;
		endcase
	end

	reg sk_d;
	always @(posedge clk) sk_d <= sk;
	wire sk_rise = sk & ~sk_d;

	// state: 0=idle/start, 1=opcode(2 bit), 2=addr(6 bit), 3=data-read, 4=data-write
	reg [2:0]  state;
	reg [3:0]  bitcnt;
	reg [1:0]  op;
	reg [5:0]  addr;
	reg [15:0] sr;            // shift register in/out
	reg        wen;           // write enable (EWEN/EWDS)
	reg        do_r;          // DO durante READ
	reg        reading;       // 1 = comando READ in corso (copre tutti i 16 bit, incl. l'ultimo)

	// DO: durante una READ (reading) = do_r; altrimenti ready(1).
	// `reading` resta alto fino a fine sessione (CS basso) o nuovo comando: cosi' l'ULTIMO
	// bit dati (16o) non viene mascherato a ready quando lo stato interno torna a idle.
	// Il firmware (sub_3E7A4) legge DO DOPO il fronte di clock -> serve do_r valido fino
	// a dopo l'ultimo bit. Il busy-poll WRITE (reading=0) vede ready=1 -> immune perdita edge.
	assign dout = (cs && reading) ? do_r : 1'b1;

	always @(posedge clk) begin
		if (reset) begin
			state <= 0; bitcnt <= 0; do_r <= 1'b1; reading <= 1'b0; wen <= 1'b0;
			// INIEZIONE DIP: durante il reset (>=64 clk garantiti dal reset-hold
			// del Template) sweep 0..63 scrive blocco settings + specchio.
			mem[init_idx] <= gen_w;
			init_idx <= init_idx + 6'd1;
		end else if (!cs) begin
			// CS basso = fine sessione comando. reading si azzera (DO torna ready al prossimo CS alto).
			state <= 0; bitcnt <= 0; do_r <= 1'b1; reading <= 1'b0;
		end else if (sk_rise) begin
			case (state)
				0: if (di) begin state <= 1; bitcnt <= 0; reading <= 1'b0; end  // start bit (nuovo comando)
				1: begin                                   // opcode (2 bit MSB-first)
					op <= {op[0], di}; bitcnt <= bitcnt + 1'b1;
					if (bitcnt == 4'd1) begin state <= 2; bitcnt <= 0; end
				end
				2: begin                                   // addr (6 bit MSB-first)
					addr <= {addr[4:0], di}; bitcnt <= bitcnt + 1'b1;
					if (bitcnt == 4'd5) begin
						bitcnt <= 0;
						case ({op[1], op[0]})
							2'b10: begin                       // READ
								sr      <= mem[{addr[4:0], di}];
								do_r    <= 1'b0;               // leading dummy 0
								reading <= 1'b1;               // DO=do_r per tutti i 16 bit (incl. ultimo)
								state   <= 3;
							end
							2'b01: begin                       // WRITE (addr completo = {addr[4:0],di})
								addr  <= {addr[4:0], di};
								sr    <= 16'd0;
								state <= 4;
							end
							2'b11: begin                       // ERASE
								if (wen) mem[{addr[4:0], di}] <= 16'hFFFF;
								state <= 0;
							end
							2'b00: begin                       // EWEN/EWDS per addr[5:4]
								wen <= addr[4];                // EWEN se addr[5:4]=11 -> addr[4]=1
								state <= 0;
							end
						endcase
					end
				end
				3: begin                                   // READ: shift out 16 bit
					do_r <= sr[15]; sr <= {sr[14:0], 1'b0}; bitcnt <= bitcnt + 1'b1;
					if (bitcnt == 4'd15) state <= 0;       // reading RESTA alto -> ultimo bit non mascherato
				end
				4: begin                                   // WRITE: shift in 16 bit dato
					sr <= {sr[14:0], di}; bitcnt <= bitcnt + 1'b1;
					if (bitcnt == 4'd15) begin
						if (wen) mem[addr] <= {sr[14:0], di};
						state <= 0;
					end
				end
			endcase
		end
	end

endmodule
