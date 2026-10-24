//============================================================================
//
//  TI SN76477 complex sound generator, sample-stepped (MAME sn76477.cpp model, Derrick Renaud / Zsolt Vasvari et al.)
//  Copyright (C) 2026 Rodimus
//
//  Volts in Q8.24. The RC networks are the chip's measured charge / discharge rates (MAME's fitted formulas), so the
//  per-sample steps depend only on the external parts: the owner computes them (verilator/n8080snd/gen_sn_consts.py)
//  and passes the ones for the current pin state. Thresholds, noise LFSR, mixer / envelope modes, output gain
//  curves and clip levels are MAME's measured values. One update per `step`.
//    enable  = pin 9 (1 = inhibit; a falling edge restarts the attack and the one-shot)
//    vco_sel = pin 22 (1 = the SLF sweeps the VCO, 0 = pin 16 voltage)
//    mixer   = {C, B, A} = pins 27, 25, 26; env = {2, 1} = pins 28, 1
//  vout = pin 13 (volts), 2.57 V idle.
//
//============================================================================

module sn76477 #(
    parameter logic [31:0] C2P = 32'd20574012       // centre-to-peak output (Q24 volts): 3.818 x Rf / Ra + 0.03
)
(
    input  logic        clk,
    input  logic        reset,
    input  logic        step,

    input  logic        enable,         // pin 9, high = inhibit
    input  logic        vco_sel,        // pin 22
    input  logic  [2:0] mixer,          // {C, B, A}
    input  logic  [1:0] env,            // {2, 1}
    input  logic [31:0] vco_v,          // pin 16 external VCO voltage (Q24)

    input  logic [31:0] os_c, os_d,     // per-sample steps (Q24 volts)
    input  logic [31:0] slf_c, slf_d,
    input  logic [31:0] vco_c, vco_d,
    input  logic [31:0] nf_c, nf_d,
    input  logic [31:0] ad_c, ad_d,
    input  logic [31:0] noise_f,        // noise clock (Hz)
    input  logic [31:0] fs,             // sample rate (Hz)

    output logic [31:0] vout            // pin 13 (Q24 volts)
);

localparam logic [31:0] V_OS_MAX  = 32'd41943040;   // 2.5
localparam logic [31:0] V_SLF_MIN = 32'd5536481;    // 0.33
localparam logic [31:0] V_SLF_MAX = 32'd39762002;   // 2.37
localparam logic [31:0] V_VCO_D   = 32'd5872026;    // 0.35 VCO above SLF
localparam logic [31:0] V_VCO_MAX = 32'd45634028;   // 2.72
localparam logic [31:0] V_NF_MAX  = 32'd83886080;   // 5.0
localparam logic [31:0] V_NF_HI   = 32'd56203674;   // 3.35
localparam logic [31:0] V_NF_LO   = 32'd12415139;   // 0.74
localparam logic [31:0] V_AD_MAX  = 32'd74490839;   // 4.44
localparam logic [31:0] V_CEN     = 32'd43117445;   // 2.57
localparam logic [31:0] V_CLIP_H  = 32'd58887045;   // 3.51
localparam logic [31:0] V_CLIP_L  = 32'd11995709;   // 0.715

// MAME out_pos_gain / out_neg_gain (magnitudes x 2^16), index = A/D cap volts x 10
localparam logic [16:0] GP [45] = '{0, 0, 0, 0, 0, 0, 0, 0, 0, 655, 1966, 7209, 9830, 12452, 13763, 15073, 17039, 19005,
    20316, 21627, 23593, 24904, 26870, 28180, 30147, 32113, 34079, 35389, 37356, 39322, 40632, 42598, 44564, 45875, 47841,
    49807, 52429, 53740, 55050, 57016, 58982, 60948, 62915, 64225, 65536};
localparam logic [16:0] GN [45] = '{0, 0, 0, 0, 0, 0, 0, 0, 0, 655, 1311, 5898, 8520, 9830, 11141, 12452, 14418, 15729,
    17039, 18350, 19661, 20972, 22282, 24248, 25559, 26870, 28836, 30147, 31457, 33423, 34734, 36700, 38011, 39322, 40632,
    42598, 43909, 45220, 47186, 48497, 49807, 51118, 53084, 55050, 55705};

logic [31:0] os_v, slf_v, vco_cap, nf_v, ad_v;
logic        os_run, slf_ff, vco_ff, vco_alt, nf_bit, noise_bit;
logic [30:0] rng;
logic [31:0] nacc;
logic        en_q, en_fall;

function automatic [31:0] up(input [31:0] v, input [31:0] d, input [31:0] lim);
    up = ({1'b0, v} + {1'b0, d} >= {1'b0, lim}) ? lim : v + d;
endfunction
function automatic [31:0] dn(input [31:0] v, input [31:0] d, input [31:0] lim);
    dn = ({1'b0, v} <= {1'b0, lim} + {1'b0, d}) ? lim : v - d;
endfunction

wire [31:0] vco_lim = (vco_sel ? slf_v : vco_v) + V_VCO_D;
wire [31:0] nf_n    = noise_bit ? up(nf_v, nf_c, V_NF_MAX) : dn(nf_v, nf_d, 32'd0);
wire        rng_bit = ((rng & 31'h1000001F) == 31'd0) ? 1'b1 : (rng[28] ^ rng[0]);

always_ff @(posedge clk) begin
    en_q <= enable;
    if (en_q && !enable) en_fall <= 1'b1;
    if (reset) begin
        os_v <= 32'd0; slf_v <= V_SLF_MIN; vco_cap <= V_SLF_MIN; nf_v <= 32'd0; ad_v <= 32'd0;
        os_run <= 1'b0; slf_ff <= 1'b0; vco_ff <= 1'b0; vco_alt <= 1'b0; nf_bit <= 1'b0; noise_bit <= 1'b0;
        rng <= 31'd0; nacc <= 32'd0; en_fall <= 1'b0;
    end else if (step) begin
        // one-shot: a falling enable edge starts it (and the attack phase)
        if (en_fall) begin os_run <= 1'b1; en_fall <= 1'b0; end
        else if (os_run) begin
            os_v <= up(os_v, os_c, V_OS_MAX);
            if (up(os_v, os_c, V_OS_MAX) >= V_OS_MAX) os_run <= 1'b0;
        end else os_v <= dn(os_v, os_d, 32'd0);

        // SLF triangle
        if (!slf_ff) begin slf_v <= up(slf_v, slf_c, V_SLF_MAX); if (up(slf_v, slf_c, V_SLF_MAX) >= V_SLF_MAX) slf_ff <= 1'b1; end
        else         begin slf_v <= dn(slf_v, slf_d, V_SLF_MIN); if (dn(slf_v, slf_d, V_SLF_MIN) <= V_SLF_MIN) slf_ff <= 1'b0; end

        // VCO triangle up to the SLF (or pin 16) voltage + 0.35
        if (!vco_ff) begin
            vco_cap <= up(vco_cap, vco_c, vco_lim);
            if (up(vco_cap, vco_c, vco_lim) >= vco_lim) begin vco_ff <= 1'b1; vco_alt <= ~vco_alt; end
        end else begin
            vco_cap <= dn(vco_cap, vco_d, V_SLF_MIN);
            if (dn(vco_cap, vco_d, V_SLF_MIN) <= V_SLF_MIN) vco_ff <= 1'b0;
        end

        // noise: LFSR clocked at noise_f, then the RC filter with hysteresis
        if (nacc + noise_f >= fs) begin
            nacc <= nacc + noise_f - fs;
            noise_bit <= rng_bit;
            rng <= {rng_bit, rng[30:1]};
        end else nacc <= nacc + noise_f;
        nf_v <= nf_n;
        if (nf_n >= V_NF_HI) nf_bit <= 1'b0;
        else if (nf_n <= V_NF_LO) nf_bit <= 1'b1;

        // attack / decay
        if (en_fall) ad_v <= 32'd0;
        else begin
            logic chg;
            case (env)
                2'd0:    chg = vco_ff;
                2'd1:    chg = os_run;
                2'd3:    chg = vco_ff & vco_alt;
                default: chg = 1'b1;
            endcase
            ad_v <= chg ? up(ad_v, ad_c, V_AD_MAX) : dn(ad_v, ad_d, 32'd0);
        end
    end
end

// output (pin 13)
logic       mix;
always_comb begin
    case (mixer)
        3'd0:    mix = vco_ff;
        3'd1:    mix = slf_ff;
        3'd2:    mix = nf_bit;
        3'd3:    mix = vco_ff & nf_bit;
        3'd4:    mix = slf_ff & nf_bit;
        3'd5:    mix = vco_ff & slf_ff & nf_bit;
        3'd6:    mix = vco_ff & slf_ff;
        default: mix = 1'b0;
    endcase
end
// MULPOOL-2026-10-23: originals (two run-time multipliers by the constant c2p, one by 10)
// wire  [35:0] idx10 = {4'd0, ad_v} * 36'd10;
// wire  [48:0] gp    = 49'(GP[gi]) * 49'(c2p);
// wire  [48:0] gn    = 49'(GN[gi]) * 49'(c2p);
wire  [35:0] idx10 = ({4'd0, ad_v} << 3) + ({4'd0, ad_v} << 1);
wire   [5:0] gi    = (idx10[35:24] > 12'd44) ? 6'd44 : 6'(idx10[35:24]);
logic [31:0] gpc [45], gnc [45];                    // GP / GN x C2P >> 16, folded at elaboration
genvar gk;
generate
    for (gk = 0; gk < 45; gk++) begin : gtab
        localparam logic [48:0] PP = 49'(GP[gk]) * 49'(C2P);
        localparam logic [48:0] PN = 49'(GN[gk]) * 49'(C2P);
        assign gpc[gk] = PP[47:16];
        assign gnc[gk] = PN[47:16];
    end
endgenerate
wire  [32:0] hi    = {1'b0, V_CEN} + {1'b0, gpc[gi]};
wire  [32:0] lo    = {1'b0, V_CEN} - {1'b0, gnc[gi]};
always_ff @(posedge clk) begin
    if (enable || vco_cap > V_VCO_MAX) vout <= V_CEN;
    else if (mix) vout <= (hi > {1'b0, V_CLIP_H}) ? V_CLIP_H : hi[31:0];
    else          vout <= (lo < {1'b0, V_CLIP_L}) ? V_CLIP_L : lo[31:0];
end

endmodule
