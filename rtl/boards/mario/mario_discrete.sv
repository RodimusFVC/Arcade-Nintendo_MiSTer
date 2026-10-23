//============================================================================
//
//  Nintendo Mario Bros. discrete sounds (TMA1-CPU sound quarter; MAME nl_mario.cpp snd0 / snd1 / snd7)
//  Copyright (C) 2026 Rodimus
//
//  Mario walk (7C00 write): 74123 2H one-shot (R17 27K / C14 4.7u + diode) -> 1H inverter -> R6 4.7K / C3 10u -> FC of
//    LS629 1J (3.9n) and 2J (22n); out = (1J ^ 2J) & one-shot.
//  Luigi walk (7C80 write): 2H second half (R18 30K / C15 4.7u) -> R7 4.7K / C4 4.7u -> LS629 1J (39n) / 2J (6.8n).
//  Skid (7F07, SOUND7 = data inverted, rising edge triggers): 74123 4L (R61 47K / C41 4.7u) -> 4J inverter (FC high
//    while idle) -> R65 10K / C44 3.3u -> LS629 4K (22n); LS629 4K second half (4.7n) clocks CD4020 3H, Q12 inverted ->
//    R64 20K / C43 3.3u -> its own FC (slow self-sweep); out = (3H Q4 ^ 4K_A) & one-shot.
//  LS629: MAME netlist polynomial (C = 0.1 uF, RNG = 5 V) as an increment table over FC 0-3.2 V (0.05 V steps, linear
//    interpolation), x 0.1 uF / C; FC / RNG inputs 90K each (MAME). FC sources: TTL high 3.4 V #unverified into the
//    series R and the FC input(s): walk 2 x 90K, skid 90K.
//  VCOs and the CD4020 run on 32-bit phase accumulators at the system clock; each voice's TTL output is averaged over
//    the 256 clocks of a 192 kHz sample (no aliasing of the ultrasonic XOR products) -> lvl = 0..256.
//  One-shot widths: calibrated against MAME's isolated captures (the diode networks are not the plain 74123 formula).
//
//============================================================================

module mario_discrete
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        run,            // !pause
    input  logic        step,           // 192 kHz (clk / 256), one clock
    input  logic        walk0,          // 7C00 write (one clock)
    input  logic        walk1,          // 7C80 write
    input  logic        sound7,         // SOUND7 level (7F07 data inverted)
    output logic  [8:0] lvl0,           // Mario walk, fraction of the sample the output was high (0..256)
    output logic  [8:0] lvl1,           // Luigi walk
    output logic  [8:0] lvl7            // skid
);

// ------------------------------------------------------------------ constants
// one-shot widths in clocks, measured on MAME's isolated captures (tone on until): walk 0 22 ms, walk 1 24 ms, skid
// 37 ms (re-triggered every 4 frames -> 37 ms bursts). = 0.173 x R x C for these diode networks.
localparam int W0 = 1081344;
localparam int W1 = 1199309;
localparam int W7 = 1818624;

// FC targets (65536 = 3.2 V) and one-pole coefficients (x 2^24) at 192 kHz
localparam logic [15:0] T_W   = 16'd63048;  // 3.4 V x 45K / (4.7K + 45K)
localparam logic [15:0] T_S7A = 16'd62669;  // 3.4 V x 90K / (10K + 90K)
localparam logic [15:0] T_S7B = 16'd56975;  // 3.4 V x 90K / (20K + 90K)
localparam logic [12:0] A_W0  = 13'd2051;   // (4.7K || 45K) x 10u   = 42.6 ms
localparam logic [12:0] A_W1  = 13'd4366;   // (4.7K || 45K) x 4.7u  = 20.0 ms
localparam logic [12:0] A_S7A = 13'd2941;   // (10K || 90K) x 3.3u   = 29.7 ms
localparam logic [12:0] A_S7B = 13'd1618;   // (20K || 90K) x 3.3u   = 54.0 ms

// LS629 increment table, C = 0.1 uF, RNG 5 V, FC = i x 0.05 V; inc = f x 2^32 / 49.152 MHz
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

// increment for FC v (65536 = 3.2 V) and cap scale (0.1 uF / C x 256)
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

// ------------------------------------------------------------------ one-shots (retriggerable)
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

// ------------------------------------------------------------------ FC voltages (192 kHz one-pole)
logic [31:0] v0 = 32'd0, v1 = 32'd0, v7a = 32'd0, v7b = 32'd0;      // upper 16 bits = FC (65536 = 3.2 V)
logic [31:0] cnt = 32'd0;                                         // CD4020 (bit 3 = Q4, bit 11 = Q12) in clocks of 4K_B
function automatic [31:0] rc(input [31:0] v, input [15:0] t, input [12:0] a);
    logic signed [32:0] d;
    logic signed [45:0] p;
    d  = $signed({1'b0, t, 16'd0}) - $signed({1'b0, v});
    p  = 46'(d) * $signed({33'd0, a});
    rc = 32'($signed({1'b0, v}) + 33'(p >>> 24));
endfunction
always_ff @(posedge clk) begin
    if (reset) begin v0 <= 32'd0; v1 <= 32'd0; v7a <= 32'd0; v7b <= 32'd0; end
    else if (step && run) begin
        v0  <= rc(v0,  q0 ? T_W : 16'd0, A_W0);
        v1  <= rc(v1,  q1 ? T_W : 16'd0, A_W1);
        v7a <= rc(v7a, q7 ? 16'd0 : T_S7A, A_S7A);              // 4J inverts the one-shot: high while idle
        v7b <= rc(v7b, cnt[11] ? 16'd0 : T_S7B, A_S7B);         // 4J inverts Q12
    end
end

// ------------------------------------------------------------------ VCOs (phase accumulators, MSB = output)
logic [31:0] i0a, i0b, i1a, i1b, i7a, i7b;
always_ff @(posedge clk) if (step) begin
    i0a <= vco_inc(v0[31:16],  13'd6564);   // 1J 3.9n
    i0b <= vco_inc(v0[31:16],  13'd1164);   // 2J 22n
    i1a <= vco_inc(v1[31:16],  13'd656);    // 1J 39n (C5)
    i1b <= vco_inc(v1[31:16],  13'd3765);   // 2J 6.8n (C16)
    i7a <= vco_inc(v7a[31:16], 13'd1164);   // 4K 22n
    i7b <= vco_inc(v7b[31:16], 13'd5447);   // 4K 4.7n
end

logic [31:0] p0a = 32'd0, p0b = 32'd0, p1a = 32'd0, p1b = 32'd0, p7a = 32'd0, p7b = 32'd0;
logic        p7b_q = 1'b0;
always_ff @(posedge clk) begin
    if (run) begin
        p0a <= p0a + i0a; p0b <= p0b + i0b;
        p1a <= p1a + i1a; p1b <= p1b + i1b;
        p7a <= p7a + i7a; p7b <= p7b + i7b;
        p7b_q <= p7b[31];
        if (p7b_q && !p7b[31]) cnt <= cnt + 32'd1;           // CD4020 counts falling edges
    end
end

wire o0 = (p0a[31] ^ p0b[31]) & q0;
wire o1 = (p1a[31] ^ p1b[31]) & q1;
wire o7 = (cnt[3]  ^ p7a[31]) & q7;

// ------------------------------------------------------------------ per-sample averages
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
