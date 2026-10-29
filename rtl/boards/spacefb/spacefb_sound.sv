//  Copyright (C) 2026 Rodimus
//    corner are measured from MAME's spacefb samples (recordings of the board); levels = MAME (samples 1.0, DAC 0.25).

module spacefb_sound
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,

    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] port1,
    input  logic        v2,

    output logic [11:0] pa,
    input  logic  [7:0] pd,

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
        if (xacc >= 16'd43152) begin xacc <= xacc - 16'd43152; xen <= 1'b1; end
        else xacc <= xacc + 16'd6000;
    end
end

assign pa = {2'b00, mcs48_0_o.pmem_a[9:0]};

assign mcs48_0_i.reset_n = ~reset;
assign mcs48_0_i.xtal_en = xen;
assign mcs48_0_i.int_n   = port1[1];
assign mcs48_0_i.t0      = port1[5];
assign mcs48_0_i.t1      = port1[2];
assign mcs48_0_i.p1_in   = mcs48_0_o.p1;
assign mcs48_0_i.p2_in   = mcs48_0_o.p2 & {2'b00, port1[4:3], 4'b0000};
assign mcs48_0_i.db      = 8'hFF;
assign mcs48_0_i.pmem_d  = pd;

wire [7:0] dac = mcs48_0_o.p1;

logic [7:0] sdiv = 8'd0;
wire        step = sdiv == 8'd0;
always_ff @(posedge clk) sdiv <= sdiv + 8'd1;

localparam signed [17:0] F  = 18'sd4108;
localparam signed [17:0] D  = 18'sd88441;
localparam signed [17:0] AH = 18'sd6286;

logic signed [31:0] lo = 32'sd0, bp = 32'sd0, h = 32'sd0;
wire  signed [31:0] x0 = {8'd0, dac, 16'd0};
logic signed [49:0] fb, db, p3, p4, mh;
wire  signed [31:0] lo_n = lo + 32'(fb >>> 16);
wire  signed [31:0] dbs  = 32'(db >>> 16);
wire  signed [32:0] dh   = 33'(lo) - 33'(h);
wire  signed [49:0] xf   = 50'({dac, 28'd0}) + 50'({dac, 19'd0}) + 50'({dac, 18'd0});
wire  signed [49:0] fh   = xf - p3 - p4;
always_ff @(posedge clk) begin
    if (reset) begin lo <= x0; bp <= 32'sd0; h <= x0; end
    else if (step) begin
        lo <= lo_n;
        bp <= bp + 32'(fh >>> 16);
        h  <= h + 32'(mh >>> 24);
    end
end

function automatic logic [19:0] sweep_lf(input logic [4:0] i);
    case (i)
        5'd0: sweep_lf = 20'd653118;
        5'd1: sweep_lf = 20'd688248;
        5'd2: sweep_lf = 20'd725491;
        5'd3: sweep_lf = 20'd760090;
        5'd4: sweep_lf = 20'd788803;
        5'd5: sweep_lf = 20'd810797;
        5'd6: sweep_lf = 20'd828628;
        5'd7: sweep_lf = 20'd834360;
        5'd8: sweep_lf = 20'd837773;
        5'd9: sweep_lf = 20'd841068;
        5'd10: sweep_lf = 20'd866964;
        5'd11: sweep_lf = 20'd881539;
        5'd12: sweep_lf = 20'd912260;
        5'd13: sweep_lf = 20'd927443;
        5'd14: sweep_lf = 20'd932006;
        5'd15: sweep_lf = 20'd933480;
        default: sweep_lf = 20'd933966;
    endcase
endfunction
function automatic logic [19:0] fire_lf(input logic [4:0] i);
    case (i)
        5'd0: fire_lf = 20'd539284;
        5'd1: fire_lf = 20'd577620;
        5'd2: fire_lf = 20'd643156;
        5'd3: fire_lf = 20'd694554;
        5'd4: fire_lf = 20'd743460;
        5'd5: fire_lf = 20'd805288;
        5'd6: fire_lf = 20'd899198;
        5'd7: fire_lf = 20'd912260;
        5'd8: fire_lf = 20'd905954;
        5'd9: fire_lf = 20'd865974;
        5'd10: fire_lf = 20'd859805;
        5'd11: fire_lf = 20'd887271;
        5'd12: fire_lf = 20'd904641;
        5'd13: fire_lf = 20'd914072;
        5'd14: fire_lf = 20'd924809;
        5'd15: fire_lf = 20'd936360;
        default: fire_lf = 20'd940973;
    endcase
endfunction
function automatic logic [15:0] exp2m(input logic [7:0] i);
    case (i)
        8'd0: exp2m = 16'd32768; 8'd1: exp2m = 16'd32857; 8'd2: exp2m = 16'd32946; 8'd3: exp2m = 16'd33035;
        8'd4: exp2m = 16'd33125; 8'd5: exp2m = 16'd33215; 8'd6: exp2m = 16'd33305; 8'd7: exp2m = 16'd33395;
        8'd8: exp2m = 16'd33486; 8'd9: exp2m = 16'd33576; 8'd10: exp2m = 16'd33667; 8'd11: exp2m = 16'd33759;
        8'd12: exp2m = 16'd33850; 8'd13: exp2m = 16'd33942; 8'd14: exp2m = 16'd34034; 8'd15: exp2m = 16'd34126;
        8'd16: exp2m = 16'd34219; 8'd17: exp2m = 16'd34312; 8'd18: exp2m = 16'd34405; 8'd19: exp2m = 16'd34498;
        8'd20: exp2m = 16'd34591; 8'd21: exp2m = 16'd34685; 8'd22: exp2m = 16'd34779; 8'd23: exp2m = 16'd34874;
        8'd24: exp2m = 16'd34968; 8'd25: exp2m = 16'd35063; 8'd26: exp2m = 16'd35158; 8'd27: exp2m = 16'd35253;
        8'd28: exp2m = 16'd35349; 8'd29: exp2m = 16'd35445; 8'd30: exp2m = 16'd35541; 8'd31: exp2m = 16'd35637;
        8'd32: exp2m = 16'd35734; 8'd33: exp2m = 16'd35831; 8'd34: exp2m = 16'd35928; 8'd35: exp2m = 16'd36025;
        8'd36: exp2m = 16'd36123; 8'd37: exp2m = 16'd36221; 8'd38: exp2m = 16'd36319; 8'd39: exp2m = 16'd36417;
        8'd40: exp2m = 16'd36516; 8'd41: exp2m = 16'd36615; 8'd42: exp2m = 16'd36715; 8'd43: exp2m = 16'd36814;
        8'd44: exp2m = 16'd36914; 8'd45: exp2m = 16'd37014; 8'd46: exp2m = 16'd37114; 8'd47: exp2m = 16'd37215;
        8'd48: exp2m = 16'd37316; 8'd49: exp2m = 16'd37417; 8'd50: exp2m = 16'd37518; 8'd51: exp2m = 16'd37620;
        8'd52: exp2m = 16'd37722; 8'd53: exp2m = 16'd37824; 8'd54: exp2m = 16'd37927; 8'd55: exp2m = 16'd38030;
        8'd56: exp2m = 16'd38133; 8'd57: exp2m = 16'd38236; 8'd58: exp2m = 16'd38340; 8'd59: exp2m = 16'd38444;
        8'd60: exp2m = 16'd38548; 8'd61: exp2m = 16'd38653; 8'd62: exp2m = 16'd38757; 8'd63: exp2m = 16'd38863;
        8'd64: exp2m = 16'd38968; 8'd65: exp2m = 16'd39074; 8'd66: exp2m = 16'd39180; 8'd67: exp2m = 16'd39286;
        8'd68: exp2m = 16'd39392; 8'd69: exp2m = 16'd39499; 8'd70: exp2m = 16'd39606; 8'd71: exp2m = 16'd39714;
        8'd72: exp2m = 16'd39821; 8'd73: exp2m = 16'd39929; 8'd74: exp2m = 16'd40037; 8'd75: exp2m = 16'd40146;
        8'd76: exp2m = 16'd40255; 8'd77: exp2m = 16'd40364; 8'd78: exp2m = 16'd40473; 8'd79: exp2m = 16'd40583;
        8'd80: exp2m = 16'd40693; 8'd81: exp2m = 16'd40804; 8'd82: exp2m = 16'd40914; 8'd83: exp2m = 16'd41025;
        8'd84: exp2m = 16'd41136; 8'd85: exp2m = 16'd41248; 8'd86: exp2m = 16'd41360; 8'd87: exp2m = 16'd41472;
        8'd88: exp2m = 16'd41584; 8'd89: exp2m = 16'd41697; 8'd90: exp2m = 16'd41810; 8'd91: exp2m = 16'd41923;
        8'd92: exp2m = 16'd42037; 8'd93: exp2m = 16'd42151; 8'd94: exp2m = 16'd42265; 8'd95: exp2m = 16'd42380;
        8'd96: exp2m = 16'd42495; 8'd97: exp2m = 16'd42610; 8'd98: exp2m = 16'd42726; 8'd99: exp2m = 16'd42841;
        8'd100: exp2m = 16'd42958; 8'd101: exp2m = 16'd43074; 8'd102: exp2m = 16'd43191; 8'd103: exp2m = 16'd43308;
        8'd104: exp2m = 16'd43425; 8'd105: exp2m = 16'd43543; 8'd106: exp2m = 16'd43661; 8'd107: exp2m = 16'd43780;
        8'd108: exp2m = 16'd43898; 8'd109: exp2m = 16'd44017; 8'd110: exp2m = 16'd44137; 8'd111: exp2m = 16'd44256;
        8'd112: exp2m = 16'd44376; 8'd113: exp2m = 16'd44497; 8'd114: exp2m = 16'd44617; 8'd115: exp2m = 16'd44738;
        8'd116: exp2m = 16'd44859; 8'd117: exp2m = 16'd44981; 8'd118: exp2m = 16'd45103; 8'd119: exp2m = 16'd45225;
        8'd120: exp2m = 16'd45348; 8'd121: exp2m = 16'd45471; 8'd122: exp2m = 16'd45594; 8'd123: exp2m = 16'd45718;
        8'd124: exp2m = 16'd45842; 8'd125: exp2m = 16'd45966; 8'd126: exp2m = 16'd46091; 8'd127: exp2m = 16'd46216;
        8'd128: exp2m = 16'd46341; 8'd129: exp2m = 16'd46467; 8'd130: exp2m = 16'd46593; 8'd131: exp2m = 16'd46719;
        8'd132: exp2m = 16'd46846; 8'd133: exp2m = 16'd46973; 8'd134: exp2m = 16'd47100; 8'd135: exp2m = 16'd47228;
        8'd136: exp2m = 16'd47356; 8'd137: exp2m = 16'd47484; 8'd138: exp2m = 16'd47613; 8'd139: exp2m = 16'd47742;
        8'd140: exp2m = 16'd47871; 8'd141: exp2m = 16'd48001; 8'd142: exp2m = 16'd48131; 8'd143: exp2m = 16'd48262;
        8'd144: exp2m = 16'd48393; 8'd145: exp2m = 16'd48524; 8'd146: exp2m = 16'd48655; 8'd147: exp2m = 16'd48787;
        8'd148: exp2m = 16'd48920; 8'd149: exp2m = 16'd49052; 8'd150: exp2m = 16'd49185; 8'd151: exp2m = 16'd49319;
        8'd152: exp2m = 16'd49452; 8'd153: exp2m = 16'd49586; 8'd154: exp2m = 16'd49721; 8'd155: exp2m = 16'd49856;
        8'd156: exp2m = 16'd49991; 8'd157: exp2m = 16'd50126; 8'd158: exp2m = 16'd50262; 8'd159: exp2m = 16'd50399;
        8'd160: exp2m = 16'd50535; 8'd161: exp2m = 16'd50672; 8'd162: exp2m = 16'd50810; 8'd163: exp2m = 16'd50947;
        8'd164: exp2m = 16'd51085; 8'd165: exp2m = 16'd51224; 8'd166: exp2m = 16'd51363; 8'd167: exp2m = 16'd51502;
        8'd168: exp2m = 16'd51642; 8'd169: exp2m = 16'd51782; 8'd170: exp2m = 16'd51922; 8'd171: exp2m = 16'd52063;
        8'd172: exp2m = 16'd52204; 8'd173: exp2m = 16'd52346; 8'd174: exp2m = 16'd52488; 8'd175: exp2m = 16'd52630;
        8'd176: exp2m = 16'd52773; 8'd177: exp2m = 16'd52916; 8'd178: exp2m = 16'd53059; 8'd179: exp2m = 16'd53203;
        8'd180: exp2m = 16'd53347; 8'd181: exp2m = 16'd53492; 8'd182: exp2m = 16'd53637; 8'd183: exp2m = 16'd53782;
        8'd184: exp2m = 16'd53928; 8'd185: exp2m = 16'd54074; 8'd186: exp2m = 16'd54221; 8'd187: exp2m = 16'd54368;
        8'd188: exp2m = 16'd54515; 8'd189: exp2m = 16'd54663; 8'd190: exp2m = 16'd54811; 8'd191: exp2m = 16'd54960;
        8'd192: exp2m = 16'd55109; 8'd193: exp2m = 16'd55258; 8'd194: exp2m = 16'd55408; 8'd195: exp2m = 16'd55558;
        8'd196: exp2m = 16'd55709; 8'd197: exp2m = 16'd55860; 8'd198: exp2m = 16'd56012; 8'd199: exp2m = 16'd56163;
        8'd200: exp2m = 16'd56316; 8'd201: exp2m = 16'd56468; 8'd202: exp2m = 16'd56622; 8'd203: exp2m = 16'd56775;
        8'd204: exp2m = 16'd56929; 8'd205: exp2m = 16'd57083; 8'd206: exp2m = 16'd57238; 8'd207: exp2m = 16'd57393;
        8'd208: exp2m = 16'd57549; 8'd209: exp2m = 16'd57705; 8'd210: exp2m = 16'd57861; 8'd211: exp2m = 16'd58018;
        8'd212: exp2m = 16'd58176; 8'd213: exp2m = 16'd58333; 8'd214: exp2m = 16'd58491; 8'd215: exp2m = 16'd58650;
        8'd216: exp2m = 16'd58809; 8'd217: exp2m = 16'd58968; 8'd218: exp2m = 16'd59128; 8'd219: exp2m = 16'd59289;
        8'd220: exp2m = 16'd59449; 8'd221: exp2m = 16'd59611; 8'd222: exp2m = 16'd59772; 8'd223: exp2m = 16'd59934;
        8'd224: exp2m = 16'd60097; 8'd225: exp2m = 16'd60260; 8'd226: exp2m = 16'd60423; 8'd227: exp2m = 16'd60587;
        8'd228: exp2m = 16'd60751; 8'd229: exp2m = 16'd60916; 8'd230: exp2m = 16'd61081; 8'd231: exp2m = 16'd61247;
        8'd232: exp2m = 16'd61413; 8'd233: exp2m = 16'd61579; 8'd234: exp2m = 16'd61746; 8'd235: exp2m = 16'd61914;
        8'd236: exp2m = 16'd62081; 8'd237: exp2m = 16'd62250; 8'd238: exp2m = 16'd62419; 8'd239: exp2m = 16'd62588;
        8'd240: exp2m = 16'd62757; 8'd241: exp2m = 16'd62928; 8'd242: exp2m = 16'd63098; 8'd243: exp2m = 16'd63269;
        8'd244: exp2m = 16'd63441; 8'd245: exp2m = 16'd63613; 8'd246: exp2m = 16'd63785; 8'd247: exp2m = 16'd63958;
        8'd248: exp2m = 16'd64132; 8'd249: exp2m = 16'd64306; 8'd250: exp2m = 16'd64480; 8'd251: exp2m = 16'd64655;
        8'd252: exp2m = 16'd64830; 8'd253: exp2m = 16'd65006; 8'd254: exp2m = 16'd65182;
        default: exp2m = 16'd65359;
    endcase
endfunction

logic p6_q = 1'b1, fire_go = 1'b0, v2_q = 1'b0;
logic [23:0] nsr = 24'd0;
always_ff @(posedge clk) begin
    p6_q <= port1[6];
    if (p6_q & ~port1[6]) fire_go <= 1'b1;
    else if (step) fire_go <= 1'b0;
    v2_q <= v2;
    if (reset) nsr <= 24'd0;
    else if (v2 & ~v2_q) nsr <= {nsr[22:0], ~(nsr[10] ^ nsr[23])};
end

localparam [24:0] ONE = 25'h1000000;
logic        fire_m = 1'b0;
logic [24:0] fq = 25'd0;
logic [23:0] sp = 24'd0;
logic [24:0] ek = 25'd0, ef = 25'd0;
logic [24:0] u = ONE;
logic [39:0] vacc = 40'd0;
logic  [8:0] vhi = 9'd0, vsum = 9'd0;
logic signed [17:0] nl = 18'sd0, vm = 18'sd0, vl = 18'sd0;

wire  [4:0] ti = fire_m ? {1'b0, fq[23:20]} : {1'b0, sp[23:20]};
wire [15:0] tf = fire_m ? fq[19:4] : sp[19:4];
wire [19:0] t0 = fire_m ? fire_lf(ti) : sweep_lf(ti);
wire [19:0] t1 = fire_m ? fire_lf(ti + 5'd1) : sweep_lf(ti + 5'd1);
wire signed [37:0] di = (38'($signed({2'b00, t1})) - 38'($signed({2'b00, t0}))) * 38'($signed({1'b0, tf}));
wire [20:0] lf = 21'(t0) + 21'(di >>> 16) + 21'd946946;
wire [31:0] inc = 32'(exp2m(lf[15:8])) << (lf[20:16] - 5'd15);

wire [16:0] avk = 17'(ek >> 8);
logic [49:0] afp;
wire [16:0] avf = (afp >= 50'(1) << 30) ? 17'd65536 : 17'(afp >> 14);
wire [16:0] avm = (avk > avf) ? avk : avf;
wire [16:0] av  = (avm < 17'd328) ? 17'd0 : avm;
wire [49:0] uxp = 50'(u) * 50'd77988;
wire [16:0] ux = 17'(uxp >> 24);
wire [16:0] ax = (ux >= 17'd65536) ? 17'd0 : 17'd65536 - ux;

wire signed [18:0] nin = nsr[0] ? 19'sd65536 : -19'sd65536;
logic signed [35:0] nd1, nd0, vd, vd2;
wire signed [35:0] nd = nsr[0] ? nd1 : nd0;
wire signed [35:0] ne = 36'(nl) * 36'($signed({1'b0, ax}));
wire signed [35:0] no = 36'(18'(ne >>> 16)) * 36'sd17745;
wire signed [10:0] vsq = $signed({2'b00, vsum}) * 11'sd2 - 11'sd256;
wire signed [23:0] vs27 = (24'(vsq) <<< 11) + (24'(vsq) <<< 9) + (24'(vsq) <<< 7) + (24'(vsq) <<< 3) + (24'(vsq) <<< 2);
logic signed [41:0] vip;
wire signed [35:0] vin = 36'(vip >>> 8);
wire [24:0] fq_n = fq + 25'd218;
logic [49:0] ekm, efm, ud, uc;
wire  [24:0] onemu = ONE - u;
wire signed [35:0] ndh = 36'sd65536 - 36'(nl);
wire signed [35:0] ndl = -36'sd65536 - 36'(nl);
wire signed [35:0] vmd = 36'(vm) - 36'(vl);
wire signed [35:0] vid = 36'(18'(vin >>> 16)) - 36'(vm);

always_comb begin
    mul_a = 40'sd0; mul_b = 27'sd0;
    case (sdiv)
        8'd8:  begin mul_a = 40'(bp);  mul_b = 27'(F);  end
        8'd9:  begin mul_a = 40'(bp);  mul_b = 27'(D);  end
        8'd10: begin mul_a = 40'(dh);  mul_b = 27'(AH); end
        8'd11: begin mul_a = 40'($signed({1'b0, ef})); mul_b = 27'sd173;  end
        8'd12: begin mul_a = 40'($signed({1'b0, ek})); mul_b = 27'sd218;  end
        8'd13: begin mul_a = 40'($signed({1'b0, ef})); mul_b = 27'sd350;  end
        8'd14: begin mul_a = 40'($signed({1'b0, u}));  mul_b = 27'sd1859; end
        8'd15: begin mul_a = 40'($signed({1'b0, onemu})); mul_b = 27'sd169; end
        8'd16: begin mul_a = 40'(ndh);  mul_b = 27'sd534; end
        8'd17: begin mul_a = 40'(ndl);  mul_b = 27'sd534; end
        8'd18: begin mul_a = 40'(vmd);  mul_b = 27'sd24085; end
        8'd19: begin mul_a = 40'(lo_n); mul_b = 27'(F); end
        8'd20: begin mul_a = 40'(dbs);  mul_b = 27'(F); end
        8'd21: begin mul_a = 40'(vs27); mul_b = 27'($signed({1'b0, av})); end
        8'd24: begin mul_a = 40'(vid);  mul_b = 27'sd24085; end
        default: ;
    endcase
end
always_ff @(posedge clk) begin
    case (sdiv)
        8'd10: fb  <= 50'(mul_p);
        8'd11: db  <= 50'(mul_p);
        8'd12: mh  <= 50'(mul_p);
        8'd13: afp <= 50'(mul_p);
        8'd14: ekm <= 50'(mul_p);
        8'd15: efm <= 50'(mul_p);
        8'd16: ud  <= 50'(mul_p);
        8'd17: uc  <= 50'(mul_p);
        8'd18: nd1 <= 36'(mul_p);
        8'd19: nd0 <= 36'(mul_p);
        8'd20: vd2 <= 36'(mul_p);
        8'd21: p3  <= 50'(mul_p);
        8'd22: p4  <= 50'(mul_p);
        8'd23: vip <= 42'(mul_p);
        8'd26: vd  <= 36'(mul_p);
        default: ;
    endcase
end

always_ff @(posedge clk) begin
    if (reset) begin
        fire_m <= 1'b0; fq <= 25'd0; sp <= 24'd0; ek <= 25'd0; ef <= 25'd0; u <= ONE;
        nl <= 18'sd0; vm <= 18'sd0; vl <= 18'sd0;
    end else if (step) begin
        if (fire_go) begin fire_m <= 1'b1; fq <= 25'd0; sp <= 24'd0; end
        else if (fire_m) begin fq <= fq_n; if (fq_n >= ONE) fire_m <= 1'b0; end
        else sp <= sp + (port1[0] ? 24'd253 : 24'd1085);
        if (!port1[0]) ek <= ONE; else ek <= ek - 25'(ekm >> 24);
        if (fire_go) ef <= ONE; else ef <= ef - 25'(efm >> 24);
        if (!port1[7]) u <= u - 25'(ud >> 24);
        else u <= u + 25'(uc >> 24);
        nl <= nl + 18'(nd >>> 16);
        vm <= vm + 18'(vd >>> 16);
        vl <= vl + 18'(vd2 >>> 16);
    end
end

always_ff @(posedge clk) begin
    vacc <= vacc + 40'(inc);
    if (step) begin vsum <= vhi; vhi <= 9'(vacc[39]); end
    else vhi <= vhi + 9'(vacc[39]);
end

wire fx_on = ~mcs48_0_o.p2[6];

wire signed [31:0] ac = lo - h;
wire signed [21:0] o  = 22'(ac >>> 10) + (fx_on ? 22'(vl) + 22'(no >>> 16) : 22'sd0);
assign audio = (o > 22'sd32767) ? 16'sd32767 : (o < -22'sd32768) ? -16'sd32768 : o[15:0];

endmodule
