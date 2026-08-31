// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) - Arcade-TaitoF2 savestate system.
    Modified/adapted by: Umberto Parisi (rmonic79)
*/

/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonic79)
*/

//============================================================================
//  BoogieWings Savestate — adaptor per le RAM inferite inline
//
//  Le RAM di BoogieWings sono `reg [7:0] mem[0:N]` con porta CPU separata in
//  byte (lo/hi). L'adaptor si interpone IN SERIE sulle linee della porta:
//  in modo normale passa i segnali del gioco; quando il ssbus accede a SS_IDX,
//  dirotta la porta verso il bus savestate (read/write).
//  NON aggiunge BRAM.
//
//  Riferimento: _reference/taitof2_ss/ram.sv (ram_ss_adaptor / m68k_ram_ss_adaptor)
//
//  Variante "byte-pair" (lo+hi a 16 bit, indirizzo word) per le RAM tipiche del
//  68K di BoogieWings: ram_lo/ram_hi, pf*_vram_lo/hi, sprite, palette, mirror.
//============================================================================

`timescale 1ns / 1ps

// Adaptor per una coppia di BRAM byte (lo+hi) indirizzate a word.
// WIDTHAD = bit dell'indirizzo word (es. 15 per 32K word, 12 per 4K word).
// Espone una porta WR a 16 bit sul ssbus; la lettura usa q (= {q_hi,q_lo}) della BRAM.
//
// Uso: collegare we_lo/we_hi/addr/wdata del gioco agli _in; gli _out vanno alla BRAM.
// q_in = dato letto dalla BRAM all'indirizzo addr_out (latenza 1 ck → read_delay).
module ss_ram16_adaptor #(
    parameter WIDTHAD = 15,
    parameter SS_IDX  = -1
) (
    input                    clk,

    // lato gioco (in)
    input                    we_lo_in,
    input                    we_hi_in,
    input      [WIDTHAD-1:0] addr_in,
    input      [15:0]        wdata_in,

    // lato BRAM (out)
    output                   we_lo_out,
    output                   we_hi_out,
    output     [WIDTHAD-1:0] addr_out,
    output     [15:0]        wdata_out,

    // dato letto dalla BRAM (q_hi,q_lo) all'indirizzo addr_out
    input      [15:0]        q_in,

    ssbus_if.slave           ssbus
);

wire sel = (ssbus.select == SS_IDX[7:0]) & ~ssbus.query & (ssbus.read | ssbus.write);

assign addr_out  = sel ? ssbus.addr[WIDTHAD-1:0] : addr_in;
assign wdata_out = sel ? ssbus.data[15:0]        : wdata_in;
assign we_lo_out = sel ? ssbus.write             : we_lo_in;
assign we_hi_out = sel ? ssbus.write             : we_hi_in;

wire [31:0] SIZE = 32'd1 << WIDTHAD;

reg read_delay;
always @(posedge clk) begin
    ssbus.setup(SS_IDX, SIZE, 1);  // width 1 = 16 bit

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            if (read_delay) begin
                ssbus.read_response(SS_IDX, {48'd0, q_in});
            end
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end

endmodule


// Adaptor per una singola BRAM a WIDTH bit (es. pal_buf_top 24-bit, ace 16-bit,
// ram audio 8-bit). Una sola linea wren.
module ss_ram_adaptor #(
    parameter WIDTH   = 8,
    parameter WIDTHAD = 13,
    parameter SS_IDX  = -1
) (
    input                    clk,

    input                    wren_in,
    input      [WIDTHAD-1:0] addr_in,
    input      [WIDTH-1:0]   wdata_in,

    output                   wren_out,
    output     [WIDTHAD-1:0] addr_out,
    output     [WIDTH-1:0]   wdata_out,

    input      [WIDTH-1:0]   q_in,

    ssbus_if.slave           ssbus
);

wire sel = (ssbus.select == SS_IDX[7:0]) & ~ssbus.query & (ssbus.read | ssbus.write);

assign addr_out  = sel ? ssbus.addr[WIDTHAD-1:0] : addr_in;
assign wdata_out = sel ? ssbus.data[WIDTH-1:0]   : wdata_in;
assign wren_out  = sel ? ssbus.write             : wren_in;

wire [31:0] SIZE = 32'd1 << WIDTHAD;

reg read_delay;
always @(posedge clk) begin
    ssbus.setup(SS_IDX, SIZE, ((WIDTH + 7) / 8) - 1);

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            if (read_delay) begin
                ssbus.read_response(SS_IDX, { {(64-WIDTH){1'b0}}, q_in });
            end
            read_delay <= 1;
        end
    end else begin
        read_delay <= 0;
    end
end

endmodule


// ============================================================================
// auto_save_lean_adaptor — variante LEGGERA (NS 2026-07-23): ZERO FF di buffer.
// L'auto_save_adaptor originale (F2) tiene doppio buffer (storage load +
// storage1 ombra save) = 2xN_BITS FF + barrel mux: su YM 2820 bit = ~5600 FF.
// Qui:
//   SAVE: read_response con la slice DIRETTA di bits_in (mux LUT). Lecito
//     perche' durante lo scan il chip e' CONGELATO (paused_safe tiene i cen
//     giu' per tutto il SS, fix "mantenimento" gia' nel top) -> dato stabile.
//   LOAD: read-modify-write ATTRAVERSO il chip: bits_out = bits_in con la sola
//     word indirizzata sostituita, bits_wr a impulso per OGNI word -> il chip
//     accumula in se' stesso (tra due word passano piu' clk di handshake ssbus,
//     bits_in riflette gia' le word precedenti).
// A SS spento: bits_wr=0 -> tutto inerte (bits_out non consumato dal chip).
// Protocollo ssbus identico all'originale (setup N_WORDS+1, marker finale).
// ============================================================================
module auto_save_lean_adaptor #(parameter N_BITS = 16, SS_IDX = -1)(
    input clk,

    ssbus_if.slave ssbus,

    input  [N_BITS-1:0] bits_in,
    output [N_BITS-1:0] bits_out,
    output reg          bits_wr
);

localparam N_WORDS = (N_BITS + 15) / 16;
localparam AW = (N_WORDS <= 1) ? 1 : $clog2(N_WORDS);

reg [15:0]    word_wr;
reg [AW-1:0]  word_idx;

wire [N_WORDS*16-1:0] padded_in = {{(N_WORDS*16-N_BITS){1'b0}}, bits_in};

// RMW: la word indirizzata viene dal bus, tutte le altre dal chip stesso
genvar gw;
generate
for (gw = 0; gw < N_WORDS; gw = gw + 1) begin : gen_rmw
    if (gw*16 + 16 <= N_BITS) begin : g_full
        assign bits_out[gw*16 +: 16] = (bits_wr && word_idx == gw[AW-1:0])
                                       ? word_wr : bits_in[gw*16 +: 16];
    end else begin : g_part
        assign bits_out[N_BITS-1 : gw*16] = (bits_wr && word_idx == gw[AW-1:0])
                                       ? word_wr[N_BITS-1-gw*16 : 0]
                                       : bits_in[N_BITS-1 : gw*16];
    end
end
endgenerate

// bits_wr RITARDATO di 2 clk rispetto a word_wr/word_idx: alla cattura le
// sorgenti del mux RMW sono stabili da 3 periodi -> il multicycle 3 dichiarato
// nell'SDC sui path adaptor->chip e' VERO PER COSTRUZIONE (le word ssbus
// arrivano comunque a >=4 clk di distanza: nessuna sovrapposizione).
reg wr_p1, wr_p2;
always @(posedge clk) begin
    wr_p1   <= 0;
    wr_p2   <= wr_p1;
    bits_wr <= wr_p2;
    ssbus.setup(SS_IDX, N_WORDS + 1, 1);

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            if (ssbus.addr != N_WORDS) begin
                word_wr  <= ssbus.data[15:0];
                word_idx <= ssbus.addr[AW-1:0];
                wr_p1    <= 1;                    // impulso a T+2: il chip carica (RMW)
            end
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            ssbus.read_response(SS_IDX, {48'd0, padded_in[ssbus.addr[AW-1:0]*16 +: 16]});
        end
    end
end

endmodule
