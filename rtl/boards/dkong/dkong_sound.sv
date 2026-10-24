//============================================================================
//
//  Nintendo Donkey Kong sound board (TKG-04 CPU sheet; MAME dkong_a.cpp dkong2b_audio)
//  Copyright (C) 2026 Rodimus
//
//  8035 (MB8884 7H, 6 MHz): program 0x000-0xFFF; MOVX reads the tune latch (P2.6 high: LS175 3D, inverted low
//  nibble) or the sample ROM at 0x1000 + P2[2:0] * 256 + address (P2.6 low).
//    P1 -> DAC-08 8K.  P2.7 low -> Q7 / R20 / C32 decay of the DAC reference (tau 0.1 s).  P2.4 -> IN2 bit 6
//    (inverted on the main board).  P2.5 in = 6H Q3 inverted.  T0 = 6H Q5 inverted, T1 = 6H Q4 inverted.
//    INT = 5H Q0 (7D80).
//  Analog path at 192 kHz (clk / 256), volts in Q8.24:
//    DAC (0-5 V) x decay -> MB3614 Sallen-Key low pass (5.6K / 5.6K, 22n / 10n: 1916 Hz, Q 0.74) -> VR2 (0.9)
//    walk / jump / stomp (6H Q0-Q2): 556 8N VCOs with CD4049 8L LFOs on their CV, LS164 noise, transistor envelopes
//    -> mix (4 x 47K, C159 100n, C12 1u) -> Q3 amp -> output coupling. MAME's model except: emitter followers are
//    ideal (charge to Vb - 0.7), 555s flip at the sample, Q3 = linear -8.4 x with the 0-5 V swing (MAME's 48 kHz
//    transistor step rolls off the treble: gain 2.3 at 3 kHz vs 8.4 in its own model at 768 kHz).
//  Radar Scope (rs, TRS2-03 / 04-SOU sheet, Radar_Scope_Schematics.pdf p11; network as MAME radarscp_discrete with the
//    sheet's values where MAME differs: SOUND0 C22 load 10K, R27 10K, R9 10K, CV networks R55 / R60 at the mid node;
//    model: dksnd/radarscp_discrete.py, constants: dksnd/gen_rs_consts.py, in the verilator dir): same
//    8035 / DAC (VR2 0.35); SOUND2 / SOUND1 (6H Q2 / Q1) = the stomp form on noise QC / QB of a 4-bit LS161 cleared
//    while 6H Q6 is low; SOUND0 (Q0) = the walk form with a resistor CV mixer and its 555 enabled by Q6; SOUND7 (Q7,
//    the game-start siren) = CD4049 LFO -> 555 VCO (enabled by Q7) gating a slow CD4049 sine through R46 / C45;
//    mix 5 x 10K into VR2 10K, C2, the DK Q3 amp form, output CR 1K / 33u, MAME route gain 0.7. Own sequencer block
//    and multiplier (same 256-step sample).
//
//============================================================================

module dkong_sound
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        jr,             // DK Jr.: LS174 latch on MOVX, P2.4-6 inputs, own discrete board
    input  logic        rs,             // Radar Scope (TRS-02) discrete board

    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] tune,           // 7C00 latch
    input  logic  [7:0] sfx,            // 6H LS259 (7D00-7D07)
    input  logic        irq,            // 5H Q0 (7D80)
    input  logic        lat4h1,         // DK Jr. 4H Q1 -> P2.6
    input  logic        snd9,           // DK Jr. 5H Q1: falling

    output logic [11:0] pa,
    input  logic  [7:0] pd,
    output logic [12:0] xa,
    input  logic  [7:0] xd,

    output logic        status,         // P2.4
    output logic signed [15:0] audio
);

// ------------------------------------------------------------------ 8035
// 6 MHz crystal from 49.152 MHz: 6000 / 49152 per clock
logic [15:0] xacc = 16'd0;
logic        xen  = 1'b0;
always_ff @(posedge clk) begin
    xen <= 1'b0;
    if (!pause) begin
        if (xacc >= 16'd43152) begin xacc <= xacc - 16'd43152; xen <= 1'b1; end
        else xacc <= xacc + 16'd6000;
    end
end

wire [7:0] p1 = mcs48_0_o.p1;
wire [7:0] p2 = mcs48_0_o.p2;
logic [7:0] movx_a;
always_ff @(posedge clk) if (mcs48_0_o.ale) movx_a <= mcs48_0_o.db;

assign pa = mcs48_0_o.pmem_a;
assign xa = {2'b10, p2[2:0], movx_a};                 // soundcpu region 0x1000 + page * 256 + a

assign mcs48_0_i.reset_n = ~reset;
assign mcs48_0_i.xtal_en = xen;
assign mcs48_0_i.int_n   = ~irq;
assign mcs48_0_i.t0      = ~sfx[5];
assign mcs48_0_i.t1      = ~sfx[4];
assign mcs48_0_i.p1_in   = 8'hFF;
// MAME virtual_p2: DK P2.5 = 6H Q3 inverted; DK Jr. P2.6 / 5 / 4 = 4H Q1 / 6H Q3 / 6H Q6, inverted
assign mcs48_0_i.p2_in   = jr ? {p2[7], ~lat4h1, ~sfx[3], ~sfx[6], p2[3:0]} : {p2[7:6], ~sfx[3], p2[4:0]};
assign mcs48_0_i.db      = jr ? {3'b000, tune[4:0]} : p2[6] ? {4'h0, ~tune[3:0]} : xd;
assign mcs48_0_i.pmem_d  = pd;

assign status = p2[4];

// ------------------------------------------------------------------ analog
// One step per sample (192 kHz = clk / 256), sequenced through one shared multiplier: an operand pair written at
// step k is multiplied during k + 1 and read as mq at k + 2. Volts Q8.24, coefficients Q2.30.
// Network = verilator/dksnd/dkong_discrete.py with the RTL forms (ri, 555, amp), itself a port of MAME
// dkong2b_discrete; constants generated from that script.
localparam logic signed [31:0] V0_4   = 32'sd6710886;
localparam logic signed [31:0] V0_6   = 32'sd10066330;
localparam logic signed [31:0] V0_7   = 32'sd11744051;
localparam logic signed [31:0] V0_8   = 32'sd13421773;
localparam logic signed [31:0] V0_1   = 32'sd1677722;
localparam logic signed [31:0] V0_25  = 32'sd4194304;
localparam logic signed [31:0] V1_53  = 32'sd25669140;
localparam logic signed [31:0] V4_5   = 32'sd75497472;
localparam logic signed [31:0] V5     = 32'sd83886080;
localparam logic signed [31:0] V5_1   = 32'sd85563802;
localparam logic signed [31:0] Q1     = 32'sd1073741824;              // 1.0 in Q2.30
localparam logic signed [31:0] V5_256 = 32'sd327680;                  // DAC: 5 V / 256 per step
localparam logic signed [31:0] K_ENV  = 32'sd1073685901;              // exp(-dt / 0.1 s): R20 C32
// Sallen-Key 1916 Hz, Q 0.7416, bilinear with pre-warp (MAME calculate_filter2_coefficients)
localparam logic signed [31:0] SK_B0  = 32'sd1012338;
localparam logic signed [31:0] SK_B1  = 32'sd2024675;
localparam logic signed [31:0] SK_A1  = 32'sd2056385588;              // -a1
localparam logic signed [31:0] SK_A2  = 32'sd986693115;               // a2
localparam logic signed [31:0] K_VR2  = 32'sd966367642;               // 0.9
// rcdisc_mod: AL = charge to the clamp, TG = 0.6 V / gain, G = gain, AH = normal charge, TV = -0.6 V / vd_gain
localparam logic signed [31:0] S_AL0 = 32'sd559095,     S_AL1 = 32'sd1067867614, S_TG0 = 32'sd20132659, S_TG1 = 32'sd10067336;
localparam logic signed [31:0] S_AH0 = 32'sd279584,     S_AH1 = 32'sd559039,     S_TV0 = -32'sd20132659, S_TV1 = -32'sd10067336;
localparam logic signed [31:0] W_AL0 = 32'sd297269,     W_AL1 = 32'sd360507,     W_TG0 = 32'sd15804137, W_TG1 = 32'sd14797505;
localparam logic signed [31:0] W_G0  = 32'sd683911990,  W_G1  = 32'sd730436615;
localparam logic signed [31:0] W_AH0 = 32'sd107935,     W_AH1 = 32'sd115277,     W_AH2 = 32'sd256384,    W_AH3 = 32'sd302086;
localparam logic signed [31:0] W_TV0 = -32'sd15804137,  W_TV1 = -32'sd14797505,  W_TV2 = -32'sd73182216, W_TV3 = -32'sd62109254;
// rcdisc2 (A20 toward 5 V, A21 toward 0), emitter follower (RG12 divider, RA0 charge, RA1 discharge)
localparam logic signed [31:0] S_A20 = 32'sd15406,   S_A21 = 32'sd169453, S_RG12 = 32'sd848668040,  S_RA0 = 32'sd7430710,  S_RA1 = 32'sd1561875;
localparam logic signed [31:0] J_A20 = 32'sd10817,   J_A21 = 32'sd118981, J_RG12 = 32'sd1019657503, J_RA0 = 32'sd36642860, J_RA1 = 32'sd1876287;
// CD4049 oscillators (IW / IWC charge, IR = RP / (RP + R)), 555 CV mixers (target CA + in2 * CB, rate CE), 555s
localparam logic signed [31:0] J_IW  = 32'sd94144,    J_IWC = 32'sd94658,    J_IR  = 32'sd1067916823;
localparam logic signed [31:0] W_IW  = 32'sd130048,   W_IWC = 32'sd143052,   W_IR  = 32'sd976128931;
localparam logic signed [31:0] J_CA0 = 32'sd49099987, J_CB0 = 32'sd251391935, J_CE0 = 32'sd238835;
localparam logic signed [31:0] J_CA1 = 32'sd36370189, J_CB1 = 32'sd232769207, J_CE1 = 32'sd257941;
localparam logic signed [31:0] W_CA0 = 32'sd54948567, W_CB0 = 32'sd201478079, W_CE0 = 32'sd752356;
localparam logic signed [31:0] W_CA1 = 32'sd37260079, W_CB1 = 32'sd198720423, W_CE1 = 32'sd762793;
localparam logic signed [31:0] J_5C  = 32'sd1606734,  J_5D  = 32'sd4397907,  W_5C  = 32'sd2287652, W_5D = 32'sd6258240;
localparam logic signed [31:0] W_CR  = 32'sd106233;                   // walk C23 coupling
// mix / amp: 0.7183 = R3 / (R3 + R4) = R25 / (R25 + R26); 4 x 47K into 10K; cF C159; cAmp C12 (100K);
// Q3 stage -8.4 with a 55 Hz high pass; output coupling C13 (50K) / C? (1K, 4.7u); 32767 / 5 * 3.41 * 0.9 per volt
localparam logic signed [31:0] K_RI_OUT = 32'sd771279338, K_MIX = 32'sd123418600, A_CF = 32'sd10302158;
localparam logic signed [31:0] A_CAMP = 32'sd55923, A_AMPHP = 32'sd1930858, A_CR1 = 32'sd3389, A_CR2 = 32'sd1189214;
localparam logic signed [31:0] K_AMP  = -32'sd563714457;              // -8.4 / 16 (result shifted left 4)
localparam logic signed [31:0] K_OUT  = 32'sd1287168;                 // 20112 / 2^24 in Q2.30 terms
localparam logic signed [31:0] K_TFIDX = 32'sd332188877;              // 99 / 5 / 64
// DK Jr. mixer (MAME dkongjr_mixer_desc, but R3 walk / land = 150K per DKJr.pdf p31; MAME 100K): 150K fall, 150K walk,
// 20K climb, 47K jump, 47K DAC; C155 0.01u, C161 1u;
// C13 coupling into 1K; 32767 / 1.18 * 0.5 per volt
localparam logic signed [31:0] JK_S9 = 32'sd67603303, JK_S0 = 32'sd67603303, JK_S2 = 32'sd507024773, JK_S1 = 32'sd215755223;
localparam logic signed [31:0] JA_CF = 32'sd57612785, JK_OUT = 32'sd888597;
// DK Jr. discrete (verilator/dksnd/gen_jr_consts.py): 74LS624 V* = 5K pin 7, 5K pin 10, 8L, 7P (Horner D0-D4 in Q4.28
// half cycles per sample, input targets T* pre-scaled by the 90K input, E = C_FREQ_IN rate), C24 mixer targets,
// rcdisc_mod for Q3 (jump) / Q2 (climb), CR to 2.5 V and RC out
localparam logic signed [31:0] V0_2 = 32'sd3355443, V4_9 = 32'sd82208358, V2_5 = 32'sd41943040, HALF = 32'sd268435456;
// DK Jr. land thump (walk circuit with 7D07 set): swing cut to 1/3 (-9.5 dB) around the 4.9 V idle level -- user trim
// 2026-10-23 ("way too loud" on HW with the schematic's R3 150K); walking keeps the full 0.2 V low
localparam logic signed [31:0] V_LAND = 32'sd55924053;               // 4.9 - (4.9 - 0.2) / 3 V
localparam logic signed [31:0] VA_D0    = 32'sd10526684;   // 0.0392149522
localparam logic signed [31:0] VA_D1    = -32'sd5925939;   // -0.0220758415
localparam logic signed [31:0] VA_D2    = 32'sd8333921;   // 0.0310462733
localparam logic signed [31:0] VA_D3    = -32'sd1782158;   // -0.00663905664
localparam logic signed [31:0] VA_D4    = 32'sd141763;   // 0.000528107252
localparam logic signed [31:0] VA_SC    = 32'sd966367642;   // 0.9
localparam logic signed [31:0] VA_E     = 32'sd188280;   // 0.000175349383
localparam logic signed [31:0] VB_D0    = 32'sd49273838;   // 0.183559351
localparam logic signed [31:0] VB_D1    = -32'sd27738436;   // -0.103333726
localparam logic signed [31:0] VB_D2    = 32'sd39009841;   // 0.145322981
localparam logic signed [31:0] VB_D3    = -32'sd8342017;   // -0.0310764354
localparam logic signed [31:0] VB_D4    = 32'sd663570;   // 0.00247199139
localparam logic signed [31:0] VB_SC    = 32'sd878516038;   // 0.818181818
localparam logic signed [31:0] VB_E     = 32'sd103558;   // 9.64459661e-05
localparam logic signed [31:0] VC_D0    = 32'sd1052668;   // 0.00392149522
localparam logic signed [31:0] VC_D1    = -32'sd592594;   // -0.00220758415
localparam logic signed [31:0] VC_D2    = 32'sd833392;   // 0.00310462733
localparam logic signed [31:0] VC_D3    = -32'sd178216;   // -0.000663905664
localparam logic signed [31:0] VC_D4    = 32'sd14176;   // 5.28107252e-05
localparam logic signed [31:0] VC_SC    = 32'sd983624207;   // 0.916071429
localparam logic signed [31:0] VD_D0    = 32'sd1929892;   // 0.00718940791
localparam logic signed [31:0] VD_D1    = -32'sd1086422;   // -0.00404723761
localparam logic signed [31:0] VD_D2    = 32'sd1527885;   // 0.00569181677
localparam logic signed [31:0] VD_D3    = -32'sd326729;   // -0.00121716038
localparam logic signed [31:0] VD_D4    = 32'sd25990;   // 9.68196628e-05
localparam logic signed [31:0] VD_SC    = 32'sd805306368;   // 0.75
localparam logic signed [31:0] VD_E     = 32'sd5288;   // 4.92512578e-06
localparam logic signed [31:0] VA_T0    = 32'sd62511907;   // 3.726
localparam logic signed [31:0] VA_T1    = 32'sd2280024;   // 0.1359
localparam logic signed [31:0] VB_T0    = 32'sd56966274;   // 3.39545455
localparam logic signed [31:0] VB_T1    = 32'sd1853120;   // 0.110454545
localparam logic signed [31:0] VD_T0    = 32'sd52344914;   // 3.12
localparam logic signed [31:0] VD_T1    = 32'sd1686110;   // 0.1005
localparam logic signed [31:0] M13_T00  = 32'sd52872497;   // 3.15144643
localparam logic signed [31:0] M13_T01  = 32'sd2320738;   // 0.138326786
localparam logic signed [31:0] M13_T10  = 32'sd63628191;   // 3.79253571
localparam logic signed [31:0] M13_T11  = 32'sd13076432;   // 0.779416071
localparam logic signed [31:0] M13_E    = 32'sd14430;   // 1.34392488e-05
localparam logic signed [31:0] JJ_AL0   = 32'sd55260;   // 5.14644201e-05
localparam logic signed [31:0] JJ_G0    = 32'sd975065223;   // 0.908100254
localparam logic signed [31:0] JJ_AL1   = 32'sd55923;   // 5.2081977e-05
localparam logic signed [31:0] JJ_G1    = 32'sd976128931;   // 0.909090909
localparam logic signed [31:0] JJ_AH0   = 32'sd5078;   // 4.72967764e-06
localparam logic signed [31:0] JJ_TV0   = -32'sd11085042;   // -0.66072
localparam logic signed [31:0] JJ_AH1   = 32'sd5084;   // 4.73483728e-06
localparam logic signed [31:0] JJ_TV1   = -32'sd11072963;   // -0.66
localparam logic signed [31:0] JJ_AH2   = 32'sd55254;   // 5.14593353e-05
localparam logic signed [31:0] JJ_TV2   = -32'sd2147483647;   // -6072.66072
localparam logic signed [31:0] JJ_AH3   = 32'sd55917;   // 5.20767695e-05
localparam logic signed [31:0] JJ_TV3   = -32'sd2147483647;   // -6000.66
localparam logic signed [31:0] JC_AL0   = 32'sd116019;   // 0.00010805087
localparam logic signed [31:0] JC_G0    = 32'sd1024367319;   // 0.954016409
localparam logic signed [31:0] JC_AL1   = 32'sd118981;   // 0.000110809463
localparam logic signed [31:0] JC_G1    = 32'sd1025541379;   // 0.955109838
localparam logic signed [31:0] JC_AH0   = 32'sd5335;   // 4.96882312e-06
localparam logic signed [31:0] JC_TV0   = -32'sd10551527;   // -0.62892
localparam logic signed [31:0] JC_AH1   = 32'sd5341;   // 4.97451803e-06
localparam logic signed [31:0] JC_TV1   = -32'sd10539447;   // -0.6282
localparam logic signed [31:0] JC_AH2   = 32'sd115995;   // 0.000108028459
localparam logic signed [31:0] JC_TV2   = -32'sd2147483647;   // -2892.62892
localparam logic signed [31:0] JC_AH3   = 32'sd118955;   // 0.000110785893
localparam logic signed [31:0] JC_TV3   = -32'sd2147483647;   // -2820.6282
localparam logic signed [31:0] JJ_CR    = 32'sd253135;   // 0.000235750085
localparam logic signed [31:0] JC_CR    = 32'sd594772;   // 0.000553924541
localparam logic signed [31:0] JJ_RC    = 32'sd650118220;   // 0.605469774
localparam logic signed [31:0] JC_RC    = 32'sd45606494;   // 0.0424743577

// Radar Scope (verilator/dksnd/gen_rs_consts.py; TRS2-03 / 04-SOU sheet values, see radarscp_discrete.py for MAME's)
localparam logic signed [31:0] RS2_AL0   = 32'sd559095;
localparam logic signed [31:0] RS2_TG0   = 32'sd20132659;
localparam logic signed [31:0] RS2_G0    = 32'sd536870912;
localparam logic signed [31:0] RS2_AL1   = 32'sd1067867614;
localparam logic signed [31:0] RS2_TG1   = 32'sd10067336;
localparam logic signed [31:0] RS2_G1    = 32'sd1073634461;
localparam logic signed [31:0] RS2_AH0   = 32'sd279584;
localparam logic signed [31:0] RS2_TV0   = -32'sd20132659;
localparam logic signed [31:0] RS2_AH1   = 32'sd559039;
localparam logic signed [31:0] RS2_TV1   = -32'sd10067336;
localparam logic signed [31:0] RS2_AH2   = 32'sd279584;
localparam logic signed [31:0] RS2_TV2   = -32'sd20132659;
localparam logic signed [31:0] RS2_AH3   = 32'sd559039;
localparam logic signed [31:0] RS2_TV3   = -32'sd10067336;
localparam logic signed [31:0] RS1_AL0   = 32'sd559095;
localparam logic signed [31:0] RS1_TG0   = 32'sd20132659;
localparam logic signed [31:0] RS1_G0    = 32'sd536870912;
localparam logic signed [31:0] RS1_AL1   = 32'sd1067867614;
localparam logic signed [31:0] RS1_TG1   = 32'sd10067336;
localparam logic signed [31:0] RS1_G1    = 32'sd1073634461;
localparam logic signed [31:0] RS1_AH0   = 32'sd279584;
localparam logic signed [31:0] RS1_TV0   = -32'sd20132659;
localparam logic signed [31:0] RS1_AH1   = 32'sd559039;
localparam logic signed [31:0] RS1_TV1   = -32'sd10067336;
localparam logic signed [31:0] RS1_AH2   = 32'sd279584;
localparam logic signed [31:0] RS1_TV2   = -32'sd20132659;
localparam logic signed [31:0] RS1_AH3   = 32'sd559039;
localparam logic signed [31:0] RS1_TV3   = -32'sd10067336;
localparam logic signed [31:0] RS0_AL0   = 32'sd20875;
localparam logic signed [31:0] RS0_TG0   = 32'sd15804137;
localparam logic signed [31:0] RS0_G0    = 32'sd683911990;
localparam logic signed [31:0] RS0_AL1   = 32'sd25316;
localparam logic signed [31:0] RS0_TG1   = 32'sd14797505;
localparam logic signed [31:0] RS0_G1    = 32'sd730436615;
localparam logic signed [31:0] RS0_AH0   = 32'sd7579;
localparam logic signed [31:0] RS0_TV0   = -32'sd15804137;
localparam logic signed [31:0] RS0_AH1   = 32'sd8094;
localparam logic signed [31:0] RS0_TV1   = -32'sd14797505;
localparam logic signed [31:0] RS0_AH2   = 32'sd18003;
localparam logic signed [31:0] RS0_TV2   = -32'sd73182216;
localparam logic signed [31:0] RS0_AH3   = 32'sd21213;
localparam logic signed [31:0] RS0_TV3   = -32'sd62109254;
localparam logic signed [31:0] RS2_A20   = 32'sd2311;
localparam logic signed [31:0] RS2_A21   = 32'sd25420;
localparam logic signed [31:0] RS1_A20   = 32'sd5084;
localparam logic signed [31:0] RS1_A21   = 32'sd55923;
localparam logic signed [31:0] RS2_RG12  = 32'sd848668040;
localparam logic signed [31:0] RS2_RA0   = 32'sd7430710;
localparam logic signed [31:0] RS2_RA1   = 32'sd1561875;
localparam logic signed [31:0] RS1_RG12  = 32'sd1030612081;
localparam logic signed [31:0] RS1_RA0   = 32'sd36642860;
localparam logic signed [31:0] RS1_RA1   = 32'sd1496517;
localparam logic signed [31:0] RS7_RG12  = 32'sd536870912;
localparam logic signed [31:0] RS7_RA0   = 32'sd254170;
localparam logic signed [31:0] RS7_RA1   = 32'sd127093;
localparam logic signed [31:0] RS0_IW    = 32'sd394037;
localparam logic signed [31:0] RS0_IWC   = 32'sd433432;
localparam logic signed [31:0] RS0_IR    = 32'sd976128931;
localparam logic signed [31:0] RS7A_IW   = 32'sd2792565;
localparam logic signed [31:0] RS7A_IWC  = 32'sd3071422;
localparam logic signed [31:0] RS7A_IR   = 32'sd976128931;
localparam logic signed [31:0] RS7B_IW   = 32'sd14122;
localparam logic signed [31:0] RS7B_IWC  = 32'sd14199;
localparam logic signed [31:0] RS7B_IR   = 32'sd1067916823;
localparam logic signed [31:0] RS0_CA    = 32'sd37260079;
localparam logic signed [31:0] RS0_CB    = 32'sd162885592;
localparam logic signed [31:0] RS0_CE    = 32'sd762793;
localparam logic signed [31:0] RS0_5C    = 32'sd7530772;
localparam logic signed [31:0] RS0_5D    = 32'sd20514116;
localparam logic signed [31:0] RS0_CR    = 32'sd106233;
localparam logic signed [31:0] RS7_CA    = 32'sd15935442;
localparam logic signed [31:0] RS7_CB    = 32'sd757928272;
localparam logic signed [31:0] RS7_CE    = 32'sd1782706;
localparam logic signed [31:0] RS7_5C    = 32'sd2287652;
localparam logic signed [31:0] RS7_5D    = 32'sd6258240;
localparam logic signed [31:0] RS7_CR    = 32'sd621199;
localparam logic signed [31:0] RS0_OUT   = 32'sd536870912;   // R15 / (R15 + R16)
localparam logic signed [31:0] RS7_OUT   = 32'sd465288124;   // R44 / (R43 + R44)
localparam logic signed [31:0] RS2_OUT   = 32'sd771279338;   // R3 / (R3 + R4)
localparam logic signed [31:0] RS1_OUT   = 32'sd362654523;   // R26 / (R26 + R27), R27 10K (sheet)
localparam logic signed [31:0] RS_MIX    = 32'sd178956971;   // 5 x 10K into VR2 10K
localparam logic signed [31:0] RS_CRO    = 32'sd169453;   // output CR 1K / 33u
localparam logic signed [31:0] RS_VR2    = 32'sd375809638;   // MAME VR2 default 35
localparam logic signed [31:0] RS_OUT    = 32'sd880777;   // 32767 / 5 x 3 x 0.7 (MAME route) / 2^24 in Q2.30 terms

// CD4049 transfer (MAME dss_inverter_osc tftab, DEFAULT_CD40XX_VALUES(5)), 100 entries over 0-5 V: tf_tab below

function automatic logic signed [31:0] vmax(input logic signed [31:0] a, input logic signed [31:0] b);
    vmax = (a > b) ? a : b;
endfunction
function automatic logic signed [31:0] vclip(input logic signed [31:0] a, input logic signed [31:0] lo, input logic signed [31:0] hi);
    vclip = (a < lo) ? lo : (a > hi) ? hi : a;
endfunction
function automatic logic signed [31:0] tf_tab(input logic [6:0] i);
    case (i)
        7'd0: tf_tab = 32'sd83886080;
        7'd1: tf_tab = 32'sd83886080;
        7'd2: tf_tab = 32'sd83886080;
        7'd3: tf_tab = 32'sd83886079;
        7'd4: tf_tab = 32'sd83886073;
        7'd5: tf_tab = 32'sd83886054;
        7'd6: tf_tab = 32'sd83885998;
        7'd7: tf_tab = 32'sd83885867;
        7'd8: tf_tab = 32'sd83885592;
        7'd9: tf_tab = 32'sd83885065;
        7'd10: tf_tab = 32'sd83884126;
        7'd11: tf_tab = 32'sd83882547;
        7'd12: tf_tab = 32'sd83880013;
        7'd13: tf_tab = 32'sd83876102;
        7'd14: tf_tab = 32'sd83870266;
        7'd15: tf_tab = 32'sd83861800;
        7'd16: tf_tab = 32'sd83849821;
        7'd17: tf_tab = 32'sd83833234;
        7'd18: tf_tab = 32'sd83810704;
        7'd19: tf_tab = 32'sd83780619;
        7'd20: tf_tab = 32'sd83741057;
        7'd21: tf_tab = 32'sd83689746;
        7'd22: tf_tab = 32'sd83624026;
        7'd23: tf_tab = 32'sd83540812;
        7'd24: tf_tab = 32'sd83436548;
        7'd25: tf_tab = 32'sd83307173;
        7'd26: tf_tab = 32'sd83148078;
        7'd27: tf_tab = 32'sd82954075;
        7'd28: tf_tab = 32'sd82719361;
        7'd29: tf_tab = 32'sd82437494;
        7'd30: tf_tab = 32'sd82101379;
        7'd31: tf_tab = 32'sd81703254;
        7'd32: tf_tab = 32'sd81234705;
        7'd33: tf_tab = 32'sd80686687;
        7'd34: tf_tab = 32'sd80049570;
        7'd35: tf_tab = 32'sd79313210;
        7'd36: tf_tab = 32'sd78467054;
        7'd37: tf_tab = 32'sd77500268;
        7'd38: tf_tab = 32'sd76401920;
        7'd39: tf_tab = 32'sd75161190;
        7'd40: tf_tab = 32'sd73767640;
        7'd41: tf_tab = 32'sd72211519;
        7'd42: tf_tab = 32'sd70484131;
        7'd43: tf_tab = 32'sd68578231;
        7'd44: tf_tab = 32'sd66488478;
        7'd45: tf_tab = 32'sd64211906;
        7'd46: tf_tab = 32'sd61748418;
        7'd47: tf_tab = 32'sd59101271;
        7'd48: tf_tab = 32'sd56277534;
        7'd49: tf_tab = 32'sd53288492;
        7'd50: tf_tab = 32'sd50149941;
        7'd51: tf_tab = 32'sd46882369;
        7'd52: tf_tab = 32'sd43510952;
        7'd53: tf_tab = 32'sd40065349;
        7'd54: tf_tab = 32'sd36579253;
        7'd55: tf_tab = 32'sd33089688;
        7'd56: tf_tab = 32'sd29636044;
        7'd57: tf_tab = 32'sd26258859;
        7'd58: tf_tab = 32'sd22998406;
        7'd59: tf_tab = 32'sd19893129;
        7'd60: tf_tab = 32'sd16978029;
        7'd61: tf_tab = 32'sd14283118;
        7'd62: tf_tab = 32'sd11832037;
        7'd63: tf_tab = 32'sd9640989;
        7'd64: tf_tab = 32'sd7718071;
        7'd65: tf_tab = 32'sd6063095;
        7'd66: tf_tab = 32'sd4667932;
        7'd67: tf_tab = 32'sd3517365;
        7'd68: tf_tab = 32'sd2590372;
        7'd69: tf_tab = 32'sd1861735;
        7'd70: tf_tab = 32'sd1303804;
        7'd71: tf_tab = 32'sd888263;
        7'd72: tf_tab = 32'sd587717;
        7'd73: tf_tab = 32'sd376983;
        7'd74: tf_tab = 32'sd233989;
        7'd75: tf_tab = 32'sd140264;
        7'd76: tf_tab = 32'sd81039;
        7'd77: tf_tab = 32'sd45032;
        7'd78: tf_tab = 32'sd24014;
        7'd79: tf_tab = 32'sd12261;
        7'd80: tf_tab = 32'sd5980;
        7'd81: tf_tab = 32'sd2779;
        7'd82: tf_tab = 32'sd1227;
        7'd83: tf_tab = 32'sd513;
        7'd84: tf_tab = 32'sd203;
        7'd85: tf_tab = 32'sd76;
        7'd86: tf_tab = 32'sd27;
        7'd87: tf_tab = 32'sd9;
        7'd88: tf_tab = 32'sd3;
        7'd89: tf_tab = 32'sd1;
        7'd90: tf_tab = 32'sd0;
        7'd91: tf_tab = 32'sd0;
        7'd92: tf_tab = 32'sd0;
        7'd93: tf_tab = 32'sd0;
        7'd94: tf_tab = 32'sd0;
        7'd95: tf_tab = 32'sd0;
        7'd96: tf_tab = 32'sd0;
        7'd97: tf_tab = 32'sd0;
        7'd98: tf_tab = 32'sd0;
        7'd99: tf_tab = 32'sd0;
        default: tf_tab = 32'sd0;
    endcase
endfunction
// CD4049 transfer: idx = int(99 * x / 5) from the multiplier (x * K_TFIDX = x * 99 / 5 / 64)
function automatic logic signed [31:0] tf(input logic signed [31:0] x, input logic signed [31:0] xk);
    tf = (x < 0) ? V5 : (x > V5 || (xk >>> 18) > 99) ? tf_tab(7'd99) : tf_tab(xk[24:18]);
endfunction

// sound triggers (6H): MAME DS_SOUNDx_INV = written bit inverted
wire s0i = ~sfx[0], s1i = ~sfx[1], s2i = ~sfx[2], s7i = ~sfx[7];

logic [7:0] div = 8'd0;
always_ff @(posedge clk) div <= pause ? div : div + 8'd1;
wire  [7:0] st = div;                                                  // step within the sample

logic signed [31:0] ma = 0, mb = 0, mq = 0;
logic signed [31:0] mq24 = 0;                                          // Q4.28 x Q8.24 -> Q4.28 (74LS624 polynomials)
always_ff @(posedge clk) begin
    mq   <= 32'((64'(ma) * 64'(mb)) >>> 30);
    mq24 <= 32'((64'(ma) * 64'(mb)) >>> 24);
end

// noise: 3 x LS164 (24 bits), XOR of bits 10 / 23 inverted back in, clocked by 2VF (4 kHz); LS161 3J counts it
logic [24:0] lfsr = 25'd0;
logic [17:0] lfsr_acc = 18'd0;
logic  [2:0] ncnt = 3'd0;
logic        nout = 1'b0;

// circuit state
logic signed [31:0] s_rdm, s_rd2, s_ri, j_inv, j_vg2, j_cm, j_c5, j_rdm, j_rd2, j_ri;
logic signed [31:0] w_inv, w_vg2, w_cm, w_c5, w_rdm, w_cr;
logic               j_ff, w_ff;
logic signed [31:0] env, x1, x2, y1, y2, mixf, mixa, amphp, cr1, cr2;
logic signed [31:0] walk_vo, out_v;
logic signed [31:0] jr_s0, jr_s1, jr_s2, jr_s9;                        // DK Jr. discrete outputs (dkongjr_discrete)
logic signed [31:0] va_cap, vb_cap, vd_cap, va_ph, vb_ph, vc_ph, vd_ph, j_m13, jj_v, jc_v, jj_cr, jc_cr, jj_rc, jc_rc;
logic               va_ff, vb_ff, vc_ff, vd_ff, j_n106, j_n107, j_lout;
logic        [13:0] j_cnt;
logic        [16:0] j_lfsr, jl;
logic        [17:0] j_lacc;
logic        [15:0] os_walk, os_jump, os_climb;
logic               os_walk_on, os_jump_on, os_climb_on, os_walk_l, os_jump_l, os_climb_l;
logic         [3:0] rcnt;                                              // Radar Scope 3J (4 bits, cleared by 6H Q6 low)
logic signed [31:0] t_dac;                                             // DAC x VR2 (slot 69)

// LS123 one-shot step (MAME dst_oneshot, retriggerable, rising edge; widths in samples) -> {count, on, last trigger}
function automatic logic [17:0] os_next(input logic [15:0] cnt, input logic on, input logic last, input logic trig,
                                        input logic [15:0] w);
    logic count;
    count = on;
    if (trig != last) begin
        last = trig;
        if (trig) begin cnt = w; if (on) count = 1'b0; on = 1'b1; end
    end
    if (count) begin
        if (cnt <= 16'd1) begin cnt = 16'd0; on = 1'b0; end else cnt = cnt - 16'd1;
    end
    os_next = {cnt, on, last};
endfunction
// per-sample temporaries
logic signed [31:0] t_u, t_vi, t_g1, t_g2, t_g3, t_p1, t_n20, t_v71, t_y0, t_mix;
logic               t_low, t_m1, t_m2, t_clamp, t_skip;
logic               ff_n;
logic signed [31:0] u_n, d_n, v_n, g_n, vi_c, tg, n60;
logic        [24:0] l;
logic               n16, n34;
logic         [1:0] sx;

always_ff @(posedge clk) begin
    if (reset) begin
        lfsr <= 25'd0; lfsr_acc <= 18'd0; ncnt <= 3'd0; nout <= 1'b0;
        s_rdm <= 0; s_rd2 <= 0; s_ri <= 0; j_inv <= 0; j_vg2 <= 0; j_cm <= 0; j_c5 <= 0; j_rdm <= 0; j_rd2 <= 0; j_ri <= 0;
        w_inv <= 0; w_vg2 <= 0; w_cm <= 0; w_c5 <= 0; w_rdm <= 0; w_cr <= 0; j_ff <= 1'b1; w_ff <= 1'b1;
        env <= Q1; x1 <= 0; x2 <= 0; y1 <= 0; y2 <= 0; mixf <= 0; mixa <= 0; amphp <= 0; cr1 <= 0; cr2 <= 0;
        walk_vo <= 0; out_v <= 0;
        va_cap <= 0; vb_cap <= 0; vd_cap <= 0; va_ph <= 0; vb_ph <= 0; vc_ph <= 0; vd_ph <= 0; j_m13 <= 0;
        jj_v <= 0; jc_v <= 0; jj_cr <= 0; jc_cr <= 0; jj_rc <= 0; jc_rc <= 0;
        va_ff <= 0; vb_ff <= 0; vc_ff <= 0; vd_ff <= 0; j_n106 <= 0; j_n107 <= 0; j_lout <= 1'b1;
        j_cnt <= 0; j_lfsr <= 0; j_lacc <= 0; os_walk <= 0; os_jump <= 0; os_climb <= 0;
        os_walk_on <= 0; os_jump_on <= 0; os_climb_on <= 0; os_walk_l <= 0; os_jump_l <= 0; os_climb_l <= 0;
        jr_s0 <= V4_9; jr_s1 <= 0; jr_s2 <= 0; jr_s9 <= V4_9; rcnt <= 4'd0; t_dac <= 0;
    end else if (!pause) begin
        case (st)
            // ---------------------------------------------------------- noise, stomp (6H Q2)
            8'd0: begin
                if (lfsr_acc + 18'd4000 >= 18'd192000) begin
                    lfsr_acc <= lfsr_acc + 18'd4000 - 18'd192000;
                    l = {1'b0, lfsr[22:0], ~lfsr[24]};
                    l[24] = l[10] ^ l[23];
                    lfsr <= l;
                    if (l[24] && !nout) begin ncnt <= ncnt + 3'd1; rcnt <= rcnt + 4'd1; end
                    nout <= l[24];
                end else lfsr_acc <= lfsr_acc + 18'd4000;
                if (!sfx[6]) rcnt <= 4'd0;
                // rcdisc_mod (in2 = 0)
                t_m1 <= s2i;
                u_n = s2i ? 32'sd0 : V5;
                d_n = u_n - s_rdm;
                t_u <= u_n;
                t_low <= d_n < (s2i ? S_TV1 : S_TV0);
                ma <= (d_n < (s2i ? S_TV1 : S_TV0)) ? u_n + V0_6 - s_rdm : d_n;
                mb <= (d_n < (s2i ? S_TV1 : S_TV0)) ? (s2i ? S_AL1 : S_AL0) : (s2i ? S_AH1 : S_AH0);
            end
            8'd2: begin
                v_n = s_rdm + mq; s_rdm <= v_n;
                n16 = !t_low && (t_u - v_n > (t_m1 ? S_TG1 : S_TG0));
                ma <= (n16 ? 32'sd0 : V5) - s_rd2;
                mb <= n16 ? S_A21 : S_A20;
            end
            8'd4: begin
                v_n = s_rd2 + mq; s_rd2 <= v_n;
                t_n20 <= vmax(vmax(32'sd0, v_n - V0_4), (ncnt[2] ? V5 : 32'sd0) - V0_8);
                ma <= s_ri; mb <= S_RG12;
            end
            8'd6: begin
                if (t_n20 - V0_7 < mq) begin ma <= -s_ri; mb <= S_RA1; end
                else                    begin ma <= t_n20 - V0_7 - s_ri; mb <= S_RA0; end
            end
            8'd8: begin
                s_ri <= s_ri + mq;
                // ------------------------------------------------------ jump (6H Q1): CD4049 type 1
                t_vi <= j_inv + j_vg2;
                ma <= j_inv + j_vg2; mb <= K_TFIDX;
            end
            8'd10: begin t_g1 <= tf(t_vi, mq); ma <= tf(t_vi, mq); mb <= K_TFIDX; end
            8'd12: begin t_g2 <= tf(t_g1, mq); ma <= tf(t_g1, mq); mb <= K_TFIDX; end
            8'd14: begin
                t_g3 <= tf(t_g2, mq);
                t_clamp <= (t_vi < -V0_1) || (t_vi > V5_1);
                ma <= tf(t_g2, mq); mb <= J_IR;
            end
            8'd15: begin ma <= vclip(t_vi, -V0_1, V5_1); mb <= Q1 - J_IR; end
            8'd16: t_p1 <= mq;
            8'd17: begin
                ma <= t_clamp ? t_p1 - (j_inv + t_g2) + mq : t_g3 - (j_inv + t_g2);
                mb <= t_clamp ? J_IWC : J_IW;
                j_vg2 <= t_g2;
            end
            8'd19: begin
                j_inv <= j_inv + mq;
                ma <= t_g3; mb <= s1i ? J_CB1 : J_CB0;                  // 555 CV mixer
            end
            8'd21: begin ma <= (s1i ? J_CA1 : J_CA0) + mq - j_cm; mb <= s1i ? J_CE1 : J_CE0; end
            8'd23: begin
                v_n = j_cm + mq; j_cm <= v_n;
                // 555: threshold = CV, trigger = CV / 2; below 0.25 V MAME leaves it alone
                t_skip <= v_n < V0_25;
                ff_n = (j_c5 >= v_n) ? 1'b0 : (j_c5 <= (v_n >>> 1)) ? 1'b1 : j_ff;
                if (v_n >= V0_25) j_ff <= ff_n;
                t_g1 <= v_n;                                            // CV for step 25
                ma <= ff_n ? V5 - j_c5 : -j_c5; mb <= ff_n ? J_5C : J_5D;
            end
            8'd25: begin
                if (!t_skip) begin
                    v_n = j_c5 + mq;
                    if (j_ff && v_n >= t_g1)                  begin j_c5 <= t_g1;        j_ff <= 1'b0; end
                    else if (!j_ff && v_n <= (t_g1 >>> 1))    begin j_c5 <= t_g1 >>> 1;  j_ff <= 1'b1; end
                    else j_c5 <= v_n;
                end
            end
            8'd26: begin                                                // rcdisc_mod (in2 = 0)
                t_m1 <= s1i;
                u_n = s1i ? 32'sd0 : V5;
                d_n = u_n - j_rdm;
                t_u <= u_n;
                t_low <= d_n < (s1i ? S_TV1 : S_TV0);
                ma <= (d_n < (s1i ? S_TV1 : S_TV0)) ? u_n + V0_6 - j_rdm : d_n;
                mb <= (d_n < (s1i ? S_TV1 : S_TV0)) ? (s1i ? S_AL1 : S_AL0) : (s1i ? S_AH1 : S_AH0);
            end
            8'd28: begin
                v_n = j_rdm + mq; j_rdm <= v_n;
                n34 = !t_low && (t_u - v_n > (t_m1 ? S_TG1 : S_TG0));
                ma <= (n34 ? 32'sd0 : V5) - j_rd2;
                mb <= n34 ? J_A21 : J_A20;
            end
            8'd30: begin
                v_n = j_rd2 + mq; j_rd2 <= v_n;
                t_n20 <= vmax(vmax(32'sd0, v_n - V0_4), (j_ff ? V4_5 : 32'sd0) - V0_8);
                ma <= j_ri; mb <= J_RG12;
            end
            8'd32: begin
                if (t_n20 - V0_7 < mq) begin ma <= -j_ri; mb <= J_RA1; end
                else                    begin ma <= t_n20 - V0_7 - j_ri; mb <= J_RA0; end
            end
            8'd34: begin
                j_ri <= j_ri + mq;
                // ------------------------------------------------------ walk (6H Q0): CD4049 type 2
                t_vi <= w_inv + w_vg2;
                ma <= w_inv + w_vg2; mb <= K_TFIDX;
            end
            8'd36: begin t_g3 <= tf(t_vi, mq); ma <= tf(t_vi, mq); mb <= K_TFIDX; end
            8'd38: begin
                t_g2 <= tf(t_g3, mq);
                t_clamp <= (t_vi < -V0_1) || (t_vi > V5_1);
                ma <= t_g3; mb <= W_IR;
            end
            8'd39: begin ma <= vclip(t_vi, -V0_1, V5_1); mb <= Q1 - W_IR; end
            8'd40: t_p1 <= mq;
            8'd41: begin
                ma <= t_clamp ? t_p1 - (w_inv + t_g2) + mq : t_g3 - (w_inv + t_g2);
                mb <= t_clamp ? W_IWC : W_IW;
                w_vg2 <= t_g2;
            end
            8'd43: begin
                w_inv <= w_inv + mq;
                ma <= t_g3; mb <= s0i ? W_CB1 : W_CB0;
            end
            8'd45: begin ma <= (s0i ? W_CA1 : W_CA0) + mq - w_cm; mb <= s0i ? W_CE1 : W_CE0; end
            8'd47: begin
                v_n = w_cm + mq; w_cm <= v_n;
                t_skip <= v_n < V0_25;
                ff_n = (w_c5 >= v_n) ? 1'b0 : (w_c5 <= (v_n >>> 1)) ? 1'b1 : w_ff;
                if (v_n >= V0_25) w_ff <= ff_n;
                t_g1 <= v_n;
                ma <= ff_n ? V5 - w_c5 : -w_c5; mb <= ff_n ? W_5C : W_5D;
            end
            8'd49: begin
                if (!t_skip) begin
                    v_n = w_c5 + mq;
                    if (w_ff && v_n >= t_g1)                  begin w_c5 <= t_g1;        w_ff <= 1'b0; end
                    else if (!w_ff && v_n <= (t_g1 >>> 1))    begin w_c5 <= t_g1 >>> 1;  w_ff <= 1'b1; end
                    else w_c5 <= v_n;
                end
            end
            8'd50: begin                                                // rcdisc_mod, in2 = 555 output
                sx = {w_ff, s0i};
                t_m1 <= s0i; t_m2 <= w_ff;
                u_n = s0i ? 32'sd0 : V5;
                d_n = u_n - w_rdm;
                t_u <= u_n;
                case (sx)
                    2'd0: tg = W_TV0; 2'd1: tg = W_TV1; 2'd2: tg = W_TV2; default: tg = W_TV3;
                endcase
                t_low <= d_n < tg;
                ma <= (d_n < tg) ? u_n + V0_6 - w_rdm : d_n;
                case (sx)
                    2'd0: mb <= (d_n < tg) ? W_AL0 : W_AH0;
                    2'd1: mb <= (d_n < tg) ? W_AL1 : W_AH1;
                    2'd2: mb <= (d_n < tg) ? W_AL0 : W_AH2;
                    default: mb <= (d_n < tg) ? W_AL1 : W_AH3;
                endcase
            end
            8'd52: begin
                v_n = w_rdm + mq; w_rdm <= v_n;
                ma <= t_u - v_n; mb <= t_m1 ? W_G1 : W_G0;
            end
            8'd54: begin
                n60 = t_m2 ? 32'sd0 : t_low ? -V0_6 : mq;
                walk_vo <= n60 - w_cr;
                ma <= n60 - w_cr; mb <= W_CR;
            end
            8'd56: w_cr <= w_cr + mq;
            // ---------------------------------------------------------- DAC: P2.7 decay, Sallen-Key
            8'd57: begin ma <= env; mb <= K_ENV; end
            8'd59: begin
                v_n = p2[7] ? Q1 : mq; env <= v_n;
                ma <= V5_256 * $signed({24'd0, p1}); mb <= v_n;
            end
            8'd61: begin t_v71 <= mq; ma <= SK_B0; mb <= mq; end
            8'd62: begin ma <= SK_B1; mb <= x1; end
            8'd63: begin t_y0 <= mq; ma <= SK_B0; mb <= x2; end
            8'd64: begin t_y0 <= t_y0 + mq; ma <= SK_A1; mb <= y1; end
            8'd65: begin t_y0 <= t_y0 + mq; ma <= SK_A2; mb <= y2; end
            8'd66: t_y0 <= t_y0 + mq;
            8'd67: begin
                t_y0 <= t_y0 - mq;
                x2 <= x1; x1 <= t_v71; y2 <= y1; y1 <= t_y0 - mq;
                ma <= t_y0 - mq; mb <= rs ? RS_VR2 : K_VR2;
            end
            // ---------------------------------------------------------- DK Jr. discrete (verilator/dksnd/dkongjr_discrete.py)
            // walk: LS123 4K, VCO 5K pin 7 (n113), 4020 6L clocked by VCO 5K pin 10, 6K LS157 by 6H Q7
            8'd110: if (jr) begin
                // LS123s (retriggerable, rising edge of the inverted trigger; the triggering step does not count)
                {os_walk,  os_walk_on,  os_walk_l}  <= os_next(os_walk,  os_walk_on,  os_walk_l,  s0i, 16'd10762);
                {os_jump,  os_jump_on,  os_jump_l}  <= os_next(os_jump,  os_jump_on,  os_jump_l,  s1i, 16'd50372);
                {os_climb, os_climb_on, os_climb_l} <= os_next(os_climb, os_climb_on, os_climb_l, s2i, 16'd50372);
                // climb noise: 2 x LS164 (3J / 4J) at 710 Hz, bits 2 ^ 15, inverted in and out
                if (j_lacc + 18'd710 >= 18'd192000) begin
                    j_lacc <= j_lacc + 18'd710 - 18'd192000;
                    jl = {1'b0, j_lfsr[14:0], ~j_lfsr[16]};
                    jl[16] = jl[2] ^ jl[15];
                    j_lfsr <= jl;
                    j_lout <= ~jl[16];
                end else j_lacc <= j_lacc + 18'd710;
                j_n106 <= s7i ? j_cnt[3] : j_cnt[6];
                j_n107 <= s7i ? j_cnt[11] : j_cnt[12];
            end
            8'd111: if (jr) begin ma <= (os_walk_on ? VA_T1 : VA_T0) - va_cap; mb <= VA_E; end
            8'd113: if (jr) begin v_n = va_cap + mq; va_cap <= v_n; ma <= VA_D4; mb <= v_n; end
            8'd115: if (jr) begin ma <= VA_D3 + mq24; mb <= va_cap; end
            8'd117: if (jr) begin ma <= VA_D2 + mq24; mb <= va_cap; end
            8'd119: if (jr) begin ma <= VA_D1 + mq24; mb <= va_cap; end
            8'd121: if (jr) begin
                v_n = va_ph + VA_D0 + mq24;
                if (v_n >= HALF) begin va_ph <= v_n - HALF; va_ff <= ~va_ff; end else va_ph <= v_n;
                ma <= (j_n107 ? VB_T1 : VB_T0) - vb_cap; mb <= VB_E;
            end
            8'd123: if (jr) begin v_n = vb_cap + mq; vb_cap <= v_n; ma <= VB_D4; mb <= v_n; end
            8'd125: if (jr) begin ma <= VB_D3 + mq24; mb <= vb_cap; end
            8'd127: if (jr) begin ma <= VB_D2 + mq24; mb <= vb_cap; end
            8'd129: if (jr) begin ma <= VB_D1 + mq24; mb <= vb_cap; end
            8'd131: if (jr) begin
                v_n = vb_ph + VB_D0 + mq24;
                if (v_n >= HALF) begin
                    vb_ph <= v_n - HALF; vb_ff <= ~vb_ff;
                    if (vb_ff) j_cnt <= j_cnt + 14'd1;                  // falling edge clocks the 4020
                end else vb_ph <= v_n;
            end
            8'd132: if (jr) begin
                jr_s0 <= (os_walk_on && ((s7i & va_ff) ^ j_n106)) ? (s7i ? V0_2 : V_LAND) : V4_9;   // 5N NAND, 1K pull-up
                // jump: LS123 4K, C24 mixer (n11 / n12) into VCO 8L, Q3 envelope
                case ({os_jump_on, j_cnt[11]})
                    2'b00: ma <= M13_T00 - j_m13; 2'b01: ma <= M13_T01 - j_m13;
                    2'b10: ma <= M13_T10 - j_m13; default: ma <= M13_T11 - j_m13;
                endcase
                mb <= M13_E;
            end
            8'd134: if (jr) begin v_n = j_m13 + mq; j_m13 <= v_n; ma <= VC_D4; mb <= v_n; end
            8'd136: if (jr) begin ma <= VC_D3 + mq24; mb <= j_m13; end
            8'd138: if (jr) begin ma <= VC_D2 + mq24; mb <= j_m13; end
            8'd140: if (jr) begin ma <= VC_D1 + mq24; mb <= j_m13; end
            8'd142: if (jr) begin
                v_n = vc_ph + VC_D0 + mq24;
                if (v_n >= HALF) begin vc_ph <= v_n - HALF; vc_ff <= ~vc_ff; end else vc_ph <= v_n;
            end
            8'd143: if (jr) begin                                       // rcdisc_mod: in1 = n10 inverted, in2 = 8L
                sx = {vc_ff, ~os_jump_on};
                t_m1 <= ~os_jump_on; t_m2 <= vc_ff;
                u_n = os_jump_on ? V5 : 32'sd0;
                d_n = u_n - jj_v;
                t_u <= u_n;
                case (sx) 2'd0: tg = JJ_TV0; 2'd1: tg = JJ_TV1; 2'd2: tg = JJ_TV2; default: tg = JJ_TV3; endcase
                t_low <= d_n < tg;
                ma <= (d_n < tg) ? u_n + V0_6 - jj_v : d_n;
                case (sx)
                    2'd0: mb <= (d_n < tg) ? JJ_AL0 : JJ_AH0;  2'd1: mb <= (d_n < tg) ? JJ_AL1 : JJ_AH1;
                    2'd2: mb <= (d_n < tg) ? JJ_AL0 : JJ_AH2;  default: mb <= (d_n < tg) ? JJ_AL1 : JJ_AH3;
                endcase
            end
            8'd145: if (jr) begin v_n = jj_v + mq; jj_v <= v_n; ma <= t_u - v_n; mb <= t_m1 ? JJ_G1 : JJ_G0; end
            8'd147: if (jr) begin
                n60 = t_m2 ? 32'sd0 : t_low ? -V0_6 : mq;
                t_p1 <= n60 - jj_cr;                                    // CR to 2.5 V (R4, C23)
                ma <= n60 - jj_cr - V2_5; mb <= JJ_CR;
            end
            8'd149: if (jr) begin jj_cr <= jj_cr + mq; ma <= t_p1 - jj_rc; mb <= JJ_RC; end
            8'd151: if (jr) begin
                jj_rc <= jj_rc + mq; jr_s1 <= jj_rc + mq;               // R19 / C21
                // climb: LS123 8N (output active low), LFSR into Q2 envelope
                sx = {j_lout, ~os_climb_on};
                t_m1 <= ~os_climb_on; t_m2 <= j_lout;
                u_n = os_climb_on ? V5 : 32'sd0;
                d_n = u_n - jc_v;
                t_u <= u_n;
                case (sx) 2'd0: tg = JC_TV0; 2'd1: tg = JC_TV1; 2'd2: tg = JC_TV2; default: tg = JC_TV3; endcase
                t_low <= d_n < tg;
                ma <= (d_n < tg) ? u_n + V0_6 - jc_v : d_n;
                case (sx)
                    2'd0: mb <= (d_n < tg) ? JC_AL0 : JC_AH0;  2'd1: mb <= (d_n < tg) ? JC_AL1 : JC_AH1;
                    2'd2: mb <= (d_n < tg) ? JC_AL0 : JC_AH2;  default: mb <= (d_n < tg) ? JC_AL1 : JC_AH3;
                endcase
            end
            8'd153: if (jr) begin v_n = jc_v + mq; jc_v <= v_n; ma <= t_u - v_n; mb <= t_m1 ? JC_G1 : JC_G0; end
            8'd155: if (jr) begin
                n60 = t_m2 ? 32'sd0 : t_low ? -V0_6 : mq;
                t_p1 <= n60 - jc_cr;                                    // CR to 2.5 V (R6, C30)
                ma <= n60 - jc_cr - V2_5; mb <= JC_CR;
            end
            8'd157: if (jr) begin jc_cr <= jc_cr + mq; ma <= t_p1 - jc_rc; mb <= JC_RC; end
            8'd159: if (jr) begin
                jc_rc <= jc_rc + mq; jr_s2 <= jc_rc + mq;               // R2 / C25
                // fall: VCO 7P (input C26), 5N NAND with 5H Q1
                ma <= (snd9 ? VD_T1 : VD_T0) - vd_cap; mb <= VD_E;
            end
            8'd161: if (jr) begin v_n = vd_cap + mq; vd_cap <= v_n; ma <= VD_D4; mb <= v_n; end
            8'd163: if (jr) begin ma <= VD_D3 + mq24; mb <= vd_cap; end
            8'd165: if (jr) begin ma <= VD_D2 + mq24; mb <= vd_cap; end
            8'd167: if (jr) begin ma <= VD_D1 + mq24; mb <= vd_cap; end
            8'd169: if (jr) begin
                v_n = vd_ph + VD_D0 + mq24;
                if (v_n >= HALF) begin vd_ph <= v_n - HALF; vd_ff <= ~vd_ff; end else vd_ph <= v_n;
            end
            8'd170: if (jr) jr_s9 <= (snd9 && vd_ff) ? V0_2 : V4_9;
            // ---------------------------------------------------------- DK Jr. mixer, output coupling
            8'd90: if (jr) begin ma <= t_y0; mb <= JK_S1; end           // DAC (no VR2 on DK Jr.)
            8'd91: if (jr) begin ma <= jr_s1; mb <= JK_S1; end
            8'd92: if (jr) begin t_mix <= mq; ma <= jr_s0; mb <= JK_S0; end
            8'd93: if (jr) begin t_mix <= t_mix + mq; ma <= jr_s2; mb <= JK_S2; end
            8'd94: if (jr) begin t_mix <= t_mix + mq; ma <= jr_s9; mb <= JK_S9; end
            8'd95: if (jr) t_mix <= t_mix + mq;
            8'd96: if (jr) begin t_mix <= t_mix + mq; ma <= t_mix + mq - mixf; mb <= JA_CF; end
            8'd98: if (jr) begin v_n = mixf + mq; mixf <= v_n; ma <= v_n - mixa; mb <= A_CAMP; end
            8'd100: if (jr) begin v_n = mixa + mq; mixa <= v_n; t_mix <= mixf - v_n - cr2; ma <= mixf - v_n - cr2; mb <= A_CR2; end
            8'd102: if (jr) begin cr2 <= cr2 + mq; ma <= t_mix; mb <= JK_OUT; end
            8'd104: if (jr) out_v <= mq;
            // ---------------------------------------------------------- DK mixer, Q3 amp, output coupling
            8'd69: begin
                t_dac <= mq;                                            // DAC x VR2 (Radar Scope mixer)
                if (!jr) begin t_mix <= mq + (walk_vo >>> 1); ma <= s_ri + j_ri; mb <= K_RI_OUT; end
            end
            8'd71: if (!jr) begin ma <= t_mix + mq; mb <= K_MIX; end
            8'd73: if (!jr) begin ma <= mq - mixf; mb <= A_CF; end
            8'd75: if (!jr) begin v_n = mixf + mq; mixf <= v_n; ma <= v_n - mixa; mb <= A_CAMP; end
            8'd77: if (!jr) begin
                v_n = mixa + mq; mixa <= v_n;
                t_mix <= mixf - v_n;
                ma <= mixf - v_n - amphp; mb <= A_AMPHP;
            end
            8'd79: if (!jr) begin v_n = amphp + mq; amphp <= v_n; ma <= t_mix - v_n; mb <= K_AMP; end
            8'd81: if (!jr) begin
                v_n = vclip(V1_53 + (mq <<< 4), 32'sd0, V5);           // -8.4 x, 0-5 V swing
                t_mix <= v_n - cr1;
                ma <= v_n - cr1; mb <= A_CR1;
            end
            8'd83: if (!jr) begin cr1 <= cr1 + mq; ma <= t_mix - cr2; mb <= A_CR2; t_mix <= t_mix - cr2; end
            8'd85: if (!jr) begin cr2 <= cr2 + mq; ma <= t_mix; mb <= K_OUT; end
            8'd87: if (!jr) out_v <= mq;
            default: ;
        endcase
    end
end

// ------------------------------------------------------------------ Radar Scope discrete (rs): own sequencer + multiplier
logic signed [31:0] rma = 0, rmb = 0, rmq = 0;
always_ff @(posedge clk) rmq <= 32'((64'(rma) * 64'(rmb)) >>> 30);
logic signed [31:0] r2_rdm, r2_rd2, r2_ri, r1_rdm, r1_rd2, r1_ri, r0_inv, r0_vg2, r0_cm, r0_c5, r0_rdm, r0_cr, r0_vo;
logic signed [31:0] r7a_inv, r7a_vg2, r7_cm, r7_c5, r7b_inv, r7b_vg2, r7_ri, r7_cr, r7_vo, r_mixa, r_amphp, r_cr1, rs_out;
logic signed [31:0] rt_u, rt_n20, rt_vi, rt_g1, rt_g2, rt_g3, rt_p1, rt_mix, rt_s7;
logic               r0_ff, r7_ff, rt_low, rt_m1, rt_m2, rt_clamp, rt_skip;
logic signed [31:0] ru_n, rd_n, rv_n, rtg, rn60;
logic               rn16, rff_n;
logic         [1:0] rsx;

always_ff @(posedge clk) begin
    if (reset || !rs) begin
        r2_rdm <= 0; r2_rd2 <= 0; r2_ri <= 0; r1_rdm <= 0; r1_rd2 <= 0; r1_ri <= 0; r0_inv <= 0; r0_vg2 <= 0;
        r0_cm <= 0; r0_c5 <= 0; r0_rdm <= 0; r0_cr <= 0; r0_vo <= 0; r7a_inv <= 0; r7a_vg2 <= 0; r7_cm <= 0; r7_c5 <= 0;
        r7b_inv <= 0; r7b_vg2 <= 0; r7_ri <= 0; r7_cr <= 0; r7_vo <= 0; r_mixa <= 0; r_amphp <= 0; r_cr1 <= 0; rs_out <= 0;
        r0_ff <= 1'b1; r7_ff <= 1'b1;
    end else if (!pause) begin
        case (st)
            // ---------------------------------------------------------- SOUND2 (6H Q2): stomp form, noise QC
            8'd0: begin
                rt_m1 <= s2i;
                ru_n = s2i ? 32'sd0 : V5;
                rd_n = ru_n - r2_rdm;
                rt_u <= ru_n;
                rt_low <= rd_n < (s2i ? RS2_TV1 : RS2_TV0);
                rma <= (rd_n < (s2i ? RS2_TV1 : RS2_TV0)) ? ru_n + V0_6 - r2_rdm : rd_n;
                rmb <= (rd_n < (s2i ? RS2_TV1 : RS2_TV0)) ? (s2i ? RS2_AL1 : RS2_AL0) : (s2i ? RS2_AH1 : RS2_AH0);
            end
            8'd2: begin
                rv_n = r2_rdm + rmq; r2_rdm <= rv_n;
                rn16 = !rt_low && (rt_u - rv_n > (rt_m1 ? RS2_TG1 : RS2_TG0));
                rma <= (rn16 ? 32'sd0 : V5) - r2_rd2; rmb <= rn16 ? RS2_A21 : RS2_A20;
            end
            8'd4: begin
                rv_n = r2_rd2 + rmq; r2_rd2 <= rv_n;
                rt_n20 <= vmax(vmax(32'sd0, rv_n - V0_4), (rcnt[2] ? V5 : 32'sd0) - V0_8);
                rma <= r2_ri; rmb <= RS2_RG12;
            end
            8'd6: begin
                if (rt_n20 - V0_7 < rmq) begin rma <= -r2_ri; rmb <= RS2_RA1; end
                else                      begin rma <= rt_n20 - V0_7 - r2_ri; rmb <= RS2_RA0; end
            end
            8'd8: r2_ri <= r2_ri + rmq;
            // ---------------------------------------------------------- SOUND1 (6H Q1): stomp form, noise QB
            8'd10: begin
                rt_m1 <= s1i;
                ru_n = s1i ? 32'sd0 : V5;
                rd_n = ru_n - r1_rdm;
                rt_u <= ru_n;
                rt_low <= rd_n < (s1i ? RS1_TV1 : RS1_TV0);
                rma <= (rd_n < (s1i ? RS1_TV1 : RS1_TV0)) ? ru_n + V0_6 - r1_rdm : rd_n;
                rmb <= (rd_n < (s1i ? RS1_TV1 : RS1_TV0)) ? (s1i ? RS1_AL1 : RS1_AL0) : (s1i ? RS1_AH1 : RS1_AH0);
            end
            8'd12: begin
                rv_n = r1_rdm + rmq; r1_rdm <= rv_n;
                rn16 = !rt_low && (rt_u - rv_n > (rt_m1 ? RS1_TG1 : RS1_TG0));
                rma <= (rn16 ? 32'sd0 : V5) - r1_rd2; rmb <= rn16 ? RS1_A21 : RS1_A20;
            end
            8'd14: begin
                rv_n = r1_rd2 + rmq; r1_rd2 <= rv_n;
                rt_n20 <= vmax(vmax(32'sd0, rv_n - V0_4), (rcnt[1] ? V5 : 32'sd0) - V0_8);
                rma <= r1_ri; rmb <= RS1_RG12;
            end
            8'd16: begin
                if (rt_n20 - V0_7 < rmq) begin rma <= -r1_ri; rmb <= RS1_RA1; end
                else                      begin rma <= rt_n20 - V0_7 - r1_ri; rmb <= RS1_RA0; end
            end
            8'd18: r1_ri <= r1_ri + rmq;
            // ---------------------------------------------------------- SOUND0 (6H Q0): walk form, CD4049 type 2 LFO
            8'd20: begin rt_vi <= r0_inv + r0_vg2; rma <= r0_inv + r0_vg2; rmb <= K_TFIDX; end
            8'd22: begin rt_g3 <= tf(rt_vi, rmq); rma <= tf(rt_vi, rmq); rmb <= K_TFIDX; end
            8'd24: begin
                rt_g2 <= tf(rt_g3, rmq);
                rt_clamp <= (rt_vi < -V0_1) || (rt_vi > V5_1);
                rma <= rt_g3; rmb <= RS0_IR;
            end
            8'd25: begin rma <= vclip(rt_vi, -V0_1, V5_1); rmb <= Q1 - RS0_IR; end
            8'd26: rt_p1 <= rmq;
            8'd27: begin
                rma <= rt_clamp ? rt_p1 - (r0_inv + rt_g2) + rmq : rt_g3 - (r0_inv + rt_g2);
                rmb <= rt_clamp ? RS0_IWC : RS0_IW;
                r0_vg2 <= rt_g2;
            end
            8'd29: begin r0_inv <= r0_inv + rmq; rma <= rt_g3; rmb <= RS0_CB; end           // resistor CV mixer, C51
            8'd31: begin rma <= RS0_CA + rmq - r0_cm; rmb <= RS0_CE; end
            8'd33: begin
                rv_n = r0_cm + rmq; r0_cm <= rv_n;
                // 555 (enable = 6H Q6; in reset: output 0, flip-flop set, cap empty)
                rt_skip <= rv_n < V0_25 || !sfx[6];
                rff_n = (r0_c5 >= rv_n) ? 1'b0 : (r0_c5 <= (rv_n >>> 1)) ? 1'b1 : r0_ff;
                if (!sfx[6]) begin r0_ff <= 1'b1; r0_c5 <= 32'sd0; end
                else if (rv_n >= V0_25) r0_ff <= rff_n;
                rt_g1 <= rv_n;
                rma <= rff_n ? V5 - r0_c5 : -r0_c5; rmb <= rff_n ? RS0_5C : RS0_5D;
            end
            8'd35: begin
                if (!rt_skip) begin
                    rv_n = r0_c5 + rmq;
                    if (r0_ff && rv_n >= rt_g1)                begin r0_c5 <= rt_g1;        r0_ff <= 1'b0; end
                    else if (!r0_ff && rv_n <= (rt_g1 >>> 1))  begin r0_c5 <= rt_g1 >>> 1;  r0_ff <= 1'b1; end
                    else r0_c5 <= rv_n;
                end
            end
            8'd36: begin                                                // rcdisc_mod, in2 = 555 output
                rsx = {r0_ff & sfx[6], s0i};
                rt_m1 <= s0i; rt_m2 <= r0_ff & sfx[6];
                ru_n = s0i ? 32'sd0 : V5;
                rd_n = ru_n - r0_rdm;
                rt_u <= ru_n;
                case (rsx)
                    2'd0: rtg = RS0_TV0; 2'd1: rtg = RS0_TV1; 2'd2: rtg = RS0_TV2; default: rtg = RS0_TV3;
                endcase
                rt_low <= rd_n < rtg;
                rma <= (rd_n < rtg) ? ru_n + V0_6 - r0_rdm : rd_n;
                case (rsx)
                    2'd0: rmb <= (rd_n < rtg) ? RS0_AL0 : RS0_AH0;
                    2'd1: rmb <= (rd_n < rtg) ? RS0_AL1 : RS0_AH1;
                    2'd2: rmb <= (rd_n < rtg) ? RS0_AL0 : RS0_AH2;
                    default: rmb <= (rd_n < rtg) ? RS0_AL1 : RS0_AH3;
                endcase
            end
            8'd38: begin
                rv_n = r0_rdm + rmq; r0_rdm <= rv_n;
                rma <= rt_u - rv_n; rmb <= rt_m1 ? RS0_G1 : RS0_G0;
            end
            8'd40: begin
                rn60 = rt_m2 ? 32'sd0 : rt_low ? -V0_6 : rmq;
                r0_vo <= rn60 - r0_cr;
                rma <= rn60 - r0_cr; rmb <= RS0_CR;
            end
            8'd42: r0_cr <= r0_cr + rmq;
            // ---------------------------------------------------------- SOUND7 (6H Q7): siren
            // CD4049 type 2 LFO (R62 / R61 / C54) -> resistor CV mixer (C50) -> 555 (enable = Q7)
            8'd44: begin rt_vi <= r7a_inv + r7a_vg2; rma <= r7a_inv + r7a_vg2; rmb <= K_TFIDX; end
            8'd46: begin rt_g3 <= tf(rt_vi, rmq); rma <= tf(rt_vi, rmq); rmb <= K_TFIDX; end
            8'd48: begin
                rt_g2 <= tf(rt_g3, rmq);
                rt_clamp <= (rt_vi < -V0_1) || (rt_vi > V5_1);
                rma <= rt_g3; rmb <= RS7A_IR;
            end
            8'd49: begin rma <= vclip(rt_vi, -V0_1, V5_1); rmb <= Q1 - RS7A_IR; end
            8'd50: rt_p1 <= rmq;
            8'd51: begin
                rma <= rt_clamp ? rt_p1 - (r7a_inv + rt_g2) + rmq : rt_g3 - (r7a_inv + rt_g2);
                rmb <= rt_clamp ? RS7A_IWC : RS7A_IW;
                r7a_vg2 <= rt_g2;
            end
            8'd53: begin r7a_inv <= r7a_inv + rmq; rma <= rt_g3; rmb <= RS7_CB; end
            8'd55: begin rma <= RS7_CA + rmq - r7_cm; rmb <= RS7_CE; end
            8'd57: begin
                rv_n = r7_cm + rmq; r7_cm <= rv_n;
                rt_skip <= rv_n < V0_25 || !sfx[7];
                rff_n = (r7_c5 >= rv_n) ? 1'b0 : (r7_c5 <= (rv_n >>> 1)) ? 1'b1 : r7_ff;
                if (!sfx[7]) begin r7_ff <= 1'b1; r7_c5 <= 32'sd0; end
                else if (rv_n >= V0_25) r7_ff <= rff_n;
                rt_g1 <= rv_n;
                rma <= rff_n ? V5 - r7_c5 : -r7_c5; rmb <= rff_n ? RS7_5C : RS7_5D;
            end
            8'd59: begin
                if (!rt_skip) begin
                    rv_n = r7_c5 + rmq;
                    if (r7_ff && rv_n >= rt_g1)                begin r7_c5 <= rt_g1;        r7_ff <= 1'b0; end
                    else if (!r7_ff && rv_n <= (rt_g1 >>> 1))  begin r7_c5 <= rt_g1 >>> 1;  r7_ff <= 1'b1; end
                    else r7_c5 <= rv_n;
                end
            end
            // slow sine: CD4049 type 3 (R48 / R49 / C47), output = the first inverter
            8'd60: begin rt_vi <= r7b_inv + r7b_vg2; rma <= r7b_inv + r7b_vg2; rmb <= K_TFIDX; end
            8'd62: begin rt_g1 <= tf(rt_vi, rmq); rma <= tf(rt_vi, rmq); rmb <= K_TFIDX; end
            8'd64: begin rt_g2 <= tf(rt_g1, rmq); rma <= tf(rt_g1, rmq); rmb <= K_TFIDX; end
            8'd66: begin
                rt_g3 <= tf(rt_g2, rmq);
                rt_clamp <= (rt_vi < -V0_1) || (rt_vi > V5_1);
                rma <= tf(rt_g2, rmq); rmb <= RS7B_IR;
            end
            8'd67: begin rma <= vclip(rt_vi, -V0_1, V5_1); rmb <= Q1 - RS7B_IR; end
            8'd68: rt_p1 <= rmq;
            8'd69: begin
                rma <= rt_clamp ? rt_p1 - (r7b_inv + rt_g2) + rmq : rt_g3 - (r7b_inv + rt_g2);
                rmb <= rt_clamp ? RS7B_IWC : RS7B_IW;
                r7b_vg2 <= rt_g2;
                rt_s7 <= rt_g1;
            end
            // R46 / C45 emitter follower (rcintegrate type 1, RTL form)
            8'd71: begin r7b_inv <= r7b_inv + rmq; rma <= r7_ri; rmb <= RS7_RG12; end
            8'd73: begin
                if (rt_s7 - V0_7 < rmq) begin rma <= -r7_ri; rmb <= RS7_RA1; end
                else                     begin rma <= rt_s7 - V0_7 - r7_ri; rmb <= RS7_RA0; end
            end
            8'd75: begin
                rv_n = r7_ri + rmq; r7_ri <= rv_n;
                // gate: Q7 and the 555 output low (MAME n55 x SOUND7 x (n54 < 2.5)), then C46 coupling
                rn60 = (sfx[7] && !r7_ff) ? rv_n : 32'sd0;
                r7_vo <= rn60 - r7_cr;
                rma <= rn60 - r7_cr; rmb <= RS7_CR;
            end
            8'd77: r7_cr <= r7_cr + rmq;
            // ---------------------------------------------------------- mixer, Q3 amp, output coupling (DAC x VR2 from slot 69)
            8'd90: begin rma <= r2_ri; rmb <= RS2_OUT; end
            8'd91: begin rma <= r1_ri; rmb <= RS1_OUT; end
            8'd92: begin rt_mix <= rmq + t_dac; rma <= r0_vo; rmb <= RS0_OUT; end
            8'd93: rt_mix <= rt_mix + rmq;
            8'd94: begin rt_mix <= rt_mix + rmq; rma <= r7_vo; rmb <= RS7_OUT; end
            8'd96: begin rma <= rt_mix + rmq; rmb <= RS_MIX; end
            8'd98: begin rt_mix <= rmq; rma <= rmq - r_mixa; rmb <= A_CAMP; end
            8'd100: begin
                rv_n = r_mixa + rmq; r_mixa <= rv_n;
                rt_mix <= rt_mix - rv_n;
                rma <= rt_mix - rv_n - r_amphp; rmb <= A_AMPHP;
            end
            8'd102: begin rv_n = r_amphp + rmq; r_amphp <= rv_n; rma <= rt_mix - rv_n; rmb <= K_AMP; end
            8'd104: begin
                rv_n = vclip(V1_53 + (rmq <<< 4), 32'sd0, V5);
                rt_mix <= rv_n - r_cr1;
                rma <= rv_n - r_cr1; rmb <= RS_CRO;
            end
            8'd106: begin r_cr1 <= r_cr1 + rmq; rma <= rt_mix; rmb <= RS_OUT; end
            8'd108: rs_out <= rmq;
            default: ;
        endcase
    end
end

wire signed [31:0] snd_out = rs ? rs_out : out_v;
always_ff @(posedge clk) audio <= (snd_out > 32'sd32767) ? 16'sd32767 : (snd_out < -32'sd32768) ? -16'sd32768 : snd_out[15:0];

endmodule
