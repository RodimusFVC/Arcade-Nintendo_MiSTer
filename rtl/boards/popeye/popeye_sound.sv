//============================================================================
//
//  Nintendo Popeye sound output (TPP2-CPU sheet 2): AY-3-8910 7L channels into the board's resistor / RC network
//  Copyright (C) 2026 Rodimus
//
//  Each AY output is a MOSFET source follower (MAME ay8910 RESISTOR_OUTPUT, mosfet table at the 2K load MAME tpp2
//  sets); on the board every pin has 2K (R52 / R55 / R58) to ground and feeds 2K (R53 / R56 / R59) + 20K (R54, A) /
//  30K (R57 / R60, B / C) into the sum node (R61 120K, C40 680p), then C7 3.3u into complementary followers.
//  A also has C4 0.047u at its 2K / 20K junction: a ~1 kHz low-pass. tools/popeye_snd.py derives the constants:
//    pin voltage per AY step with its load (the loaded curve compresses the steps: 14 = 0.85, 12 = 0.58, 8 = 0.17
//    of step 15), sum = weighted pins (A weight includes its slightly lighter load), within ~5 % of the full nodal
//    solution with the channel ratios kept; C4 low-pass at 1030 Hz (Thevenin R 3.1-3.6K over the volume range);
//    C7 high-pass as a ~2 Hz DC blocker.
//  jt49 gives linear channel values (jt49_exp, index {volume, volume bit 3}); AY step = index >> 1.
//
//============================================================================

module popeye_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        ce,             // AY clock (2 MHz)
    input  logic  [7:0] ch_a,           // jt49 A / B / C
    input  logic  [7:0] ch_b,
    input  logic  [7:0] ch_c,
    output logic signed [15:0] audio
);

// jt49 linear value -> AY step
function automatic [3:0] step(input [7:0] v);
    case (v)
        8'd0:   step = 4'd0;
        8'd1:   step = 4'd1;
        8'd2:   step = 4'd2;  8'd3:   step = 4'd3;
        8'd4:   step = 4'd4;  8'd5:   step = 4'd4;  8'd6:   step = 4'd5;  8'd7:   step = 4'd5;
        8'd9:   step = 4'd6;  8'd11:  step = 4'd6;  8'd13:  step = 4'd7;  8'd15:  step = 4'd7;
        8'd18:  step = 4'd8;  8'd22:  step = 4'd8;  8'd26:  step = 4'd9;  8'd31:  step = 4'd9;
        8'd37:  step = 4'd10; 8'd45:  step = 4'd10; 8'd53:  step = 4'd11; 8'd63:  step = 4'd11;
        8'd75:  step = 4'd12; 8'd90:  step = 4'd12; 8'd107: step = 4'd13; 8'd127: step = 4'd13;
        8'd151: step = 4'd14; 8'd180: step = 4'd14; 8'd214: step = 4'd15; 8'd255: step = 4'd15;
        default: step = 4'd0;
    endcase
endfunction

// pin voltage (B / C load), 65535 = 5 V
function automatic [15:0] pin(input [3:0] s);
    case (s)
        4'd0:  pin = 16'd0;     4'd1:  pin = 16'd232;   4'd2:  pin = 16'd324;   4'd3:  pin = 16'd473;
        4'd4:  pin = 16'd683;   4'd5:  pin = 16'd1001;  4'd6:  pin = 16'd1454;  4'd7:  pin = 16'd2336;
        4'd8:  pin = 16'd2794;  4'd9:  pin = 16'd4514;  4'd10: pin = 16'd6203;  4'd11: pin = 16'd7662;
        4'd12: pin = 16'd9729;  4'd13: pin = 16'd11983; 4'd14: pin = 16'd14337; 4'd15: pin = 16'd16845;
    endcase
endfunction

localparam [15:0] W_A  = 16'd25118;     // 25617 x PA / PB (A's pin sits on a 22K branch instead of 32K)
localparam [15:0] W_BC = 16'd17611;
localparam [11:0] K_A  = 12'd3388;      // 1 - exp(-2 pi 1030 / 2 MHz), x 2^20

logic [15:0] pa, pb, pc;
always_ff @(posedge clk) begin
    pa <= pin(step(ch_a));
    pb <= pin(step(ch_b));
    pc <= pin(step(ch_c));
end

// A: C4 low-pass at the AY clock, 16.16
logic signed [32:0] a_lp = 33'sd0;
wire  signed [32:0] a_df = $signed({1'b0, pa, 16'd0}) - a_lp;
wire  signed [47:0] a_pr = 48'(a_df) * $signed({36'd0, K_A});      // full 46-bit product (operands sized first)
always_ff @(posedge clk) begin
    if (reset) a_lp <= 33'sd0;
    else if (ce) a_lp <= a_lp + 33'(a_pr >>> 20);
end

// sum node, 65535 = 5 V
logic [33:0] s_acc;
logic [15:0] s_v;
always_ff @(posedge clk) begin
    s_acc <= W_A * a_lp[31:16] + W_BC * pb + W_BC * pc;
    s_v   <= s_acc[31:16];
end

// C7: DC blocker ~2 Hz, at the AY clock / 41 (48.8 kHz)
logic [5:0] hp_div = 6'd0;
logic signed [31:0] dc = 32'sd0;
always_ff @(posedge clk) begin
    if (reset) begin hp_div <= 6'd0; dc <= 32'sd0; end
    else if (ce) begin
        hp_div <= (hp_div == 6'd40) ? 6'd0 : hp_div + 6'd1;
        if (hp_div == 6'd0) dc <= dc + (($signed({16'd0, s_v} <<< 12) - dc) >>> 12);
    end
end

// output: sum node AC part x 77 / 32 (2.41): title music 100 ms RMS = MAME's on average (x 2 gave 0.84 of MAME,
// envelope correlation 0.935, same onset frame)
wire signed [18:0] ac = $signed({3'b000, s_v}) - 19'(dc >>> 12);
wire signed [26:0] o7 = 27'(ac) * 27'sd77;
wire signed [21:0] o  = 22'(o7 >>> 5);
assign audio = (o > 22'sd32767) ? 16'sd32767 : (o < -22'sd32768) ? -16'sd32768 : o[15:0];

endmodule
