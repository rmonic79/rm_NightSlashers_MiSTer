derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# OSD HDMI (framework sys/osd.v): gp_outr (strobe HPS, dominio h2f) -> osd|bcnt (blanking
# counter dell'OSD, dominio video). E' un crossing HPS->OSD di CONFIG (non timing-critico:
# l'OSD e' il menu, i suoi counter non hanno requisiti hard rispetto allo strobe HPS).
# sys_top.sdc gia' false_path-a altri segnali OSD (v_cnt/v_osd_start...); estendo a bcnt che
# nel nostro core risulta il worst residuo (-4.8 ns). Path framework, NON tocca il core game.
set_false_path -from [get_registers {*gp_outr*}] -to [get_registers {*_osd|bcnt*}]

# CONFIG/STATUS HPS -> core (async, statici durante il gioco). status[] e gp_outr dall'HPS
# (dominio h2f_user0_clk 100MHz) verso registri di config del core (cfg_custom, audio config
# OKI/YM, dsw/inputs gia' coperti dal download MC). Questi cambiano solo quando l'utente tocca
# l'OSD: sono crossing async, NON path runtime. Il framework gli da' un clock group async ma
# alcuni endpoint del core non sono coperti. False_path: e' config, non dato di gioco.
set_false_path -from [get_registers {*hps_io|status*}]
set_false_path -from [get_registers {*gp_outr*}] -to [get_registers {*cfg_custom*}]

# ============================================================
# AUDIO ns_audio_z80 (T80pa u_z80 + jt51 u_ym + 2x jt6295 u_oki0/1, emu|game|u_audio).
# DECISIONE FINALE 2026-07-10: NESSUN multicycle audio — pattern del core
# RILASCIATO ChinaGate (stesso T80+jt51+jt6295 a 96 MHz, Template.sdc con i
# soli vincoli precisi del 6809 main): l'audio chiude single-cycle onesto.
# Storia: (1) i rapporti pieni ereditati BW (u_ym 27/26, u_oki 95/94 e 48/47,
# u_z80 13/12) erano multicycle FALSI (jt51 MMR, wrn jt6295 e condizionamento
# CEN T80pa girano a clk PIENO): gli hold enormi = licenza al fitter di
# inserire ritardi fisici su path 1-ck con STA verde -> esito diverso a OGNI
# refit (lotteria: garbage/mute/glitch cambiavano faccia a ogni build).
# (2) La variante 4/3 stile Darius2NW = regressione (pressione irrealizzabile
# sui coni profondi -> degrado globale del fit). Vincoli onesti = fit stabile.
# ============================================================
# ECCEZIONE MIRATA jt51 PHASE GENERATOR (u_pg): modulo INTERAMENTE cen-paced.
# VERIFICATO riga-per-riga nel sorgente Jotego jt51_pg.v: TUTTI e 6 gli
# always @(posedge clk) hanno if(cen), ZERO registri a clk pieno. cen = ce_ym =
# 96/27 = 3.556 MHz (ns_audio_z80). Il worst path reale (-4.9) e'
# jt51_lfo|u_lfo|pm -> jt51_pg|u_pg|keycode_II: pm E keycode_II sono entrambi
# if(cen) (verificato) -> avanzano ogni 27 ck, ma STA li valuta single-cycle @96
# -> -4.9 FALSO. Ancoro il multicycle al -to u_pg (100% cen): QUALSIASI path che
# FINISCE nel pg ha 27 ck reali (il pg consuma solo su cen). Multicycle 13
# (conservativo, ~meta' di 27). NON e' come i multicycle audio FALSI rimossi
# sopra: quelli erano su registri a clk PIENO (jt51_mmr write, T80pa CEN); il pg
# e' cen-gated al 100% -> l'hold non e' rompibile. -to mirato al SOLO u_pg
# (NON tutto il jt51: jt51_kon/mmr hanno registri a clk pieno, esclusi apposta).
set_multicycle_path -setup -to [get_registers {*jt51_pg:u_pg|*}] 13
set_multicycle_path -hold  -to [get_registers {*jt51_pg:u_pg|*}] 12
# jt51_eg (envelope generator): VERIFICATO riga-per-riga jt51_eg.v -> TUTTI e 8 gli
# always @(posedge clk) sono dentro if(cen)/else if(cen) (incl. envelope_counter r86),
# ZERO clk pieno. Stesso cen=ce_ym=96/27. Worst path jt51_eg|eg_VII (-0.45) = FALSO
# (avanza ogni 27 ck). Multicycle 13, -to u_eg (100% cen), come u_pg.
set_multicycle_path -setup -to [get_registers {*jt51_eg:u_eg|*}] 13
set_multicycle_path -hold  -to [get_registers {*jt51_eg:u_eg|*}] 12
# jt51_op (operator, contiene jt51_exprom): VERIFICATO jt51_op.v -> i 4 always
# @(posedge clk) sono TUTTI dentro if(cen) (il resto sono always @(*) combinatori);
# jt51_exprom.v r73 `if(cen) exp<=explut[addr]` -> anch'esso cen-paced. Stesso
# cen=ce_ym=96/27. Worst path (-0.273) = reset_hold_cnt -> ...|jt51_op:u_op|
# jt51_exprom:u_exprom|exp[*] dentro u_audio_huc: reset quasi-statico verso registro
# cen-paced (avanza ogni 27 ck), STA lo valuta single-cycle @96 -> FALSO. Il jt51 di
# u_audio_z80 non lo mostra (fit-lottery), ma il path e' realmente multicycle in
# ENTRAMBI. Multicycle 13, -to u_op (copre exprom sottomodulo), come u_pg/u_eg.
set_multicycle_path -setup -to [get_registers {*jt51_op:u_op|*}] 13
set_multicycle_path -hold  -to [get_registers {*jt51_op:u_op|*}] 12

# FALSE_PATH dal reset globale. VERIFICATO Template.sv:596-601: reset_hold_cnt pilota
# SOLO `wire reset` (601), nessuna logica funzionale. E' un reset quasi-statico
# (decrementa da 0x1FFFF al boot, poi resta 0 per sempre). I 16 path residui negativi
# (-0.005..-0.001) sono TUTTI reset_hold_cnt -> registri CE-paced (ARM r4, ecc.): il
# reset sincrono non ha requisito setup single-cycle rispetto ai clock funzionali
# (i FF escono dal reset quando si disattiva, stabile per milioni di ck). STA li
# valuta single-cycle @96 -> FALSI. false_path dalla sorgente reset = corretto/standard.
set_false_path -from [get_registers {*reset_hold_cnt[*]}]

# ECCEZIONE MIRATA Z80 CORE (T80:u0): il core T80 e' ClkEn-gated. VERIFICATO nel
# sorgente VHDL: T80pa istanzia u0:T80 con CLK_n=>CLK (clk_sys pieno) e CEN=>CEN,
# dove CEN = CEN_p and not CEN_pol, CEN_p = ce_z80_p = ce_ym = 96/27 (ns_audio_z80).
# In T80.vhd i registri IR/F/regs sono TUTTI dentro `if ClkEn='1'` (ClkEn=CEN and
# not BusAck) -> avanzano ogni ~13-27 ck, NON a clk pieno. Il worst path reale
# (-3.1) e' T80:u0|IR -> T80:u0|F (opcode->flag, datapath ALU lungo): STA lo valuta
# single-cycle @96 -> FALSO. Multicycle 13 (conservativo). Ancorato al SOLO core
# T80:u0 (ClkEn-gated); il wrapper T80pa (CEN_pol/generazione phase) gira a clk
# PIENO ed e' ESCLUSO (quello era il multicycle FALSO da evitare). Distinzione
# verificata: la logica clk-pieno del T80pa e' fuori da u0.
# AGGIORNATO 2026-07-23: Z80 = tv80s instrumentato (VERBATIM F2, il T80pa e'
# stato rimosso). Stessa motivazione: il core tv80 e' cen-gated (cen = ce_ym
# 3.556 MHz = 27 clk) -> i registri di GIOCO consumano ogni 27 ck. Il vecchio
# pattern T80pa non matchava piu' nulla -> tutto lo Z80 era tornato
# single-cycle (TNS -288 nella build 03:42).
set_multicycle_path -setup -to [get_registers {*tv80s:u_z80|*}] 13
set_multicycle_path -hold  -to [get_registers {*tv80s:u_z80|*}] 12
# LOAD SAVESTATE adaptor->chip (tv80/jt51/jt6295): le catture auto_ss_wr NON
# sono cen-gated (pattern F2: if separati) -> il MC 13 sopra sarebbe FALSO su
# quei path. Ma il lean adaptor alza bits_wr a T+2 rispetto a word_wr/word_idx
# (sorgenti del mux RMW stabili 3 periodi alla cattura) -> MC 3/2 VERO PER
# COSTRUZIONE, dichiarato esplicito (ultima assegnazione vince sul 13/12).
set_multicycle_path -setup -from [get_registers {*_ss_adaptor|word_wr* *_ss_adaptor|word_idx*}] 3
set_multicycle_path -hold  -from [get_registers {*_ss_adaptor|word_wr* *_ss_adaptor|word_idx*}] 2

# ECCEZIONE MIRATA HuC6280 CORE (set USA): il core HUC6280_CPU e' ClkEn-gated.
# VERIFICATO nel sorgente VHDL HUC6280_CPU.vhd: EN <= RDY and CE (riga 139), e TUTTI
# i registri di stato (T, DH, SH, PC, regs...) sono dentro `elsif EN='1'` (righe 342,
# 428...). CE = pulse del divisore interno /24 (HUC6280.vhd CPU_CLK_CNT) -> il core
# avanza ogni ~24 ck, NON a clk pieno. CE_IN alla HuC = ~pause (clk pieno, come BW),
# ma il DIVISORE interno rende i registri del core CE-paced. Worst path reale
# T[5]->DH[6] (-0.44): STA lo valuta single-cycle @96 -> FALSO -> boot INSTABILE
# (a volte parte a volte resetta: il path a volte fallisce nel fit-lottery). Il Z80
# non aveva il problema perche' e' CE-paced dall'esterno; l'HuC gira CE_IN pieno e i
# suoi path interni sono al limite. Multicycle 13 (conservativo, ~meta' di 24).
# Ancorato al SOLO core HUC6280_CPU (EN-gated); il wrapper HUC6280 (divisore
# CPU_CLK_CNT a clk pieno) e' ESCLUSO. use_huc=0 (Z80): la HuC ha CE_IN=0, ferma.
# AGGIORNAMENTO 2026-07-16 (fix velocita' HuC): CE_IN = ce_huc (24 MHz, pulse 1 ck
# ogni 4). Il core avanza CPU_CLK_CNT solo su ce_huc -> i registri EN-gated
# (EN=RDY and CE) avanzano ogni ce_huc (4 clk clk_sys) MINIMO. Ciclo macchina =
# 6 ce_huc = 24 clk. Prima CE_IN=clk pieno (96 MHz) -> avanzamento ogni clk, ciclo
# /6 = 6 clk -> l'HuC girava 4x troppo veloce (16 vs 4 MHz MAME). Ora CE-paced come
# il Z80 (ce_ym). Multicycle ONESTO 4/3 (< i 4 clk tra due ce_huc). -from/-to INTERNO
# al core (pattern BoogieWings): i path esterni->core restano single-cycle onesti.
set_multicycle_path -setup -from [get_registers {*HUC6280_CPU:*|*}] -to [get_registers {*HUC6280_CPU:*|*}] 4
set_multicycle_path -hold  -from [get_registers {*HUC6280_CPU:*|*}] -to [get_registers {*HUC6280_CPU:*|*}] 3

# FALSE_PATH Z80 <-> HuC6280 (set-select MUTUAMENTE ESCLUSIVO): le due CPU audio
# condividono il read-mux (cpu_din_val) e il decode. Quando use_huc=0 la HuC ha
# CE_IN=0 (FERMA), quando use_huc=1 il Z80 ha CEN=0 (FERMO). Non sono MAI attive
# insieme -> i path che attraversano da una CPU all'altra (es. T80|MCycle ->
# HUC6280|CPU_DI attraverso il mux) sono FISICAMENTE IMPOSSIBILI a runtime. STA li
# valuta come reali single-cycle @96 -> falsi negativi. false_path CORRETTO (NON e'
# come i multicycle falsi del nero: qui il path e' davvero irraggiungibile, non solo
# lento). Bidirezionale tra i due core.
set_false_path -from [get_registers {*tv80s:u_z80|*}] -to [get_registers {*HUC6280:u_cpu|*}]
set_false_path -from [get_registers {*HUC6280:u_cpu|*}] -to [get_registers {*tv80s:u_z80|*}]

# ============================================================
# CPU PRINCIPALE ARM (Amber a23): u_maincpu|u_arm, CE-paced a cpu_cen = 7.0805 MHz
# da clk_sys 96 MHz (jtframe_frac_cen 17/231 ~= 1/13.5). I path INTERNI dell'Amber
# (execute -> register_bank, decode, ecc.) hanno ~13 cicli clk tra un ce e l'altro,
# ma SENZA questo multicycle Quartus li valuta single-cycle @96MHz -> setup -14ns su
# path interni (es. status_bits_mode -> register_bank r1/r4/r7) -> sul ferro la CPU
# scrive valori CORROTTI nei registri -> esecuzione rotta -> CPU si incarta -> NERO TOTALE.
# La sim non lo vede (no timing). BUG che mancava: l'SDC aveva il multicycle per l'AUDIO
# (u_cpu=H6280, u_ym, u_oki) ma NON per la CPU ARM principale. Ratio 13 (conservativo, <13.5).
# ============================================================
# RISCRITTURA PRECISA 2026-07-09 -- le vecchie eccezioni A COPERTA (-from/-to
# *u_arm*, *u_maincpu*, FSM ROM, DECO104) erano multicycle FALSI: coprivano anche
# il Wishbone/fetch dell'Amber, il wrapper e le FSM del top che girano su clk
# PIENO (ack trasparente, ready dal bridge su qualsiasi ciclo). Un multicycle
# falso -- soprattutto il -hold 12 -- autorizza il fitter a instradare quei path
# con cicli di ritardo: l'handshake bus si rompe FISICAMENTE sul silicio mentre
# STA e sim sono verdi. RIMOSSE. Restano SOLO i registri pipeline realmente
# enable-gated da i_system_rdy (= ce_cpu 7.08 MHz): decode, execute (register
# bank/barrel/flags) e copro BCD -- quelli avanzano davvero ogni ~13 ck.
# Il Wishbone/fetch, la FSM ROM, il ready-latch e il DECO104 tornano ai vincoli
# single-cycle di default: i loro coni sono corti (handshake) e con hold di
# default il silicio non puo' piu' essere legalmente rotto.
set_multicycle_path -setup -from [get_registers {*u_arm|u_decode|*}] -to [get_registers {*u_arm|u_decode|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_arm|u_decode|*}] -to [get_registers {*u_arm|u_decode|*}] 2
set_multicycle_path -setup -from [get_registers {*u_arm|u_execute|*}] -to [get_registers {*u_arm|u_execute|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_arm|u_execute|*}] -to [get_registers {*u_arm|u_execute|*}] 2
set_multicycle_path -setup -from [get_registers {*u_arm|u_decode|*}] -to [get_registers {*u_arm|u_execute|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_arm|u_decode|*}] -to [get_registers {*u_arm|u_execute|*}] 2
set_multicycle_path -setup -from [get_registers {*u_arm|u_execute|*}] -to [get_registers {*u_arm|u_decode|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_arm|u_execute|*}] -to [get_registers {*u_arm|u_decode|*}] 2
set_multicycle_path -setup -from [get_registers {*u_copro156|*}] -to [get_registers {*u_copro156|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_copro156|*}] -to [get_registers {*u_copro156|*}] 2
set_multicycle_path -setup -from [get_registers {*u_arm|u_execute|*}] -to [get_registers {*u_copro156|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_arm|u_execute|*}] -to [get_registers {*u_copro156|*}] 2
set_multicycle_path -setup -from [get_registers {*u_copro156|*}] -to [get_registers {*u_arm|u_execute|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_copro156|*}] -to [get_registers {*u_arm|u_execute|*}] 2
set_multicycle_path -setup -from [get_registers {*u_arm|u_decode|*}] -to [get_registers {*u_copro156|*}] 3
set_multicycle_path -hold  -from [get_registers {*u_arm|u_decode|*}] -to [get_registers {*u_copro156|*}] 2

# SAVESTATE (save_state_data:u_save_state|memory_stream): lo stream di save/load avanza solo
# durante un save/restore (gated, lento) e NON durante il gioco normale. I path memory_stream
# -> registri di stato (ace_regs, palette, dma, ecc.) sono valutati single-cycle ma in realta'
# scorrono al ritmo dello stream SS. Non e' un path runtime critico. Multicycle generoso.
set_multicycle_path -setup -from [get_registers {*u_save_state|*}] 8
set_multicycle_path -hold  -from [get_registers {*u_save_state|*}] 7
set_multicycle_path -setup -from [get_registers {*memory_stream|*}] 8
set_multicycle_path -hold  -from [get_registers {*memory_stream|*}] 7

# ============================================================
# DOWNLOAD decrypt path (de102 + deco56 COMBINATORI in cascata).
# Attivo SOLO durante il caricamento ROM: ioctl_addr/dout_raw da hps_io sono
# statici durante il gioco. hps_io eroga 1 word, il bridge alza prog_wr e ferma
# hps_io via ioctl_wait (prog_ack) -> fra una word e l'altra passano molti ck.
# Il path decrypt->write-data NON serve in 1 ck @96MHz. Multicycle 4 (41.6 ns).
# NON e' un path di gioco: zero impatto runtime, zero rischio pacing.
# ============================================================
# From ROBUSTO ai refit: il fitter rinomina i nodi interni (ioctl_addr_out/dout_out
# spariscono, launch reali diventano game|comb~N, in_data, in_op, Add). Quindi
# ancoro il -from a NOMI STABILI (hps_io ioctl_addr = radice di TUTTO il fan-out
# download; gp_outr = strobe HPS) + le gerarchie decrypt + game|comb (launch decrypt),
# e il -to a TUTTI gli endpoint download (tile1 BRAM, prog_*, ddr_dl_*, dl_data_word,
# audio_rom_*, sdram_a). Cosi' nessun refit fa decadere il multicycle.
# NS: top istanziato come nightslashers_top:game (non boogwings_top). I moduli
# decrypt NS (de156/deco56/deco74_ioctl_decrypt) sono COMBINATORI puri (0 reg) ->
# get_registers non li aggancia: il path parte dai registri SORGENTE (hps_io
# ioctl_addr = radice fan-out download, gp_outr = strobe HPS) attraverso la
# cascata combinatoria, e i launch interni del top diventano nightslashers_top:game|comb*.
set DL_FROM {*hps_io*ioctl_addr* *hps_io*ioctl_dout* *nightslashers_top:game|comb* \
             *hps_io*ioctl_download* *hps_io*ioctl_index* *hps_io*ioctl_wr* \
             *sdram_bridge*prog_wr* *gp_outr* \
             *game|dl_active* *de156_ioctl_decrypt*|is_main* *de156_ioctl_decrypt*}
set DL_TO   {*game*tile1_* *sdram_bridge*prog_* *ddr_dl_* *dl_data_word* \
             *audio_rom_* *u_sdram_jt|sdram_a* *u_sdram_jt|sdram_* \
             *dsw_port* *inputs_port* *system_port* *board_mod*}
# VERIFICATO 2026-08-10: questa eccezione SERVE e NON e' bugiarda. Disattivandola
# il setup crolla a -16.3 ns sul path hps_io|ioctl_addr -> dsw_port/prog_*: la
# cascata di decrypt (de156->deco56->deco74->deco74) e' COMBINATORIA, ~26 ns in un
# periodo da 10.4. I dati arrivano da hps_io e restano fermi per molti cicli prima
# dello strobe, quindi il multicycle e' legittimo. NON toglierla: il modo pulito
# per eliminarla sarebbe REGISTRARE l'uscita della cascata (ritardando lo strobe
# della stessa quantita'), non lasciare il path scoperto.
# set_multicycle_path -setup -from [get_registers $DL_FROM] -to [get_registers $DL_TO] 4
# set_multicycle_path -hold  -from [get_registers $DL_FROM] -to [get_registers $DL_TO] 3

# ============================================================
# PIPELINE VIDEO NS (palette DECO_ACE -> fade -> blend/mix -> scanlines/rgb_out).
# Il rendering avanza al ritmo CE_PIX = clk_sys/14 (6.857 MHz, Template.sv ce_pix /14),
# NON a 96 MHz pieno. La catena pal_buf_top/bot (M10K) -> top/bot_color_raw -> fade8 ->
# blend8/sub_blend8 -> mix_r/g/b -> rgb_out -> scanlines e' una cascata combinatoria
# profonda (mixer ACE: fade + alpha-blend), ~20 ns di logica. Quartus la valuta single-
# cycle @96 MHz -> setup -20 ns (TNS enorme) su pal_buf_top -> scanlines|dout. MA il
# pixel cambia solo ogni 14 ck (ce_pix) -> path reale = multicycle, NON un percorso a
# 96 MHz. Endpoint su clk_sys (no CDC). Multicycle 7 (conservativo, metÃ  di 14) sui
# registri video sorgente/destinazione. Path VIDEO, non CPU: non tocca il boot.
# Worst path reale (da quartus_sta sul fit): FROM ace_regs[32] (config DECO_ACE: fade/blend/alpha)
# -> TO scanlines:VGA_scanlines|dout1[*]. ace_regs alimenta la cascata fade/blend combinatoria che
# finisce nello scandoubler. Sorgente = ace_regs + pal_buf (palette) + i registri colore; dest = lo
# scandoubler scanlines (dout/dout1/dout2). Nomi ancorati al NETLIST FITTATO (i wire mix_*/rgb_out
# combinatori NON sono registri -> uso ace_regs/pal_buf come launch e scanlines come latch).
# Rendering video NS = tutto ce_pix-paced (96/14): tilegen DECO16IC (deco16ic_jt), sprite
# (boogwings_sprites: pixel pipeline + line buffer lb_*), palette (pal_buf/ace_regs/pal_idx),
# fade/blend -> scanlines. Lo sweep dei path con quartus_sta li trova tutti tra questi moduli.
# FIX 2026-07-22 (trattato 13, pattern Raiden): RIMOSSI *u_sprites|* e
# deco16ic_jt:*|* da FROM/TO. Il renderer sprite (58 always@(posedge clk),
# free-run) e la FSM fetch del tilegen catturano OGNI clock: multicycle 7 /
# hold 6 su di loro = FALSO -> STA verde bugiardo + fitter autorizzato a
# skewarli (profilo replica residua: raro, picchi attivita', pulito in sim,
# immune ai fix logici). Ora single-cycle onesto. Resta il MC solo sulla
# catena colore feed-forward (dato stabile 14 ck fino allo scandoubler).
set VID_FROM {*game|ace_regs* *game|pal_buf_top* *game|pal_buf_bot* *game|pal_buf_at* \
              *game|pal_dma_wr_en* *game|top_pal_idx_r* *game|bot_pal_idx_r* \
              *game|at_idx_r* *game|at_en_r* *game|at_alpha_r* *game|at_color_raw* \
              *game|tmap_pal_idx* \
              *game|priority_reg* *game|ns_pri_reg* *game|*blend* *game|*alpha*}
set VID_TO   {*VGA_scanlines|dout* *game|top_pal_idx_r* *game|bot_pal_idx_r* \
              *game|tmap_pal_idx* *game|top_color_raw* *game|bot_color_raw* \
              *game|at_idx_r* *game|at_en_r* *game|at_alpha_r* *game|at_color_raw* \
              *game|at_en_d* *game|at_alpha_d* *game|at_raw_d* \
              *game|rgb_out_q* *game|probe_flags*}
set_multicycle_path -setup -from [get_registers $VID_FROM] -to [get_registers $VID_TO] 7
set_multicycle_path -hold  -from [get_registers $VID_FROM] -to [get_registers $VID_TO] 6
# Copertura anche dei path interni alla pipeline colore (ace_regs/pal_buf -> stessi registri colore
# a valle, ce_pix-paced): -to su qualunque registro del game raggiunto da ace_regs sarebbe troppo
# largo; mi limito allo scandoubler (il worst path reale). Se residuo, estendere a top/bot_color_raw
# col nome fittato reale.
