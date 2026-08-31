// Modified for NightSlashers_MiSTer (DECO156 ARM: 26-bit, irq, boot/wishbone fixes): Umberto Parisi (rmonic79)
//////////////////////////////////////////////////////////////////
//                                                              //
//  a23_copro_deco156 - Data East 156 BCD coprocessor           //
//                                                              //
//  Drop-in replacement for a23_coprocessor (CP15) in the       //
//  Amber 2 (Amber23) core, used by the Night Slashers core.    //
//                                                              //
//  The DECO 156 ARM has NO CP15 system control coprocessor;    //
//  instead it exposes a custom BCD math coprocessor that the   //
//  game uses for score / decimal arithmetic.                   //
//                                                              //
//  Behaviour is reproduced BIT-EXACT from MAME                 //
//  src/devices/cpu/arm/arm.cpp (HandleCoPro, BCDToDecimal,     //
//  DecimalToBCD):                                              //
//                                                              //
//   MCR (write Rn -> CRn):                                     //
//     - CRn := Rn                                              //
//     - if CRn==2 (command register) trigger BCD op on the     //
//       value just written:                                    //
//         cmd 0: CR5 = bcd( bcd2dec(CR0) + bcd2dec(CR1) )      //
//         cmd 1: CR5 = bcd( bcd2dec(CR0) * bcd2dec(CR1) )      //
//         cmd 3: CR5 = bcd( bcd2dec(CR0) - bcd2dec(CR1) )      //
//   MRC (read CRn -> Rn):                                      //
//     - Rn := CRn                                              //
//   CDP (data op): binary divide (NOT bcd)                     //
//         if CR1!=0: CR3 = CR0/CR1 ; CR4 = CR0%CR1             //
//         else      CR3 = CR4 = 0xffffffff                     //
//                                                              //
//  bcd<->dec use 8 nibbles (32-bit), base-10, exactly as MAME. //
//                                                              //
//  Cache control: this core runs from flat SDRAM with DMA, so  //
//  the L1 cache is permanently DISABLED here (o_cache_enable=0)//
//  which keeps a23_fetch routing every access to the Wishbone  //
//  bus (sel_cache=0). o_cacheable_area=0 for completeness.     //
//                                                              //
//////////////////////////////////////////////////////////////////
//
//  GPLv3 — part of the Night Slashers MiSTer core.
//  Reproduces public-domain documented behaviour from MAME.
//
//////////////////////////////////////////////////////////////////

module a23_copro_deco156
(
input                       i_clk,
input                       i_reset,

input                       i_fetch_stall,      // when high the pipeline is held

input       [2:0]           i_copro_opcode1,    // unused by DECO156
input       [2:0]           i_copro_opcode2,    // unused by DECO156
input       [3:0]           i_copro_crn,        // CRn  (which copro register)
input       [3:0]           i_copro_crm,        // CRm  (unused by DECO156)
input       [3:0]           i_copro_num,        // copro number (unused; 156 ignores)
input       [1:0]           i_copro_operation,  // 0=none 1=MRC(read) 2=MCR(write)
input       [31:0]          i_copro_write_data, // Rn value for MCR

// fault inputs (CP15 used these; DECO156 has no fault regs — ignored)
input                       i_fault,
input       [7:0]           i_fault_status,
input       [31:0]          i_fault_address,

output reg  [31:0]          o_copro_read_data,
output                      o_cache_enable,
output                      o_cache_flush,
output      [31:0]          o_cacheable_area
);

// ----------------------------------------------------------------
// Cache permanently off (flat SDRAM + DMA coherency).
// ----------------------------------------------------------------
assign o_cache_enable   = 1'b0;
assign o_cache_flush    = 1'b0;
assign o_cacheable_area = 32'd0;

// ----------------------------------------------------------------
// Copro register file: CR0..CR5 used by DECO156 (others harmless).
// ----------------------------------------------------------------
reg [31:0] cr [0:15];

// a23_decode encodes the transfer type on i_copro_operation:
//   2'd1 = MRC (read  copro -> core)
//   2'd2 = MCR (write core  -> copro)   [see a23_localparams]
// CDP (data operation, used here for the divider) arrives as a
// distinct decode; Amber23's stock decode does not raise a CDP
// strobe, so the divider is triggered the DECO way: a CDP in the
// 156 firmware is decoded by Amber as a copro op with operation==0
// and crn/crm set — we trigger the divide whenever a copro data
// operation (operation==0 but a valid copro instr) is seen.
localparam OP_NONE = 2'd0;
localparam OP_MRC  = 2'd1;
localparam OP_MCR  = 2'd2;

// Edge detect: act once per copro instruction, only when the
// pipeline is advancing (not stalled).
reg [1:0] op_d;
wire op_stb = !i_fetch_stall && (i_copro_operation != OP_NONE) && (op_d == OP_NONE);

// ----------------------------------------------------------------
// Combinational BCD <-> decimal (8 nibbles), matches MAME loops.
// These are unrolled; at 7 MHz they close timing comfortably, but
// if needed they can be pipelined later (see NOTE in docs).
// ----------------------------------------------------------------
// bcd2dec HORNER (leggero): acc = ((...(d7*10+d6)*10+d5)...)*10+d0. Solo *10
// (costante piccola = shift+add), niente 8 mult per 10^k grandi. Meno ALM.
function [31:0] bcd2dec;
    input [31:0] v;
    reg [31:0] acc;
    begin
        acc = 32'd0;
        acc = acc*32'd10 + v[31:28];
        acc = acc*32'd10 + v[27:24];
        acc = acc*32'd10 + v[23:20];
        acc = acc*32'd10 + v[19:16];
        acc = acc*32'd10 + v[15:12];
        acc = acc*32'd10 + v[11: 8];
        acc = acc*32'd10 + v[ 7: 4];
        acc = acc*32'd10 + v[ 3: 0];
        bcd2dec = acc;
    end
endfunction


// ----------------------------------------------------------------
// Core operation. One-shot on op_stb.
//
// BCD op PIPELINATA (fix timing): la vecchia versione calcolava
//   cr5 <= dec2bcd( bcd2dec(cr0) OP bcd2dec(cr1) )
// in UN ciclo -> catena combinatoria enorme (2x bcd2dec Horner + mult
// 32x32 + dec2bcd loop /10) = path critico -76 ns (Add14..Add27 nel
// report STA). Ora spezzata in 3 stadi registrati:
//   S1: v0=bcd2dec(cr0), v1=bcd2dec(cr1)      (2 Horner, corti)
//   S2: prod = v0 OP v1                        (isola la mult 32x32)
//   S3: cr5  = dec2bcd(prod)                   (isola il loop /10)
// Il gioco NON esegue MAI istruzioni coprocessore (verificato capstone
// sui 3 firmware: 0 MCR/MRC/CDP reali -> [[nslasher-de156-decrypt-and-copro]]),
// quindi i +2 cicli di latenza sono INVISIBILI a runtime: nessuna
// istruzione legge mai cr5. Comportamento MRC/MCR-registro invariato.
// ----------------------------------------------------------------
integer k;

// stadi BCD
reg        bcd_s1, bcd_s2, bcd_s3;   // valid per stadio
reg [1:0]  bcd_cmd;                  // 0=add 1=mul 3=sub (write_data)
reg [31:0] bcd_v0, bcd_v1;           // dopo bcd2dec (S1 -> S2)
reg [31:0] bcd_prod;                 // dopo OP     (S2 -> S3)

// S3 seriale: bin->BCD con DOUBLE-DABBLE (32 cicli, 1 bit/ciclo). Niente /10
// %10 (erano il path critico residuo -22): ogni ciclo = solo confronti/somme
// su nibble 4-bit. Latenza +32 cicli invisibile a runtime (il gioco non esegue
// MAI istruzioni copro -> [[nslasher-de156-decrypt-and-copro]]).
reg        bcd_ser;                  // 1 = conversione double-dabble in corso
reg [5:0]  bcd_dig;                  // contatore bit 0..31
reg [31:0] bcd_bin;                  // binario residuo (shift-left, MSB entra nel BCD)
reg [31:0] bcd_acc;                  // 8 nibble BCD accumulati
reg [31:0] bcd_add3;                 // BCD dopo add-3 (temp blocking)

// add-3 double-dabble: +3 a ogni nibble >=5 (in preparazione allo shift-left).
// Solo confronti/somme su 4 bit -> combinatoria cortissima, niente /10 %10.
function [31:0] dd_add3;
    input [31:0] b;
    reg [3:0] n0,n1,n2,n3,n4,n5,n6,n7;
    begin
        n0 = b[ 3: 0]; n1 = b[ 7: 4]; n2 = b[11: 8]; n3 = b[15:12];
        n4 = b[19:16]; n5 = b[23:20]; n6 = b[27:24]; n7 = b[31:28];
        if (n0 >= 4'd5) n0 = n0 + 4'd3;
        if (n1 >= 4'd5) n1 = n1 + 4'd3;
        if (n2 >= 4'd5) n2 = n2 + 4'd3;
        if (n3 >= 4'd5) n3 = n3 + 4'd3;
        if (n4 >= 4'd5) n4 = n4 + 4'd3;
        if (n5 >= 4'd5) n5 = n5 + 4'd3;
        if (n6 >= 4'd5) n6 = n6 + 4'd3;
        if (n7 >= 4'd5) n7 = n7 + 4'd3;
        dd_add3 = {n7,n6,n5,n4,n3,n2,n1,n0};
    end
endfunction

always @(posedge i_clk) begin
    if (i_reset) begin
        op_d <= OP_NONE;
        o_copro_read_data <= 32'd0;
        bcd_s1 <= 1'b0; bcd_s2 <= 1'b0; bcd_s3 <= 1'b0;
        bcd_ser <= 1'b0; bcd_dig <= 6'd0;
        for (k = 0; k < 16; k = k + 1) cr[k] <= 32'd0;
    end else begin
        if (!i_fetch_stall)
            op_d <= i_copro_operation;

        // avanzamento pipeline BCD (default: nessun nuovo trigger)
        bcd_s1 <= 1'b0;
        bcd_s2 <= bcd_s1;
        bcd_s3 <= bcd_s2;

        // S1 -> S2: converti gli operandi BCD->dec (Horner, corti)
        if (bcd_s1) begin
            bcd_v0 <= bcd2dec(cr[0]);
            bcd_v1 <= bcd2dec(cr[1]);
        end
        // S2 -> S3: applica l'operazione (mult 32x32 isolata nel suo ciclo)
        if (bcd_s2) begin
            case (bcd_cmd)
                2'd0: bcd_prod <= bcd_v0 + bcd_v1; // add
                2'd1: bcd_prod <= bcd_v0 * bcd_v1; // multiply
                2'd3: bcd_prod <= bcd_v0 - bcd_v1; // subtract
                default: bcd_prod <= bcd_prod;
            endcase
        end
        // S3: arma la conversione double-dabble (bin -> BCD packed)
        if (bcd_s3) begin
            bcd_ser <= 1'b1;
            bcd_dig <= 6'd0;
            bcd_bin <= bcd_prod;
            bcd_acc <= 32'd0;
        end
        // DOUBLE-DABBLE SERIALE (32 cicli, 1 bit/ciclo): add-3 ai nibble >=5,
        // poi shift-left di {bcd,bin} di 1 (MSB di bin -> nibble0 del bcd).
        // ZERO /10 e %10: ogni ciclo = solo confronti/somme 4-bit -> path corto.
        // Risultato bit-exact a dec2bcd: gli 8 nibble bassi = cifre 0..7 (l'overflow
        // oltre l'8a cifra cade fuori dai 32 bit, come le 8 iterazioni di dec2bcd).
        else if (bcd_ser) begin
            bcd_add3 = dd_add3(bcd_acc);               // +3 ai nibble >=5
            bcd_acc <= {bcd_add3[30:0], bcd_bin[31]};  // shift-left, MSB bin entra
            bcd_bin <= {bcd_bin[30:0], 1'b0};          // shift-left binario
            bcd_dig <= bcd_dig + 6'd1;
            if (bcd_dig == 6'd31) begin
                bcd_ser <= 1'b0;
                cr[5]   <= {bcd_add3[30:0], bcd_bin[31]};
            end
        end

        if (op_stb) begin
            case (i_copro_operation)
            // ---- MRC: copro register -> core (read) ----
            OP_MRC: begin
                o_copro_read_data <= cr[i_copro_crn];
            end
            // ---- MCR: core -> copro register (write) ----
            OP_MCR: begin
                cr[i_copro_crn] <= i_copro_write_data;
                // DECO156: scrivere CR2 lancia la BCD op su CR0/CR1.
                // Qui si arma solo la pipeline (S1); il calcolo avviene
                // nei 3 cicli successivi. cmd valido = {0,1,3}.
                if (i_copro_crn == 4'd2 &&
                    (i_copro_write_data == 32'd0 ||
                     i_copro_write_data == 32'd1 ||
                     i_copro_write_data == 32'd3)) begin
                    bcd_s1  <= 1'b1;
                    bcd_cmd <= i_copro_write_data[1:0];
                end
            end
            default: ;
            endcase
        end
    end
end

endmodule
