//  Based on MAME n8080_a.cpp (Pierpaolo Prazzoli, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module n8080_sound
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic        hf,
    input  logic        sfev,

    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,
    output chip_pool_pkg::sn76477_i_t sn76477_0_i,
    input  chip_pool_pkg::sn76477_o_t sn76477_0_o,

    input  logic  [7:0] snd1,
    input  logic  [7:0] snd2,
    output logic [11:0] pa,
    input  logic  [7:0] pd,
    output logic signed [15:0] audio,

    output logic signed [39:0] mul_a,
    output logic signed [26:0] mul_b,
    input  logic signed [66:0] mul_p
);

logic [12:1] pin;
always_comb begin
    pin[7] = ~snd1[0]; pin[5] = ~snd1[1]; pin[6] = ~snd1[2]; pin[3] = ~snd1[3]; pin[4] = ~snd1[4]; pin[1] = ~snd1[5];
    pin[8] = ~snd2[0]; pin[9] = ~snd2[1]; pin[10] = ~snd2[2]; pin[11] = ~snd2[3]; pin[2] = ~snd2[4]; pin[12] = ~snd2[5];
end

logic [15:0] xacc = 16'd0;
logic        xen  = 1'b0;
always_ff @(posedge clk) begin
    xen <= 1'b0;
    if (!pause) begin
        if (xacc >= 16'd43152) begin xacc <= xacc - 16'd43152; xen <= 1'b1; end
        else xacc <= xacc + 16'd6000;
    end
end

wire [7:0] p1_pins = {pin[1], pin[2], pin[3], pin[5], pin[8], pin[9], pin[10], pin[11]};

assign pa = {2'b00, mcs48_0_o.pmem_a[9:0]};
assign mcs48_0_i.reset_n = ~reset;
assign mcs48_0_i.xtal_en = xen;
assign mcs48_0_i.int_n   = hf ? pin[6] : (pin[2] & pin[3] & pin[5]);
assign mcs48_0_i.t0      = hf ? pin[3] : pin[7];
assign mcs48_0_i.t1      = hf ? pin[4] : pin[12];
assign mcs48_0_i.p1_in   = hf ? mcs48_0_o.p1 : (mcs48_0_o.p1 & p1_pins);
assign mcs48_0_i.p2_in   = hf ? (mcs48_0_o.p2 & {3'b000, pin[12], 4'b0000}) : mcs48_0_o.p2;
assign mcs48_0_i.db      = hf ? {4'h0, pin[1], pin[9], pin[8], pin[7]} : 8'hFF;
assign mcs48_0_i.pmem_d  = pd;

logic [7:0] sdiv = 8'd0;
wire        step = sdiv == 8'd0 && !pause;
always_ff @(posedge clk) sdiv <= sdiv + 8'd1;

localparam logic [31:0] SH_NOISE     = 32'd31510;
localparam logic [31:0] SH_NF_C      = 32'd14558703;
localparam logic [31:0] SH_NF_D      = 32'd14254704;
localparam logic [31:0] SH_SLF_C     = 32'd4166;
localparam logic [31:0] SH_SLF_D     = 32'd4512;
localparam logic [31:0] SH_OS_C      = 32'd9417;
localparam logic [31:0] SH_OS_D      = 32'd3758602;
localparam logic [31:0] SH_AD_C      = 32'd19399;
localparam logic [31:0] SH_AD_D0     = 32'd626;
localparam logic [31:0] SH_VC0_50    = 32'd178211;
localparam logic [31:0] SH_VC0_C18   = 32'd108665;
localparam logic [31:0] SH_VC0_D18   = 32'd292267;
localparam logic [31:0] SF_NOISE     = 32'd31510;
localparam logic [31:0] SF_NF_C      = 32'd11538536;
localparam logic [31:0] SF_NF_D      = 32'd11711746;
localparam logic [31:0] SF_SLF_C     = 32'd6155;
localparam logic [31:0] SF_SLF_D     = 32'd6655;
localparam logic [31:0] SF_OS_C      = 32'd6619;
localparam logic [31:0] SF_OS_D      = 32'd3758602;
localparam logic [31:0] SF_AD_C      = 32'd19399;
localparam logic [31:0] SF_AD_D0     = 32'd388;
localparam logic [31:0] SF_AD_D1     = 32'd2974;
localparam logic [31:0] SF_VC0_50    = 32'd178211;
localparam logic [31:0] SF_VC0_C18   = 32'd108665;
localparam logic [31:0] SF_VC0_D18   = 32'd292267;
localparam logic [31:0] SF_VC1_50    = 32'd609368;
localparam logic [31:0] SF_VC1_C18   = 32'd371566;
localparam logic [31:0] SF_VC1_D18   = 32'd999363;
localparam logic [31:0] SF_VCO_K     = 32'd397;
localparam logic [31:0] SH_MONO      = 32'd114998;
localparam logic [31:0] SF_MONO0     = 32'd380160;
localparam logic [31:0] SF_MONO12    = 32'd76666;
localparam logic [31:0] V5     = 32'd83886080;
localparam logic [31:0] MUS_HI = 32'd18236457;

logic [12:1] pin_q;
always_ff @(posedge clk) pin_q <= pin;
wire  [12:1] fall = pin_q & ~pin;
logic [18:0] mo0 = 19'd0, mo1 = 19'd0, mo2 = 19'd0;
logic        f3 = 1'b0, f4 = 1'b0, f6 = 1'b0;
always_ff @(posedge clk) begin
    if (reset) begin
        mo0 <= 19'd0; mo1 <= 19'd0; mo2 <= 19'd0; f3 <= 1'b0; f4 <= 1'b0; f6 <= 1'b0;
    end else begin
        if (fall[3]) f3 <= 1'b1;
        if (fall[4]) f4 <= 1'b1;
        if (fall[6]) f6 <= 1'b1;
        if (step) begin
            f3 <= 1'b0; f4 <= 1'b0; f6 <= 1'b0;
            if (sfev) begin
                mo0 <= f3 ? 19'(SF_MONO0) : (mo0 != 19'd0) ? mo0 - 19'd1 : 19'd0;
                mo1 <= f6 ? 19'(SF_MONO12) : f3 ? 19'd0 : (mo1 != 19'd0) ? mo1 - 19'd1 : 19'd0;
                mo2 <= f4 ? 19'(SF_MONO12) : (f3 || f6) ? 19'd0 : (mo2 != 19'd0) ? mo2 - 19'd1 : 19'd0;
            end else begin
                mo0 <= f6 ? 19'(SH_MONO) : (mo0 != 19'd0) ? mo0 - 19'd1 : 19'd0;
                mo1 <= f4 ? 19'(SH_MONO) : f6 ? 19'd0 : (mo1 != 19'd0) ? mo1 - 19'd1 : 19'd0;
                mo2 <= 19'd0;
            end
        end
    end
end
wire m0 = mo0 != 19'd0, m1 = mo1 != 19'd0, m2 = mo2 != 19'd0;

wire sf_after = m0 | (m1 & ~f3) | (m2 & ~(f3 | f6));
wire sh_after = m0 | (m1 & ~f6);
logic en_g = 1'b0;
always_ff @(posedge clk) begin
    if (reset) en_g <= 1'b0;
    else if (step) en_g <= sfev ? ((f3 | f4 | f6) & (m0 | m1 | m2) & ~sf_after) : ((f4 | f6) & (m0 | m1) & ~sh_after);
end

logic [31:0] sf_vco = 32'd0;
wire  [31:0] sf_gap = V5 - sf_vco;
logic [55:0] sf_dv;
always_ff @(posedge clk) begin
    if (reset || !m2) sf_vco <= 32'd0;
    else if (step) sf_vco <= sf_vco + 32'(sf_dv >> 24);
end

logic        sn_en, sn_vsel;
logic  [2:0] sn_mix;
logic [31:0] sn_vco_v, sn_ad_d, sn_vc, sn_vd;
always_comb begin
    if (sfev) begin
        sn_en    = en_g || (!m0 && !m1 && !m2);
        sn_vsel  = m1;
        sn_mix   = {1'b0, m0, 1'b0};
        sn_vco_v = sf_vco;
        sn_ad_d  = m0 ? SF_AD_D0 : SF_AD_D1;
        if (sf_vco != 32'd0) begin sn_vc = m1 ? SF_VC0_C18 : SF_VC1_C18; sn_vd = m1 ? SF_VC0_D18 : SF_VC1_D18; end
        else                 begin sn_vc = m1 ? SF_VC0_50  : SF_VC1_50;  sn_vd = sn_vc; end
    end else begin
        sn_en    = en_g || (!m0 && !m1);
        sn_vsel  = m0;
        sn_mix   = {1'b0, !m0, 1'b0};
        sn_vco_v = m1 ? V5 : 32'd0;
        sn_ad_d  = SH_AD_D0;
        if (m1) begin sn_vc = SH_VC0_C18; sn_vd = SH_VC0_D18; end
        else    begin sn_vc = SH_VC0_50;  sn_vd = SH_VC0_50;  end
    end
end

logic [31:0] sn_out;
assign sn76477_0_i.reset = reset | hf;
assign sn76477_0_i.step = step;
assign sn76477_0_i.enable = sn_en;
assign sn76477_0_i.vco_sel = sn_vsel;
assign sn76477_0_i.mixer = sn_mix;
assign sn76477_0_i.env = 2'b01;
assign sn76477_0_i.vco_v = sn_vco_v;
assign sn76477_0_i.os_c = sfev ? SF_OS_C : SH_OS_C;
assign sn76477_0_i.os_d = sfev ? SF_OS_D : SH_OS_D;
assign sn76477_0_i.slf_c = sfev ? SF_SLF_C : SH_SLF_C;
assign sn76477_0_i.slf_d = sfev ? SF_SLF_D : SH_SLF_D;
assign sn76477_0_i.vco_c = sn_vc;
assign sn76477_0_i.vco_d = sn_vd;
assign sn76477_0_i.nf_c = sfev ? SF_NF_C : SH_NF_C;
assign sn76477_0_i.nf_d = sfev ? SF_NF_D : SH_NF_D;
assign sn76477_0_i.ad_c = sfev ? SF_AD_C : SH_AD_C;
assign sn76477_0_i.ad_d = sn_ad_d;
assign sn76477_0_i.noise_f = sfev ? SF_NOISE : SH_NOISE;
assign sn76477_0_i.fs = 32'd192000;
assign sn_out = sn76477_0_o.vout;
wire signed [32:0] sn_ac = 33'(sn_out) - 33'sd43117445;
logic signed [49:0] sn_m;
wire signed [31:0] sn_mixv = 32'(sn_m >>> 16);

localparam signed [17:0] K_LP = 18'sd3327;
localparam signed [17:0] F  = 18'sd4108;
localparam signed [17:0] D  = 18'sd88441;
localparam logic [31:0] E_ATT = 32'd17467;
localparam logic [31:0] E_DEC = 32'd546;
localparam signed [17:0] K_DC = 18'sd5633;

logic signed [31:0] y = 32'sd0, lo = 32'sd0, bp = 32'sd0, h = 32'sd0;
logic        [24:0] env = 25'd0;
logic signed [31:0] v_r = 32'sd0;
logic signed [49:0] fb, dbm, lp1, lp0, p3, p4;
logic signed [50:0] mh;
logic signed [57:0] lv1, lv0;
logic        [49:0] ea, ed;
wire  signed [31:0] lo_n    = lo + 32'(fb >>> 16);
wire  signed [31:0] dbs     = 32'(dbm >>> 16);
wire         [24:0] envc    = 25'd16777216 - env;
wire         [24:0] env1    = env + 25'(ea >> 24);
wire         [24:0] env0    = env - 25'(ed >> 24);
wire  signed [32:0] d_lp1   = 33'($signed(MUS_HI) + sn_mixv) - 33'(y);
wire  signed [32:0] d_lp0   = 33'(sn_mixv) - 33'(y);
wire  signed [32:0] dh      = 33'(v_r) - 33'(h);

always_comb begin
    mul_a = 40'sd0; mul_b = 27'sd0;
    case (sdiv)
        8'd8:  begin mul_a = 40'(bp);                 mul_b = 27'(F);            end
        8'd9:  begin mul_a = 40'(bp);                 mul_b = 27'(D);            end
        8'd10: begin mul_a = 40'($signed({1'b0, envc})); mul_b = 27'($signed({1'b0, E_ATT[25:0]})); end
        8'd11: begin mul_a = 40'($signed({1'b0, env}));  mul_b = 27'($signed({1'b0, E_DEC[25:0]})); end
        8'd12: begin mul_a = 40'(sn_ac);              mul_b = 27'sd283989;       end
        8'd13: begin mul_a = 40'($signed({1'b0, sf_gap})); mul_b = 27'($signed({1'b0, SF_VCO_K[25:0]})); end
        8'd14: begin mul_a = 40'(lo_n);               mul_b = 27'(F);            end
        8'd15: begin mul_a = 40'(dbs);                mul_b = 27'(F);            end
        8'd16: begin mul_a = 40'(dh);                 mul_b = 27'(K_DC);         end
        8'd17: begin mul_a = 40'(d_lp1);              mul_b = 27'(K_LP);         end
        8'd18: begin mul_a = 40'(d_lp0);              mul_b = 27'(K_LP);         end
        8'd19: begin mul_a = 40'(lo_n);               mul_b = 27'($signed({1'b0, env1})); end
        8'd20: begin mul_a = 40'(lo_n);               mul_b = 27'($signed({1'b0, env0})); end
        default: ;
    endcase
end
always_ff @(posedge clk) begin
    case (sdiv)
        8'd10: fb    <= 50'(mul_p);
        8'd11: dbm   <= 50'(mul_p);
        8'd12: ea    <= 50'(mul_p);
        8'd13: ed    <= 50'(mul_p);
        8'd14: sn_m  <= 50'(mul_p);
        8'd15: sf_dv <= 56'(mul_p);
        8'd16: p3    <= 50'(mul_p);
        8'd17: p4    <= 50'(mul_p);
        8'd18: mh    <= 51'(mul_p);
        8'd19: lp1   <= 50'(mul_p);
        8'd20: lp0   <= 50'(mul_p);
        8'd21: lv1   <= 58'(mul_p);
        8'd22: lv0   <= 58'(mul_p);
        default: ;
    endcase
end

wire  [7:0]         p1     = mcs48_0_o.p1;
wire  signed [49:0] xf     = 50'({p1, 28'd0}) + 50'({p1, 19'd0}) + 50'({p1, 18'd0});
wire  signed [49:0] fh     = xf - p3 - p4;
wire  signed [49:0] lp_m   = mcs48_0_o.p2[7] ? lp1 : lp0;
wire  signed [31:0] y_n    = y + 32'(lp_m >>> 16);
wire  signed [57:0] lv_n   = mcs48_0_o.p2[7] ? lv1 : lv0;

always_ff @(posedge clk) begin
    if (reset) begin
        y <= 32'sd0; lo <= 32'sd0; bp <= 32'sd0; h <= 32'sd0; env <= 25'd0; v_r <= 32'sd0;
    end else if (step) begin
        y   <= y_n;
        lo  <= lo_n;
        bp  <= bp + 32'(fh >>> 16);
        h   <= h + 32'(mh >>> 24);
        env <= mcs48_0_o.p2[7] ? env1 : env0;
        v_r <= hf ? 32'(lv_n >>> 24) : y_n;
    end
end

wire signed [32:0] o   = 33'(v_r) - 33'(h);
wire signed [36:0] o_m = (37'(o) <<< 3) + (37'(o) <<< 1);
wire signed [32:0] o_s = hf ? (o >>> 10) : 33'(o_m >>> 15);
always_ff @(posedge clk) audio <= (o_s > 33'sd32767) ? 16'sd32767 : (o_s < -33'sd32768) ? 16'sh8000 : 16'(o_s);

endmodule
