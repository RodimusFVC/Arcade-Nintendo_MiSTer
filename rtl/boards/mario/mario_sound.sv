//============================================================================
//
//  Nintendo Mario Bros. sound (TMA1-CPU sheet, sound quarter; MAME mario.cpp mario_state + nl_mario.cpp)
//  Copyright (C) 2026 Rodimus
//
//  Sound CPU M58715 5L (8039 family, X2 11 MHz) = the pooled T48 (mcs48_0). Its 2K internal ROM is not dumped; as
//  MAME, it is a bootstrap "SEL MB1 / JMP 0" (F5 04 00, then 00s) that jumps to the external 2732 6K at 0x800.
//  EA = P2.5 inverted: internal ROM answers 0000-07FF only while EA is low.
//  Ports (MAME mario): MOVX read = P2.7 ? sound latch 7E00 (7J LS374) : 6K ROM at {P2 3-0, A7-0}; MOVX write = DAC;
//  P1 in = latch 7F03-7F06 (crab / turtle / fly / coin); P2 in = P2 out with bit 4 grounded; T0 / T1 = 7F01 / 7F02
//  (get coin / ice); INT = 7F00 (death, level).
//  DAC (MAME R2R 3.4 V) -> 3M LM3900 inverting x -0.5 (R35 1M / R34 2M) -> C20 1u -> 3M multiple-feedback low-pass
//  (R37 750K in, R39 750K feedback, R38 360K, C18 / C30 100p: gain -1, f0 3.06 kHz, Q 0.35 = real poles at 1266 Hz and
//  7411 Hz) -> R40 22K into the mix node (walk R19 / R20 22K, skid R41 100K, C31 0.022u: ~1048 Hz with the 6.9K
//  source) -> C32 1u into 43K || 100K (30 ms) -> Q10 follower -> C47 4.7u into VR1 10K (47 ms). Values on the TMA1-CPU
//  sheet = nl_mario.cpp.
//  Walk / skid discrete circuits: mario_discrete.sv; their TTL outputs join the mix node (R20 / R19 22K, R41 100K).
//
//============================================================================

module mario_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,

    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] tune,           // 7E00 latch
    input  logic  [3:0] lat1,           // 7F03-7F06 -> P1 0-3
    input  logic  [1:0] lat3,           // 7F01 / 7F02 -> T0 / T1
    input  logic        irq,            // 7F00
    input  logic        walk0,          // 7C00 write
    input  logic        walk1,          // 7C80 write
    input  logic        sound7,         // SOUND7 (7F07 data inverted)

    output logic [11:0] pa,             // 6K program
    input  logic  [7:0] pd,
    output logic [12:0] xa,             // 6K MOVX data
    input  logic  [7:0] xd,

    output logic signed [15:0] audio,

    // MULPOOL-2026-10-23: the dispatcher's shared multiplier (rtl/nintendo_board.sv): a / b in clock t, product in t + 2
    output logic signed [39:0] mul_a,
    output logic signed [26:0] mul_b,
    input  logic signed [66:0] mul_p
);

// ------------------------------------------------------------------ 8039 (11 MHz crystal from 49.152 MHz)
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
wire [7:0] boot = (ia_q == 11'd0) ? 8'hF5 : (ia_q == 11'd1) ? 8'h04 : 8'h00;   // MAME fake internal ROM

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

// DAC: MOVX write data, sampled for the whole /WR low time (the T48 still drives the address byte when /WR falls;
// the data is valid by /WR rising)
logic [7:0] dac = 8'd0;
always_ff @(posedge clk) begin
    if (reset) dac <= 8'd0;
    else if (!mcs48_0_o.wr_n) dac <= mcs48_0_o.db;
end

// ------------------------------------------------------------------ analog: one-pole sections at 192 kHz (clk / 256)
// signal = DAC code x 256 (16.16 in the accumulators); coefficients a = 1 - exp(-2 pi f / 192 kHz) x 65536
logic [7:0] sdiv = 8'd0;
wire        step = sdiv == 8'd0;
always_ff @(posedge clk) sdiv <= sdiv + 8'd1;

localparam signed [17:0] A1 = 18'sd2660;    // MFB pole 1266 Hz
localparam signed [17:0] A2 = 18'sd14117;   // MFB pole 7411 Hz
localparam signed [17:0] A3 = 18'sd2209;    // mix node C31, 1048 Hz


// MULPOOL-2026-10-23: original analog arithmetic below
// logic signed [31:0] f1 = 32'sd0, f2 = 32'sd0, f3 = 32'sd0, h1 = 32'sd0, h2 = 32'sd0;
// // output coupling: two one-pole high-passes, y = x - lowpass(x); a = 1 - exp(-1 / (192 kHz x tau)) x 2^24
// wire  signed [31:0] y1 = f3 - h1;
// wire  signed [49:0] m4 = 50'(33'(f3) - 33'(h1)) * 50'sd2906;      // tau 30.1 ms
// wire  signed [49:0] m5 = 50'(33'(y1) - 33'(h2)) * 50'sd1859;      // tau 47 ms
//
// // discrete voices into the mix node: a TTL output through 22K, 1/256 of a sample high = 90440 (skid through 100K:
// // x 22K / 100K = 19897). Calibrated on MAME's isolated captures (verilator/mariosnd: envelope corr 0.99 / 0.96 /
// // 0.97): an ideal 3.4 V high would be 2^17; x 0.69 brings the three voices to MAME's level on average (effective
// // V_OH ~2.35 V into the network; MAME's gate-on / gate-off steps are asymmetric, the per-voice ratio stays 0.8-1.2)
// logic [8:0] lvl0, lvl1, lvl7;
// mario_discrete disc
// (
//     .clk(clk), .reset(reset), .run(!pause), .step(step), .walk0(walk0), .walk1(walk1), .sound7(sound7),
//     .lvl0(lvl0), .lvl1(lvl1), .lvl7(lvl7)
// );
// wire signed [31:0] mix = f2 + $signed(32'({1'b0, lvl0} + {1'b0, lvl1}) * 32'sd90440) + $signed(32'(lvl7) * 32'sd19897);
//
// wire  signed [31:0] x0 = {8'd0, dac, 16'd0};
// // differences first at 33 bits, then a full-width signed product (operands sized before the multiply)
// wire  signed [32:0] d1 = 33'(x0) - 33'(f1), d2 = 33'(f1) - 33'(f2), d3 = 33'(mix) - 33'(f3);
// wire  signed [49:0] m1 = 50'(d1) * 50'(A1);
// wire  signed [49:0] m2 = 50'(d2) * 50'(A2);
// wire  signed [49:0] m3 = 50'(d3) * 50'(A3);
// always_ff @(posedge clk) begin
//     if (reset) begin f1 <= 32'sd0; f2 <= 32'sd0; f3 <= 32'sd0; h1 <= 32'sd0; h2 <= 32'sd0; end
//     else if (step) begin
//         f1 <= f1 + 32'(m1 >>> 16);
//         f2 <= f2 + 32'(m2 >>> 16);
//         f3 <= f3 + 32'(m3 >>> 16);
//         h1 <= h1 + 32'(m4 >>> 24);                      // C32 coupling (30 ms)
//         h2 <= h2 + 32'(m5 >>> 24);                      // C47 coupling (47 ms)
//     end
// end
//
// // output: AC part x 28 / 2^14 (DAC full scale 256 << 16): gameplay f200-1150 RMS = MAME's (verilator/mariosnd
// // tb_mariocpu on MAME's write timeline; x 41 was 1.46 x MAME across music, run, jump and walk)
// wire signed [31:0] ac = y1 - h2;
// wire signed [39:0] a28 = 40'(ac) * 40'sd28;
// wire signed [23:0] o  = 24'(a28 >>> 14);
// assign audio = (o > 24'sd32767) ? 16'sd32767 : (o < -24'sd32768) ? -16'sd32768 : o[15:0];

// MULPOOL-2026-10-23: same math; state products from the shared multiplier (issued between steps, same product bits),
// the DAC term and the output x 28 as shift-adds (they see inputs / state that change at any clock)
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
wire  [9:0] lvsum = {1'b0, lvl0} + {1'b0, lvl1};                                       // the original mix terms (32-bit products)
wire  signed [31:0] mix = f2 + l01 + l7;
wire  signed [32:0] d2  = 33'(f1) - 33'(f2), d3 = 33'(mix) - 33'(f3);
wire  signed [32:0] d4  = 33'(f3) - 33'(h1), d5 = 33'(y1) - 33'(h2);
always_comb begin
    case (sdiv)
        8'd8:  begin mul_a = 40'(f1); mul_b = 27'(A1); end                                       // f1 x A1
        8'd9:  begin mul_a = 40'(d2); mul_b = 27'(A2); end                                       // m2
        8'd10: begin mul_a = 40'(d4); mul_b = 27'sd2906; end                                     // m4 (30.1 ms)
        8'd11: begin mul_a = 40'(d5); mul_b = 27'sd1859; end                                     // m5 (47 ms)
        8'd12: begin mul_a = 40'(lvsum); mul_b = 27'sd90440; end          // walk voices
        8'd13: begin mul_a = 40'(lvl7); mul_b = 27'sd19897; end                                  // skid
        8'd16: begin mul_a = 40'(d3); mul_b = 27'(A3); end                                       // m3 (mix at 15)
        default: begin mul_a = d_mul_a; mul_b = d_mul_b; end                                     // mario_discrete, 24-47
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

// m1 = (x0 - f1) x A1, x0 = DAC << 16: DAC x 2660 << 16 (2660 = 2048 + 512 + 64 + 32 + 4) - f1 x A1
wire  signed [49:0] xa1 = 50'({dac, 27'd0}) + 50'({dac, 25'd0}) + 50'({dac, 22'd0}) + 50'({dac, 21'd0}) + 50'({dac, 18'd0});
wire  signed [49:0] m1  = xa1 - pf1;
always_ff @(posedge clk) begin
    if (reset) begin f1 <= 32'sd0; f2 <= 32'sd0; f3 <= 32'sd0; h1 <= 32'sd0; h2 <= 32'sd0; end
    else if (step) begin
        f1 <= f1 + 32'(m1 >>> 16);
        f2 <= f2 + 32'(m2 >>> 16);
        f3 <= f3 + 32'(m3 >>> 16);
        h1 <= h1 + 32'(m4 >>> 24);                      // C32 coupling (30 ms)
        h2 <= h2 + 32'(m5 >>> 24);                      // C47 coupling (47 ms)
    end
end

// output: AC part x 28 / 2^14 (DAC full scale 256 << 16): gameplay f200-1150 RMS = MAME's (verilator/mariosnd
// tb_mariocpu on MAME's write timeline; x 41 was 1.46 x MAME across music, run, jump and walk)
wire signed [31:0] ac = y1 - h2;
wire signed [39:0] a28 = (40'(ac) <<< 4) + (40'(ac) <<< 3) + (40'(ac) <<< 2);   // x 28 (original 40'(ac) * 40'sd28)
wire signed [23:0] o  = 24'(a28 >>> 14);
assign audio = (o > 24'sd32767) ? 16'sd32767 : (o < -24'sd32768) ? -16'sd32768 : o[15:0];

endmodule
