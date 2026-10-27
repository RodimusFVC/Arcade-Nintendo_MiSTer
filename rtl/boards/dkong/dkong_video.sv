//============================================================================
//
//  Nintendo Donkey Kong video (TKG-04 / TRS-02 family): timing, tilemap, sprite line buffer, colour
//  Copyright (C) 2026 Rodimus
//
//  Timing from the schematics (TRS-01-CLK / TRS-01-VIDEO, same logic on TKG-04):
//    H 0-383, pixel = clk / 8 (6.144 MHz); hblank = 256H (h 256-383); HSYNC h 304-335 (LS74: PRE 256H, CK 16H,
//    D = NAND(32H, /64H)). The HSYNC edge clocks V: 9-bit counter 256..511 then 248..255 (load 248), 264 lines;
//    VSYNC = V 248-255 (256V low); VBLK flip-flop CK 16V, D = NAND(32V, 64V, 128V): blank V&FF 240 -> 16.
//    /VRAM BUSY (LS74: CLR 256H, CK 2H, D = NAND(8H..64H)): CPU may use VRAM only h 258-377.
//  Pictures from MAME dkong_v.cpp: 32x32 tilemap of 8x8 2bpp chars, colour code PROM per 4 rows x 1 column;
//  128 4-byte sprites per bank, first 16 that hit a line are drawn (MAME draw_sprites row / x formulas), later ones on
//  top; pen 0 transparent. Colour: two 256x4 PROMs into the resistor network (tools/resnet.py, schematic values),
//  pen 0 of every tile colour = black (PROM disabled).
//  Pixel pipeline: pixel h is looked up during slot h and shown in slot h+1 (blanking / sync delayed to match).
//  DK3 (DKC1-Video): sprite code bit 7 = attribute bit 6 (gfx2 16K, quarters 0x1000 apart), colour = 1d (R high /
//  G low nibble) + 1c (B low nibble) into 2200-1000-470-220 darlington networks, no tri-state black.
//  Mario Bros. (MAME mario.cpp; same raster logic per MAME, dots at 24 MHz / 4 = 6.000 MHz): the 8-clock dot slot
//  advances on 1000 of every 1024 clocks (49.152 x 1000 / 1024 / 8 = 6.000 MHz). Tiles: Y scroll (7D00 + 17), colour
//  from the code (MAME: 8 + code >> 5, granularity 8 -> index {bank, 1, code 7-5, 0, pen}), pen 0 from the PROM.
//  Sprites: byte 1 = colour (3-0) / flip y (6) / flip x (7), byte 2 = code, 3 planes 0x2000 apart (bit 2 at 0x4000),
//  halves 0x1000 apart, index {bank, colour, pen}. Sprite RAM scan = 128 entries of the bank picked by 2PSL (latch Q1;
//  TMA1-VIDEO 7B LS157: A9 = 2PSL, A8-A0 = 128H..1/2H) as on DK; MAME draws all 256. Palette = one 512 x 8
//  PROM (first half, Nintendo monitor) R 7-5 / G 4-2 / B 1-0 through the TKG-04 levels.
//  Radar Scope (TRS-02, MAME radarscp): DK picture; where the tile / sprite pen is 0 the background shows instead of
//  black: blue level, stars and radar grid from dkong_radar.sv (prepared for the next line from h 256). Background
//  levels: MAME radarscp_* res_net infos without normalize (star R 255; grid bit 0 -> 255, 1 -> 21 R/G, 71 B).
//  The background is drawn in screen order and is not turned by CRT Flip (the board flip picks the table half).
//
//============================================================================

module dkong_video
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,

    // control latches
    input  logic        flip,
    input  logic        sprite_bank,
    input  logic  [1:0] palette_bank,
    input  logic        gfx_bank,       // DK Jr. char bank
    input  logic        gfx1_8k,        // gfx1 planes 0x1000 apart (DK Jr., DK3), else 0x800
    input  logic        dk3,            // DK3: 8-bit sprite codes, 4-bit RGB palette
    input  logic        spr256,         // 16K sprite ROM on the DK / Jr. board (Up Maguila): 8-bit codes, quarters 0x1000
                                        // apart (MAME spritelayout is RGN_FRAC of the gfx2 region)
    input  logic        mario,          // Mario Bros.: 6.000 MHz dots, scroll, code colours, 3bpp sprites
    input  logic  [7:0] scroll_y,       // Mario: 7D00 + 17 (0 elsewhere)
    input  logic        crt_flip,       // MiSTer CRT Flip: whole picture turned 180 degrees
    input  logic        radar,          // Radar Scope background
    input  logic        rs_snd2,        // 6H Q2 (SOUND2)
    input  logic        rs_grid_on,     // 7D81
    input  logic  [2:0] rs_grid_col,    // 7C80 data 2-0 inverted
    input  logic        rs_ans,         // 8035 P2.5
    output logic [10:0] gfx3_a,         // radar / star timing table
    input  logic  [7:0] gfx3_d,

    // timing out
    output logic        ce_pix,
    output logic        cpu_cen_p,      // 1H rising
    output logic        cpu_cen_n,      // 1H falling
    output logic        vram_busy,
    output logic        vblank_hw,      // VBLK (for the NMI / wait logic)

    // video RAM (32x32 codes) and sprite RAM (32-bit lanes, entry = 4 bytes)
    output logic  [9:0] vram_a,
    input  logic  [7:0] vram_d,
    output logic  [7:0] spr_a,
    input  logic [31:0] spr_d,

    // ROMs / PROMs
    output logic [12:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] cprom_a,        // char colour codes
    input  logic  [3:0] cprom_d,
    output logic  [7:0] pal_a,
    input  logic  [7:0] pal_lo_d,       // c-2k (DK3 1d)
    input  logic  [7:0] pal_hi_d,       // c-2j (DK3 1c)

    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync
);

// ------------------------------------------------------------------ timing
logic [2:0] ph = 3'd0;
logic [8:0] h  = 9'd0;

// dot-slot enable: always on at 6.144 MHz dots, 1000 / 1024 of the clocks for Mario's 6.000 MHz
logic [9:0] en_acc = 10'd0;
logic       en_c;
always_ff @(posedge clk) {en_c, en_acc} <= {1'b0, en_acc} + 11'd1000;
wire        en = !mario || en_c;
logic [8:0] v  = 9'd248;
logic       hs_q = 1'b1, vblk_q = 1'b0, busy_q = 1'b0;

assign ce_pix    = (ph == 3'd7) && en;
assign cpu_cen_p = (ph == 3'd7) && en && !h[0];   // h even -> odd: 1H rises
assign cpu_cen_n = (ph == 3'd7) && en &&  h[0];
assign vram_busy = !busy_q;
assign vblank_hw = vblk_q;

wire [8:0] h_nx = (h == 9'd383) ? 9'd0 : h + 9'd1;
wire [8:0] v_nx = (v == 9'd511) ? 9'd248 : v + 9'd1;

always_ff @(posedge clk) begin
    if (reset) begin
        ph <= 3'd0; h <= 9'd0; v <= 9'd248; hs_q <= 1'b1; vblk_q <= 1'b1; busy_q <= 1'b0;
    end else if (en) begin
        ph <= ph + 3'd1;
        if (ce_pix) begin
            h <= h_nx;
            // HSYNC flip-flop: preset while 256H low, clocked by 16H rising
            if (!h_nx[8]) hs_q <= 1'b1;
            else if (h_nx[4] && !h[4]) hs_q <= ~(h_nx[5] & ~h_nx[6]);
            // VRAM BUSY flip-flop: cleared while 256H low, clocked by 2H rising
            if (!h_nx[8]) busy_q <= 1'b0;
            else if (h_nx[1] && !h[1]) busy_q <= ~(h_nx[3] & h_nx[4] & h_nx[5] & h_nx[6]);
            // V advances on the HSYNC leading edge (h 304)
            if (h_nx == 9'd304) begin
                v <= v_nx;
                if (v_nx[4] && !v[4]) vblk_q <= v_nx[7] & v_nx[6] & v_nx[5];
            end
        end
    end
end

// ------------------------------------------------------------------ tilemap pixel pipeline
// slot of pixel h: ph 0 VRAM + colour PROM address, ph 2 plane-0 address, ph 4 plane-1 address, ph 6 pens,
// ph 7 palette address; RGB registered at the next ph 1.
// CRT Flip turns the picture 180 degrees on top of the board's own flip (same mirror the cocktail flip uses)
wire       fl = flip ^ crt_flip;
wire [7:0] tx = fl ? ~h[7:0] : h[7:0];
wire [7:0] ty = (fl ? ~v[7:0] : v[7:0]) + scroll_y;
logic [7:0] code, g0;
logic [1:0] tpix;
logic [3:0] tcol;
logic [6:0] spix;                       // {colour, pen} from the line buffer

always_comb begin
    vram_a  = {ty[7:3], tx[7:3]};
    cprom_a = {ty[7:5], tx[7:3]};
end

always_ff @(posedge clk) if (en) begin
    case (ph)
        3'd2: begin code <= vram_d; tcol <= mario ? {1'b1, vram_d[7:5]} : cprom_d;
                    gfx1_a <= gfx1_8k ? {1'b0, gfx_bank, vram_d, ty[2:0]} : {2'b00, vram_d, ty[2:0]}; end
        3'd4: begin g0 <= gfx1_d;
                    gfx1_a <= gfx1_8k ? {1'b1, gfx_bank, code, ty[2:0]} : {2'b01, code, ty[2:0]}; end
        3'd6: tpix <= {gfx1_d[~tx[2:0]], g0[~tx[2:0]]};
        default: ;
    endcase
end

// ------------------------------------------------------------------ sprites: build line buffer during hblank
// line buffer: 256 x 7 ({colour, pen}, pen 3 bits for Mario); display reads and clears it, the engine writes it in hblank
logic [6:0] lbuf[256];
logic [7:0] lb_wa;
logic [6:0] lb_wd;
logic       lb_we;
logic [6:0] lb_q;
always_ff @(posedge clk) begin
    if (lb_we) lbuf[lb_wa] <= lb_wd;
    if (en && ph == 3'd4 && !h[8]) begin lb_q <= lbuf[h[7:0]]; lbuf[h[7:0]] <= 7'd0; end
end
always_ff @(posedge clk) if (en && ph == 3'd6) spix <= lb_q;

// selected sprites
logic [3:0] s_row[16];
logic [7:0] s_code[16];
logic [3:0] s_col[16];
logic       s_fx[16];
logic [7:0] s_x[16];
logic [4:0] s_n;

typedef enum logic [2:0] {SP_IDLE, SP_SCAN, SP_DRAW_A, SP_DRAW_P, SP_DONE} sp_t;
sp_t        sp;
logic [8:0] scan_i;                     // entry counter (+ 1-clock RAM latency)
logic [3:0] d_i;                        // sprite being drawn
logic [2:0] d_rd;                       // gfx byte fetch step
logic [7:0] d_g[6];                     // p0 left, p0 right, p1 left, p1 right (, p2 left, p2 right: Mario)
logic [4:0] d_px;
logic [7:0] line;                       // MAME scanline of the line being built

// the line after this one, as MAME's vpos (V & 0xFF while 256V is high)
wire [7:0] next_line = v_nx[7:0];

wire [7:0] vf   = fl ? (line - 8'd1) ^ 8'hFF : line - 8'd1;
wire [7:0] addy = fl ? 8'hF7 : 8'hF9;
wire [7:0] sy   = spr_d[7:0] + addy + 8'd1 + vf;
wire       hit  = sy[7:4] == 4'hF;
wire [7:0] sx0  = spr_d[31:24] + 8'hF8;
// entry fields: DK / DK3 byte 1 = code (+ flip y bit 7), byte 2 = colour / code bit 7 (DK3) / flip x;
// Mario byte 1 = colour / flip y (6) / flip x (7), byte 2 = code
wire       e_fy  = mario ? spr_d[14] : spr_d[15];
wire       e_fx  = mario ? spr_d[15] : spr_d[23];
wire [7:0] e_cd  = mario ? spr_d[23:16] : {spr_d[22], spr_d[14:8]};
wire [3:0] e_col = mario ? spr_d[11:8]  : spr_d[19:16];
wire [7:0] sx   = fl ? (sx0 ^ 8'hFF) - 8'd15 : sx0;

assign spr_a  = {sprite_bank, scan_i[6:0]};
// CONV-2026-10-26: 16K sprite ROM on the DK / Jr. board takes the DK3 form. Original below.
// assign gfx2_a = mario ? {d_rd[2:0], s_code[d_i], s_row[d_i]}                         // data one clock later
//               : dk3   ? {1'b0, d_rd[1:0], s_code[d_i], s_row[d_i]}
//                       : {2'b00, d_rd[1:0], s_code[d_i][6:0], s_row[d_i]};
assign gfx2_a = mario          ? {d_rd[2:0], s_code[d_i], s_row[d_i]}                // data one clock later
              : (dk3 | spr256) ? {1'b0, d_rd[1:0], s_code[d_i], s_row[d_i]}
                               : {2'b00, d_rd[1:0], s_code[d_i][6:0], s_row[d_i]};

wire [3:0] pj    = s_fx[d_i] ? 4'd15 - d_px[3:0] : d_px[3:0];
wire [7:0] gp0   = pj[3] ? d_g[1] : d_g[0];
wire [7:0] gp1   = pj[3] ? d_g[3] : d_g[2];
wire [7:0] gp2   = pj[3] ? d_g[5] : d_g[4];
wire [2:0] dpen  = {mario & gp2[~pj[2:0]], gp1[~pj[2:0]], gp0[~pj[2:0]]};

always_ff @(posedge clk) begin
    lb_we <= 1'b0;
    if (reset) sp <= SP_IDLE;
    else case (sp)
        SP_IDLE: if (ce_pix && h_nx == 9'd256) begin
            line <= next_line; scan_i <= 9'd0; s_n <= 5'd0; sp <= SP_SCAN;
        end
        SP_SCAN: begin
            // spr_a = scan_i, data for scan_i - 1 this clock
            if (scan_i != 9'd0 && s_n != 5'd16 && hit) begin
                s_row[s_n[3:0]]  <= e_fy ? 4'd15 - sy[3:0] : sy[3:0];
                s_code[s_n[3:0]] <= e_cd;
                s_col[s_n[3:0]]  <= e_col;
                s_fx[s_n[3:0]]   <= e_fx ^ fl;
                s_x[s_n[3:0]]    <= sx;
                s_n <= s_n + 5'd1;
            end
            scan_i <= scan_i + 9'd1;
            if (scan_i == 9'd128) begin
                d_i <= 4'd0; d_rd <= 3'd0; sp <= (s_n == 5'd0 && !hit) ? SP_DONE : SP_DRAW_A;
            end
        end
        SP_DRAW_A: begin
            // 4 reads (6 for Mario): {plane, half} = 00, 01, 10, 11 (, 100, 101); data 1 clock later
            if (d_rd != 3'd0) d_g[d_rd - 3'd1] <= gfx2_d;
            d_rd <= d_rd + 3'd1;
            if (d_rd == (mario ? 3'd6 : 3'd4)) begin d_px <= 5'd0; sp <= SP_DRAW_P; end
        end
        SP_DRAW_P: begin
            if (dpen != 3'd0) begin lb_we <= 1'b1; lb_wa <= s_x[d_i] + {4'd0, d_px[3:0]}; lb_wd <= {s_col[d_i], dpen}; end
            d_px <= d_px + 5'd1;
            if (d_px == 5'd15) begin
                d_rd <= 3'd0;
                if ({1'b0, d_i} + 5'd1 == s_n) sp <= SP_DONE;
                else begin d_i <= d_i + 4'd1; sp <= SP_DRAW_A; end
            end
        end
        SP_DONE: sp <= SP_IDLE;
        default: sp <= SP_IDLE;
    endcase
end

// ------------------------------------------------------------------ Radar Scope background
wire [8:0] rs_y = v_nx[8] ? {1'b0, v_nx[7:0]} : 9'(v_nx[7:0]) + 9'd8;      // MAME vpos of the next line
logic [1:0] rs_t, bg_t;
logic [7:0] rs_b, bg_b;
dkong_radar rsbg
(
    .clk(clk), .reset(reset | ~radar),
    .start(radar && ce_pix && h_nx == 9'd256), .y(rs_y), .flip(flip), .snd2(rs_snd2), .grid_on(rs_grid_on),
    .ans(rs_ans), .gfx3_a(gfx3_a), .gfx3_d(gfx3_d),
    .rd_bank(v[0]), .rd_col(h[7:2]), .rd_type(rs_t), .rd_blue(rs_b)
);
always_ff @(posedge clk) if (en && ph == 3'd7) begin bg_t <= (h[1:0] == 2'd0) ? rs_t : 2'd0; bg_b <= rs_b; end

// ------------------------------------------------------------------ colour
// MAME tile colour: colour code + 16 * palette bank; sprites draw over tiles where their pen != 0
// Mario: sprites {bank, colour, pen 3}, tiles {bank, 1, code 7-5, 0, pen}
wire       s_on  = spix[2:0] != 3'd0;
wire [7:0] pal_n = mario ? (s_on ? {palette_bank[0], spix} : {palette_bank[0], tcol, 1'b0, tpix})
                         : (s_on ? {palette_bank, spix[6:3], spix[1:0]} : {palette_bank, tcol, tpix});
logic [7:0] pix;
always_ff @(posedge clk) if (en && ph == 3'd7) pix <= pal_n;
assign pal_a = pal_n;

// resistor network levels, tools/resnet.py (TKG-04: R / G 1K-470-220 + 470 pull-up, darlington; B 470-220 + 680,
// emitter follower), scaled so the brightest red / green = 255
function automatic [7:0] lv_rg(input [2:0] x);
    case (x)
        3'd0: lv_rg = 8'd255; 3'd1: lv_rg = 8'd223; 3'd2: lv_rg = 8'd189; 3'd3: lv_rg = 8'd158;
        3'd4: lv_rg = 8'd116; 3'd5: lv_rg = 8'd80;  3'd6: lv_rg = 8'd41;  3'd7: lv_rg = 8'd0;
    endcase
endfunction
// DK3: 2200 / 1000 / 470 / 220 + 470 pull-up, darlington (MAME dkong3_net_info), same scaling
function automatic [7:0] lv4(input [3:0] x);
    case (x)
        4'd0:  lv4 = 8'd255; 4'd1:  lv4 = 8'd242; 4'd2:  lv4 = 8'd226; 4'd3:  lv4 = 8'd211;
        4'd4:  lv4 = 8'd193; 4'd5:  lv4 = 8'd180; 4'd6:  lv4 = 8'd163; 4'd7:  lv4 = 8'd149;
        4'd8:  lv4 = 8'd125; 4'd9:  lv4 = 8'd110; 4'd10: lv4 = 8'd92;  4'd11: lv4 = 8'd77;
        4'd12: lv4 = 8'd55;  4'd13: lv4 = 8'd39;  4'd14: lv4 = 8'd13;  4'd15: lv4 = 8'd0;
    endcase
endfunction
function automatic [7:0] lv_b(input [1:0] x);
    case (x)
        2'd0: lv_b = 8'd255; 2'd1: lv_b = 8'd218; 2'd2: lv_b = 8'd138; 2'd3: lv_b = 8'd0;
    endcase
endfunction

// blanking / sync delayed one slot to match the pipeline
logic hbl_d, vbl_d, hs_d, vs_d;
always_ff @(posedge clk) begin
    if (en && ph == 3'd0) begin
        // PROM data for pix (addressed at ph 7) is valid now
        if (mario) begin
            r <= lv_rg(pal_lo_d[7:5]);
            g <= lv_rg(pal_lo_d[4:2]);
            b <= lv_b(pal_lo_d[1:0]);
        end else if (dk3) begin
            r <= lv4(pal_lo_d[7:4]);
            g <= lv4(pal_lo_d[3:0]);
            b <= lv4(pal_hi_d[3:0]);
        end else if (pix[1:0] == 2'd0) begin
            if (!radar) {r, g, b} <= 24'd0;
            else if (bg_t == 2'd1) {r, g, b} <= {8'd255, 16'd0};                       // star
            else if (bg_t == 2'd2) begin                                                  // grid
                r <= rs_grid_col[0] ? 8'd21 : 8'd255;
                g <= rs_grid_col[1] ? 8'd21 : 8'd255;
                b <= rs_grid_col[2] ? 8'd71 : 8'd255;
            end else {r, g, b} <= {16'd0, bg_b};                                          // blue
        end
        else begin
            r <= lv_rg(pal_hi_d[3:1]);
            g <= lv_rg({pal_hi_d[0], pal_lo_d[3:2]});
            b <= lv_b(pal_lo_d[1:0]);
        end
        hblank <= hbl_d; vblank <= vbl_d; hsync <= hs_d; vsync <= vs_d;
    end
    if (ce_pix) begin
        hbl_d <= h[8];
        vbl_d <= vblk_q;
        hs_d  <= ~hs_q;
        vs_d  <= ~v[8];
    end
end

endmodule
