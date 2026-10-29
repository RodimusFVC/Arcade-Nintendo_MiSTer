//============================================================================
//
//  Nintendo early arcade hardware for MiSTer
//  Copyright (C) 2026 Rodimus
//
//  Top level carried over from the Rodimus Pac-Man core (MikeJ / Sorgelig lineage)
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

wire        CLK_SYS;
wire        locked;
wire [127:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire [10:0] ps2_key;
wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
wire        ioctl_wr;
wire  [7:0] ioctl_index;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] joystick_0, joystick_1;
wire [15:0] joystick_r_analog_0, joystick_r_analog_1;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire  [7:0] paddle_0, paddle_1;
wire  [8:0] spinner_0, spinner_1;
wire [24:0] ps2_mouse;
wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;
wire        pause_cpu;
wire        hblank, vblank;
wire        video_field;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = video_field;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio;
assign AUDIO_L = pause_cpu ? 16'd0 : audio;
assign AUDIO_R = pause_cpu ? 16'd0 : audio;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

reg [7:0] game_var    = 8'd0;
reg [7:0] game_flags  = 8'h11;
reg [3:0] rom_dec     = 4'd0;
reg [7:0] game_flags2 = 8'd0;
reg [7:0] dial_sens = 8'd0, dial_keyd = 8'd0;
reg       dial_rev  = 1'b0;
wire       braze = rom_dec >= 4'd4 && rom_dec <= 4'd6;
wire [7:0] nv_dout;
reg [5:0] in_map[48];
reg [7:0] port_idle[6] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'hFF,8'h00};
reg [7:0] port_dip[6]  = '{8'h80,8'h80,8'h80,8'h80,8'h80,8'h80};
wire [5:0] map_idx  = ioctl_addr[5:0] - 6'd16;
wire [2:0] idle_idx = ioctl_addr[2:0] - 3'd4;
wire [3:0] dip_idx4 = ioctl_addr[3:0] - 4'd10;
wire [2:0] dip_idx  = dip_idx4[2:0];

always @(posedge CLK_SYS) begin
    if (ioctl_wr && ioctl_index == 8'd1) begin
        if (ioctl_addr == 25'd0) game_var   <= ioctl_dout;
        if (ioctl_addr == 25'd1) game_flags  <= ioctl_dout;
        if (ioctl_addr == 25'd2) rom_dec     <= ioctl_dout[3:0];
        if (ioctl_addr == 25'd3) game_flags2 <= ioctl_dout;
        if (ioctl_addr >= 25'd4  && ioctl_addr < 25'd10) port_idle[idle_idx] <= ioctl_dout;
        if (ioctl_addr >= 25'd10 && ioctl_addr < 25'd16) port_dip[dip_idx]   <= ioctl_dout;
        if (ioctl_addr >= 25'd16 && ioctl_addr < 25'd64) in_map[map_idx] <= ioctl_dout[5:0];
        if (ioctl_addr == 25'd64) dial_sens <= ioctl_dout;
        if (ioctl_addr == 25'd65) dial_keyd <= ioctl_dout;
        if (ioctl_addr == 25'd66) dial_rev  <= ioctl_dout[0];
    end
end

wire game_vert = game_flags[4];
wire vert_view = game_vert & ~status[12];

wire [1:0] ar = status[9:8];

assign VIDEO_ARX = (!ar) ? (vert_view ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (vert_view ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"NINTENDO;;",
	"P1,Video Options;",
	"P1O89,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1O[40:37],H Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[44:41],V Position (CRT),0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1OGI,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"H1P2,Game Options;",
	"H1P2O[24:23],Steering,D-pad,Analog stick/wheel,Paddle;",
	"H1P2O[27:25],Steering Sensitivity,1.0x,0.75x,0.5x,0.25x,0.125x,1.25x,1.5x,2.0x;",
	"H1P2O[28],Steering Direction,Normal,Reversed;",
	"H1-;",
	"P3,Pause Options;",
	"P3OJ,Pause when OSD is open,On,Off;",
	"P3OK,Dim video after 10s,On,Off;",
	"-;",
	"P4,High Score Options;",
	"P4OL,Autosave Hiscores,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Btn 1,Btn 2,Btn 3,Btn 4,Coin,Start 1P,Start 2P,Pause,Btn 5,Btn 6,Rack Test;",
	"jn,A,B,X,Y,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_SYS),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({~game_flags2[1], direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(1'b0),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_r_analog_0(joystick_r_analog_0),
	.joystick_r_analog_1(joystick_r_analog_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.paddle_0(paddle_0),
	.paddle_1(paddle_1),
	.spinner_0(spinner_0),
	.spinner_1(spinner_1),
	.ps2_mouse(ps2_mouse),
	.ps2_key(ps2_key)
);

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(CLK_SYS),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(0),
	.mgmt_address(0),
	.mgmt_writedata(0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~locked;

wire [12:0] kb;
/* verilator lint_off PINCONNECTEMPTY */
ctl_keyboard keyboard(.clk(CLK_SYS), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb), .kbx());
/* verilator lint_on PINCONNECTEMPTY */

wire [3:0] dir1_raw = {joystick_0[3] | kb[0], joystick_0[2] | kb[1], joystick_0[1] | kb[2], joystick_0[0] | kb[3]};
wire [3:0] dir2_raw = joystick_1[3:0];
wire [3:0] dir1, dir2;

ctl_joy4way joy4way_1(.clk(CLK_SYS), .en(game_flags[0]), .in(dir1_raw), .out(dir1));
ctl_joy4way joy4way_2(.clk(CLK_SYS), .en(game_flags[0]), .in(dir2_raw), .out(dir2));

wire m_pause = joystick_0[11] | kb[12];

wire coin1, coin2;
ctl_coin_impulse #(.PAUSE_MODE(1)) coin_imp1(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank), .en(game_flags[2]),
                           .coin_raw(joystick_0[8] | kb[8]), .coin(coin1));
ctl_coin_impulse #(.PAUSE_MODE(1)) coin_imp2(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank), .en(game_flags[2]),
                           .coin_raw(joystick_1[8] | kb[9]), .coin(coin2));

wire rack_btn = joystick_0[14] | joystick_1[14];
wire rack_tog;
ctl_toggle rack_toggle(.clk(CLK_SYS), .clear(ioctl_download), .btn(rack_btn), .pause(pause_cpu), .q(rack_tog));

wire [3:0] rstick0, rstick1;
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) rstick_0(.stick(joystick_r_analog_0), .dir(rstick0));
ctl_stick_dirs #(.MODE(0), .THRESH(7'd48)) rstick_1(.stick(joystick_r_analog_1), .dir(rstick1));

wire [35:0] ctl36;
ctl_ids ids(.joy0(joystick_0), .joy1(joystick_1), .kb(kb), .dir1(dir1), .dir2(dir2),
            .coin1(coin1), .coin2(coin2), .coin3(1'b0), .ctl(ctl36));
wire [63:0] ctl =
{
	18'd0,
	joystick_1[13] | rstick1[3],
	joystick_1[12] | rstick1[2],
	joystick_1[7]  | rstick1[1],
	joystick_1[6]  | rstick1[0],
	joystick_0[13] | rstick0[3],
	joystick_0[12] | rstick0[2],
	joystick_0[7]  | rstick0[1],
	joystick_0[6]  | rstick0[0],
	rack_tog,
	rack_btn,
	ctl36
};

reg [7:0] dip_sw[8] = '{8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_SYS) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end

wire [7:0]   in_port[6];
wire [47:0]  port_idle_flat, port_sel_flat, in_ports;
wire [63:0]  dip_bytes_flat;
wire [383:0] in_map_flat;
genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : g_port
		assign port_idle_flat[gi*8 +: 8] = port_idle[gi];
		assign port_sel_flat[gi*8 +: 8]  = port_dip[gi];
		assign in_port[gi] = in_ports[gi*8 +: 8];
	end
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_dip
		assign dip_bytes_flat[gi*8 +: 8] = dip_sw[gi];
	end
	for (gi = 0; gi < 48; gi = gi + 1) begin : g_map
		assign in_map_flat[gi*8 +: 8] = {2'b00, in_map[gi]};
	end
endgenerate
ctl_port_map #(.NP(6), .IDW(6), .BASE_MODE(1)) port_map
(
	.clk(CLK_SYS), .idle(port_idle_flat), .in_map(in_map_flat), .dips(32'd0), .port_sel(port_sel_flat),
	.dip_bytes(dip_bytes_flat), .dip_bit(144'd0), .ctl(ctl), .ovr_mask(48'd0), .ovr_val(48'd0), .ports(in_ports)
);

wire       dial_frame, ms_ev;
wire [9:0] ms_dx;
/* verilator lint_off UNUSED */
wire [9:0] ms_dy;
wire [2:0] ms_btn;
wire [5:0] dial0_hi, dial1_hi;
wire [5:0] dial0_fhi, dial1_fhi;
/* verilator lint_on UNUSED */
wire [1:0] dial0_raw, dial1_raw, dial0, dial1;
ctl_mouse u_ms(.clk(CLK_SYS), .ps2_mouse(ps2_mouse), .ev(ms_ev), .dx(ms_dx), .dy(ms_dy), .btn(ms_btn));
ctl_tick #(.MODE(0), .DW(1)) u_dft(.clk(CLK_SYS), .pause(pause_cpu), .vblank(vblank), .period(1'b0), .tick(dial_frame));
ctl_dial_mame u_dial0
(
	.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .frame(dial_frame), .sens(dial_sens), .keyd(dial_keyd),
	.reverse(dial_rev ^ status[28]), .osd_sens(status[27:25]), .wheel(status[24:23] == 2'd1),
	.spinner(spinner_0), .mouse_ev(ms_ev), .mouse_d(ms_dx[8:0]), .stick(joystick_l_analog_0[7:0]), .paddle(paddle_0),
	.use_paddle(status[24:23] == 2'd2), .dec(dir1[1]), .inc(dir1[0]), .pos({dial0_hi, dial0_raw})
);
ctl_dial_mame u_dial1
(
	.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .frame(dial_frame), .sens(dial_sens), .keyd(dial_keyd),
	.reverse(dial_rev ^ status[28]), .osd_sens(status[27:25]), .wheel(status[24:23] == 2'd1),
	.spinner(spinner_1), .mouse_ev(1'b0), .mouse_d(9'd0), .stick(joystick_l_analog_1[7:0]), .paddle(paddle_1),
	.use_paddle(status[24:23] == 2'd2), .dec(dir2[1]), .inc(dir2[0]), .pos({dial1_hi, dial1_raw})
);
dial_follow u_dfol0(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .frame(dial_frame), .target({dial0_hi, dial0_raw}),
                    .pos({dial0_fhi, dial0}));
dial_follow u_dfol1(.clk(CLK_SYS), .reset(reset), .pause(pause_cpu), .frame(dial_frame), .target({dial1_hi, dial1_raw}),
                    .pos({dial1_fhi, dial1}));

wire [23:0] rgb_out;
pause #(8,8,8,20) pause
(
	.*,
	.clk_sys(CLK_SYS),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[20:19])
);

wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;

wire rotate_ccw = ~game_flags[7];
wire no_rotate  = ~game_vert | status[12] | direct_video;
wire flip       = status[11];
screen_rotate screen_rotate(.*);

arcade_video #(512,24) arcade_video
(
	.*,

	.clk_video(CLK_SYS),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[18:16])
);

nintendo_dispatcher board
(
	.clk(CLK_SYS),
	.reset(reset),
	.pause(pause_cpu),
	.variant(game_var),
	.game_flags2(game_flags2),
	.rom_dec(rom_dec),
	.dial0(dial0),
	.dial1(dial1),
	.ce_pix(ce_pix),

	.in0(in_port[0]),
	.in1(in_port[1]),
	.in2(in_port[2]),
	.dsw0(in_port[3]),
	.dsw1(in_port[4]),
	.coin(in_port[5]),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr0(ioctl_wr & (ioctl_index == 8'd0)),
	.ioctl_wr5(ioctl_wr & (ioctl_index == 8'd5)),

	.nv_addr(ioctl_addr[6:0]),
	.nv_din(ioctl_dout),
	.nv_we(braze & ioctl_download & ioctl_wr & (ioctl_index == 8'd4)),
	.nv_dout(nv_dout),

	.crt_flip(status[22]),
	.h_adj(status[40:37]),
	.v_adj(status[44:41]),

	.video_r(r),
	.video_g(g),
	.video_b(b),
	.video_hs(hs),
	.video_vs(vs),
	.video_hblank(hblank),
	.video_vblank(vblank),
	.video_field(video_field),

	.audio(audio),

	.hs_address(hs_address),
	.hs_data_in(hs_data_in),
	.hs_data_out(hs_data_out),
	.hs_write(hs_write_enable)
);

wire [15:0] hs_address;
wire  [7:0] hs_data_in;
wire  [7:0] hs_data_out;
wire        hs_write_enable;
wire        hs_access_read;
wire        hs_access_write;
wire        hs_pause;
wire        hs_configured;
wire        hs_upload_req;
wire  [7:0] hs_din;

assign ioctl_din        = braze ? nv_dout : hs_din;
assign ioctl_upload_req = braze ? ~ioctl_download : hs_upload_req;

hiscore #(
	.HS_ADDRESSWIDTH(16),
	.CFG_ADDRESSWIDTH(4),
	.CFG_LENGTHWIDTH(2)
) hi (
	.*,
	.clk(CLK_SYS),
	.paused(pause_cpu),
	.autosave(status[21]),
	.ram_address(hs_address),
	.data_from_ram(hs_data_out),
	.data_to_ram(hs_data_in),
	.data_from_hps(ioctl_dout),
	.data_to_hps(hs_din),
	.ioctl_upload_req(hs_upload_req),
	.ram_write(hs_write_enable),
	.ram_intent_read(hs_access_read),
	.ram_intent_write(hs_access_write),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

endmodule

module dial_follow
(
	input            clk,
	input            reset,
	input            pause,
	input            frame,
	input      [7:0] target,
	output reg [7:0] pos = 8'd0
);

reg [20:0] cnt = 21'd0, flen = 21'd819200;
reg [20:0] acc = 21'd0;
reg  [7:0] left = 8'd0;
reg  [7:0] nstep = 8'd0;
reg        down = 1'b0;
wire [7:0] gap = target - pos;

always @(posedge clk) begin
	if (reset) begin
		pos <= target; cnt <= 21'd0; acc <= 21'd0; left <= 8'd0; nstep <= 8'd0;
	end else if (!pause) begin
		cnt <= cnt + 21'd1;
		if (frame) begin
			if (cnt > 21'd100000) flen <= cnt;
			cnt  <= 21'd0;
			acc  <= 21'd0;
			down <= gap[7];
			left  <= gap[7] ? (8'd0 - gap) : gap;
			nstep <= gap[7] ? (8'd0 - gap) : gap;
		end else if (left != 8'd0) begin
			if (acc + {13'd0, nstep} >= flen) begin
				acc  <= acc + {13'd0, nstep} - flen;
				pos  <= down ? pos - 8'd1 : pos + 8'd1;
				left <= left - 8'd1;
			end else acc <= acc + {13'd0, nstep};
		end
	end
end

endmodule
