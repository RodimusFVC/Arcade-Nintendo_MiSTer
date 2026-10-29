//  Based on MAME mario.cpp (Mirko Buffoni, Couriersud, BSD-3-Clause); nl_mario.cpp (Couriersud, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module mario_sound
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,

    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] tune,
    input  logic  [3:0] lat1,
    input  logic  [1:0] lat3,
    input  logic        irq,
    input  logic        walk0,
    input  logic        walk1,
    input  logic        sound7,

    output logic [11:0] pa,
    input  logic  [7:0] pd,
    output logic [12:0] xa,
    input  logic  [7:0] xd,

    output logic signed [15:0] audio,

    output logic signed [39:0] mul_a,
    output logic signed [26:0] mul_b,
    input  logic signed [66:0] mul_p
);

logic [15:0] xacc = 16'd0;
logic        xen  = 1'b0;
always_ff @(posedge clk) begin
    xen <= 1'b0;
    if (!pause) begin
        if (xacc >= 16'd38152) begin xacc <= xacc - 16'd38152; xen <= 1'b1; end
        else xacc <= xacc + 16'd11000;
    end
end

wire [7:0] p2 = mcs48_0_o.p2;
logic [7:0] movx_a;
always_ff @(posedge clk) if (mcs48_0_o.ale) movx_a <= mcs48_0_o.db;

wire ea = ~p2[5];
wire internal = !ea && !mcs48_0_o.pmem_a[11];
logic internal_q = 1'b0;
logic [10:0] ia_q;
always_ff @(posedge clk) begin internal_q <= internal; ia_q <= mcs48_0_o.pmem_a[10:0]; end
wire [7:0] boot = (ia_q == 11'd0) ? 8'hF5 : (ia_q == 11'd1) ? 8'h04 : 8'h00;

assign pa = mcs48_0_o.pmem_a;
assign xa = {1'b0, p2[3:0], movx_a};

assign mcs48_0_i.reset_n = ~reset;
assign mcs48_0_i.xtal_en = xen;
assign mcs48_0_i.int_n   = ~irq;
assign mcs48_0_i.t0      = lat3[0];
assign mcs48_0_i.t1      = lat3[1];
assign mcs48_0_i.p1_in   = {4'h0, lat1};
assign mcs48_0_i.p2_in   = p2 & 8'hEF;
assign mcs48_0_i.db      = p2[7] ? tune : xd;
assign mcs48_0_i.pmem_d  = internal_q ? boot : pd;

logic [7:0] dac = 8'd0;
always_ff @(posedge clk) begin
    if (reset) dac <= 8'd0;
    else if (!mcs48_0_o.wr_n) dac <= mcs48_0_o.db;
end

logic [7:0] sdiv = 8'd0;
wire        step = sdiv == 8'd0;
always_ff @(posedge clk) sdiv <= sdiv + 8'd1;

localparam signed [17:0] A1 = 18'sd2660;
localparam signed [17:0] A2 = 18'sd14117;
localparam signed [17:0] A3 = 18'sd2209;

logic signed [31:0] f1 = 32'sd0, f2 = 32'sd0, f3 = 32'sd0, h1 = 32'sd0, h2 = 32'sd0;
wire  signed [31:0] y1 = f3 - h1;

logic [8:0] lvl0, lvl1, lvl7;
logic signed [39:0] d_mul_a;
logic signed [26:0] d_mul_b;
mario_discrete disc
(
    .clk(clk), .reset(reset), .run(!pause), .step(step), .walk0(walk0), .walk1(walk1), .sound7(sound7),
    .lvl0(lvl0), .lvl1(lvl1), .lvl7(lvl7),
    .sdiv(sdiv), .mul_a(d_mul_a), .mul_b(d_mul_b), .mul_p(mul_p)
);

logic signed [49:0] pf1, m2, m3, m4, m5;
logic signed [31:0] l01, l7;
wire  [9:0] lvsum = {1'b0, lvl0} + {1'b0, lvl1};
wire  signed [31:0] mix = f2 + l01 + l7;
wire  signed [32:0] d2  = 33'(f1) - 33'(f2), d3 = 33'(mix) - 33'(f3);
wire  signed [32:0] d4  = 33'(f3) - 33'(h1), d5 = 33'(y1) - 33'(h2);
always_comb begin
    case (sdiv)
        8'd8:  begin mul_a = 40'(f1); mul_b = 27'(A1); end
        8'd9:  begin mul_a = 40'(d2); mul_b = 27'(A2); end
        8'd10: begin mul_a = 40'(d4); mul_b = 27'sd2906; end
        8'd11: begin mul_a = 40'(d5); mul_b = 27'sd1859; end
        8'd12: begin mul_a = 40'(lvsum); mul_b = 27'sd90440; end
        8'd13: begin mul_a = 40'(lvl7); mul_b = 27'sd19897; end
        8'd16: begin mul_a = 40'(d3); mul_b = 27'(A3); end
        default: begin mul_a = d_mul_a; mul_b = d_mul_b; end
    endcase
end
always_ff @(posedge clk) begin
    case (sdiv)
        8'd10: pf1 <= 50'(mul_p);
        8'd11: m2  <= 50'(mul_p);
        8'd12: m4  <= 50'(mul_p);
        8'd13: m5  <= 50'(mul_p);
        8'd14: l01 <= 32'(mul_p);
        8'd15: l7  <= 32'(mul_p);
        8'd18: m3  <= 50'(mul_p);
        default: ;
    endcase
end

wire  signed [49:0] xa1 = 50'({dac, 27'd0}) + 50'({dac, 25'd0}) + 50'({dac, 22'd0}) + 50'({dac, 21'd0}) + 50'({dac, 18'd0});
wire  signed [49:0] m1  = xa1 - pf1;
always_ff @(posedge clk) begin
    if (reset) begin f1 <= 32'sd0; f2 <= 32'sd0; f3 <= 32'sd0; h1 <= 32'sd0; h2 <= 32'sd0; end
    else if (step) begin
        f1 <= f1 + 32'(m1 >>> 16);
        f2 <= f2 + 32'(m2 >>> 16);
        f3 <= f3 + 32'(m3 >>> 16);
        h1 <= h1 + 32'(m4 >>> 24);
        h2 <= h2 + 32'(m5 >>> 24);
    end
end

wire signed [31:0] ac = y1 - h2;
wire signed [39:0] a28 = (40'(ac) <<< 4) + (40'(ac) <<< 3) + (40'(ac) <<< 2);
wire signed [23:0] o  = 24'(a28 >>> 14);
assign audio = (o > 24'sd32767) ? 16'sd32767 : (o < -24'sd32768) ? -16'sd32768 : o[15:0];

endmodule
