//  Based on MAME nl_mario.cpp (Couriersud, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module mario_discrete
(
    input  logic        clk,
    input  logic        reset,
    input  logic        run,
    input  logic        step,
    input  logic        walk0,
    input  logic        walk1,
    input  logic        sound7,
    output logic  [8:0] lvl0,
    output logic  [8:0] lvl1,
    output logic  [8:0] lvl7,

    input  logic  [7:0] sdiv,
    output logic signed [39:0] mul_a,
    output logic signed [26:0] mul_b,
    input  logic signed [66:0] mul_p
);

localparam int W0 = 1081344;
localparam int W1 = 1199309;
localparam int W7 = 1818624;

localparam logic [15:0] T_W   = 16'd63048;
localparam logic [15:0] T_S7A = 16'd62669;
localparam logic [15:0] T_S7B = 16'd56975;
localparam logic [12:0] A_W0  = 13'd2051;
localparam logic [12:0] A_W1  = 13'd4366;
localparam logic [12:0] A_S7A = 13'd2941;
localparam logic [12:0] A_S7B = 13'd1618;

function automatic [17:0] ls629(input [6:0] i);
    case (i)
        7'd0:  ls629 = 18'd71243;  7'd1:  ls629 = 18'd69264;  7'd2:  ls629 = 18'd67560;  7'd3:  ls629 = 18'd66121;
        7'd4:  ls629 = 18'd64939;  7'd5:  ls629 = 18'd64004;  7'd6:  ls629 = 18'd63308;  7'd7:  ls629 = 18'd62844;
        7'd8:  ls629 = 18'd62601;  7'd9:  ls629 = 18'd62574;  7'd10: ls629 = 18'd62753;  7'd11: ls629 = 18'd63130;
        7'd12: ls629 = 18'd63699;  7'd13: ls629 = 18'd64452;  7'd14: ls629 = 18'd65381;  7'd15: ls629 = 18'd66479;
        7'd16: ls629 = 18'd67739;  7'd17: ls629 = 18'd69155;  7'd18: ls629 = 18'd70719;  7'd19: ls629 = 18'd72425;
        7'd20: ls629 = 18'd74266;  7'd21: ls629 = 18'd76237;  7'd22: ls629 = 18'd78330;  7'd23: ls629 = 18'd80541;
        7'd24: ls629 = 18'd82862;  7'd25: ls629 = 18'd85289;  7'd26: ls629 = 18'd87816;  7'd27: ls629 = 18'd90437;
        7'd28: ls629 = 18'd93148;  7'd29: ls629 = 18'd95942;  7'd30: ls629 = 18'd98816;  7'd31: ls629 = 18'd101763;
        7'd32: ls629 = 18'd104781; 7'd33: ls629 = 18'd107863; 7'd34: ls629 = 18'd111006; 7'd35: ls629 = 18'd114205;
        7'd36: ls629 = 18'd117456; 7'd37: ls629 = 18'd120756; 7'd38: ls629 = 18'd124100; 7'd39: ls629 = 18'd127486;
        7'd40: ls629 = 18'd130908; 7'd41: ls629 = 18'd134365; 7'd42: ls629 = 18'd137852; 7'd43: ls629 = 18'd141367;
        7'd44: ls629 = 18'd144907; 7'd45: ls629 = 18'd148469; 7'd46: ls629 = 18'd152051; 7'd47: ls629 = 18'd155649;
        7'd48: ls629 = 18'd159263; 7'd49: ls629 = 18'd162888; 7'd50: ls629 = 18'd166524; 7'd51: ls629 = 18'd170169;
        7'd52: ls629 = 18'd173820; 7'd53: ls629 = 18'd177477; 7'd54: ls629 = 18'd181138; 7'd55: ls629 = 18'd184801;
        7'd56: ls629 = 18'd188465; 7'd57: ls629 = 18'd192130; 7'd58: ls629 = 18'd195794; 7'd59: ls629 = 18'd199457;
        7'd60: ls629 = 18'd203119; 7'd61: ls629 = 18'd206778; 7'd62: ls629 = 18'd210435; 7'd63: ls629 = 18'd214089;
        default: ls629 = 18'd217741;
    endcase
endfunction

function automatic [31:0] vco_inc(input [15:0] v, input [12:0] scale);
    logic [17:0] t0, t1;
    logic signed [19:0] dt;
    logic [27:0] base;
    t0   = ls629({1'b0, v[15:10]});
    t1   = ls629({1'b0, v[15:10]} + 7'd1);
    dt   = $signed({2'b00, t1}) - $signed({2'b00, t0});
    base = 28'($signed(30'({12'd0, t0})) + 30'(($signed(30'(dt)) * $signed({20'd0, v[9:0]})) >>> 10));
    vco_inc = 32'((40'(base) * 40'(scale)) >>> 8);
endfunction

logic [22:0] os0 = 23'd0, os1 = 23'd0, os7 = 23'd0;
logic        s7_q = 1'b1;
wire q0 = os0 != 23'd0, q1 = os1 != 23'd0, q7 = os7 != 23'd0;
always_ff @(posedge clk) begin
    s7_q <= sound7;
    if (reset) begin os0 <= 23'd0; os1 <= 23'd0; os7 <= 23'd0; end
    else if (run) begin
        os0 <= walk0 ? 23'(W0) : q0 ? os0 - 23'd1 : 23'd0;
        os1 <= walk1 ? 23'(W1) : q1 ? os1 - 23'd1 : 23'd0;
        os7 <= (sound7 && !s7_q) ? 23'(W7) : q7 ? os7 - 23'd1 : 23'd0;
    end
end

logic [31:0] v0 = 32'd0, v1 = 32'd0, v7a = 32'd0, v7b = 32'd0;
logic [31:0] cnt = 32'd0;

logic [31:0] i0a, i0b, i1a, i1b, i7a, i7b;
logic [15:0] fv [6];
always_comb begin fv[0] = v0[31:16]; fv[1] = v0[31:16]; fv[2] = v1[31:16]; fv[3] = v1[31:16]; fv[4] = v7a[31:16]; fv[5] = v7b[31:16]; end
localparam logic [12:0] SC [6] = '{13'd6564, 13'd1164, 13'd656, 13'd3765, 13'd1164, 13'd5447};
logic [29:0] pr1 [6];
logic [39:0] pr2 [6];
logic [17:0] t0v [6];
logic signed [19:0] dtv [6];
logic [27:0] basev [6];
always_comb begin
    for (int k = 0; k < 6; k++) begin
        t0v[k]   = ls629({1'b0, fv[k][15:10]});
        dtv[k]   = $signed({2'b00, ls629({1'b0, fv[k][15:10]} + 7'd1)}) - $signed({2'b00, t0v[k]});
        basev[k] = 28'($signed(30'({12'd0, t0v[k]})) + 30'($signed(pr1[k]) >>> 10));
    end
end
logic [31:0] incv [6];
always_comb for (int k = 0; k < 6; k++) incv[k] = 32'(pr2[k] >> 8);
logic [31:0] rv [4];
always_comb begin rv[0] = v0; rv[1] = v1; rv[2] = v7a; rv[3] = v7b; end
localparam logic [15:0] RT [4] = '{T_W, T_W, T_S7A, T_S7B};
localparam logic [12:0] RA [4] = '{A_W0, A_W1, A_S7A, A_S7B};
logic signed [45:0] rph [4], rpl [4];
wire  [7:0] s24 = sdiv - 8'd24, s32 = sdiv - 8'd32, s40 = sdiv - 8'd40;
wire  [7:0] c26 = sdiv - 8'd26, c34 = sdiv - 8'd34, c42 = sdiv - 8'd42;
wire  [2:0] k24 = s24[2:0], k32 = s32[2:0], kc1 = c26[2:0], kc2 = c34[2:0];
wire  [1:0] k40 = s40[2:1], kc3 = c42[2:1];
wire  signed [32:0] rdh = $signed({1'b0, RT[k40], 16'd0}) - $signed({1'b0, rv[k40]});
wire  signed [32:0] rdl = -$signed({1'b0, rv[k40]});
always_comb begin
    mul_a = 40'sd0; mul_b = 27'sd0;
    if (sdiv >= 8'd24 && sdiv < 8'd30) begin
        mul_a = 40'(dtv[k24]); mul_b = 27'({17'd0, fv[k24][9:0]});
    end else if (sdiv >= 8'd32 && sdiv < 8'd38) begin
        mul_a = 40'({12'd0, basev[k32]}); mul_b = 27'({14'd0, SC[k32]});
    end else if (sdiv >= 8'd40 && sdiv < 8'd48) begin
        mul_a = sdiv[0] ? 40'(rdl) : 40'(rdh);
        mul_b = 27'({14'd0, RA[k40]});
    end
end
always_ff @(posedge clk) begin
    if (reset) begin
        pr1[0] <= 30'd0; pr2[0] <= 40'd467639052;
        pr1[1] <= 30'd0; pr2[1] <= 40'd82926852;
        pr1[2] <= 30'd0; pr2[2] <= 40'd46735408;
        pr1[3] <= 30'd0; pr2[3] <= 40'd268229895;
        pr1[4] <= 30'd0; pr2[4] <= 40'd82926852;
        pr1[5] <= 30'd0; pr2[5] <= 40'd388060621;
        rph[0] <= 46'sd8474555056128; rpl[0] <= 46'sd0;
        rph[1] <= 46'sd18039935336448; rpl[1] <= 46'sd0;
        rph[2] <= 46'sd12078909292544; rpl[2] <= 46'sd0;
        rph[3] <= 46'sd6041472204800; rpl[3] <= 46'sd0;
    end else begin
        if (sdiv >= 8'd26 && sdiv < 8'd32) pr1[kc1] <= 30'(mul_p);
        if (sdiv >= 8'd34 && sdiv < 8'd40) pr2[kc2] <= 40'(mul_p);
        if (sdiv >= 8'd42 && sdiv < 8'd50) begin
            if (sdiv[0]) rpl[kc3] <= 46'(mul_p);
            else         rph[kc3] <= 46'(mul_p);
        end
    end
end
function automatic [31:0] rcn(input [31:0] v, input signed [45:0] p);
    rcn = 32'($signed({1'b0, v}) + 33'(p >>> 24));
endfunction
always_ff @(posedge clk) begin
    if (reset) begin v0 <= 32'd0; v1 <= 32'd0; v7a <= 32'd0; v7b <= 32'd0; end
    else if (step && run) begin
        v0  <= rcn(v0,  q0 ? rph[0] : rpl[0]);
        v1  <= rcn(v1,  q1 ? rph[1] : rpl[1]);
        v7a <= rcn(v7a, q7 ? rpl[2] : rph[2]);
        v7b <= rcn(v7b, cnt[11] ? rpl[3] : rph[3]);
    end
end
always_ff @(posedge clk) if (step) begin
    i0a <= incv[0]; i0b <= incv[1]; i1a <= incv[2]; i1b <= incv[3]; i7a <= incv[4]; i7b <= incv[5];
end

logic [31:0] p0a = 32'd0, p0b = 32'd0, p1a = 32'd0, p1b = 32'd0, p7a = 32'd0, p7b = 32'd0;
logic        p7b_q = 1'b0;
always_ff @(posedge clk) begin
    if (run) begin
        p0a <= p0a + i0a; p0b <= p0b + i0b;
        p1a <= p1a + i1a; p1b <= p1b + i1b;
        p7a <= p7a + i7a; p7b <= p7b + i7b;
        p7b_q <= p7b[31];
        if (p7b_q && !p7b[31]) cnt <= cnt + 32'd1;
    end
end

wire o0 = (p0a[31] ^ p0b[31]) & q0;
wire o1 = (p1a[31] ^ p1b[31]) & q1;
wire o7 = (cnt[3]  ^ p7a[31]) & q7;

logic [8:0] a0 = 9'd0, a1 = 9'd0, a7 = 9'd0;
always_ff @(posedge clk) begin
    if (step) begin
        lvl0 <= a0; lvl1 <= a1; lvl7 <= a7;
        a0 <= {8'd0, o0}; a1 <= {8'd0, o1}; a7 <= {8'd0, o7};
    end else begin
        a0 <= a0 + {8'd0, o0}; a1 <= a1 + {8'd0, o1}; a7 <= a7 + {8'd0, o7};
    end
end

endmodule
