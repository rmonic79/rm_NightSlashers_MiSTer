/*  This file is part of JT51.

    JT51 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT51 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT51.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 27-10-2016
    */
// Modified for BoogieWings savestate (auto_ss instrumentation): Umberto Parisi (rmonic79)

module jt51_timers(
    input         rst,
    input         clk,
    input         cen,
    input         zero,
    input [9:0]   value_A,
    input [7:0]   value_B,
    input         load_A,
    input         load_B,
    input         clr_flag_A,
    input         clr_flag_B,
    input         enable_irq_A,
    input         enable_irq_B,
    output        flag_A,
    output        flag_B,
    output        overflow_A,
    output        irq_n,
    // Savestate (auto_ss, modello F2). 30 bit = timer_A(CW10->16) + timer_B(CW8->14).
    input  [29:0] auto_ss_in,
    output [29:0] auto_ss_out,
    input         auto_ss_wr
);

assign irq_n = ~( (flag_A&enable_irq_A) | (flag_B&enable_irq_B) );

jt51_timer #(.CW(10)) timer_A(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .zero       ( zero      ),
    .start_value( value_A   ),
    .load       ( load_A    ),
    .clr_flag   ( clr_flag_A),
    .flag       ( flag_A    ),
    .overflow   ( overflow_A),
    .auto_ss_in ( auto_ss_in[15:0]  ),
    .auto_ss_out( auto_ss_out[15:0] ),
    .auto_ss_wr ( auto_ss_wr        )
);

jt51_timer #(.CW(8),.FREE_EN(1)) timer_B(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen           ),
    .zero       ( zero          ),
    .start_value( value_B       ),
    .load       ( load_B        ),
    .clr_flag   ( clr_flag_B    ),
    .flag       ( flag_B        ),
    .overflow   (               ),
    .auto_ss_in ( auto_ss_in[29:16]  ),
    .auto_ss_out( auto_ss_out[29:16] ),
    .auto_ss_wr ( auto_ss_wr         )
);

endmodule

module jt51_timer #(parameter
    CW      = 8, // counter bit width. This is the counter that can be loaded
    FREE_EN = 0  // enables a 4-bit free enable count
) (
    input   rst,
    input   clk,
    input   cen,
    input   zero,
    input   [CW-1:0] start_value,
    input   load,
    input   clr_flag,
    output reg flag,
    output reg overflow,
    // Savestate (auto_ss, modello F2). CW+6 bit: [CW-1:0]cnt [CW]flag [CW+1]last_load
    //  [CW+5:CW+2]free_cnt.
    input   [CW+5:0] auto_ss_in,
    output  [CW+5:0] auto_ss_out,
    input            auto_ss_wr
);

reg          last_load;
reg [CW-1:0] cnt, next;
reg [   3:0] free_cnt, free_next;
reg          free_ov;

always@(posedge clk, posedge rst)
    if( rst )
        flag <= 1'b0;
    else if( auto_ss_wr )
        flag <= auto_ss_in[CW];   // restore
    else /*if(cen)*/ begin
        if( clr_flag )
            flag <= 1'b0;
        else if( cen && zero && load && overflow ) flag<=1'b1;
    end

always @(*) begin
    {free_ov, free_next} = { 1'b0, free_cnt} + 1'b1;
    /* verilator lint_off WIDTH */
    {overflow, next }    = { 1'b0, cnt }     + (FREE_EN ? free_ov : 1'b1);
    /* verilator lint_on WIDTH */
end

always @(posedge clk) begin : counter
    if( auto_ss_wr ) begin   // restore
        last_load <= auto_ss_in[CW+1];
        cnt       <= auto_ss_in[CW-1:0];
    end else if(cen && zero) begin
        last_load <= load;
        if( (load && !last_load) || overflow ) begin
          cnt  <= start_value;
        end
        else if( last_load ) cnt <= next;
    end
end

// Free running counter
always @(posedge clk) begin
    if( rst ) begin
        free_cnt <= 4'd0;
    end else if( auto_ss_wr ) begin
        free_cnt <= auto_ss_in[CW+5:CW+2];   // restore
    end else if( cen&&zero ) begin
        free_cnt <= free_next;
    end
end

assign auto_ss_out = { free_cnt, last_load, flag, cnt };

endmodule
