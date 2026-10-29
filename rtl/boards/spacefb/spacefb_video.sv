//  Based on MAME spacefb.cpp (Chris Hardy, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module spacefb_video
(
    input  logic        clk,
    input  logic        reset,

    input  logic        flip,
    input  logic        crt_flip,
    input  logic        bank,
    input  logic        cref,
    input  logic  [7:0] port2,

    output logic        ce_pix,
    output logic        irq_80,
    output logic        irq_f0,
    output logic        v2,

    output logic  [7:0] obj_a,
    input  logic  [7:0] obj_x,
    input  logic  [7:0] obj_y,
    input  logic  [7:0] obj_code,
    input  logic  [7:0] obj_attr,

    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic [12:0] gfx1_a,
    input  logic  [3:0] gfx1_d,
    output logic  [7:0] pal_a,
    input  logic  [7:0] pal_d,

    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync
);

logic [8:0] acc = 9'd0;
always_ff @(posedge clk) {ce_pix, acc} <= {1'b0, acc} + 10'd105;

logic [9:0] h = 10'd0;
logic [7:0] line = 8'd0;
assign v2 = line[2];
logic       r_go;
always_ff @(posedge clk) begin
    irq_80 <= 1'b0; irq_f0 <= 1'b0; r_go <= 1'b0;
    if (reset) begin
        h <= 10'd0; line <= 8'd0;
    end else if (ce_pix) begin
        if (h == 10'd639) begin
            h    <= 10'd0;
            line <= line + 8'd1;
            r_go <= 1'b1;
            if (line == 8'h7F) irq_80 <= 1'b1;
            if (line == 8'hEF) irq_f0 <= 1'b1;
        end else
            h <= h + 10'd1;
    end
end

logic [7:0] lb0 [256];
logic [7:0] lb1 [256];
logic [7:0] lq;
logic       w_en;
logic [7:0] w_col, w_dat;
logic       w_buf;
wire        clr = ce_pix && !h[9] && h[0];
always_ff @(posedge clk) begin
    lq <= line[0] ? lb1[h[8:1]] : lb0[h[8:1]];
    if (line[0]) begin
        if (w_en && !w_buf) lb0[w_col] <= w_dat;
        if (clr) lb1[h[8:1]] <= 8'd0;
    end else begin
        if (w_en && w_buf) lb1[w_col] <= w_dat;
        if (clr) lb0[h[8:1]] <= 8'd0;
    end
end

typedef enum logic [3:0] {R_IDLE, R_A, R_W, R_E, R_G0, R_G1, R_G2, R_D} rstate_t;
rstate_t     rs = R_IDLE;
logic  [6:0] idx;
logic  [7:0] tl;
logic        fl_r, bank_r, is_bul;
logic  [7:0] ox, d0, d1;
logic  [3:0] pen_hi;
logic  [2:0] px;

wire   [7:0] y0 = ~obj_y - 8'd2;
wire   [7:0] yy = fl_r ? ~tl : tl;
wire   [7:0] sy = yy - y0;
wire   [7:0] cx = ox + {5'd0, px};
wire   [1:0] pix = {d0[px], d1[px]};

always_ff @(posedge clk) begin
    w_en <= 1'b0;
    if (reset) rs <= R_IDLE;
    else if (r_go) begin
        rs <= R_A; idx <= 7'd0; tl <= line + 8'd1;
        fl_r <= flip ^ crt_flip; bank_r <= bank; w_buf <= ~line[0];
    end else begin
        case (rs)
            R_IDLE: ;
            R_A: begin obj_a <= {bank_r, idx}; rs <= R_W; end
            R_W: rs <= R_E;
            R_E: begin
                px <= 3'd0;
                if (obj_attr[5] && sy < 8'd4) begin
                    gfx1_a <= {5'd0, obj_code[5:0], sy[1:0]};
                    is_bul <= 1'b1; ox <= obj_x; rs <= R_G0;
                end else if (!obj_attr[5] && obj_attr[6] && sy < 8'd8) begin
                    gfx2_a <= {4'b0000, ~obj_code, ~sy[2:0]};
                    is_bul <= 1'b0; ox <= obj_x - 8'd3; pen_hi <= ~obj_attr[3:0]; rs <= R_G0;
                end else begin
                    idx <= idx + 7'd1;
                    rs  <= (idx == 7'd127) ? R_IDLE : R_A;
                end
            end
            R_G0: begin gfx2_a[11] <= 1'b1; rs <= R_G1; end
            R_G1: begin d0 <= is_bul ? {4'd0, gfx1_d} : gfx2_d; rs <= is_bul ? R_D : R_G2; end
            R_G2: begin d1 <= gfx2_d; rs <= R_D; end
            R_D: begin
                w_col <= fl_r ? ~cx : cx;
                if (is_bul) begin
                    w_en  <= d0[px];
                    w_dat <= 8'hC0;
                end else begin
                    w_en  <= 1'b1;
                    w_dat <= {pix != 2'd0, 1'b0, pen_hi, pix};
                end
                px <= px + 3'd1;
                if (px == (is_bul ? 3'd3 : 3'd7)) begin
                    idx <= idx + 7'd1;
                    rs  <= (idx == 7'd127) ? R_IDLE : R_A;
                end
            end
            default: rs <= R_IDLE;
        endcase
    end
end

assign pal_a = {3'b000, cref, lq[3:0]};

function automatic [7:0] rg_lut(input [1:0] fade, input [2:0] v);
    case ({fade, v})
        5'd0:  rg_lut = 8'd0;   5'd1:  rg_lut = 8'd33;  5'd2:  rg_lut = 8'd71;  5'd3:  rg_lut = 8'd104;
        5'd4:  rg_lut = 8'd151; 5'd5:  rg_lut = 8'd184; 5'd6:  rg_lut = 8'd222; 5'd7:  rg_lut = 8'd255;
        5'd8:  rg_lut = 8'd0;   5'd9:  rg_lut = 8'd22;  5'd10: rg_lut = 8'd47;  5'd11: rg_lut = 8'd69;
        5'd12: rg_lut = 8'd101; 5'd13: rg_lut = 8'd123; 5'd14: rg_lut = 8'd148; 5'd15: rg_lut = 8'd170;
        5'd16: rg_lut = 8'd0;   5'd17: rg_lut = 8'd13;  5'd18: rg_lut = 8'd28;  5'd19: rg_lut = 8'd42;
        5'd20: rg_lut = 8'd60;  5'd21: rg_lut = 8'd74;  5'd22: rg_lut = 8'd89;  5'd23: rg_lut = 8'd102;
        5'd24: rg_lut = 8'd0;   5'd25: rg_lut = 8'd8;   5'd26: rg_lut = 8'd18;  5'd27: rg_lut = 8'd26;
        5'd28: rg_lut = 8'd38;  5'd29: rg_lut = 8'd46;  5'd30: rg_lut = 8'd56;  5'd31: rg_lut = 8'd64;
    endcase
endfunction

function automatic [7:0] b_lut(input [1:0] fade, input [1:0] v);
    case ({fade, v})
        4'd0:  b_lut = 8'd0; 4'd1:  b_lut = 8'd79; 4'd2:  b_lut = 8'd168; 4'd3:  b_lut = 8'd247;
        4'd4:  b_lut = 8'd0; 4'd5:  b_lut = 8'd53; 4'd6:  b_lut = 8'd112; 4'd7:  b_lut = 8'd165;
        4'd8:  b_lut = 8'd0; 4'd9:  b_lut = 8'd32; 4'd10: b_lut = 8'd67;  4'd11: b_lut = 8'd99;
        4'd12: b_lut = 8'd0; 4'd13: b_lut = 8'd20; 4'd14: b_lut = 8'd42;  4'd15: b_lut = 8'd62;
    endcase
endfunction

function automatic [7:0] srg(input hi, input lo);
    case ({hi, lo})
        2'd0: srg = 8'd0; 2'd1: srg = 8'd71; 2'd2: srg = 8'd151; 2'd3: srg = 8'd222;
    endcase
endfunction
function automatic [7:0] sb(input hi, input lo);
    case ({hi, lo})
        2'd0: sb = 8'd0; 2'd1: sb = 8'd79; 2'd2: sb = 8'd168; 2'd3: sb = 8'd247;
    endcase
endfunction

logic [16:0] sr = 17'h18F89;
wire  [16:0] sr_nx = {sr[15:0], ~sr[16] ^ sr[4]};
wire  [16:0] sm    = sr & 17'h1C0FF;
wire         star  = sm == 17'h0C0B7 || sm == 17'h0C0BB || sm == 17'h0C0D7 || sm == 17'h0C0DB;
wire   [5:0] sp    = star ? sr[13:8] : 6'd0;
wire         son   = ~port2[7];
wire         s_gb  = sp[0] & port2[1] & son, s_ga = sp[1] & son;
wire         s_bb  = sp[2] & port2[2] & son, s_ba = (sp[3] | port2[4]) & son;
wire         s_ra  = (sp[4] | port2[3]) & son, s_rb = sp[5] & port2[0] & son;

wire         vis   = !h[9] && line >= 8'd16 && line < 8'd240;

always_ff @(posedge clk) begin
    if (reset) sr <= 17'h18F89;
    else if (ce_pix) begin
        if (!vis) begin
            r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end else if (lq[7]) begin
            if (lq[6]) begin r <= 8'd255; g <= 8'd0; b <= 8'd0; end
            else begin
                r <= rg_lut(lq[5:4], pal_d[2:0]);
                g <= rg_lut(lq[5:4], pal_d[5:3]);
                b <= b_lut(lq[5:4], pal_d[7:6]);
            end
        end else begin
            r <= srg(s_ra, s_rb); g <= srg(s_ga, s_gb); b <= sb(s_ba, s_bb);
        end
        if (!h[9] && !(line == 8'd15 && h == 10'd511)) sr <= sr_nx;
        hblank <= h[9];
        vblank <= !(line >= 8'd16 && line < 8'd240);
        hsync  <= h >= 10'd528 && h < 10'd575;
        vsync  <= line >= 8'd244 && line < 8'd247;
    end
end

endmodule
