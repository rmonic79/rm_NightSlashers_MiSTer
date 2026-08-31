// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Savestate della CPU ARM (Amber23, DECO156) — APPROCCIO B: estrazione/iniezione
    DIRETTA dei registri fisici via porta di scan del core (NO mini-handler/iniezione
    opcode/mode-switch, a differenza di ss_m68k che era per il 68000).
    Autore: Umberto Parisi (rmonic79).

    Decisione validata (3 giudici + trace golden): al confine vblank la CPU e' in USR
    100% sul game-loop spin -> stato pipeline non-semantico (branch-flush ogni giro) ->
    basta salvare i registri fisici + status + PC, e al restore riavviare la pipeline
    da reset col PC ripristinato. Vedi docs/SS_ARM_APPROCCIO_B.md.

    21 word 32-bit (ssbus width=2), indice = ssbus.addr:
      0-14 = r0-r14 (banco USER), 15 = r13_svc, 16 = r14_svc, 17 = r15 (PC[25:2]),
      18 = status {flags[7:4],imask[3],fmask[2],mode[1:0]}, 19 = r13_irq, 20 = r14_irq.

    SAVE: memory_stream legge le 21 word via ssbus.read -> read_response(ss_rdata[addr]).
          Il core espone ss_rdata combinatorio dell'indice ss_idx=ssbus.addr.
    RESTORE: ordine OBBLIGATORIO (spec validata):
      1) attende paused_real (pausa frame-aligned reale);
      2) memory_stream carica da DDR (scatter delle word negli adaptor RAM/pal/spr/... e
         qui bufferizza le 21 word CPU in ss_regfile[]);
      3) asserisce ss_reset per N cicli -> il core re-prima (mode=SVC, imask=1, r15=0);
      4) DOPO il reset, applica scan-in delle 21 word (ss_load + ss_idx + ss_wdata),
         una word/ciclo -> sovrascrive il re-priming col valore salvato;
      5) rilascia -> il core rifetcha pulito dal PC ripristinato.
*/

`timescale 1ns / 1ps

module ss_arm #(
    parameter integer SS_GLOB_IDX = 0
) (
    input  wire        clk,

    // Trigger (da savestate_ui, via top)
    input  wire        do_save,
    input  wire        do_restore,
    input  wire        paused_real,     // pausa REALE frame-aligned (paused_safe_r del top)

    // Verso memory_stream
    output reg         ss_mem_write,
    output reg         ss_mem_read,
    input  wire        ss_busy,
    input  wire        slot_empty,      // 1 = sotto-slot mai scritto: NON applicare il restore

    // ssbus slave (SS_GLOB_IDX): 21 word CPU
    ssbus_if.slave     ss_glob,

    // Scan verso la CPU (wrapper -> core -> execute -> register_bank)
    output reg         ss_load,         // 1: carica reg fisici
    output reg  [4:0]  ss_idx,          // indice word 0..20
    output reg  [31:0] ss_wdata,
    input  wire [31:0] ss_rdata,        // scan-out del core all'indice ss_idx

    // Override verso la CPU
    output wire        ss_reset,        // 1: reset ARM (restore)
    output wire        ss_pause,        // 1: gioco in pausa
    output wire        ss_restore_done  // pulse: restore finito
);

localparam NWORDS = 21;

// ── ssbus slave: SAVE via read, buffering delle word via write ──
// Durante il SAVE, memory_stream legge le 21 word: mettiamo ss_idx = ssbus.addr e
// rispondiamo con ss_rdata (scan-out del core), con 1 ck di latenza come gli adaptor RAM.
// Durante il RESTORE, memory_stream SCRIVE le 21 word: le bufferizziamo in ss_regfile[]
// (lo scatter reale nei reg fisici avviene DOPO, nella fase di scan-in, ordine col reset).
reg  [31:0] ss_regfile [0:NWORDS-1];
wire        ss_sel = ss_glob.access(SS_GLOB_IDX);
wire [4:0]  ss_bus_idx = ss_glob.addr[4:0];

// BoogieWings-FEDELE (ss_m68k risponde da ss_saved_ssp REGISTRATO): memory_stream legge/scrive
// SEMPRE il buffer registrato ss_regfile, MAI la porta di scan live della CPU. In SAVE le 21
// word sono pre-catturate in ss_regfile da uno sweep interno (fase ST_SAVE_CAPTURE) PRIMA che
// memory_stream legga -> risposta diretta a 0 latenza, path corto (timing-safe sul ferro).
// Il vecchio metodo (read live ss_rdata = CPU[ss_idx] con read_delay) percorreva un path
// combinatorio lungo 4 moduli durante le letture veloci di memory_stream -> valore non
// assestato sul ferro -> SAVE corrotto -> restore=reset. In sim (no timing) non si vedeva.
always @(posedge clk) begin
    ss_glob.setup(SS_GLOB_IDX, NWORDS, 2);  // 21 word, width 2 = 32 bit

    if (ss_sel) begin
        if (ss_glob.write) begin
            ss_regfile[ss_bus_idx] <= ss_glob.data[31:0];  // buffer per il restore
            ss_glob.write_ack(SS_GLOB_IDX);
        end else if (ss_glob.read) begin
            ss_glob.read_response(SS_GLOB_IDX, {32'd0, ss_regfile[ss_bus_idx]});  // DIRETTO dal buffer
        end
    end
    // SAVE-capture nello STESSO always block (ss_regfile deve avere UN SOLO driver, altrimenti
    // Quartus 10028 multi-driver): campiona la porta di scan CPU quando la FSM e' in
    // ST_SAVE_CAPTURE e il path ss_idx->ss_rdata si e' assestato (cap_wait>=2). ss_sel e' basso
    // in ST_SAVE_CAPTURE (memory_stream non accede ancora) -> nessun conflitto di scrittura.
    if (st == ST_SAVE_CAPTURE && cap_wait >= 3'd2)
        ss_regfile[scan_cnt] <= ss_rdata;
end

// Durante il SAVE, l'indice di scan del core segue l'indirizzo ssbus (per esporre la word
// giusta su ss_rdata). Durante il RESTORE lo pilota la FSM (scan-in). ss_load basso in save.
// ── FSM restore ──
localparam [3:0]
    ST_IDLE          = 4'd0,
    ST_SAVE_WPAUSE   = 4'd1,
    ST_SAVE_WRITE    = 4'd2,
    ST_RES_WPAUSE    = 4'd3,
    ST_RES_READ      = 4'd4,
    ST_RES_HOLD_RST  = 4'd5,
    ST_RES_SCANIN    = 4'd6,
    ST_RES_RELOAD    = 4'd7,   // pattern Raiden S_RELOAD: gioco fermo, stato coerente
    ST_RES_DONE      = 4'd8,
    ST_SAVE_CAPTURE  = 4'd9;   // sweep interno: cattura 21 reg CPU in ss_regfile PRIMA del DMA

reg [3:0] st = ST_IDLE;
reg [3:0] st_d;
reg [4:0] rst_cnt;      // cicli di reset ARM
reg [4:0] scan_cnt;     // 0..20 scan-in
reg [2:0] cap_wait;     // cicli di assestamento path ss_idx->ss_rdata per la cattura

// PATTERN RAIDEN (raiden_v30_ss.sv): il reset CPU resta alto per TUTTA la fase di reload
// (HOLD_RST + SCANIN + RELOAD): "mentre ss_cpu_reload e' alto scrivo i registri via SSBUS e
// tengo ss_reset_cpu alto -> la CPU ricarica i reg da SS_CPU su reset". Lo scan-in avviene
// DURANTE il reset (i_ss_load ha priorita' sul reset nel register_bank/execute), cosi' al
// rilascio del reset PC/mode/registri sono GIA' quelli salvati -> la CPU riparte dal punto
// salvato invece che dal reset vector ("il restore fa reset" = bug osservato sul ferro).
// Il reset finisce CON lo scan-in: in ST_RES_RELOAD deve essere GIA' BASSO, altrimenti
// riazzera r15/status appena scritti (bug visto in sim: r0-r14 ok ma PC/mode restavano
// quelli del reset). RELOAD = gioco ancora fermo (ss_pause), reset gia' rilasciato,
// registri intatti -> la CPU riparte pulita dal PC salvato.
assign ss_reset        = (st == ST_RES_HOLD_RST) || (st == ST_RES_SCANIN);
assign ss_pause        = (st != ST_IDLE);
assign ss_restore_done = (st == ST_IDLE) && (st_d == ST_RES_DONE);

always @(posedge clk) st_d <= st;

always @(posedge clk) begin
    ss_mem_write <= 1'b0;
    ss_load      <= 1'b0;

    case (st)
        ST_IDLE: begin
            ss_mem_read <= 1'b0;
            ss_idx      <= 5'd0;
            if (do_save)    st <= ST_SAVE_WPAUSE;
            if (do_restore) st <= ST_RES_WPAUSE;
        end

        // SAVE: attende pausa reale, poi memory_stream legge tutte le word (RAM/pal/spr/
        // CPU) da questo e dagli altri adaptor e le scrive su DDR.
        ST_SAVE_WPAUSE: if (paused_real) begin
            scan_cnt <= 5'd0; cap_wait <= 3'd0;
            st <= ST_SAVE_CAPTURE;
        end
        // Sweep INTERNO: cattura i 21 registri dalla porta di scan CPU nel buffer REGISTRATO
        // ss_regfile. 3 cicli/word: ss_idx (registrato) si posiziona, il path combinatorio
        // ss_idx->ss_rdata si assesta, poi campiono. Cosi' memory_stream leggera' ss_regfile
        // (path corto, timing-safe) invece della porta di scan live (path lungo 4 moduli).
        ST_SAVE_CAPTURE: begin
            ss_idx <= scan_cnt;
            // la scrittura di ss_regfile[scan_cnt] <= ss_rdata avviene nell'ALTRO always block
            // (unico driver di ss_regfile). Qui solo l'avanzamento indice/stato.
            if (cap_wait >= 3'd2) begin
                cap_wait <= 3'd0;
                if (scan_cnt == NWORDS-1) begin
                    ss_mem_write <= 1'b1;            // ora memory_stream salva ss_regfile su DDR
                    st <= ST_SAVE_WRITE;
                end else
                    scan_cnt <= scan_cnt + 5'd1;
            end else
                cap_wait <= cap_wait + 3'd1;
        end
        ST_SAVE_WRITE: begin
            // memory_stream legge le 21 word da ss_regfile via ssbus (risposta diretta)
            if (~ss_busy & ~ss_mem_write) st <= ST_IDLE;
        end

        // RESTORE
        ST_RES_WPAUSE: if (paused_real) begin
            ss_mem_read <= 1'b1;
            st <= ST_RES_READ;
        end
        // memory_stream ricarica da DDR: scatter negli adaptor RAM/pal/spr + le 21 word CPU
        // vengono SCRITTE su questo adaptor (bufferizzate in ss_regfile via ssbus.write).
        ST_RES_READ: begin
            if (ss_busy & ss_mem_read) ss_mem_read <= 1'b0;
            else if (~ss_busy & ~ss_mem_read) begin
                // Sotto-slot mai scritto (o .ss di una build precedente): il
                // memory_stream non ha applicato NIENTE. Tornare qui a ST_IDLE
                // significa gioco intatto; proseguire farebbe reset CPU +
                // scan-in di valori stantii = partita rotta da un load a vuoto.
                if (slot_empty) st <= ST_IDLE;
                else begin
                    rst_cnt <= 5'd0;
                    st <= ST_RES_HOLD_RST;
                end
            end
        end
        // Reset ARM: il core re-prima (mode=SVC, imask=1, r15=0). Tenuto 32 cicli di CLOCK
        // PIENO (NON ce_cpu): il reset del core (a23_execute/register_bank) e' campionato su
        // posedge clk puro, non gated da ce. CRITICO: ce_cpu qui sarebbe SEMPRE 0 (ss_pause
        // alto durante il restore lo spegne via cpu_run) -> deadlock. Conto su clk pieno.
        // Pattern Raiden/BoogieWings: reset CPU in fase DEDICATA, DOPO che TUTTO il load e'
        // finito (ss_busy 1->0 in ST_RES_READ) = tutte le RAM/palette/sprite gia' coerenti.
        ST_RES_HOLD_RST: begin
            rst_cnt <= rst_cnt + 5'd1;
            if (&rst_cnt) begin
                scan_cnt <= 5'd0;
                st <= ST_RES_SCANIN;
            end
        end
        // Scan-in con reset ANCORA ALTO (pattern Raiden: i reg salvati vincono sul reset).
        // TIMING: ss_load/ss_idx/ss_wdata sono TUTTI registrati sullo stesso fronte e
        // arrivano insieme al register_bank il ciclo dopo -> nessuno sfasamento, nessun
        // indice saltato (bug visto in sim: partiva da idx=1 perche' incrementavo l'indice
        // nello stesso ciclo in cui alzavo ss_load).
        ST_RES_SCANIN: begin
            ss_load  <= 1'b1;
            ss_idx   <= scan_cnt;
            ss_wdata <= ss_regfile[scan_cnt];
            if (scan_cnt == NWORDS-1) begin
                st      <= ST_RES_RELOAD;
                rst_cnt <= 5'd0;
            end else
                scan_cnt <= scan_cnt + 5'd1;
        end
        // RELOAD (pattern Raiden S_RELOAD): tieni il gioco FERMO ancora N cicli dopo lo
        // scan-in, con RAM+registri tutti coerenti, prima di sbloccare. Da' tempo alle FSM
        // del top (ROM bridge, DMA) di vedere lo stato nuovo prima che la CPU rifetchi.
        // ss_load resta basso qui (l'ultima word e' gia' stata scritta).
        ST_RES_RELOAD: begin
            rst_cnt <= rst_cnt + 5'd1;
            if (&rst_cnt) st <= ST_RES_DONE;
        end
        ST_RES_DONE: begin
            st <= ST_IDLE;   // rilascio: ss_pause cade -> CPU rifetcha dal PC ripristinato
        end

        default: st <= ST_IDLE;
    endcase
end

endmodule
