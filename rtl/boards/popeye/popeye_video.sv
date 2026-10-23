//============================================================================
//
//  Nintendo Popeye video (TPP2-VIDEO): 480i timing, text layer, background
//  Copyright (C) 2026 Rodimus
//
//  Clocks (TPP2-VIDEO sheet 2): X1 20.160 MHz -> 7E LS161: QA = 10.08 MHz hi-res dot clock, QB = 5.04 MHz H counter.
//  Here ce_pix = 10.08 MHz exactly (49.152 MHz x 105 / 512). H: 640 dots per line (320 H counts), active 0-511.
//  V: interlaced, two fields of 263 / 262 lines (525), active field lines 16-239 (MAME visarea y 32-479 = 2 x line +
//  field). field 0 = even frame lines. Blank / sync decode not traced yet (7B / 7C / 6B / 5C): sync placed mid-blanking
//  with porches on both sides, field 1's VSYNC half a line early (MCR 480i pattern, HW-confirmed there):
//
//    axis      active    front porch       sync               back porch        total
//    H         0-511     512-527 (16)      528-574 (47)       575-639 (65)      640
//    V fld 0   16-239    240-243 (4)       244-246 (3)        247-262, 0-15     263
//    V fld 1   16-239    240-242.5 (3.5)   242.5-245.5 (3)    245.5-261, 0-15   262
//
//  Pictures from MAME popeye_v.cpp (tpp2_state):
//    text: 32 x 32 tiles of 8 x 8 1bpp chars shown at 2 x 2 (16 x 16 dots), colour = colour RAM low nibble; char palette
//          PROM 3A address A4 = A3 (MAME tpp1_palette: "two address pins tied together"), pen 0 transparent.
//    background: 4-bit pens from two 4K nibble RAMs (8P / 8S), low-res (2 x 2 dots); rovi = (y / 2, flipped) + scroll 1,
//          roh = 0x38 + x / 2 + scroll 0 (MAME does not flip x), rovi bit 8 = 0 -> address 0; rovi bit 7 = nibble.
//          Palette PROM 4A address = {palette bank bit 3, pen}.
//    sprites (MAME draw_sprites): per frame line y, entries 1-159 of the DMA copy (4 bytes: x / 2, 256 - y / 2, code +
//          flip x, attributes) that cover y go to a 64-slot list indexed by x / 8 (TPP2-VIDEO MB7063 1M / 3M / 1P / 3P);
//          a later entry replaces an earlier one in its slot. Slots are drawn in order, 16 dots each from x - 6,
//          transparent dots included (a slot's right half is overwritten by the next slot). Line y = 2 x line + field:
//          sprites have the full 480i vertical resolution. Colour 0 = slot off. gfx2: planes 0x4000 apart (plane 0 =
//          pen bit 1), left 8 dots in the second 0x2000, rows stored bottom-up; code = 9 bits ^ 0x1FF.
//          Sprite palette = 5A (high nibble) / 5B (low nibble), address {palette bank 2-0, colour, pen}.
//          Line buffers: two 512 x 5 ({colour, pen}); line L + 1 is built during line L, display reads and clears.
//    priority: text over sprites over background.
//  Colour: MAME res_net values (txt / obj: R, G 1K / 470 / 220 + 470, B 470 / 220 + 680; bak: 1.2K / 680 / 470 + 470,
//  B 680 / 470 + 680; darlington, Sanyo EZV20), tools/resnet.py, all scaled by the same factor (brightest = 255).
//  Pixel pipeline: the low-res pixel pair k + 1 is fetched during pair k (9+ clocks) and shown from its first dot.
//
//============================================================================

module popeye_video
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,

    input  logic        flip,           // AY port B bit 0
    input  logic        crt_flip,       // MiSTer CRT Flip: whole picture turned 180 degrees
    input  logic  [7:0] scroll_x,       // dmasource[0]
    input  logic  [7:0] scroll_y,       // dmasource[1]
    input  logic  [3:0] pal_bank,       // dmasource[3] (bit 3 = text / background bank, 2-0 sprite bank)

    output logic        ce_pix,
    output logic        vblank_start,   // one clock at field line 240 (MAME screen_vblank)
    output logic        field,          // 0 = even frame lines are being shown (CPU SYSTEM bit 4, VGA_F1)

    // text RAM (video + colour) and background RAM read ports
    output logic  [9:0] txt_a,
    input  logic  [7:0] txt_code,
    input  logic  [3:0] txt_col,
    output logic [11:0] bg_a,
    input  logic  [3:0] bg_lo,
    input  logic  [3:0] bg_hi,

    // ROM / PROM
    output logic [10:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic  [7:0] prom_a,         // 0x00-0x1F background, 0x20-0x3F text
    input  logic  [7:0] prom_d,

    // sprites: DMA copy (32-bit entries: byte 0 in bits 7-0), gfx2, sprite palette nibbles
    output logic  [7:0] spr_a,
    input  logic [31:0] spr_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] spal_a,
    input  logic  [3:0] spal_lo,        // 5B
    input  logic  [3:0] spal_hi,        // 5A

    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync
);

// ------------------------------------------------------------------ timing
logic [8:0] acc = 9'd0;
always_ff @(posedge clk) begin
    {ce_pix, acc} <= {1'b0, acc} + 10'd105;
end

logic [9:0] h = 10'd0;
logic [8:0] line = 9'd0;
wire  [8:0] last_line = field ? 9'd261 : 9'd262;

always_ff @(posedge clk) begin
    vblank_start <= 1'b0;
    if (reset) begin
        h <= 10'd0; line <= 9'd0; field <= 1'b0;
    end else if (ce_pix) begin
        if (h == 10'd639) begin
            h <= 10'd0;
            if (line == last_line) begin
                line  <= 9'd0;
                field <= ~field;
            end else
                line <= line + 9'd1;
            if (line == 9'd239) vblank_start <= 1'b1;
        end else
            h <= h + 10'd1;
    end
end

// sync as positions (line, h): field 0 at the line start, field 1 half a line earlier
wire [18:0] pos      = {line, h};
wire [18:0] vs_start = field ? {9'd242, 10'd320} : {9'd244, 10'd0};
wire [18:0] vs_stop  = field ? {9'd245, 10'd320} : {9'd247, 10'd0};

// ------------------------------------------------------------------ text / background fetch
wire       fl_t = flip ^ crt_flip;      // text: both axes
wire       fl_y = flip ^ crt_flip;      // background rows
wire       fl_x = crt_flip;             // background columns (MAME: the board flip does not mirror them)

logic [7:0] fx, fy;                     // low-res column / field line being fetched
logic [2:0] seq = 3'd0;
logic [2:0] ccol;
logic [3:0] tcol, bpen;
logic       nib;
logic       tpen;
logic [7:0] nxt_r, nxt_g, nxt_b, cur_r, cur_g, cur_b;
logic       nxt_tp, cur_tp;

wire [8:0] lx_nx = {h[9:1]} + 9'd1;                       // next pair 1..320
wire       wrap  = lx_nx == 9'd320;
wire [8:0] ln_nx = (line == last_line) ? 9'd0 : line + 9'd1;

wire [7:0] cx   = fl_t ? ~fx : fx;
wire [7:0] cy   = fl_t ? ~fy : fy;
wire [8:0] rovi = {1'b0, fl_y ? ~fy : fy} + {1'b0, scroll_y};
wire [7:0] roh  = 8'h38 + (fl_x ? ~fx : fx) + scroll_x;

always_comb begin
    txt_a = {cy[7:3], cx[7:3]};
    bg_a  = rovi[8] ? {rovi[6:1], roh[7:2]} : 12'd0;
end

// resistor network levels (header)
function automatic [7:0] t_rg(input [2:0] x);
    case (x)
        3'd0: t_rg = 8'd241; 3'd1: t_rg = 8'd211; 3'd2: t_rg = 8'd179; 3'd3: t_rg = 8'd149;
        3'd4: t_rg = 8'd109; 3'd5: t_rg = 8'd76;  3'd6: t_rg = 8'd39;  3'd7: t_rg = 8'd0;
    endcase
endfunction
function automatic [7:0] t_b(input [1:0] x);
    case (x)
        2'd0: t_b = 8'd255; 2'd1: t_b = 8'd180; 2'd2: t_b = 8'd94; 2'd3: t_b = 8'd0;
    endcase
endfunction
function automatic [7:0] b_rg(input [2:0] x);
    case (x)
        3'd0: b_rg = 8'd200; 3'd1: b_rg = 8'd163; 3'd2: b_rg = 8'd135; 3'd3: b_rg = 8'd96;
        3'd4: b_rg = 8'd106; 3'd5: b_rg = 8'd66;  3'd6: b_rg = 8'd36;  3'd7: b_rg = 8'd0;
    endcase
endfunction
function automatic [7:0] b_b(input [1:0] x);
    case (x)
        2'd0: b_b = 8'd213; 2'd1: b_b = 8'd129; 2'd2: b_b = 8'd90; 2'd3: b_b = 8'd0;
    endcase
endfunction

always_ff @(posedge clk) begin
    if (reset) seq <= 3'd0;
    else if (ce_pix && !h[0]) begin
        // a pair starts: fetch the next one
        fx  <= wrap ? 8'd0 : lx_nx[7:0];
        fy  <= (wrap ? ln_nx[7:0] : line[7:0]);
        seq <= 3'd1;
    end else case (seq)
        3'd1: seq <= 3'd2;                                  // RAMs latch the addresses (combinational from fx / fy)
        3'd2: begin                                         // RAM data
            gfx1_a <= {txt_code, cy[2:0]};
            ccol   <= cx[2:0];
            tcol   <= txt_col;
            nib    <= rovi[7];
            seq    <= 3'd3;
        end
        3'd3: seq <= 3'd4;                                  // char ROM latches its address
        3'd4: begin                                         // char ROM data: pick the layer, PROM address
            tpen   <= gfx1_d[ccol];
            bpen   <= nib ? bg_hi : bg_lo;
            prom_a <= gfx1_d[ccol] ? {3'b001, tcol[3], tcol} : {3'b000, pal_bank[3], nib ? bg_hi : bg_lo};
            seq    <= 3'd5;
        end
        3'd5: seq <= 3'd6;                                  // PROM latches its address
        3'd6: begin                                         // PROM data
            if (tpen) begin nxt_r <= t_rg(prom_d[2:0]); nxt_g <= t_rg(prom_d[5:3]); nxt_b <= t_b(prom_d[7:6]); end
            else      begin nxt_r <= b_rg(prom_d[2:0]); nxt_g <= b_rg(prom_d[5:3]); nxt_b <= b_b(prom_d[7:6]); end
            nxt_tp <= tpen;
            seq <= 3'd0;
        end
        default: seq <= 3'd0;
    endcase
end

// ------------------------------------------------------------------ sprites
// line buffers A / B: {colour, pen} per dot; dsel = buffer on display, the other one is being built
logic [4:0] lbA[512], lbB[512];
logic       dsel = 1'b0;
logic [8:0] rd_x, clr_x;
logic       rd_sel, rd_go, clr_go, clr_sel;
logic [4:0] qA, qB;
logic       b_we;
logic [8:0] b_wa;
logic [4:0] b_wd;

wire [9:0] hn      = (h == 10'd639) ? 10'd0 : h + 10'd1;          // dot whose sprite pixel is fetched now
wire       dsel_n  = (h == 10'd639) ? ~dsel : dsel;

// read the dot one clock after ce_pix, clear it the clock after that (never the same clock as its read)
always_ff @(posedge clk) begin
    rd_go <= 1'b0;
    if (ce_pix) begin
        dsel   <= dsel_n;
        rd_x   <= hn[8:0];
        rd_sel <= dsel_n;
        rd_go  <= !hn[9];
    end
    clr_go <= rd_go; clr_x <= rd_x; clr_sel <= rd_sel;
end

// each buffer: one read port, one write port; the clear (buffer on display) and the build (the other buffer) never
// target the same buffer
wire clrA = clr_go && !clr_sel, clrB = clr_go && clr_sel;
wire bA   = b_we && dsel,       bB   = b_we && !dsel;
always_ff @(posedge clk) begin
    if (clrA || bA) lbA[clrA ? clr_x : b_wa] <= clrA ? 5'd0 : b_wd;
    qA <= lbA[rd_x];
end
always_ff @(posedge clk) begin
    if (clrB || bB) lbB[clrB ? clr_x : b_wa] <= clrB ? 5'd0 : b_wd;
    qB <= lbB[rd_x];
end

// sprite palette for the fetched dot: address from the buffer output, colour registered one clock later
wire [4:0] lq = rd_sel ? qB : qA;
assign spal_a = {pal_bank[2:0], lq};
logic       spr_pen;
logic [7:0] spr_r, spr_g, spr_b;
logic [1:0] lq_pen;
always_ff @(posedge clk) begin
    lq_pen  <= lq[1:0];
    spr_pen <= lq_pen != 2'd0;
    spr_r   <= t_rg(spal_lo[2:0]);
    spr_g   <= t_rg({spal_hi[1:0], spal_lo[3]});
    spr_b   <= t_b(spal_hi[3:2]);
end

// build: scan entries 1-159 into the slot list, then draw the slots
wire        fl_s  = flip ^ crt_flip;
logic [8:0] y_img;                                  // frame line of the image being built
logic [7:0] scan_i;
logic [63:0] s_val;
logic [19:0] slot[64];                              // {x low 2, row, code, colour, flip x}  (19-18, 17-14, 13-5, 4-2, 1); flip y folded into row
logic [19:0] slot_q;
logic [5:0] d_i;
logic [2:0] d_rd;
logic [7:0] d_g[4];
logic [4:0] d_px;

typedef enum logic [2:0] {SP_IDLE, SP_SCAN, SP_RD, SP_CHK, SP_FETCH, SP_PIX} sp_t;
sp_t sp = SP_IDLE;

assign spr_a = scan_i;

wire [7:0] e0 = spr_d[7:0], e1 = spr_d[15:8], e2 = spr_d[23:16], e3 = spr_d[31:24];
wire signed [11:0] sy0  = 12'sh200 - $signed({3'b000, e1, 1'b0});
wire signed [11:0] sy1  = sy0 ^ 12'sh1FF;
wire signed [11:0] yi   = $signed({3'b000, y_img});
wire signed [11:0] srow = flip ? sy1 - yi : yi - sy0;
wire        s_hit = srow >= 12'sd0 && srow < 12'sd16;
wire  [8:0] s_code = {e3[2], e3[4], e2[6:0]} ^ 9'h1FF;          // (b2 & 7F) + (b3 bit 4 << 3) + (b3 bit 2 << 6)

wire  [3:0] q_row  = slot_q[17:14];
wire  [8:0] q_code = slot_q[13:5];
wire  [2:0] q_col  = slot_q[4:2];
wire        q_fx   = slot_q[1];
assign gfx2_a = {d_rd[1], d_rd[0], q_code, ~q_row};                 // plane, quarter (0 = dots 8-15), code, row bottom-up

wire  [3:0] pj    = q_fx ? ~d_px[3:0] : d_px[3:0];
wire  [7:0] gp0   = pj[3] ? d_g[0] : d_g[1];                         // plane 0 (pen bit 1)
wire  [7:0] gp1   = pj[3] ? d_g[2] : d_g[3];
wire  [1:0] dpen  = {gp0[pj[2:0]], gp1[pj[2:0]]};
wire signed [10:0] dpx = $signed({2'b00, d_i, slot_q[19:18], 1'b0}) + $signed({7'd0, d_px[3:0]}) - 11'sd6;

always_ff @(posedge clk) begin
    b_we <= 1'b0;
    if (reset) sp <= SP_IDLE;
    else case (sp)
        SP_IDLE: if (ce_pix && h == 10'd639) begin
            // the line after the one starting now
            y_img  <= {ln_nx[7:0] + 8'd1, field} ^ {9{crt_flip}};
            scan_i <= 8'd1; s_val <= 64'd0; sp <= SP_SCAN;
        end
        SP_SCAN: begin
            // spr_a = scan_i, data for scan_i - 1 this clock
            if (scan_i >= 8'd2 && s_hit) begin
                slot[e0[7:2]] <= {e0[1:0], srow[3:0] ^ {4{e3[3]}}, s_code, e3[2:0], e2[7], 1'b0};
                s_val[e0[7:2]] <= 1'b1;
            end
            scan_i <= scan_i + 8'd1;
            if (scan_i == 8'd160) begin d_i <= 6'd0; sp <= SP_RD; end
        end
        SP_RD:  begin slot_q <= slot[d_i]; sp <= SP_CHK; end
        SP_CHK: begin
            d_rd <= 3'd0;
            if (s_val[d_i] && q_col != 3'd0) sp <= SP_FETCH;
            else if (d_i == 6'd63) sp <= SP_IDLE;
            else begin d_i <= d_i + 6'd1; sp <= SP_RD; end
        end
        SP_FETCH: begin
            // 4 reads {plane, quarter} = 00, 01, 10, 11; data 1 clock later
            if (d_rd != 3'd0) d_g[d_rd[1:0] - 2'd1] <= gfx2_d;
            d_rd <= d_rd + 3'd1;
            if (d_rd == 3'd4) begin d_px <= 5'd0; sp <= SP_PIX; end
        end
        SP_PIX: begin
            if (dpx >= 11'sd0 && dpx < 11'sd512) begin
                b_we <= 1'b1;
                b_wa <= dpx[8:0] ^ {9{fl_s}};
                b_wd <= (dpen == 2'd0) ? 5'd0 : {q_col, dpen};
            end
            d_px <= d_px + 5'd1;
            if (d_px == 5'd15) begin
                if (d_i == 6'd63) sp <= SP_IDLE;
                else begin d_i <= d_i + 6'd1; sp <= SP_RD; end
            end
        end
        default: sp <= SP_IDLE;
    endcase
end

// ------------------------------------------------------------------ output: one register per dot
// A pair's text / background colour is final on its first dot (h even) and held for the second; sprites per dot.
wire act = !h[9] && line >= 9'd16 && line < 9'd240;
wire [7:0] pr = h[0] ? cur_r : nxt_r, pg = h[0] ? cur_g : nxt_g, pb = h[0] ? cur_b : nxt_b;
wire       ptp = h[0] ? cur_tp : nxt_tp;
always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (!h[0]) begin cur_r <= nxt_r; cur_g <= nxt_g; cur_b <= nxt_b; cur_tp <= nxt_tp; end
        if (!act)                  begin r <= 8'd0;  g <= 8'd0;  b <= 8'd0;  end
        else if (ptp || !spr_pen)  begin r <= pr;    g <= pg;    b <= pb;    end
        else                       begin r <= spr_r; g <= spr_g; b <= spr_b; end
        hblank <= h[9];
        vblank <= !(line >= 9'd16 && line < 9'd240);
        hsync  <= h >= 10'd528 && h < 10'd575;
        vsync  <= pos >= vs_start && pos < vs_stop;
    end
end

endmodule
