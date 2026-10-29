//  Based on MAME sn76477.cpp (Zsolt Vasvari, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module sn76477 #(
    parameter logic [31:0] C2P = 32'd20574012
)
(
    input  logic        clk,
    input  logic        reset,
    input  logic        step,

    input  logic        enable,
    input  logic        vco_sel,
    input  logic  [2:0] mixer,          // {C, B, A}
    input  logic  [1:0] env,            // {2, 1}
    input  logic [31:0] vco_v,

    input  logic [31:0] os_c, os_d,
    input  logic [31:0] slf_c, slf_d,
    input  logic [31:0] vco_c, vco_d,
    input  logic [31:0] nf_c, nf_d,
    input  logic [31:0] ad_c, ad_d,
    input  logic [31:0] noise_f,
    input  logic [31:0] fs,

    output logic [31:0] vout
);

localparam logic [31:0] V_OS_MAX  = 32'd41943040;
localparam logic [31:0] V_SLF_MIN = 32'd5536481;
localparam logic [31:0] V_SLF_MAX = 32'd39762002;
localparam logic [31:0] V_VCO_D   = 32'd5872026;
localparam logic [31:0] V_VCO_MAX = 32'd45634028;
localparam logic [31:0] V_NF_MAX  = 32'd83886080;
localparam logic [31:0] V_NF_HI   = 32'd56203674;
localparam logic [31:0] V_NF_LO   = 32'd12415139;
localparam logic [31:0] V_AD_MAX  = 32'd74490839;
localparam logic [31:0] V_CEN     = 32'd43117445;
localparam logic [31:0] V_CLIP_H  = 32'd58887045;
localparam logic [31:0] V_CLIP_L  = 32'd11995709;

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
        if (en_fall) begin os_run <= 1'b1; en_fall <= 1'b0; end
        else if (os_run) begin
            os_v <= up(os_v, os_c, V_OS_MAX);
            if (up(os_v, os_c, V_OS_MAX) >= V_OS_MAX) os_run <= 1'b0;
        end else os_v <= dn(os_v, os_d, 32'd0);

        if (!slf_ff) begin slf_v <= up(slf_v, slf_c, V_SLF_MAX); if (up(slf_v, slf_c, V_SLF_MAX) >= V_SLF_MAX) slf_ff <= 1'b1; end
        else         begin slf_v <= dn(slf_v, slf_d, V_SLF_MIN); if (dn(slf_v, slf_d, V_SLF_MIN) <= V_SLF_MIN) slf_ff <= 1'b0; end

        if (!vco_ff) begin
            vco_cap <= up(vco_cap, vco_c, vco_lim);
            if (up(vco_cap, vco_c, vco_lim) >= vco_lim) begin vco_ff <= 1'b1; vco_alt <= ~vco_alt; end
        end else begin
            vco_cap <= dn(vco_cap, vco_d, V_SLF_MIN);
            if (dn(vco_cap, vco_d, V_SLF_MIN) <= V_SLF_MIN) vco_ff <= 1'b0;
        end

        if (nacc + noise_f >= fs) begin
            nacc <= nacc + noise_f - fs;
            noise_bit <= rng_bit;
            rng <= {rng_bit, rng[30:1]};
        end else nacc <= nacc + noise_f;
        nf_v <= nf_n;
        if (nf_n >= V_NF_HI) nf_bit <= 1'b0;
        else if (nf_n <= V_NF_LO) nf_bit <= 1'b1;

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
wire  [35:0] idx10 = ({4'd0, ad_v} << 3) + ({4'd0, ad_v} << 1);
wire   [5:0] gi    = (idx10[35:24] > 12'd44) ? 6'd44 : 6'(idx10[35:24]);
logic [31:0] gpc [45], gnc [45];
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
