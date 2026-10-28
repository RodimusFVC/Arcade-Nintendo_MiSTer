//============================================================================
//
//  Nintendo Radar Scope (TRS-02) background: blue level, radar grid and stars (reference: MAME dkong_v.cpp, TRS-02
//  hardware)
//  Copyright (C) 2026 Rodimus
//
//  Once per line (start pulse, y = MAME vpos of the line to come), the analog model is stepped in fixed point
//  (voltages Q24, RC factors 1 - exp(-dt / RC) x 2^24 with MAME's dt = 1 / 60 / 264) on one multiplier:
//    sig = SOUND2 & 30 Hz noise bit ^ 128VF; C 22u (2.2K) / 33u (10K) into two CD4049 stages solved by MAME's fixed
//    11 + 11 iterations (CD4049 = MAME's exp(-a x^b) curve, 513-point table with linear interpolation), C17 coupling
//    -> blue level = vo / 5 x 255 (wraps as MAME's uint8); grid: C (18K / 86K x 33u) and C (90K x 0.47u) chain, gated
//    by the grid enable (7D81) and ANS (8035 P2.5), through two CD4049s to a TTL threshold; stars: flip-flop toggled
//    every 459 pixels (MAME period2).
//  Then the line's dots are walked from the 2K timing table (gfx3) exactly as MAME: entry x = 4 x (t & 7F), bit 7 =
//  star (shown while the star flip-flop is set) else grid (while the grid signal is on); the table half is chosen by
//  flip ^ RFLIP; the walk restarts on lines <= 16 and > 239; after the line, entries past x 384 are skipped.
//  Output: a 64-column x 2-bit buffer per line parity (0 blue, 1 star, 2 grid) + the line's background B.
//  The 30 Hz noise bit (random in the reference) is a 16-bit LFSR here.
//
//============================================================================

module dkong_radar
(
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // prepare line y (one clock)
    input  logic  [8:0] y,              // MAME vpos 0-263
    input  logic        flip,
    input  logic        snd2,           // 6H Q2 (SOUND2)
    input  logic        grid_on,        // 7D81
    input  logic        ans,            // 8035 P2.5

    output logic [10:0] gfx3_a,         // timing table (data 2 clocks later)
    input  logic  [7:0] gfx3_d,

    input  logic        rd_bank,        // parity of the displayed line
    input  logic  [5:0] rd_col,         // h[7:2]
    output logic  [1:0] rd_type,        // 0 blue, 1 star, 2 grid
    output logic  [7:0] rd_blue         // B of the line's background
);

// 5 V x CD4049(v / 5) at v = i x 8 V / 512, Q24 (CD4049 inverter model); entry = {value[26:0], next - value [20:0]}
function automatic logic [47:0] cd_lut(input logic [8:0] i);
    case (i)
        9'd0: cd_lut = {27'd83886080, 21'h000000};
        9'd1: cd_lut = {27'd83886080, 21'h000000};
        9'd2: cd_lut = {27'd83886080, 21'h000000};
        9'd3: cd_lut = {27'd83886080, 21'h000000};
        9'd4: cd_lut = {27'd83886080, 21'h000000};
        9'd5: cd_lut = {27'd83886080, 21'h000000};
        9'd6: cd_lut = {27'd83886080, 21'h000000};
        9'd7: cd_lut = {27'd83886080, 21'h000000};
        9'd8: cd_lut = {27'd83886080, 21'h000000};
        9'd9: cd_lut = {27'd83886080, 21'h000000};
        9'd10: cd_lut = {27'd83886080, 21'h000000};
        9'd11: cd_lut = {27'd83886080, 21'h000000};
        9'd12: cd_lut = {27'd83886080, 21'h000000};
        9'd13: cd_lut = {27'd83886080, 21'h000000};
        9'd14: cd_lut = {27'd83886080, 21'h000000};
        9'd15: cd_lut = {27'd83886080, 21'h000000};
        9'd16: cd_lut = {27'd83886080, 21'h000000};
        9'd17: cd_lut = {27'd83886080, 21'h000000};
        9'd18: cd_lut = {27'd83886080, 21'h000000};
        9'd19: cd_lut = {27'd83886080, 21'h1FFFFF};
        9'd20: cd_lut = {27'd83886079, 21'h000000};
        9'd21: cd_lut = {27'd83886079, 21'h000000};
        9'd22: cd_lut = {27'd83886079, 21'h1FFFFF};
        9'd23: cd_lut = {27'd83886078, 21'h1FFFFF};
        9'd24: cd_lut = {27'd83886077, 21'h000000};
        9'd25: cd_lut = {27'd83886077, 21'h1FFFFE};
        9'd26: cd_lut = {27'd83886075, 21'h1FFFFF};
        9'd27: cd_lut = {27'd83886074, 21'h1FFFFE};
        9'd28: cd_lut = {27'd83886072, 21'h1FFFFE};
        9'd29: cd_lut = {27'd83886070, 21'h1FFFFD};
        9'd30: cd_lut = {27'd83886067, 21'h1FFFFD};
        9'd31: cd_lut = {27'd83886064, 21'h1FFFFC};
        9'd32: cd_lut = {27'd83886060, 21'h1FFFFB};
        9'd33: cd_lut = {27'd83886055, 21'h1FFFFA};
        9'd34: cd_lut = {27'd83886049, 21'h1FFFF8};
        9'd35: cd_lut = {27'd83886041, 21'h1FFFF8};
        9'd36: cd_lut = {27'd83886033, 21'h1FFFF5};
        9'd37: cd_lut = {27'd83886022, 21'h1FFFF4};
        9'd38: cd_lut = {27'd83886010, 21'h1FFFF2};
        9'd39: cd_lut = {27'd83885996, 21'h1FFFEF};
        9'd40: cd_lut = {27'd83885979, 21'h1FFFEC};
        9'd41: cd_lut = {27'd83885959, 21'h1FFFE9};
        9'd42: cd_lut = {27'd83885936, 21'h1FFFE5};
        9'd43: cd_lut = {27'd83885909, 21'h1FFFE1};
        9'd44: cd_lut = {27'd83885878, 21'h1FFFDC};
        9'd45: cd_lut = {27'd83885842, 21'h1FFFD7};
        9'd46: cd_lut = {27'd83885801, 21'h1FFFD1};
        9'd47: cd_lut = {27'd83885754, 21'h1FFFCB};
        9'd48: cd_lut = {27'd83885701, 21'h1FFFC3};
        9'd49: cd_lut = {27'd83885640, 21'h1FFFBA};
        9'd50: cd_lut = {27'd83885570, 21'h1FFFB2};
        9'd51: cd_lut = {27'd83885492, 21'h1FFFA7};
        9'd52: cd_lut = {27'd83885403, 21'h1FFF9C};
        9'd53: cd_lut = {27'd83885303, 21'h1FFF90};
        9'd54: cd_lut = {27'd83885191, 21'h1FFF82};
        9'd55: cd_lut = {27'd83885065, 21'h1FFF73};
        9'd56: cd_lut = {27'd83884924, 21'h1FFF62};
        9'd57: cd_lut = {27'd83884766, 21'h1FFF50};
        9'd58: cd_lut = {27'd83884590, 21'h1FFF3B};
        9'd59: cd_lut = {27'd83884393, 21'h1FFF26};
        9'd60: cd_lut = {27'd83884175, 21'h1FFF0F};
        9'd61: cd_lut = {27'd83883934, 21'h1FFEF4};
        9'd62: cd_lut = {27'd83883666, 21'h1FFED8};
        9'd63: cd_lut = {27'd83883370, 21'h1FFEB9};
        9'd64: cd_lut = {27'd83883043, 21'h1FFE97};
        9'd65: cd_lut = {27'd83882682, 21'h1FFE74};
        9'd66: cd_lut = {27'd83882286, 21'h1FFE4C};
        9'd67: cd_lut = {27'd83881850, 21'h1FFE22};
        9'd68: cd_lut = {27'd83881372, 21'h1FFDF3};
        9'd69: cd_lut = {27'd83880847, 21'h1FFDC3};
        9'd70: cd_lut = {27'd83880274, 21'h1FFD8C};
        9'd71: cd_lut = {27'd83879646, 21'h1FFD54};
        9'd72: cd_lut = {27'd83878962, 21'h1FFD15};
        9'd73: cd_lut = {27'd83878215, 21'h1FFCD3};
        9'd74: cd_lut = {27'd83877402, 21'h1FFC8B};
        9'd75: cd_lut = {27'd83876517, 21'h1FFC3F};
        9'd76: cd_lut = {27'd83875556, 21'h1FFBED};
        9'd77: cd_lut = {27'd83874513, 21'h1FFB95};
        9'd78: cd_lut = {27'd83873382, 21'h1FFB36};
        9'd79: cd_lut = {27'd83872156, 21'h1FFAD2};
        9'd80: cd_lut = {27'd83870830, 21'h1FFA67};
        9'd81: cd_lut = {27'd83869397, 21'h1FF9F4};
        9'd82: cd_lut = {27'd83867849, 21'h1FF97A};
        9'd83: cd_lut = {27'd83866179, 21'h1FF8F8};
        9'd84: cd_lut = {27'd83864379, 21'h1FF86D};
        9'd85: cd_lut = {27'd83862440, 21'h1FF7DA};
        9'd86: cd_lut = {27'd83860354, 21'h1FF73D};
        9'd87: cd_lut = {27'd83858111, 21'h1FF697};
        9'd88: cd_lut = {27'd83855702, 21'h1FF5E6};
        9'd89: cd_lut = {27'd83853116, 21'h1FF52B};
        9'd90: cd_lut = {27'd83850343, 21'h1FF463};
        9'd91: cd_lut = {27'd83847370, 21'h1FF392};
        9'd92: cd_lut = {27'd83844188, 21'h1FF2B2};
        9'd93: cd_lut = {27'd83840782, 21'h1FF1C7};
        9'd94: cd_lut = {27'd83837141, 21'h1FF0CD};
        9'd95: cd_lut = {27'd83833250, 21'h1FEFC5};
        9'd96: cd_lut = {27'd83829095, 21'h1FEEAF};
        9'd97: cd_lut = {27'd83824662, 21'h1FED89};
        9'd98: cd_lut = {27'd83819935, 21'h1FEC54};
        9'd99: cd_lut = {27'd83814899, 21'h1FEB0C};
        9'd100: cd_lut = {27'd83809535, 21'h1FE9B4};
        9'd101: cd_lut = {27'd83803827, 21'h1FE849};
        9'd102: cd_lut = {27'd83797756, 21'h1FE6CB};
        9'd103: cd_lut = {27'd83791303, 21'h1FE539};
        9'd104: cd_lut = {27'd83784448, 21'h1FE393};
        9'd105: cd_lut = {27'd83777171, 21'h1FE1D6};
        9'd106: cd_lut = {27'd83769449, 21'h1FE003};
        9'd107: cd_lut = {27'd83761260, 21'h1FDE19};
        9'd108: cd_lut = {27'd83752581, 21'h1FDC17};
        9'd109: cd_lut = {27'd83743388, 21'h1FD9FB};
        9'd110: cd_lut = {27'd83733655, 21'h1FD7C5};
        9'd111: cd_lut = {27'd83723356, 21'h1FD574};
        9'd112: cd_lut = {27'd83712464, 21'h1FD306};
        9'd113: cd_lut = {27'd83700950, 21'h1FD07A};
        9'd114: cd_lut = {27'd83688784, 21'h1FCDD2};
        9'd115: cd_lut = {27'd83675938, 21'h1FCB08};
        9'd116: cd_lut = {27'd83662378, 21'h1FC81E};
        9'd117: cd_lut = {27'd83648072, 21'h1FC512};
        9'd118: cd_lut = {27'd83632986, 21'h1FC1E3};
        9'd119: cd_lut = {27'd83617085, 21'h1FBE90};
        9'd120: cd_lut = {27'd83600333, 21'h1FBB16};
        9'd121: cd_lut = {27'd83582691, 21'h1FB776};
        9'd122: cd_lut = {27'd83564121, 21'h1FB3AD};
        9'd123: cd_lut = {27'd83544582, 21'h1FAFBB};
        9'd124: cd_lut = {27'd83524033, 21'h1FAB9D};
        9'd125: cd_lut = {27'd83502430, 21'h1FA753};
        9'd126: cd_lut = {27'd83479729, 21'h1FA2DA};
        9'd127: cd_lut = {27'd83455883, 21'h1F9E33};
        9'd128: cd_lut = {27'd83430846, 21'h1F995A};
        9'd129: cd_lut = {27'd83404568, 21'h1F944E};
        9'd130: cd_lut = {27'd83376998, 21'h1F8F0E};
        9'd131: cd_lut = {27'd83348084, 21'h1F8998};
        9'd132: cd_lut = {27'd83317772, 21'h1F83EB};
        9'd133: cd_lut = {27'd83286007, 21'h1F7E05};
        9'd134: cd_lut = {27'd83252732, 21'h1F77E2};
        9'd135: cd_lut = {27'd83217886, 21'h1F7184};
        9'd136: cd_lut = {27'd83181410, 21'h1F6AE7};
        9'd137: cd_lut = {27'd83143241, 21'h1F6409};
        9'd138: cd_lut = {27'd83103314, 21'h1F5CEA};
        9'd139: cd_lut = {27'd83061564, 21'h1F5586};
        9'd140: cd_lut = {27'd83017922, 21'h1F4DDB};
        9'd141: cd_lut = {27'd82972317, 21'h1F45EA};
        9'd142: cd_lut = {27'd82924679, 21'h1F3DAF};
        9'd143: cd_lut = {27'd82874934, 21'h1F3526};
        9'd144: cd_lut = {27'd82823004, 21'h1F2C50};
        9'd145: cd_lut = {27'd82768812, 21'h1F232B};
        9'd146: cd_lut = {27'd82712279, 21'h1F19B2};
        9'd147: cd_lut = {27'd82653321, 21'h1F0FE7};
        9'd148: cd_lut = {27'd82591856, 21'h1F05C4};
        9'd149: cd_lut = {27'd82527796, 21'h1EFB48};
        9'd150: cd_lut = {27'd82461052, 21'h1EF074};
        9'd151: cd_lut = {27'd82391536, 21'h1EE540};
        9'd152: cd_lut = {27'd82319152, 21'h1ED9AF};
        9'd153: cd_lut = {27'd82243807, 21'h1ECDBD};
        9'd154: cd_lut = {27'd82165404, 21'h1EC166};
        9'd155: cd_lut = {27'd82083842, 21'h1EB4AA};
        9'd156: cd_lut = {27'd81999020, 21'h1EA787};
        9'd157: cd_lut = {27'd81910835, 21'h1E99F8};
        9'd158: cd_lut = {27'd81819179, 21'h1E8BFF};
        9'd159: cd_lut = {27'd81723946, 21'h1E7D95};
        9'd160: cd_lut = {27'd81625023, 21'h1E6EBC};
        9'd161: cd_lut = {27'd81522299, 21'h1E5F6E};
        9'd162: cd_lut = {27'd81415657, 21'h1E4FAD};
        9'd163: cd_lut = {27'd81304982, 21'h1E3F73};
        9'd164: cd_lut = {27'd81190153, 21'h1E2EBF};
        9'd165: cd_lut = {27'd81071048, 21'h1E1D90};
        9'd166: cd_lut = {27'd80947544, 21'h1E0BE3};
        9'd167: cd_lut = {27'd80819515, 21'h1DF9B6};
        9'd168: cd_lut = {27'd80686833, 21'h1DE706};
        9'd169: cd_lut = {27'd80549367, 21'h1DD3D2};
        9'd170: cd_lut = {27'd80406985, 21'h1DC017};
        9'd171: cd_lut = {27'd80259552, 21'h1DABD6};
        9'd172: cd_lut = {27'd80106934, 21'h1D970A};
        9'd173: cd_lut = {27'd79948992, 21'h1D81B1};
        9'd174: cd_lut = {27'd79785585, 21'h1D6BCB};
        9'd175: cd_lut = {27'd79616572, 21'h1D5557};
        9'd176: cd_lut = {27'd79441811, 21'h1D3E51};
        9'd177: cd_lut = {27'd79261156, 21'h1D26B8};
        9'd178: cd_lut = {27'd79074460, 21'h1D0E8C};
        9'd179: cd_lut = {27'd78881576, 21'h1CF5CA};
        9'd180: cd_lut = {27'd78682354, 21'h1CDC73};
        9'd181: cd_lut = {27'd78476645, 21'h1CC284};
        9'd182: cd_lut = {27'd78264297, 21'h1CA7FC};
        9'd183: cd_lut = {27'd78045157, 21'h1C8CDB};
        9'd184: cd_lut = {27'd77819072, 21'h1C7121};
        9'd185: cd_lut = {27'd77585889, 21'h1C54CB};
        9'd186: cd_lut = {27'd77345452, 21'h1C37DB};
        9'd187: cd_lut = {27'd77097607, 21'h1C1A4F};
        9'd188: cd_lut = {27'd76842198, 21'h1BFC2A};
        9'd189: cd_lut = {27'd76579072, 21'h1BDD67};
        9'd190: cd_lut = {27'd76308071, 21'h1BBE0C};
        9'd191: cd_lut = {27'd76029043, 21'h1B9E15};
        9'd192: cd_lut = {27'd75741832, 21'h1B7D87};
        9'd193: cd_lut = {27'd75446287, 21'h1B5C5E};
        9'd194: cd_lut = {27'd75142253, 21'h1B3AA0};
        9'd195: cd_lut = {27'd74829581, 21'h1B184B};
        9'd196: cd_lut = {27'd74508120, 21'h1AF563};
        9'd197: cd_lut = {27'd74177723, 21'h1AD1EA};
        9'd198: cd_lut = {27'd73838245, 21'h1AADE0};
        9'd199: cd_lut = {27'd73489541, 21'h1A894A};
        9'd200: cd_lut = {27'd73131471, 21'h1A642A};
        9'd201: cd_lut = {27'd72763897, 21'h1A3E83};
        9'd202: cd_lut = {27'd72386684, 21'h1A185A};
        9'd203: cd_lut = {27'd71999702, 21'h19F1B0};
        9'd204: cd_lut = {27'd71602822, 21'h19CA8D};
        9'd205: cd_lut = {27'd71195923, 21'h19A2F1};
        9'd206: cd_lut = {27'd70778884, 21'h197AE6};
        9'd207: cd_lut = {27'd70351594, 21'h19526E};
        9'd208: cd_lut = {27'd69913944, 21'h192990};
        9'd209: cd_lut = {27'd69465832, 21'h190051};
        9'd210: cd_lut = {27'd69007161, 21'h18D6B9};
        9'd211: cd_lut = {27'd68537842, 21'h18ACCF};
        9'd212: cd_lut = {27'd68057793, 21'h188298};
        9'd213: cd_lut = {27'd67566937, 21'h18581F};
        9'd214: cd_lut = {27'd67065208, 21'h182D6A};
        9'd215: cd_lut = {27'd66552546, 21'h180283};
        9'd216: cd_lut = {27'd66028901, 21'h17D772};
        9'd217: cd_lut = {27'd65494231, 21'h17AC42};
        9'd218: cd_lut = {27'd64948505, 21'h1780FB};
        9'd219: cd_lut = {27'd64391700, 21'h1755AA};
        9'd220: cd_lut = {27'd63823806, 21'h172A58};
        9'd221: cd_lut = {27'd63244822, 21'h16FF12};
        9'd222: cd_lut = {27'd62654760, 21'h16D3E1};
        9'd223: cd_lut = {27'd62053641, 21'h16A8D5};
        9'd224: cd_lut = {27'd61441502, 21'h167DF9};
        9'd225: cd_lut = {27'd60818391, 21'h165359};
        9'd226: cd_lut = {27'd60184368, 21'h162904};
        9'd227: cd_lut = {27'd59539508, 21'h15FF08};
        9'd228: cd_lut = {27'd58883900, 21'h15D574};
        9'd229: cd_lut = {27'd58217648, 21'h15AC55};
        9'd230: cd_lut = {27'd57540869, 21'h1583BC};
        9'd231: cd_lut = {27'd56853697, 21'h155BB7};
        9'd232: cd_lut = {27'd56156280, 21'h153457};
        9'd233: cd_lut = {27'd55448783, 21'h150DAC};
        9'd234: cd_lut = {27'd54731387, 21'h14E7C6};
        9'd235: cd_lut = {27'd54004289, 21'h14C2B7};
        9'd236: cd_lut = {27'd53267704, 21'h149E8E};
        9'd237: cd_lut = {27'd52521862, 21'h147B5F};
        9'd238: cd_lut = {27'd51767013, 21'h145937};
        9'd239: cd_lut = {27'd51003420, 21'h14382D};
        9'd240: cd_lut = {27'd50231369, 21'h14184E};
        9'd241: cd_lut = {27'd49451159, 21'h13F9AE};
        9'd242: cd_lut = {27'd48663109, 21'h13DC5E};
        9'd243: cd_lut = {27'd47867555, 21'h13C06F};
        9'd244: cd_lut = {27'd47064850, 21'h13A5F5};
        9'd245: cd_lut = {27'd46255367, 21'h138CFF};
        9'd246: cd_lut = {27'd45439494, 21'h13759E};
        9'd247: cd_lut = {27'd44617636, 21'h135FE5};
        9'd248: cd_lut = {27'd43790217, 21'h134BE3};
        9'd249: cd_lut = {27'd42957676, 21'h1339A9};
        9'd250: cd_lut = {27'd42120469, 21'h132947};
        9'd251: cd_lut = {27'd41279068, 21'h131ACB};
        9'd252: cd_lut = {27'd40433959, 21'h130E47};
        9'd253: cd_lut = {27'd39585646, 21'h1303C7};
        9'd254: cd_lut = {27'd38734645, 21'h12FB59};
        9'd255: cd_lut = {27'd37881486, 21'h12F50A};
        9'd256: cd_lut = {27'd37026712, 21'h12F0E6};
        9'd257: cd_lut = {27'd36170878, 21'h12EEF9};
        9'd258: cd_lut = {27'd35314551, 21'h12EF4C};
        9'd259: cd_lut = {27'd34458307, 21'h12F1EA};
        9'd260: cd_lut = {27'd33602733, 21'h12F6DA};
        9'd261: cd_lut = {27'd32748423, 21'h12FE24};
        9'd262: cd_lut = {27'd31895979, 21'h1307CE};
        9'd263: cd_lut = {27'd31046009, 21'h1313DC};
        9'd264: cd_lut = {27'd30199125, 21'h132253};
        9'd265: cd_lut = {27'd29355944, 21'h133334};
        9'd266: cd_lut = {27'd28517084, 21'h134680};
        9'd267: cd_lut = {27'd27683164, 21'h135C37};
        9'd268: cd_lut = {27'd26854803, 21'h137456};
        9'd269: cd_lut = {27'd26032617, 21'h138EDC};
        9'd270: cd_lut = {27'd25217221, 21'h13ABC0};
        9'd271: cd_lut = {27'd24409221, 21'h13CAFE};
        9'd272: cd_lut = {27'd23609219, 21'h13EC8D};
        9'd273: cd_lut = {27'd22817808, 21'h141065};
        9'd274: cd_lut = {27'd22035573, 21'h143678};
        9'd275: cd_lut = {27'd21263085, 21'h145EBB};
        9'd276: cd_lut = {27'd20500904, 21'h14891E};
        9'd277: cd_lut = {27'd19749574, 21'h14B591};
        9'd278: cd_lut = {27'd19009623, 21'h14E406};
        9'd279: cd_lut = {27'd18281565, 21'h151464};
        9'd280: cd_lut = {27'd17565889, 21'h15469B};
        9'd281: cd_lut = {27'd16863068, 21'h157A93};
        9'd282: cd_lut = {27'd16173551, 21'h15B036};
        9'd283: cd_lut = {27'd15497765, 21'h15E76A};
        9'd284: cd_lut = {27'd14836111, 21'h162015};
        9'd285: cd_lut = {27'd14188964, 21'h165A1D};
        9'd286: cd_lut = {27'd13556673, 21'h169565};
        9'd287: cd_lut = {27'd12939558, 21'h16D1D1};
        9'd288: cd_lut = {27'd12337911, 21'h170F43};
        9'd289: cd_lut = {27'd11751994, 21'h174D9A};
        9'd290: cd_lut = {27'd11182036, 21'h178CBA};
        9'd291: cd_lut = {27'd10628238, 21'h17CC80};
        9'd292: cd_lut = {27'd10090766, 21'h180CCF};
        9'd293: cd_lut = {27'd9569757, 21'h184D83};
        9'd294: cd_lut = {27'd9065312, 21'h188E7D};
        9'd295: cd_lut = {27'd8577501, 21'h18CF9D};
        9'd296: cd_lut = {27'd8106362, 21'h1910C0};
        9'd297: cd_lut = {27'd7651898, 21'h1951C8};
        9'd298: cd_lut = {27'd7214082, 21'h199294};
        9'd299: cd_lut = {27'd6792854, 21'h19D304};
        9'd300: cd_lut = {27'd6388122, 21'h1A12FA};
        9'd301: cd_lut = {27'd5999764, 21'h1A5257};
        9'd302: cd_lut = {27'd5627627, 21'h1A90FF};
        9'd303: cd_lut = {27'd5271530, 21'h1ACED5};
        9'd304: cd_lut = {27'd4931263, 21'h1B0BBE};
        9'd305: cd_lut = {27'd4606589, 21'h1B47A1};
        9'd306: cd_lut = {27'd4297246, 21'h1B8265};
        9'd307: cd_lut = {27'd4002947, 21'h1BBBF4};
        9'd308: cd_lut = {27'd3723383, 21'h1BF438};
        9'd309: cd_lut = {27'd3458223, 21'h1C2B1D};
        9'd310: cd_lut = {27'd3207116, 21'h1C6091};
        9'd311: cd_lut = {27'd2969693, 21'h1C9484};
        9'd312: cd_lut = {27'd2745569, 21'h1CC6E7};
        9'd313: cd_lut = {27'd2534344, 21'h1CF7AF};
        9'd314: cd_lut = {27'd2335607, 21'h1D26CF};
        9'd315: cd_lut = {27'd2148934, 21'h1D543F};
        9'd316: cd_lut = {27'd1973893, 21'h1D7FF7};
        9'd317: cd_lut = {27'd1810044, 21'h1DA9F4};
        9'd318: cd_lut = {27'd1656944, 21'h1DD22E};
        9'd319: cd_lut = {27'd1514142, 21'h1DF8A8};
        9'd320: cd_lut = {27'd1381190, 21'h1E1D5F};
        9'd321: cd_lut = {27'd1257637, 21'h1E4056};
        9'd322: cd_lut = {27'd1143035, 21'h1E618F};
        9'd323: cd_lut = {27'd1036938, 21'h1E810F};
        9'd324: cd_lut = {27'd938905, 21'h1E9EDE};
        9'd325: cd_lut = {27'd848503, 21'h1EBB01};
        9'd326: cd_lut = {27'd765304, 21'h1ED581};
        9'd327: cd_lut = {27'd688889, 21'h1EEE69};
        9'd328: cd_lut = {27'd618850, 21'h1F05C4};
        9'd329: cd_lut = {27'd554790, 21'h1F1B9D};
        9'd330: cd_lut = {27'd496323, 21'h1F3001};
        9'd331: cd_lut = {27'd443076, 21'h1F42FE};
        9'd332: cd_lut = {27'd394690, 21'h1F54A0};
        9'd333: cd_lut = {27'd350818, 21'h1F64F7};
        9'd334: cd_lut = {27'd311129, 21'h1F7412};
        9'd335: cd_lut = {27'd275307, 21'h1F8200};
        9'd336: cd_lut = {27'd243051, 21'h1F8ECF};
        9'd337: cd_lut = {27'd214074, 21'h1F9A8F};
        9'd338: cd_lut = {27'd188105, 21'h1FA551};
        9'd339: cd_lut = {27'd164890, 21'h1FAF20};
        9'd340: cd_lut = {27'd144186, 21'h1FB810};
        9'd341: cd_lut = {27'd125770, 21'h1FC02C};
        9'd342: cd_lut = {27'd109430, 21'h1FC783};
        9'd343: cd_lut = {27'd94969, 21'h1FCE25};
        9'd344: cd_lut = {27'd82206, 21'h1FD41C};
        9'd345: cd_lut = {27'd70970, 21'h1FD978};
        9'd346: cd_lut = {27'd61106, 21'h1FDE44};
        9'd347: cd_lut = {27'd52470, 21'h1FE28D};
        9'd348: cd_lut = {27'd44931, 21'h1FE65C};
        9'd349: cd_lut = {27'd38367, 21'h1FE9BE};
        9'd350: cd_lut = {27'd32669, 21'h1FECBC};
        9'd351: cd_lut = {27'd27737, 21'h1FEF5F};
        9'd352: cd_lut = {27'd23480, 21'h1FF1B2};
        9'd353: cd_lut = {27'd19818, 21'h1FF3BB};
        9'd354: cd_lut = {27'd16677, 21'h1FF581};
        9'd355: cd_lut = {27'd13990, 21'h1FF70E};
        9'd356: cd_lut = {27'd11700, 21'h1FF866};
        9'd357: cd_lut = {27'd9754, 21'h1FF98F};
        9'd358: cd_lut = {27'd8105, 21'h1FFA91};
        9'd359: cd_lut = {27'd6714, 21'h1FFB6D};
        9'd360: cd_lut = {27'd5543, 21'h1FFC2A};
        9'd361: cd_lut = {27'd4561, 21'h1FFCCB};
        9'd362: cd_lut = {27'd3740, 21'h1FFD54};
        9'd363: cd_lut = {27'd3056, 21'h1FFDC9};
        9'd364: cd_lut = {27'd2489, 21'h1FFE2B};
        9'd365: cd_lut = {27'd2020, 21'h1FFE7D};
        9'd366: cd_lut = {27'd1633, 21'h1FFEC3};
        9'd367: cd_lut = {27'd1316, 21'h1FFEFC};
        9'd368: cd_lut = {27'd1056, 21'h1FFF2C};
        9'd369: cd_lut = {27'd844, 21'h1FFF55};
        9'd370: cd_lut = {27'd673, 21'h1FFF75};
        9'd371: cd_lut = {27'd534, 21'h1FFF90};
        9'd372: cd_lut = {27'd422, 21'h1FFFA6};
        9'd373: cd_lut = {27'd332, 21'h1FFFB8};
        9'd374: cd_lut = {27'd260, 21'h1FFFC7};
        9'd375: cd_lut = {27'd203, 21'h1FFFD3};
        9'd376: cd_lut = {27'd158, 21'h1FFFDC};
        9'd377: cd_lut = {27'd122, 21'h1FFFE4};
        9'd378: cd_lut = {27'd94, 21'h1FFFEB};
        9'd379: cd_lut = {27'd73, 21'h1FFFEE};
        9'd380: cd_lut = {27'd55, 21'h1FFFF3};
        9'd381: cd_lut = {27'd42, 21'h1FFFF6};
        9'd382: cd_lut = {27'd32, 21'h1FFFF8};
        9'd383: cd_lut = {27'd24, 21'h1FFFFA};
        9'd384: cd_lut = {27'd18, 21'h1FFFFC};
        9'd385: cd_lut = {27'd14, 21'h1FFFFC};
        9'd386: cd_lut = {27'd10, 21'h1FFFFD};
        9'd387: cd_lut = {27'd7, 21'h1FFFFE};
        9'd388: cd_lut = {27'd5, 21'h1FFFFF};
        9'd389: cd_lut = {27'd4, 21'h1FFFFF};
        9'd390: cd_lut = {27'd3, 21'h1FFFFF};
        9'd391: cd_lut = {27'd2, 21'h000000};
        9'd392: cd_lut = {27'd2, 21'h1FFFFF};
        9'd393: cd_lut = {27'd1, 21'h000000};
        9'd394: cd_lut = {27'd1, 21'h000000};
        9'd395: cd_lut = {27'd1, 21'h1FFFFF};
        9'd396: cd_lut = {27'd0, 21'h000000};
        9'd397: cd_lut = {27'd0, 21'h000000};
        9'd398: cd_lut = {27'd0, 21'h000000};
        9'd399: cd_lut = {27'd0, 21'h000000};
        9'd400: cd_lut = {27'd0, 21'h000000};
        9'd401: cd_lut = {27'd0, 21'h000000};
        9'd402: cd_lut = {27'd0, 21'h000000};
        9'd403: cd_lut = {27'd0, 21'h000000};
        9'd404: cd_lut = {27'd0, 21'h000000};
        9'd405: cd_lut = {27'd0, 21'h000000};
        9'd406: cd_lut = {27'd0, 21'h000000};
        9'd407: cd_lut = {27'd0, 21'h000000};
        9'd408: cd_lut = {27'd0, 21'h000000};
        9'd409: cd_lut = {27'd0, 21'h000000};
        9'd410: cd_lut = {27'd0, 21'h000000};
        9'd411: cd_lut = {27'd0, 21'h000000};
        9'd412: cd_lut = {27'd0, 21'h000000};
        9'd413: cd_lut = {27'd0, 21'h000000};
        9'd414: cd_lut = {27'd0, 21'h000000};
        9'd415: cd_lut = {27'd0, 21'h000000};
        9'd416: cd_lut = {27'd0, 21'h000000};
        9'd417: cd_lut = {27'd0, 21'h000000};
        9'd418: cd_lut = {27'd0, 21'h000000};
        9'd419: cd_lut = {27'd0, 21'h000000};
        9'd420: cd_lut = {27'd0, 21'h000000};
        9'd421: cd_lut = {27'd0, 21'h000000};
        9'd422: cd_lut = {27'd0, 21'h000000};
        9'd423: cd_lut = {27'd0, 21'h000000};
        9'd424: cd_lut = {27'd0, 21'h000000};
        9'd425: cd_lut = {27'd0, 21'h000000};
        9'd426: cd_lut = {27'd0, 21'h000000};
        9'd427: cd_lut = {27'd0, 21'h000000};
        9'd428: cd_lut = {27'd0, 21'h000000};
        9'd429: cd_lut = {27'd0, 21'h000000};
        9'd430: cd_lut = {27'd0, 21'h000000};
        9'd431: cd_lut = {27'd0, 21'h000000};
        9'd432: cd_lut = {27'd0, 21'h000000};
        9'd433: cd_lut = {27'd0, 21'h000000};
        9'd434: cd_lut = {27'd0, 21'h000000};
        9'd435: cd_lut = {27'd0, 21'h000000};
        9'd436: cd_lut = {27'd0, 21'h000000};
        9'd437: cd_lut = {27'd0, 21'h000000};
        9'd438: cd_lut = {27'd0, 21'h000000};
        9'd439: cd_lut = {27'd0, 21'h000000};
        9'd440: cd_lut = {27'd0, 21'h000000};
        9'd441: cd_lut = {27'd0, 21'h000000};
        9'd442: cd_lut = {27'd0, 21'h000000};
        9'd443: cd_lut = {27'd0, 21'h000000};
        9'd444: cd_lut = {27'd0, 21'h000000};
        9'd445: cd_lut = {27'd0, 21'h000000};
        9'd446: cd_lut = {27'd0, 21'h000000};
        9'd447: cd_lut = {27'd0, 21'h000000};
        9'd448: cd_lut = {27'd0, 21'h000000};
        9'd449: cd_lut = {27'd0, 21'h000000};
        9'd450: cd_lut = {27'd0, 21'h000000};
        9'd451: cd_lut = {27'd0, 21'h000000};
        9'd452: cd_lut = {27'd0, 21'h000000};
        9'd453: cd_lut = {27'd0, 21'h000000};
        9'd454: cd_lut = {27'd0, 21'h000000};
        9'd455: cd_lut = {27'd0, 21'h000000};
        9'd456: cd_lut = {27'd0, 21'h000000};
        9'd457: cd_lut = {27'd0, 21'h000000};
        9'd458: cd_lut = {27'd0, 21'h000000};
        9'd459: cd_lut = {27'd0, 21'h000000};
        9'd460: cd_lut = {27'd0, 21'h000000};
        9'd461: cd_lut = {27'd0, 21'h000000};
        9'd462: cd_lut = {27'd0, 21'h000000};
        9'd463: cd_lut = {27'd0, 21'h000000};
        9'd464: cd_lut = {27'd0, 21'h000000};
        9'd465: cd_lut = {27'd0, 21'h000000};
        9'd466: cd_lut = {27'd0, 21'h000000};
        9'd467: cd_lut = {27'd0, 21'h000000};
        9'd468: cd_lut = {27'd0, 21'h000000};
        9'd469: cd_lut = {27'd0, 21'h000000};
        9'd470: cd_lut = {27'd0, 21'h000000};
        9'd471: cd_lut = {27'd0, 21'h000000};
        9'd472: cd_lut = {27'd0, 21'h000000};
        9'd473: cd_lut = {27'd0, 21'h000000};
        9'd474: cd_lut = {27'd0, 21'h000000};
        9'd475: cd_lut = {27'd0, 21'h000000};
        9'd476: cd_lut = {27'd0, 21'h000000};
        9'd477: cd_lut = {27'd0, 21'h000000};
        9'd478: cd_lut = {27'd0, 21'h000000};
        9'd479: cd_lut = {27'd0, 21'h000000};
        9'd480: cd_lut = {27'd0, 21'h000000};
        9'd481: cd_lut = {27'd0, 21'h000000};
        9'd482: cd_lut = {27'd0, 21'h000000};
        9'd483: cd_lut = {27'd0, 21'h000000};
        9'd484: cd_lut = {27'd0, 21'h000000};
        9'd485: cd_lut = {27'd0, 21'h000000};
        9'd486: cd_lut = {27'd0, 21'h000000};
        9'd487: cd_lut = {27'd0, 21'h000000};
        9'd488: cd_lut = {27'd0, 21'h000000};
        9'd489: cd_lut = {27'd0, 21'h000000};
        9'd490: cd_lut = {27'd0, 21'h000000};
        9'd491: cd_lut = {27'd0, 21'h000000};
        9'd492: cd_lut = {27'd0, 21'h000000};
        9'd493: cd_lut = {27'd0, 21'h000000};
        9'd494: cd_lut = {27'd0, 21'h000000};
        9'd495: cd_lut = {27'd0, 21'h000000};
        9'd496: cd_lut = {27'd0, 21'h000000};
        9'd497: cd_lut = {27'd0, 21'h000000};
        9'd498: cd_lut = {27'd0, 21'h000000};
        9'd499: cd_lut = {27'd0, 21'h000000};
        9'd500: cd_lut = {27'd0, 21'h000000};
        9'd501: cd_lut = {27'd0, 21'h000000};
        9'd502: cd_lut = {27'd0, 21'h000000};
        9'd503: cd_lut = {27'd0, 21'h000000};
        9'd504: cd_lut = {27'd0, 21'h000000};
        9'd505: cd_lut = {27'd0, 21'h000000};
        9'd506: cd_lut = {27'd0, 21'h000000};
        9'd507: cd_lut = {27'd0, 21'h000000};
        9'd508: cd_lut = {27'd0, 21'h000000};
        9'd509: cd_lut = {27'd0, 21'h000000};
        9'd510: cd_lut = {27'd0, 21'h000000};
        default: cd_lut = {27'd0, 21'h000000};
    endcase
endfunction
// blue background level -> B (blue resistor net, not normalised)
function automatic logic [7:0] blue_lut(input logic [7:0] i);
    case (i)
        8'd0: blue_lut = 8'd255; 8'd1: blue_lut = 8'd255; 8'd2: blue_lut = 8'd255; 8'd3: blue_lut = 8'd255;
        8'd4: blue_lut = 8'd255; 8'd5: blue_lut = 8'd255; 8'd6: blue_lut = 8'd255; 8'd7: blue_lut = 8'd255;
        8'd8: blue_lut = 8'd255; 8'd9: blue_lut = 8'd255; 8'd10: blue_lut = 8'd255; 8'd11: blue_lut = 8'd255;
        8'd12: blue_lut = 8'd255; 8'd13: blue_lut = 8'd255; 8'd14: blue_lut = 8'd255; 8'd15: blue_lut = 8'd255;
        8'd16: blue_lut = 8'd255; 8'd17: blue_lut = 8'd255; 8'd18: blue_lut = 8'd255; 8'd19: blue_lut = 8'd255;
        8'd20: blue_lut = 8'd255; 8'd21: blue_lut = 8'd255; 8'd22: blue_lut = 8'd255; 8'd23: blue_lut = 8'd255;
        8'd24: blue_lut = 8'd255; 8'd25: blue_lut = 8'd255; 8'd26: blue_lut = 8'd255; 8'd27: blue_lut = 8'd255;
        8'd28: blue_lut = 8'd255; 8'd29: blue_lut = 8'd255; 8'd30: blue_lut = 8'd255; 8'd31: blue_lut = 8'd255;
        8'd32: blue_lut = 8'd255; 8'd33: blue_lut = 8'd255; 8'd34: blue_lut = 8'd255; 8'd35: blue_lut = 8'd255;
        8'd36: blue_lut = 8'd255; 8'd37: blue_lut = 8'd255; 8'd38: blue_lut = 8'd255; 8'd39: blue_lut = 8'd255;
        8'd40: blue_lut = 8'd255; 8'd41: blue_lut = 8'd255; 8'd42: blue_lut = 8'd255; 8'd43: blue_lut = 8'd255;
        8'd44: blue_lut = 8'd255; 8'd45: blue_lut = 8'd255; 8'd46: blue_lut = 8'd255; 8'd47: blue_lut = 8'd255;
        8'd48: blue_lut = 8'd255; 8'd49: blue_lut = 8'd255; 8'd50: blue_lut = 8'd255; 8'd51: blue_lut = 8'd255;
        8'd52: blue_lut = 8'd255; 8'd53: blue_lut = 8'd255; 8'd54: blue_lut = 8'd255; 8'd55: blue_lut = 8'd255;
        8'd56: blue_lut = 8'd255; 8'd57: blue_lut = 8'd255; 8'd58: blue_lut = 8'd255; 8'd59: blue_lut = 8'd255;
        8'd60: blue_lut = 8'd255; 8'd61: blue_lut = 8'd255; 8'd62: blue_lut = 8'd255; 8'd63: blue_lut = 8'd255;
        8'd64: blue_lut = 8'd255; 8'd65: blue_lut = 8'd255; 8'd66: blue_lut = 8'd255; 8'd67: blue_lut = 8'd255;
        8'd68: blue_lut = 8'd255; 8'd69: blue_lut = 8'd255; 8'd70: blue_lut = 8'd255; 8'd71: blue_lut = 8'd255;
        8'd72: blue_lut = 8'd254; 8'd73: blue_lut = 8'd253; 8'd74: blue_lut = 8'd251; 8'd75: blue_lut = 8'd250;
        8'd76: blue_lut = 8'd249; 8'd77: blue_lut = 8'd247; 8'd78: blue_lut = 8'd246; 8'd79: blue_lut = 8'd244;
        8'd80: blue_lut = 8'd243; 8'd81: blue_lut = 8'd242; 8'd82: blue_lut = 8'd240; 8'd83: blue_lut = 8'd239;
        8'd84: blue_lut = 8'd237; 8'd85: blue_lut = 8'd236; 8'd86: blue_lut = 8'd235; 8'd87: blue_lut = 8'd233;
        8'd88: blue_lut = 8'd232; 8'd89: blue_lut = 8'd230; 8'd90: blue_lut = 8'd229; 8'd91: blue_lut = 8'd228;
        8'd92: blue_lut = 8'd226; 8'd93: blue_lut = 8'd225; 8'd94: blue_lut = 8'd224; 8'd95: blue_lut = 8'd222;
        8'd96: blue_lut = 8'd221; 8'd97: blue_lut = 8'd219; 8'd98: blue_lut = 8'd218; 8'd99: blue_lut = 8'd217;
        8'd100: blue_lut = 8'd215; 8'd101: blue_lut = 8'd214; 8'd102: blue_lut = 8'd212; 8'd103: blue_lut = 8'd211;
        8'd104: blue_lut = 8'd210; 8'd105: blue_lut = 8'd208; 8'd106: blue_lut = 8'd207; 8'd107: blue_lut = 8'd205;
        8'd108: blue_lut = 8'd204; 8'd109: blue_lut = 8'd203; 8'd110: blue_lut = 8'd201; 8'd111: blue_lut = 8'd200;
        8'd112: blue_lut = 8'd199; 8'd113: blue_lut = 8'd197; 8'd114: blue_lut = 8'd196; 8'd115: blue_lut = 8'd194;
        8'd116: blue_lut = 8'd193; 8'd117: blue_lut = 8'd192; 8'd118: blue_lut = 8'd190; 8'd119: blue_lut = 8'd189;
        8'd120: blue_lut = 8'd187; 8'd121: blue_lut = 8'd186; 8'd122: blue_lut = 8'd185; 8'd123: blue_lut = 8'd183;
        8'd124: blue_lut = 8'd182; 8'd125: blue_lut = 8'd180; 8'd126: blue_lut = 8'd179; 8'd127: blue_lut = 8'd178;
        8'd128: blue_lut = 8'd176; 8'd129: blue_lut = 8'd175; 8'd130: blue_lut = 8'd174; 8'd131: blue_lut = 8'd172;
        8'd132: blue_lut = 8'd171; 8'd133: blue_lut = 8'd169; 8'd134: blue_lut = 8'd168; 8'd135: blue_lut = 8'd167;
        8'd136: blue_lut = 8'd165; 8'd137: blue_lut = 8'd164; 8'd138: blue_lut = 8'd162; 8'd139: blue_lut = 8'd161;
        8'd140: blue_lut = 8'd160; 8'd141: blue_lut = 8'd158; 8'd142: blue_lut = 8'd157; 8'd143: blue_lut = 8'd155;
        8'd144: blue_lut = 8'd154; 8'd145: blue_lut = 8'd153; 8'd146: blue_lut = 8'd151; 8'd147: blue_lut = 8'd150;
        8'd148: blue_lut = 8'd149; 8'd149: blue_lut = 8'd147; 8'd150: blue_lut = 8'd146; 8'd151: blue_lut = 8'd144;
        8'd152: blue_lut = 8'd143; 8'd153: blue_lut = 8'd142; 8'd154: blue_lut = 8'd140; 8'd155: blue_lut = 8'd139;
        8'd156: blue_lut = 8'd137; 8'd157: blue_lut = 8'd136; 8'd158: blue_lut = 8'd135; 8'd159: blue_lut = 8'd133;
        8'd160: blue_lut = 8'd132; 8'd161: blue_lut = 8'd130; 8'd162: blue_lut = 8'd129; 8'd163: blue_lut = 8'd128;
        8'd164: blue_lut = 8'd126; 8'd165: blue_lut = 8'd125; 8'd166: blue_lut = 8'd124; 8'd167: blue_lut = 8'd122;
        8'd168: blue_lut = 8'd121; 8'd169: blue_lut = 8'd119; 8'd170: blue_lut = 8'd118; 8'd171: blue_lut = 8'd117;
        8'd172: blue_lut = 8'd115; 8'd173: blue_lut = 8'd114; 8'd174: blue_lut = 8'd112; 8'd175: blue_lut = 8'd111;
        8'd176: blue_lut = 8'd110; 8'd177: blue_lut = 8'd108; 8'd178: blue_lut = 8'd107; 8'd179: blue_lut = 8'd105;
        8'd180: blue_lut = 8'd104; 8'd181: blue_lut = 8'd103; 8'd182: blue_lut = 8'd101; 8'd183: blue_lut = 8'd100;
        8'd184: blue_lut = 8'd99; 8'd185: blue_lut = 8'd97; 8'd186: blue_lut = 8'd96; 8'd187: blue_lut = 8'd94;
        8'd188: blue_lut = 8'd93; 8'd189: blue_lut = 8'd92; 8'd190: blue_lut = 8'd90; 8'd191: blue_lut = 8'd89;
        8'd192: blue_lut = 8'd87; 8'd193: blue_lut = 8'd86; 8'd194: blue_lut = 8'd85; 8'd195: blue_lut = 8'd83;
        8'd196: blue_lut = 8'd82; 8'd197: blue_lut = 8'd80; 8'd198: blue_lut = 8'd79; 8'd199: blue_lut = 8'd78;
        8'd200: blue_lut = 8'd76; 8'd201: blue_lut = 8'd75; 8'd202: blue_lut = 8'd74; 8'd203: blue_lut = 8'd72;
        8'd204: blue_lut = 8'd71; 8'd205: blue_lut = 8'd69; 8'd206: blue_lut = 8'd68; 8'd207: blue_lut = 8'd67;
        8'd208: blue_lut = 8'd65; 8'd209: blue_lut = 8'd64; 8'd210: blue_lut = 8'd62; 8'd211: blue_lut = 8'd61;
        8'd212: blue_lut = 8'd60; 8'd213: blue_lut = 8'd58; 8'd214: blue_lut = 8'd57; 8'd215: blue_lut = 8'd55;
        8'd216: blue_lut = 8'd54; 8'd217: blue_lut = 8'd53; 8'd218: blue_lut = 8'd51; 8'd219: blue_lut = 8'd50;
        8'd220: blue_lut = 8'd49; 8'd221: blue_lut = 8'd47; 8'd222: blue_lut = 8'd46; 8'd223: blue_lut = 8'd44;
        8'd224: blue_lut = 8'd43; 8'd225: blue_lut = 8'd42; 8'd226: blue_lut = 8'd40; 8'd227: blue_lut = 8'd39;
        8'd228: blue_lut = 8'd37; 8'd229: blue_lut = 8'd36; 8'd230: blue_lut = 8'd35; 8'd231: blue_lut = 8'd33;
        8'd232: blue_lut = 8'd32; 8'd233: blue_lut = 8'd30; 8'd234: blue_lut = 8'd29; 8'd235: blue_lut = 8'd28;
        8'd236: blue_lut = 8'd26; 8'd237: blue_lut = 8'd25; 8'd238: blue_lut = 8'd24; 8'd239: blue_lut = 8'd22;
        8'd240: blue_lut = 8'd21; 8'd241: blue_lut = 8'd19; 8'd242: blue_lut = 8'd18; 8'd243: blue_lut = 8'd17;
        8'd244: blue_lut = 8'd15; 8'd245: blue_lut = 8'd14; 8'd246: blue_lut = 8'd12; 8'd247: blue_lut = 8'd11;
        8'd248: blue_lut = 8'd10; 8'd249: blue_lut = 8'd8; 8'd250: blue_lut = 8'd7; 8'd251: blue_lut = 8'd5;
        8'd252: blue_lut = 8'd4; 8'd253: blue_lut = 8'd3; 8'd254: blue_lut = 8'd1;
        default: blue_lut = 8'd0;
    endcase
endfunction

localparam signed [31:0] V4_8 = 32'sd80530637, V5 = 32'sd83886080, V10_3 = 32'sd55924053, V2_4 = 32'sd40265318;
localparam signed [17:0] K1 = 18'sd21869, K2 = 18'sd3209, K31 = 18'sd1783, K32 = 18'sd373, K4 = 18'sd25021,
                         K17 = 18'sd4814, K08 = 18'sd52429, K51 = 18'sd51;

// iteration weights x 2^16: j / 100 (j = 1..11), j / 40 (j = 10..20)
function automatic logic signed [17:0] fw(input logic second, input logic [3:0] j);
    case ({second, j})
        5'h00: fw = 18'sd655;   5'h01: fw = 18'sd1311;  5'h02: fw = 18'sd1966;  5'h03: fw = 18'sd2621;
        5'h04: fw = 18'sd3277;  5'h05: fw = 18'sd3932;  5'h06: fw = 18'sd4588;  5'h07: fw = 18'sd5243;
        5'h08: fw = 18'sd5898;  5'h09: fw = 18'sd6554;  5'h0A: fw = 18'sd7209;
        5'h10: fw = 18'sd16384; 5'h11: fw = 18'sd18022; 5'h12: fw = 18'sd19661; 5'h13: fw = 18'sd21299;
        5'h14: fw = 18'sd22938; 5'h15: fw = 18'sd24576; 5'h16: fw = 18'sd26214; 5'h17: fw = 18'sd27853;
        5'h18: fw = 18'sd29491; 5'h19: fw = 18'sd31130; default: fw = 18'sd32768;
    endcase
endfunction

// state (voltages Q24)
logic signed [31:0] cv1, cv2, vg1, vg2, vg3, cv3, cv4, vc17, u;
logic        sig30, lfsr5i, star_ff, grid_sig, rflip;
logic  [9:0] pixcnt;
logic [15:0] rnd = 16'hACE1;
logic  [7:0] blue_lv[2];
logic  [1:0] cb[2][64];

assign rd_type = cb[rd_bank][rd_col];
assign rd_blue = blue_lut(blue_lv[rd_bank]);

// one multiplier: m_a x m_b >>> 16 or 24 (operands registered by the previous state)
logic signed [31:0] m_a;
logic signed [17:0] m_b;
logic               m_s24;
wire  signed [49:0] m_p = 50'(m_a) * 50'(m_b);
wire  signed [31:0] m_r = m_s24 ? 32'(m_p >>> 24) : 32'(m_p >>> 16);

// CD4049: input registered (cd_issue), ROM registered, result (cd_v) two clocks after the issue
logic  [8:0] cd_i;
logic [47:0] cd_q;
always_ff @(posedge clk) cd_q <= cd_lut(cd_i);
logic  [9:0] cd_fr, cd_fr_q;
logic  [1:0] cd_sat, cd_sat_q;          // 1: input <= 0 V (5 V out), 2: input >= 8 V (0 V out)
always_ff @(posedge clk) begin cd_fr_q <= cd_fr; cd_sat_q <= cd_sat; end
wire  signed [20:0] cd_d  = cd_q[20:0];
wire  signed [31:0] cd_df = 32'(cd_d) * 32'($signed({1'b0, cd_fr_q}));
wire  signed [31:0] cd_v  = (cd_sat_q == 2'd1) ? V5 : (cd_sat_q == 2'd2) ? 32'sd0
                          : 32'($signed({5'd0, cd_q[47:21]})) + (cd_df >>> 10);

typedef enum logic [4:0] {
    R_IDLE, R_CV1, R_CV2, R_U, R_A1, R_A2, R_A3, R_B1, R_B2, R_B3, R_C17, R_BLUE, R_CV3, R_CV4A, R_CV4B,
    R_G1W, R_G1, R_G2W, R_G2, R_WRD, R_WRD2, R_WALK, R_SRD, R_SRD2, R_SKIP
} rs_t;
rs_t         rs;
logic  [3:0] it;
logic  [8:0] ly;
logic        wb;                        // bank written for line ly
logic [11:0] cnt;                       // table entry (2048 = end)
logic  [9:0] xcur;
logic        hoff;                      // table half: 0 -> 0x400 (MAME (flip ^ rflip) ? 0x000 : 0x400)
wire   [9:0] lcw = {1'b0, ly} + 10'd249;                    // line count + 256 - 8 + 1, > 511 -> - VTOTAL
wire   [9:0] lc  = (lcw > 10'd511) ? lcw - 10'd264 : lcw;
wire   [8:0] p4  = {gfx3_d[6:0], 2'b00};
wire   [9:0] pix_n = pixcnt + 10'd384;
wire signed [31:0] cv1_n = cv1 + m_r, cv2_n = cv2 + m_r, cv3_n = cv3 + m_r, cv4_n = cv4 + m_r, vc17_n = vc17 + m_r;

assign gfx3_a = cnt[10:0] | (hoff ? 11'd0 : 11'h400);

always_ff @(posedge clk) begin
    cd_sat <= 2'd0;
    if (reset) begin
        rs <= R_IDLE; cv1 <= 0; cv2 <= 0; vg1 <= 0; vg2 <= 0; vg3 <= 0; cv3 <= 0; cv4 <= 0; vc17 <= 0;
        sig30 <= 1'b0; lfsr5i <= 1'b0; star_ff <= 1'b0; grid_sig <= 1'b0; rflip <= 1'b0; pixcnt <= 10'd0; cnt <= 12'd0;
    end else case (rs)
        R_IDLE: if (start) begin
            ly <= y; wb <= y[0]; rnd <= {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};
            if (y == 9'd0) begin sig30 <= ~sig30; if (!sig30) lfsr5i <= rnd[0]; end   // VSYNC / 2 clocks the 5I LFSR
            rs <= R_CV1;
        end
        R_CV1: begin                                        // cv1 toward 0 V (sig) or 4.8 V, RC1
            rflip <= snd2 & lfsr5i;
            m_a <= (((snd2 & lfsr5i) ^ lc[7]) ? 32'sd0 : V4_8) - cv1; m_b <= K1; m_s24 <= 1'b1;
            rs <= R_CV2;
        end
        R_CV2: begin cv1 <= cv1_n; m_a <= cv1_n - cv2 - vg1; m_b <= K2; rs <= R_U; end
        R_U: begin
            cv2 <= cv2_n; u <= cv1 - cv2_n; it <= 4'd0;
            m_a <= vg2 - (cv1 - cv2_n); m_b <= fw(1'b0, 4'd0); m_s24 <= 1'b0;
            rs <= R_A1;
        end
        // vg1 = u + f (vg2 - u); vg2 = CD4049(vg1)  (11 times)
        R_A1: begin
            vg1 <= u + m_r;
            cd_i <= 9'((u + m_r) >>> 18); cd_fr <= 10'((u + m_r) >>> 8);
            cd_sat <= ((u + m_r) <= 0) ? 2'd1 : ((u + m_r) >= 32'sd134217728) ? 2'd2 : 2'd0;
            rs <= R_A2;
        end
        R_A2: rs <= R_A3;
        R_A3: begin
            vg2 <= cd_v;
            if (it == 4'd10) begin it <= 4'd0; m_a <= vg3 - cd_v; m_b <= fw(1'b1, 4'd0); rs <= R_B1; end
            else begin it <= it + 4'd1; m_a <= cd_v - u; m_b <= fw(1'b0, it + 4'd1); rs <= R_A1; end
        end
        // vg3i = vg2 + f (vg3 - vg2); vg3 = CD4049(vg3i)  (11 times)
        R_B1: begin
            cd_i <= 9'((vg2 + m_r) >>> 18); cd_fr <= 10'((vg2 + m_r) >>> 8);
            cd_sat <= ((vg2 + m_r) <= 0) ? 2'd1 : ((vg2 + m_r) >= 32'sd134217728) ? 2'd2 : 2'd0;
            rs <= R_B2;
        end
        R_B2: rs <= R_B3;
        R_B3: begin
            vg3 <= cd_v;
            if (it == 4'd10) begin m_a <= cd_v - vc17; m_b <= K17; m_s24 <= 1'b1; rs <= R_C17; end
            else begin it <= it + 4'd1; m_a <= cd_v - vg2; m_b <= fw(1'b1, it + 4'd1); rs <= R_B1; end
        end
        R_C17: begin vc17 <= vc17_n; m_a <= vg3 - vc17_n + V10_3; m_b <= K51; rs <= R_BLUE; end
        R_BLUE: begin
            blue_lv[wb] <= m_r[7:0];                        // (int)(vo / 5 x 255) into a uint8
            m_a <= (grid_on & ans) ? -cv3 : V5 - cv3; m_b <= (grid_on & ans) ? K32 : K31;
            rs <= R_CV3;
        end
        R_CV3: begin cv3 <= cv3_n; m_a <= cv3_n; m_b <= K08; m_s24 <= 1'b0; rs <= R_CV4A; end
        R_CV4A: begin m_a <= vg2 - m_r - cv4; m_b <= K4; m_s24 <= 1'b1; rs <= R_CV4B; end
        R_CV4B: begin
            cv4 <= cv4_n;
            cd_i <= 9'((vg2 - cv4_n) >>> 18); cd_fr <= 10'((vg2 - cv4_n) >>> 8);
            cd_sat <= ((vg2 - cv4_n) <= 0) ? 2'd1 : ((vg2 - cv4_n) >= 32'sd134217728) ? 2'd2 : 2'd0;
            rs <= R_G1W;
        end
        R_G1W: rs <= R_G1;
        R_G1: begin
            cd_i <= 9'(cd_v >>> 18); cd_fr <= 10'(cd_v >>> 8);
            cd_sat <= (cd_v <= 0) ? 2'd1 : (cd_v >= 32'sd134217728) ? 2'd2 : 2'd0;
            rs <= R_G2W;
        end
        R_G2W: rs <= R_G2;
        R_G2: begin
            grid_sig <= !(cd_v > V2_4);
            if (pix_n > 10'd459) begin star_ff <= ~star_ff; pixcnt <= pix_n - 10'd459; end else pixcnt <= pix_n;
            if (ly <= 9'd16 || ly > 9'd239) cnt <= 12'd0;
            hoff <= flip ^ rflip; xcur <= 10'd0;
            for (int k = 0; k < 64; k++) cb[wb][k] <= 2'd0;
            rs <= R_WRD;
        end
        // dot walk: table data two clocks after the address
        R_WRD: rs <= cnt[11] ? R_IDLE : R_WRD2;
        R_WRD2: rs <= R_WALK;
        R_WALK: begin
            if ({1'b0, p4} >= xcur && p4 <= 9'd383) begin
                if (!p4[8]) cb[wb][p4[7:2]] <= (star_ff && gfx3_d[7]) ? 2'd1 : (grid_sig && !gfx3_d[7]) ? 2'd2 : 2'd0;
                xcur <= {1'b0, p4} + 10'd1; cnt <= cnt + 12'd1; rs <= R_WRD;
            end else if (p4 > 9'd384) begin cnt <= cnt + 12'd1; rs <= R_SRD; end
            else rs <= R_IDLE;
        end
        // end of line: skip entries past x 384
        R_SRD: rs <= cnt[11] ? R_IDLE : R_SRD2;
        R_SRD2: rs <= R_SKIP;
        R_SKIP: if (p4 > 9'd384) begin cnt <= cnt + 12'd1; rs <= R_SRD; end else rs <= R_IDLE;
        default: rs <= R_IDLE;
    endcase
end

endmodule
