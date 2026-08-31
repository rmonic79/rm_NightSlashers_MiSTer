// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original algorithm: MAME project (deco146.cpp).
    RTL port: Umberto Parisi (rmonic79)
*/

//
// deco146_base.sv
// Data East 146/104 protection chip — porting RTL.
//
// Riferimento C++: reference/mame/deco146.cpp (read_data, read_protport,
// write_protport, reorder).
//
// Read latency: 2 ck (registered table BRAM + registered final output).
// Per 68K: jtframe_68kdtack_cen wait1 interno + bus_busy 1 ck = 2 ck totali.
//

module deco146_base #(
    parameter [7:0]  XOR_PORT  = 8'h2c,
    parameter [7:0]  MASK_PORT = 8'h36,
    parameter [7:0]  SOUND_PORT= 8'h64,
    parameter [7:0]  BANK_SWAP_READ_ADDR = 8'h78,
    parameter [15:0] MAGIC_READ_ADDR_XOR = 16'h44a,
    parameter        MAGIC_XOR_ENABLED = 1'b0,
    parameter [1:0]  ADDR_SCRAMBLE = 2'd0,   // 0=none, 1=reversed, 2=interleave
    parameter        TABLE_OFFSET_HEX  = "deco146_offset.hex",
    parameter        TABLE_MAPPING_HEX = "deco146_mapping.hex",
    parameter        TABLE_FLAGS_HEX   = "deco146_flags.hex",
    parameter integer SS_RB0_IDX        = 0,
    parameter integer SS_RB1_IDX        = 0
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [11:0] cpu_addr,
    input  wire        cpu_cs,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire [15:0] cpu_wdata,
    input  wire  [1:0] cpu_dsn,
    output reg  [15:0] cpu_rdata,

    input  wire [15:0] port_a,
    input  wire [15:0] port_b,
    input  wire [15:0] port_c,

    output reg   [7:0] soundlatch_data,
    output reg         soundlatch_irq,
    input  wire        soundlatch_rd,
    output wire  [7:0] soundlatch_dout,

    // Savestate auto_ss (69 bit): stato protezione DECO104. NON include soundlatch_irq (pulse
    // transitorio 1 ciclo: salvarlo crea edge artificiale -> push spurio FIFO al restore).
    //  [15:0] xor_reg  [31:16] nand_reg  [32] current_rambank  [43:33] latch_addr
    //  [59:44] latch_data  [60] latch_flag  [68:61] soundlatch_data
    input  wire [68:0] dc_ss_in,
    output wire [68:0] dc_ss_out,
    input  wire        dc_ss_wr,
    // Savestate rambank0/1 (RAM 128x16 protezione) via ssbus
    ssbus_if.slave     ss_rb0,
    ssbus_if.slave     ss_rb1
);

// ============================================================
// Address scramble
// ============================================================
wire [10:0] addr_w = cpu_addr[11:1];
reg [10:0] addr_scrambled;
always @(*) begin
    case (ADDR_SCRAMBLE)
        2'd1: begin // reversed (boogwing)
            addr_scrambled = {addr_w[10],
                              addr_w[0], addr_w[1], addr_w[2], addr_w[3], addr_w[4],
                              addr_w[5], addr_w[6], addr_w[7], addr_w[8], addr_w[9]};
        end
        2'd2: begin // interleave (Night Slashers) — MAME set_interface_scramble(4,5,3,6,2,7,1,8,0,9)
            // address = bitswap<16>(word, 15..10, 4,5,3,6,2,7,1,8,0,9); bit10 kept.
            //   result[9]=w[4] [8]=w[5] [7]=w[3] [6]=w[6] [5]=w[2] [4]=w[7] [3]=w[1] [2]=w[8] [1]=w[0] [0]=w[9]
            addr_scrambled = {addr_w[10],
                              addr_w[4], addr_w[5], addr_w[3], addr_w[6],
                              addr_w[2], addr_w[7], addr_w[1], addr_w[8],
                              addr_w[0], addr_w[9]};
        end
        default: addr_scrambled = addr_w;
    endcase
end

wire [10:0] magic_xor_w = {1'b0, MAGIC_READ_ADDR_XOR[10:1]};
// MAME deco146.cpp: magic xor è applicato SOLO in read_protport (linea 1217-1218),
// NON in write_protport. Quindi serve un addr separato per la write path.
wire [10:0] addr_for_lookup = MAGIC_XOR_ENABLED ? (addr_scrambled ^ magic_xor_w) : addr_scrambled;
wire [10:0] addr_for_write  = addr_scrambled;

// ============================================================
// Lookup tables (BRAM, .hex initialized)
// ============================================================
(* ramstyle = "M10K" *) reg [15:0] tbl_offset  [0:1023];
(* ramstyle = "M10K" *) reg [79:0] tbl_mapping [0:1023];
(* ramstyle = "M10K" *) reg [1:0]  tbl_flags   [0:1023];
initial begin
    $readmemh(TABLE_OFFSET_HEX,  tbl_offset);
    $readmemh(TABLE_MAPPING_HEX, tbl_mapping);
    $readmemh(TABLE_FLAGS_HEX,   tbl_flags);
end

// ============================================================
// RAMBANK 2 x 128 word
// ============================================================
(* ramstyle = "MLAB" *) reg [15:0] rambank0 [0:127];
(* ramstyle = "MLAB" *) reg [15:0] rambank1 [0:127];
integer init_i;
initial begin
    for (init_i = 0; init_i < 128; init_i = init_i + 1) begin
        rambank0[init_i] = 16'hFFFF;
        rambank1[init_i] = 16'hFFFF;
    end
end
// ── PORTA DI LETTURA UNICA per rambank0/1 (2026-08-10) ──────────────────────
// Prima ogni banco aveva DUE letture indipendenti (path gioco + path savestate).
// Una MLAB/M10K ha UNA sola porta di lettura: con due, Quartus ignora `ramstyle`
// e realizza i banchi in FLIP-FLOP con davanti un MUX ASINCRONO da 128 posizioni.
// Quel mux sta nel percorso critico del core: CPU (u_wishbone|o_wb_adr) ->
// deco146_base|s1_rb1 = scramble + tabella 1024 in LUT + mux 128, tutto in un
// ciclo (misurato 10.821 ns su 10.416 -> setup -1.053, e il boot diventa
// fragile perche' e' la protezione che la CPU interroga all'avvio).
// Con la porta unica il mux sparisce: misurato setup -0.345 (il migliore).
// La LATENZA NON CAMBIA: il dato esce registrato al ciclo dopo, come prima;
// durante il SS il gioco e' congelato, quindi il dirottamento e' trasparente.
// Decode esplicito invece di .access(): logica identica in sintesi, ma la
// chiamata a funzione d'interfaccia in un assign continuo non e' rivalutata da
// ModelSim (resterebbe X e renderebbe cieca ogni sim della protezione).
wire rb0_ss_sel = (ss_rb0.select == SS_RB0_IDX[7:0]) & ~ss_rb0.query & (ss_rb0.read | ss_rb0.write);
wire rb1_ss_sel = (ss_rb1.select == SS_RB1_IDX[7:0]) & ~ss_rb1.query & (ss_rb1.read | ss_rb1.write);

reg current_rambank;
reg [15:0] xor_reg;
reg [15:0] nand_reg;

reg [10:0] latch_addr;
reg [15:0] latch_data;
reg        latch_flag;

// ============================================================
// Pipeline read: 1 ck registered (BRAM read + source select + reorder + xor/nand)
// ============================================================
// Stage 0 (combinatorial): addr_for_lookup
// Stage 1 (clocked):       read BRAM, read rambank, sample ports
// Stage 2 (combinatorial): reorder + xor/nand + latch_hit mux
// Stage 3 (clocked):       cpu_rdata

reg [15:0] s1_offset;
reg [79:0] s1_mapping;
reg [1:0]  s1_flags;
reg [15:0] s1_pa, s1_pb, s1_pc;
reg        s1_latch_hit;
reg [15:0] s1_latch_val;
reg        s1_cb_bank;

wire [6:0] rb_game_idx  = s1_offset[7:1];   // dal REGISTRO stage1: tbl_offset non ha piu' letture async -> inferisce BRAM
wire [6:0] rb0_rd_addr  = rb0_ss_sel ? ss_rb0.addr[6:0] : rb_game_idx;
wire [6:0] rb1_rd_addr  = rb1_ss_sel ? ss_rb1.addr[6:0] : rb_game_idx;

// MAME read_protport (deco146.cpp:1204): the latch compares the RAW scrambled
// address (m_latchaddr), NOT the magic-xored one — magic is applied later (1217).
// So latch_hit must use addr_scrambled (== addr_for_write), magic-independent.
wire latch_hit_w = cpu_cs && cpu_rd && (addr_for_write == latch_addr) && latch_flag;

always @(posedge clk) begin
    s1_offset    <= tbl_offset[addr_for_lookup[9:0]];
    s1_mapping   <= tbl_mapping[addr_for_lookup[9:0]];
    s1_flags     <= tbl_flags[addr_for_lookup[9:0]];
    s1_pa        <= port_a;
    s1_pb        <= port_b;
    s1_pc        <= port_c;
    s1_latch_hit <= latch_hit_w;
    s1_latch_val <= latch_data;
    s1_cb_bank   <= current_rambank;
end

// ── STAGE 1b (2026-08-10): rambank letto QUI, con l'indice dal REGISTRO s1_offset.
// PRIMA: tutto in un ciclo -> scramble + tabella 1024 (in LUT, perche' letta in
// ASINCRONO proprio per calcolare l'indice del rambank) + mux del rambank. Era il
// percorso peggiore del core (98 path, worst -0.387) e coinvolge la PROTEZIONE,
// cioe' il blocco che la CPU interroga al boot.
// ORA: la catena e' spezzata. tbl_offset non ha piu' letture asincrone -> puo'
// stare in BRAM; il rambank si legge al ciclo dopo con l'indice gia' registrato.
// COSTO REALE ZERO: l'handshake del bus concede gia' 4 cicli alle letture DECO104
// (busy -> busy2 -> busy3 -> ready, vedi nightslashers_top), qui se ne usano 3.
// Per NON alterare il comportamento, TUTTI gli altri segnali di stage1 sono
// ripipelinati insieme: lo stage combinatorio vede la stessa identica
// combinazione di prima, solo un ciclo dopo. Il bankswitch resta agganciato a
// s1_offset/s1_latch_hit (stage 1), quindi non cambia di un ciclo.
reg [15:0] s2_offset;
reg [79:0] s2_mapping;
reg [1:0]  s2_flags;
reg [15:0] s2_rb0, s2_rb1;
reg [15:0] s2_pa, s2_pb, s2_pc;
reg        s2_latch_hit;
reg [15:0] s2_latch_val;
reg        s2_cb_bank;
always @(posedge clk) begin
    s2_rb0       <= rambank0[rb0_rd_addr];
    s2_rb1       <= rambank1[rb1_rd_addr];
    s2_offset    <= s1_offset;
    s2_mapping   <= s1_mapping;
    s2_flags     <= s1_flags;
    s2_pa        <= s1_pa;
    s2_pb        <= s1_pb;
    s2_pc        <= s1_pc;
    s2_latch_hit <= s1_latch_hit;
    s2_latch_val <= s1_latch_val;
    s2_cb_bank   <= s1_cb_bank;
end

// Stage 2 (combinatorial)
function [15:0] reorder_fn(input [15:0] src, input [79:0] map);
    integer i;
    reg [4:0] dest;
    begin
        reorder_fn = 16'd0;
        for (i = 0; i < 16; i = i + 1) begin
            dest = map[i*5 +: 5];
            if (src[i] && (dest[4] == 1'b0))
                reorder_fn[dest[3:0]] = 1'b1;
        end
    end
endfunction

reg [15:0] src_sel;
always @(*) begin
    case (s2_offset)
        16'h8000: src_sel = s2_pa;
        16'h8001: src_sel = s2_pb;
        16'h8002: src_sel = s2_pc;
        default:  src_sel = s2_cb_bank ? s2_rb1 : s2_rb0;
    endcase
end

reg [15:0] reord;
always @(*) reord = reorder_fn(src_sel, s2_mapping);

reg [15:0] final_data;
always @(*) begin
    final_data = reord;
    if (s2_flags[0]) final_data = final_data ^ xor_reg;
    if (s2_flags[1]) final_data = final_data & ~nand_reg;
end

// Stage 3: register final output (1 ck total latency)
always @(posedge clk) begin
    if (s2_latch_hit) cpu_rdata <= s2_latch_val;
    else              cpu_rdata <= final_data;
end

// ============================================================
// Bankswitch on read: trigger ck dopo lookup
// ============================================================
// BUG COMUNICAZIONE ce-paced (causa boot deviato/nero): la CPU ARM e' ce-paced,
// (cpu_cs & cpu_rd) restano ALTI per ~13 cicli clk pieni per UN SOLO accesso CPU
// (system_rdy stall). A LIVELLO, current_rambank toggla ~13 volte per lettura ->
// bank finale imprevedibile -> protezione legge dal bank sbagliato -> boot deviato.
// MAME/68000 fa 1 ciclo bus = 1 toggle. FIX: edge-detect dell'accesso, swap UNA VOLTA.
// L'edge di (cpu_cs&cpu_rd) ritardato 1ck allinea a s1_offset (stage1).
reg cpu_acc_rd_d;       // (cpu_cs&cpu_rd) registrato
reg acc_rd_rise_d;      // rising edge ritardato 1ck (allineato a s1_offset)
always @(posedge clk) begin
    cpu_acc_rd_d  <= cpu_cs & cpu_rd;
    acc_rd_rise_d <= (cpu_cs & cpu_rd) & ~cpu_acc_rd_d;   // 1 ck dopo l'edge
end
always @(posedge clk) begin
    if (reset) begin
        current_rambank <= 1'b0;
    end else if (dc_ss_wr) begin
        current_rambank <= dc_ss_in[32];   // restore (trasparente)
    end else begin
        // SOLO sull'impulso di accesso (1 per lettura CPU), non ad ogni clock.
        if (acc_rd_rise_d && !s1_latch_hit
            && s1_offset[15] == 1'b0 && s1_offset[7:0] == BANK_SWAP_READ_ADDR)
            current_rambank <= ~current_rambank;
    end
end

// Savestate rambank select (forward-declared here so the write_protport always
// block below can use them; the assigns live in the savestate section). Moving
// these up keeps the file portable to strict single-pass tools (ModelSim ASE)
// while Quartus accepts it unchanged.

// ============================================================
// Write protport
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        xor_reg  <= 16'h0000;
        nand_reg <= 16'h0000;
        soundlatch_data <= 8'h00;
        soundlatch_irq  <= 1'b0;
        latch_addr <= 11'h7FF;
        latch_data <= 16'h0000;
        latch_flag <= 1'b0;
    end else if (dc_ss_wr) begin
        // Restore savestate (priorita', trasparente a SS spento): ricarica i reg protezione.
        xor_reg         <= dc_ss_in[15:0];
        nand_reg        <= dc_ss_in[31:16];
        latch_addr      <= dc_ss_in[43:33];
        latch_data      <= dc_ss_in[59:44];
        latch_flag      <= dc_ss_in[60];
        soundlatch_data <= dc_ss_in[68:61];
        // soundlatch_irq NON ripristinato: pulse transitorio (1 ciclo). L'edge-detect del wrapper
        // (sl_pulse_d) e' salvato in AUDIO_BUS -> nessun edge artificiale al restore.
    end else begin
        soundlatch_irq <= 1'b0;

        // Write rambank0/1 da SS (restore) — nello STESSO always della write CPU per non creare
        // doppio driver. Durante SS la CPU e' ferma (no cpu_wr), quindi niente conflitto reale.
        if (rb0_ss_sel & ss_rb0.write) rambank0[ss_rb0.addr[6:0]] <= ss_rb0.data[15:0];
        if (rb1_ss_sel & ss_rb1.write) rambank1[ss_rb1.addr[6:0]] <= ss_rb1.data[15:0];

        if (cpu_cs && cpu_wr) begin
            latch_addr <= addr_for_write;
            latch_data <= cpu_wdata;
            latch_flag <= 1'b1;

            if (current_rambank)
                rambank1[addr_for_write[7:1]] <= cpu_wdata;
            else
                rambank0[addr_for_write[7:1]] <= cpu_wdata;

            // Special port writes — FIX 2026-07-10: MAME write_protport confronta
            // (address & 0xff) == port, con address = scrambled<<1 (deco146.cpp:1244):
            // maschera a 8 BIT -> scr[7+] IGNORATI -> ogni porta ha 16 ALIAS.
            // Il vecchio compare a 9 bit ((addr[7:0]<<1) == {1'b0,PORT}) pretendeva
            // scr[7]==0 e PERDEVA meta' degli alias: nslasher manda i comandi sonori
            // su [base,#0x700..0x7e0] (8 alias della sound port 0xa8) -> i comandi
            // sugli alias con scr[7]=1 (0x720/0x760/0x7a0/0x7e0) finivano nel solo
            // rambank = FM/SFX persi. Compare 8-bit esatto MAME:
            if ({addr_for_write[6:0], 1'b0} == XOR_PORT)
                xor_reg <= cpu_wdata;
            else if ({addr_for_write[6:0], 1'b0} == MASK_PORT)
                nand_reg <= cpu_wdata;
            else if ({addr_for_write[6:0], 1'b0} == SOUND_PORT) begin
                soundlatch_data <= cpu_wdata[7:0];
                soundlatch_irq  <= 1'b1;
            end
        end

        // Clear latch flag after ANY read (MAME deco146.cpp read_protport:
        // on a latch HIT it returns latchdata then sets m_latchflag=0 (line
        // 1209); on a non-hit it also sets m_latchflag=0 (line 1215). So a
        // single read consumes the latch — the NEXT read of the same address
        // goes through the lookup table. Previously this only cleared on
        // non-hit, so a polled latch address returned the latched value forever
        // and the boot EEPROM/status loop never advanced.
        if (cpu_cs && cpu_rd) begin
            latch_flag <= 1'b0;
        end

        if (soundlatch_rd) begin
            soundlatch_irq <= 1'b0;
        end
    end
end

assign soundlatch_dout = soundlatch_data;

// ============================================================
// Savestate: SAVE dei reg protezione (combinatorio, non tocca la logica).
// ============================================================
assign dc_ss_out = {soundlatch_data, latch_flag, latch_data,
                    latch_addr, current_rambank, nand_reg, xor_reg};

// ============================================================
// Savestate rambank0/1 (RAM 128x16): porta SS dedicata in lettura/scrittura.
// A SS spento (no access) la RAM e' scritta solo dalla CPU (logica originale, trasparente).
// Durante SS: la porta SS dirotta addr/we/data e legge le word per save / scrive per restore.
// ============================================================
// rb0_ss_sel / rb1_ss_sel declared earlier (before write_protport) for tool portability.
// La read SS riusa la porta unica: durante il SS rb*_rd_addr = ss_rb*.addr,
// quindi s2_rb0/s2_rb1 contengono gia' la word richiesta, stessa latenza (1 ck).
// NB: la WRITE SS di rambank0/1 e' nell'always "Write protport" (stesso always della write CPU)
// per evitare doppio driver. Qui solo read/setup/ack/response.
reg rb0_rd_d, rb1_rd_d;
always @(posedge clk) begin
    ss_rb0.setup(SS_RB0_IDX, 128, 1);   // 128 word, width 1 = 16 bit
    ss_rb1.setup(SS_RB1_IDX, 128, 1);
    rb0_rd_d <= rb0_ss_sel & ss_rb0.read;
    rb1_rd_d <= rb1_ss_sel & ss_rb1.read;
    if (rb0_ss_sel & ss_rb0.write) ss_rb0.write_ack(SS_RB0_IDX);
    if (rb1_ss_sel & ss_rb1.write) ss_rb1.write_ack(SS_RB1_IDX);
    if (rb0_rd_d) ss_rb0.read_response(SS_RB0_IDX, {48'b0, s2_rb0});
    if (rb1_rd_d) ss_rb1.read_response(SS_RB1_IDX, {48'b0, s2_rb1});
end

endmodule
