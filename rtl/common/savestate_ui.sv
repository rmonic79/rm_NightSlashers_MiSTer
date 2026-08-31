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
//  savestate_ui — trigger del savestate da tasti/gamepad/OSD
//  Portato da _reference/taitof2_ss/savestate_ui.sv (Martin Donlon).
//  Genera ss_save/ss_load + slot da: Alt+F1-F4 (save), F1-F4 (load),
//  gamepad (SS+Down=save, SS+Up=load, SS+L/R=slot), OSD status bits.
//============================================================================

module savestate_ui #(parameter INFO_TIMEOUT_BITS)
(
    input            clk,
    input     [10:0] ps2_key,
    input            allow_ss,
    input            joySS   ,
    input            joyRight,
    input            joyLeft ,
    input            joyDown ,
    input            joyUp   ,
    input            joyStart,
    input            joyRewind,
    input            rewindEnable,
    input      [3:0] status_slot,   // 16 slot
    input            autoincslot,
    input      [1:0] OSD_saveload,
    output reg       ss_save,
    output reg       ss_load,
    output reg       ss_info_req,
    output reg [7:0] ss_info,
    output reg       statusUpdate,
    output     [3:0] selected_slot  // 16 slot: [3:2]=regione (file .ss1-.ss4), [1:0]=sotto-slot
);

reg [3:0] ss_base = 0;

reg lastRight  = 1'b0;
reg lastLeft   = 1'b0;
reg lastDown   = 1'b0;
reg lastUp     = 1'b0;

reg [(INFO_TIMEOUT_BITS-1):0] InfoWaitcnt = 0;

reg        slotswitched   = 1'b0;
// Deve essere largo quanto status_slot: a 2 bit il confronto con un valore a
// 4 bit e' sempre vero da slot 4 in su, e statusUpdate resta incollato alto.
reg [3:0]  lastOSDsetting = 4'b0;

assign selected_slot = ss_base;

wire pressed = ps2_key[9];

always @(posedge clk) begin
    reg old_state;
    reg alt = 0;
    reg [1:0] old_st;

    old_state <= ps2_key[10];
    
    lastRight <= joyRight;
    lastLeft  <= joyLeft; 
    lastDown  <= joyDown; 
    lastUp    <= joyUp;   
    
    slotswitched <= 1'b0;
    
    ss_save      <= 1'b0;
    ss_load      <= 1'b0;
    ss_info_req  <= 1'b0;
    statusUpdate <= 1'b0;
    
    if(allow_ss) begin
    
        // keyboard
        if(old_state != ps2_key[10]) begin
            case(ps2_key[7:0])
                'h11: alt <= pressed;
                'h05: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; ss_base <= 0; statusUpdate <= 1'b1; end // F1
                'h06: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; ss_base <= 1; statusUpdate <= 1'b1; end // F2
                'h04: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; ss_base <= 2; statusUpdate <= 1'b1; end // F3
                'h0C: begin ss_save <= pressed & alt; ss_load <= pressed & ~alt; ss_base <= 3; statusUpdate <= 1'b1; end // F4
            endcase
        end
        
        lastOSDsetting <= status_slot;
        if (lastOSDsetting != status_slot) begin
            ss_base      <= status_slot;
            statusUpdate <= 1'b1;
        end

        // gamepad
        if (joySS) begin
            // timeout with no button pressed -> help text
            InfoWaitcnt <= InfoWaitcnt + 1'b1;
            if (InfoWaitcnt[(INFO_TIMEOUT_BITS-1)]) begin
                ss_info     <= 7'd1;
                ss_info_req <= 1'b1;
                InfoWaitcnt <= 25'b0;
            end
            // switch slot
            if (joyRight & ~lastRight & ss_base < 4'd15) begin
                ss_base      <= ss_base + 1'd1;
                statusUpdate <= 1'b1;
                slotswitched <= 1'b1;
                InfoWaitcnt  <= 25'b0;
            end
            if (joyLeft & ~lastLeft & ss_base > 0) begin
                ss_base      <= ss_base - 1'd1;
                statusUpdate <= 1'b1;
                slotswitched <= 1'b1;
                InfoWaitcnt  <= 25'b0;
            end
            // save
            if (joyDown & ~lastDown) begin
                ss_save     <= 1'b1;
                InfoWaitcnt <= 25'b0;
            if (autoincslot) begin
                ss_base      <= ss_base + 1'd1;
                statusUpdate <= 1'b1;
            end
            end
            // load
            if (joyUp & ~lastUp) begin
                ss_load     <= 1'b1;
                InfoWaitcnt <= 25'b0;
            end
        end else begin
            InfoWaitcnt <= 25'b0;
        end
        
        // OSD
        old_st <= OSD_saveload;
        if(~old_st[0] && OSD_saveload[0]) begin
            ss_save <= 1'b1;
            if (autoincslot) begin
                ss_base      <= ss_base + 1'd1;
                statusUpdate <= 1'b1;
            end
        end

        if(~old_st[1] && OSD_saveload[1]) ss_load <= 1'b1;

        // infotexts
        if (slotswitched) begin
            ss_info     <= 7'd2 + ss_base;
            ss_info_req <= 1'b1;
        end

        if(ss_load | ss_save) begin
            ss_info     <= 7'd6 + {ss_base, ss_load};
            ss_info_req <= 1'b1;
        end
        
        // rewind info
        if (rewindEnable & joyRewind) begin
            ss_info_req <= 1'b1;
            ss_info     <= 7'd14;
        end

    end
end

endmodule

