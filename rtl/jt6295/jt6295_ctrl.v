/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */
// Modified for BoogieWings savestate (auto_ss instrumentation): Umberto Parisi (rmonic79)

module jt6295_ctrl(
    input                  rst,
    input                  clk,
    input                  cen4,
    input                  cen1,
    // CPU
    input                  wrn,
    input      [ 7:0]      din,
    // Channel address
    output reg [17:0]      start_addr,
    output reg [17:0]      stop_addr,
    // Attenuation
    output reg [ 3:0]      att,
    // ROM interface
    output     [ 9:0]      rom_addr,
    input      [ 7:0]      rom_data,
    input                  rom_ok,
    // flow control
    output reg [ 3:0]      start,
    output reg [ 3:0]      stop,
    input      [ 3:0]      busy,
    input      [ 3:0]      ack,
    input                  zero,
    // Savestate (auto_ss, modello F2). FSM comando, tutto persistente = 102 bit. Mappa:
    //  [0]last_wrn [7:1]phrase [8]push [9]pull [13:10]ch [17:14]new_att [18]cmd [22:19]stop
    //  [26:23]start [44:27]start_addr [62:45]stop_addr [66:63]att [84:67]new_start
    //  [94:85]new_stop [97:95]st [100:98]addr_lsb [101]wrom
    input      [101:0]     auto_ss_in,
    output     [101:0]     auto_ss_out,
    input                  auto_ss_wr
);

reg  last_wrn;
wire negedge_wrn  = !wrn && last_wrn;

// new request
reg [6:0] phrase;
reg       push, pull;
reg [3:0] ch, new_att;
reg       cmd;

always @(posedge clk) begin
    last_wrn <= wrn;
    if(auto_ss_wr) last_wrn <= auto_ss_in[0];   // restore
end

reg stop_clr;

`ifdef JT6295_DUMP
integer fdump;
integer ticks=0;
initial begin
    fdump=$fopen("jt6295.log");
end
always @(posedge zero) ticks<=ticks+1;
always @(posedge clk ) begin
    if( negedge_wrn ) begin
        if( !cmd && !din[7] ) begin
            $fwrite(fdump,"@%0d - Mute %1X\n", ticks, din[6:3]);
        end
        if( cmd ) begin
            $fwrite(fdump,"@%0d - Start %1X, phrase %X, Att %X\n",
                ticks, din[7:4], phrase, din[3:0] );
        end
    end
end
`endif


// Bus interface
always @(posedge clk) begin
    if( rst ) begin
        cmd      <= 1'b0;
        stop     <= 4'd0;
        ch       <= 4'd0;
        pull     <= 1'b1;
        phrase   <= 7'd0;
        new_att  <= 0;
    end else begin
        if( cen4 ) begin
            stop <= stop & busy;
        end
        if( push ) pull <= 1'b0;
        if( negedge_wrn  ) begin // new write
            if( cmd ) begin // 2nd byte
                ch      <= din[7:4];
                new_att <= din[3:0];
                cmd     <= 1'b0;
                pull    <= 1'b1;
            end
            else if( din[7] ) begin // channel start
                phrase <= din[6:0];
                cmd    <= 1'b1; // wait for second byte
                stop   <= 4'd0;
            end else begin // stop data
                stop   <= din[6:3];
            end
        end
        if(auto_ss_wr) begin   // restore (ultimo = priorita'). push e' guidato dall'altro process.
            phrase  <= auto_ss_in[7:1];
            pull    <= auto_ss_in[9];
            ch      <= auto_ss_in[13:10];
            new_att <= auto_ss_in[17:14];
            cmd     <= auto_ss_in[18];
            stop    <= auto_ss_in[22:19];
        end
    end
end

reg [17:0] new_start;
reg [17:8] new_stop;
reg [ 2:0] st, addr_lsb;
reg        wrom;

assign rom_addr = { phrase, addr_lsb };

// Request phrase address
always @(posedge clk) begin
    if( rst ) begin
        st         <= 7;
        att        <= 0;
        start_addr <= 0;
        stop_addr  <= 0;
        start      <= 0;
        push       <= 0;
        addr_lsb   <= 0;
    end else begin
        if( st!=7 ) begin
            wrom <= 0;
            if( !wrom && rom_ok ) begin
                st       <= st+3'd1;
                addr_lsb <= st;
                wrom     <= 1;
            end
        end
        case( st )
            7: begin
                start    <= start & ~ack;
                addr_lsb <= 0;
                if(pull) begin
                    st       <= 0;
                    wrom     <= 1;
                    push     <= 1;
                end
            end
            0:;
            1: new_start[17:16] <= rom_data[1:0];
            2: new_start[15: 8] <= rom_data;
            3: new_start[ 7: 0] <= rom_data;
            4: new_stop [17:16] <= rom_data[1:0];
            5: new_stop [15: 8] <= rom_data;
            6: begin
                start       <= ch;
                start_addr  <= new_start;
                stop_addr   <= {new_stop[17:8], rom_data} ;
                att         <= new_att;
                push        <= 0;
            end
        endcase
        if(auto_ss_wr) begin   // restore (ultimo = priorita')
            push       <= auto_ss_in[8];
            start      <= auto_ss_in[26:23];
            start_addr <= auto_ss_in[44:27];
            stop_addr  <= auto_ss_in[62:45];
            att        <= auto_ss_in[66:63];
            new_start  <= auto_ss_in[84:67];
            new_stop   <= auto_ss_in[94:85];
            st         <= auto_ss_in[97:95];
            addr_lsb   <= auto_ss_in[100:98];
            wrom       <= auto_ss_in[101];
        end
    end
end

// Savestate output: concatenazione nell'ordine della mappa (102 bit).
assign auto_ss_out = { wrom, addr_lsb, st, new_stop, new_start, att, stop_addr, start_addr,
                       start, stop, cmd, new_att, ch, pull, push, phrase, last_wrn };

endmodule