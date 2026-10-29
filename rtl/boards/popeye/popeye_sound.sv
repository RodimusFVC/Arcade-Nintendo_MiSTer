//  Copyright (C) 2026 Rodimus

module popeye_sound
(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic  [7:0] ch_a,
    input  logic  [7:0] ch_b,
    input  logic  [7:0] ch_c,
    output logic signed [15:0] audio
);

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

function automatic [15:0] pin(input [3:0] s);
    case (s)
        4'd0:  pin = 16'd0;     4'd1:  pin = 16'd232;   4'd2:  pin = 16'd324;   4'd3:  pin = 16'd473;
        4'd4:  pin = 16'd683;   4'd5:  pin = 16'd1001;  4'd6:  pin = 16'd1454;  4'd7:  pin = 16'd2336;
        4'd8:  pin = 16'd2794;  4'd9:  pin = 16'd4514;  4'd10: pin = 16'd6203;  4'd11: pin = 16'd7662;
        4'd12: pin = 16'd9729;  4'd13: pin = 16'd11983; 4'd14: pin = 16'd14337; 4'd15: pin = 16'd16845;
    endcase
endfunction

localparam [15:0] W_A  = 16'd25118;
localparam [15:0] W_BC = 16'd17611;
localparam [11:0] K_A  = 12'd3388;

logic [15:0] pa, pb, pc;
always_ff @(posedge clk) begin
    pa <= pin(step(ch_a));
    pb <= pin(step(ch_b));
    pc <= pin(step(ch_c));
end

logic signed [32:0] a_lp = 33'sd0;
wire  signed [32:0] a_df = $signed({1'b0, pa, 16'd0}) - a_lp;
wire  signed [47:0] a_pr = 48'(a_df) * $signed({36'd0, K_A});
always_ff @(posedge clk) begin
    if (reset) a_lp <= 33'sd0;
    else if (ce) a_lp <= a_lp + 33'(a_pr >>> 20);
end

logic [33:0] s_acc;
logic [15:0] s_v;
always_ff @(posedge clk) begin
    s_acc <= W_A * a_lp[31:16] + W_BC * pb + W_BC * pc;
    s_v   <= s_acc[31:16];
end

logic [5:0] hp_div = 6'd0;
logic signed [31:0] dc = 32'sd0;
always_ff @(posedge clk) begin
    if (reset) begin hp_div <= 6'd0; dc <= 32'sd0; end
    else if (ce) begin
        hp_div <= (hp_div == 6'd40) ? 6'd0 : hp_div + 6'd1;
        if (hp_div == 6'd0) dc <= dc + (($signed({16'd0, s_v} <<< 12) - dc) >>> 12);
    end
end

wire signed [18:0] ac = $signed({3'b000, s_v}) - 19'(dc >>> 12);
wire signed [26:0] o7 = 27'(ac) * 27'sd77;
wire signed [21:0] o  = 22'(o7 >>> 5);
assign audio = (o > 22'sd32767) ? 16'sd32767 : (o < -22'sd32768) ? -16'sd32768 : o[15:0];

endmodule
