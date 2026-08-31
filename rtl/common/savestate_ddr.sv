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
//  BoogieWings Savestate — ddr_if interface
//  Portato da _reference/taitof2_ss/ddram.sv (Martin Donlon).
//  ddr_if mappa 1:1 sui segnali DDRAM_* MiSTer.
//  NB: ddr_mux dell'originale RIMOSSO — su BoogieWings il mux DDR è fatto a mano
//  nel top (gated su ss_busy). Qui serve solo l'interface ddr_if.
//============================================================================

interface ddr_if;
    logic        acquire;

    logic [31:0] addr;
    logic [63:0] wdata;
    logic [63:0] rdata;
    logic        read;
    logic        write;
    logic  [7:0] burstcnt;
    logic  [7:0] byteenable;
    logic        busy;
    logic        rdata_ready;

    modport to_host(
        output addr, wdata, read, write, burstcnt, byteenable, acquire,
        input rdata, busy, rdata_ready
    );

    modport from_host(
        output rdata, busy, rdata_ready,
        input addr, wdata, read, write, burstcnt, byteenable, acquire
    );


endinterface


