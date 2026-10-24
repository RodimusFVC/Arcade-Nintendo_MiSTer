//============================================================================
//
//  Nintendo 8080 board (Space Fever / SF-HiSplitter / Space Launcher, Sheriff / Bandido, HeliFire; MAME n8080.cpp)
//  Copyright (C) 2026 Rodimus
//
//  Sources: Bandido operator's manual (Exidy, 1980) p33-36 = I/O PCB 77-3367-1 and CPU PCB 77-3366-1 (Sheriff
//  hardware), MAME n8080.cpp as reference. No Space Fever schematic on hand: its deltas are MAME's (#unverified).
//
//  Clocks: X 20.160 MHz (I/O 1A); LS160 2A / 10 = 8080 clock 2.016 MHz; dots 5.04 MHz (MAME set_raw: 320 x 256,
//  visible x 0-255, y 16-239). Here a 20.16 MHz phase accumulator (49.152 MHz x 105 / 256) gives both.
//  CPU: the pooled T80pa in its runtime 8080 mode (rtl/nintendo_board.sv drives I8080).
//  Memory (MAME main_cpu_map, global mask 7FFF): 0000-3FFF ROM, 4000-7FFF RAM (8 x 4116 16K x 1 DRAM, CPU board);
//    the picture is 4000-5FFF, 32 bytes per line, bit n = dot x + n.
//  I/O (LS42 3C, A2-A0): R 0 IN0, 1 IN1, 2 IN2, 3 shifter, 4 IN3; W 2 shift count, 3 shift data, 4 sound 1,
//    5 sound 2, 6 video control. Shifter (LS151 2E-2H, LS174 3I, LS175 2J): read = {data, previous} >> (8 - count).
//  Interrupts (CPU sheet: LS74 3D): DINTR clocks the latch with D = the 8080's INTE, INTA clears it, Q = INT. A
//    request that arrives with interrupts off is dropped. The INTA data comes from the read mux (LS153 x 4) with
//    INTD selecting RST 1 (0xCF) or RST 2 (0xD7): MAME raises them at lines 128 (V7 = 1, V6 = 0) and 240 (vblank).
//  Colour (MAME): Sheriff PROM 3L (82S137, 1K) per 8 x 8 cell, address {y / 8, x / 8}; port 6 bits 4-3 = mode
//    (1: cells without bit 3 take ~bits 2-0, 2: all cells ~bits 2-0, 3: white), bit 5 = flip.
//    Space Fever PROM 32 x 8 per column: the highest n above the start colour whose PROM bit n is 0 wins; start
//    colour = red / white for column 6 (cannon: red for 550 x 68 x 10 us after sound 1 bit 4 rises), UFO column
//    0x1B cycles red, green, white, yellow, magenta, cyan every 32 frames; sound 1 bit 3 = whole screen red;
//    sound 2 bit 5 = flip. Colour bits: 0 = R, 1 = G, 2 = B.
//  Flip turns the whole picture (MAME: x ^ 0xFF, y ^ 0xFF on the drawn bitmap, colours looked up unflipped).
//  Sync (#unverified: the I/O board H / V decode was not traced): mid-blanking with porches both sides,
//    H 256-271 front, 272-295 sync, 296-319 back; V 240-243 front, 244-246 sync, 247-255 + 0-15 back.
//  HeliFire (hf; helifire_schematics.pdf: TUB CPU = the Sheriff CPU board, TUB I/O, TUB-ESS = sea / sky + sound):
//    RAM 4000-7FFF only (no mirror; MAME helifire map). Colour RAM = one 2114 on ESS (IC19), 1K x 3: LS157 IC11-13
//    address it {V7-V3, H4-H0} for the picture and {A12-A8, A4-A0} for the CPU (C000-DFFF): one colour per 8 x 8 cell
//    (MAME keeps a colour per byte). Foreground dot = colour RAM bits 2-0 (R, G, B); a set dot covers the background.
//    Flash (sound 2 bit 5, MAME): each frame G |= B when LFSR[(frame / 2) mod 63] bit 5, R |= G when frame bit 2.
//    Background (ESS, analog): brightness ramp = the TONE network, R8 1.2K / C26 0.033u (tau 39.6 us = 199.6 dots),
//    255 x exp(-i / 199.6); sky (red) from the horizon, i = SUN + x - horizon, sea (blue) below it, i = SEA + x.
//    Horizon, MV / SC line counter, wave and stars are MAME's model (#unverified: the 74121 IC59 horizon one-shot and
//    the LS164 / LS85 star circuit were not traced); SUN = 0x50 / SEA = 0 are MAME's VR1 / VR2 pot defaults.
//    The background ignores the board flip (MAME) and CRT Flip turns only its columns (#unverified, as Radar Scope).
//  Sound: rtl/boards/n8080/n8080_sound.sv (8035 music; SN76477 / HeliFire analog effects not yet).
//
//============================================================================

module n8080_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,
    input  logic        sfev,           // 1 = Space Fever colour logic, 0 = Sheriff
    input  logic        hf,             // 1 = HeliFire (colour RAM, sea / sky background)

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] in0,            // IN0
    input  logic  [7:0] in1,            // IN1
    input  logic  [7:0] in2,            // IN2
    input  logic  [7:0] in3,            // IN3

    // ROMs (shared blocks in rtl/nintendo_board.sv)
    output logic [14:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [12:0] prom_a,         // colour PROM in the gfx1 block (0x10000)
    input  logic  [7:0] prom_d,
    output logic [11:0] snd_pa,         // 8035 program (sound block, 0x08000)
    input  logic  [7:0] snd_pd,

    output logic        ce_pix,
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,

    output logic signed [15:0] audio,
    output logic signed [39:0] mul_a,   // MULPOOL-2026-10-23: shared multiplier (rtl/nintendo_board.sv)
    output logic signed [26:0] mul_b,
    input  logic signed [66:0] mul_p,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

wire run = ~pause;

// ------------------------------------------------------------------ 20.16 MHz ticks: CPU / 10 (two phases), dots / 4
logic [7:0] x_acc = 8'd0;
logic       xtal;
always_ff @(posedge clk) {xtal, x_acc} <= {1'b0, x_acc} + 9'd105;

logic [3:0] div10 = 4'd0;
logic [1:0] div4 = 2'd0;
logic       cen_p, cen_n;
always_ff @(posedge clk) begin
    cen_p <= 1'b0; cen_n <= 1'b0; ce_pix <= 1'b0;
    if (xtal) begin
        div10 <= (div10 == 4'd9) ? 4'd0 : div10 + 4'd1;
        div4  <= div4 + 2'd1;
        if (div10 == 4'd0) cen_p <= 1'b1;
        if (div10 == 4'd5) cen_n <= 1'b1;
        if (div4 == 2'd0)  ce_pix <= 1'b1;
    end
end

// ------------------------------------------------------------------ CPU bus
wire [15:0] cpu_a = z80pa_0_o.a;
wire  [7:0] cpu_d = z80pa_0_o.dout;
wire        mreq  = ~z80pa_0_o.mreq_n;
wire        iorq  = ~z80pa_0_o.iorq_n;
wire        m1    = ~z80pa_0_o.m1_n;
wire        rd    = ~z80pa_0_o.rd_n;
wire        wr    = ~z80pa_0_o.wr_n;
wire        inta  = m1 & iorq & ~mreq;   // !MREQ: T80pa IntCycleD_n has no reset value (vault: Space Firebird 2026-10-22)

logic wr_q = 1'b0, iow_q = 1'b0;
always_ff @(posedge clk) begin wr_q <= wr & mreq; iow_q <= wr & iorq; end
wire cpu_we = wr & mreq & ~wr_q;
wire io_we  = wr & iorq & ~m1 & ~iow_q;

wire sel_ram  = hf ? cpu_a[15:14] == 2'b01 : cpu_a[14];              // 4000-7FFF (mirrored at C000-FFFF but HeliFire)
wire sel_cram = hf && cpu_a[15:13] == 3'b110;                       // HeliFire colour RAM C000-DFFF
assign rom_a = {1'b0, cpu_a[13:0]};

// ------------------------------------------------------------------ RAM 4000-7FFF; port B = video
logic [7:0] ram_q, vram_q;
logic [13:0] v_addr;
dpram_dc #(.widthad_a(14)) ram
(
    .clock_a(clk), .address_a(cpu_a[13:0]), .data_a(cpu_d), .wren_a(cpu_we & sel_ram), .q_a(ram_q),
    .clock_b(clk), .address_b(v_addr), .data_b(8'h00), .wren_b(1'b0), .q_b(vram_q)
);
assign hs_data_out = 8'h00;             // hiscore: not yet (needs its own RAM port; the video owns port B)

// HeliFire colour RAM (2114 IC19, 1K x 3; stored 8 wide, bits 2-0 used)
logic [7:0] cram_q8, cram_v8;
logic [9:0] c_addr;
dpram_dc #(.widthad_a(10)) cram
(
    .clock_a(clk), .address_a({cpu_a[12:8], cpu_a[4:0]}), .data_a({5'd0, cpu_d[2:0]}), .wren_a(cpu_we & sel_cram),
    .q_a(cram_q8),
    .clock_b(clk), .address_b(c_addr), .data_b(8'd0), .wren_b(1'b0), .q_b(cram_v8)
);
wire [2:0] cram_q = cram_q8[2:0], cram_v = cram_v8[2:0];

// ------------------------------------------------------------------ I/O writes: shifter, sound latches, video control
logic  [2:0] shift_n;
logic [15:0] shift_d;
logic  [7:0] snd1, snd2;
logic  [1:0] col_mode;
logic  [2:0] col_data;
logic        flip;
always_ff @(posedge clk) begin
    if (reset) begin
        shift_n <= 3'd0; shift_d <= 16'd0; snd1 <= 8'd0; snd2 <= 8'd0;
        col_mode <= 2'd0; col_data <= 3'd0; flip <= 1'b0;
    end else if (io_we) begin
        case (cpu_a[2:0])
            3'd2: shift_n <= cpu_d[2:0];
            3'd3: shift_d <= {cpu_d, shift_d[15:8]};
            3'd4: snd1 <= cpu_d;
            3'd5: begin snd2 <= cpu_d; if (sfev) flip <= cpu_d[5]; end      // MAME spacefev delayed_sound_2
            3'd6: begin col_mode <= cpu_d[4:3]; col_data <= cpu_d[2:0]; flip <= cpu_d[5]; end
            default: ;
        endcase
    end
end
wire [15:0] shift_q = shift_d >> (4'd8 - {1'b0, shift_n});

// ------------------------------------------------------------------ CPU read data
logic [7:0] io_q;
always_comb begin
    case (cpu_a[2:0])
        3'd0:    io_q = in0;
        3'd1:    io_q = in1;
        3'd2:    io_q = in2;
        3'd3:    io_q = shift_q[7:0];
        3'd4:    io_q = in3;
        default: io_q = 8'h00;
    endcase
end

// ------------------------------------------------------------------ video timing
logic [8:0] hc = 9'd0;                  // dot being fetched for the next ce_pix (0-319)
logic [7:0] vc = 8'd0;                  // line (0-255)
logic       dintr;                      // one clock at the start of lines 128 / 240
logic [4:0] frame = 5'd0;               // frames mod 32
logic [2:0] ufo_i = 3'd0;               // (frames / 32) mod 6
always_ff @(posedge clk) begin
    dintr <= 1'b0;
    if (reset) begin
        hc <= 9'd0; vc <= 8'd0;
    end else if (ce_pix) begin
        if (hc == 9'd319) begin
            hc <= 9'd0;
            vc <= vc + 8'd1;
            if (vc == 8'd127 || vc == 8'd239) dintr <= 1'b1;
            if (vc == 8'd255) begin
                frame <= frame + 5'd1;
                if (frame == 5'd31) ufo_i <= (ufo_i == 3'd5) ? 3'd0 : ufo_i + 3'd1;
            end
        end else
            hc <= hc + 9'd1;
    end
end

// ------------------------------------------------------------------ interrupt latch (LS74 3D) and vector (INTD)
logic int_q = 1'b0, rst2 = 1'b0;
always_ff @(posedge clk) begin
    if (reset) int_q <= 1'b0;
    else if (inta) int_q <= 1'b0;
    else if (dintr) begin
        int_q <= z80pa_0_o.inte;
        rst2  <= vc == 8'd240;
    end
end

always_comb begin
    if (inta)                 z80pa_0_i.di = rst2 ? 8'hD7 : 8'hCF;
    else if (iorq & ~m1)      z80pa_0_i.di = io_q;
    else if (sel_ram)         z80pa_0_i.di = ram_q;
    else if (sel_cram)        z80pa_0_i.di = {5'd0, cram_q};
    else if (hf && cpu_a[15]) z80pa_0_i.di = 8'h00;                      // HeliFire 8000-BFFF, E000-FFFF: nothing
    else                      z80pa_0_i.di = rom_d;
end

assign z80pa_0_i.reset_n = ~reset;
assign z80pa_0_i.cen_p   = cen_p & run;
assign z80pa_0_i.cen_n   = cen_n & run;
assign z80pa_0_i.wait_n  = 1'b1;
assign z80pa_0_i.int_n   = ~int_q;
assign z80pa_0_i.nmi_n   = 1'b1;
assign z80pa_0_i.busrq_n = 1'b1;

// ------------------------------------------------------------------ Space Fever red cannon (550 x 68 x 10 us = 374 ms)
logic        snd1_b4 = 1'b0;
logic [24:0] cannon = 25'd0;
always_ff @(posedge clk) begin
    snd1_b4 <= snd1[4];
    if (reset) cannon <= 25'd0;
    else if (snd1[4] && !snd1_b4) cannon <= 25'd18382848;           // 0.374 s x 49.152 MHz
    else if (cannon != 25'd0 && run) cannon <= cannon - 25'd1;
end
wire red_cannon = cannon != 25'd0;

// ------------------------------------------------------------------ picture: fetch for (hc, vc), shown at the next ce_pix
wire       fl = flip ^ crt_flip;
wire [7:0] sx = hc[7:0] ^ {8{fl}};
wire [7:0] sy = vc ^ {8{fl}};
assign v_addr = {1'b0, sy, sx[7:3]};
assign prom_a = sfev ? {8'd0, sx[7:3]} : {3'd0, sy[7:3], sx[7:3]};
assign c_addr = {sy[7:3], sx[7:3]};

// Space Fever start colour for a column
logic [2:0] ufo;
always_comb begin
    case (ufo_i)
        3'd0: ufo = 3'd1; 3'd1: ufo = 3'd2; 3'd2: ufo = 3'd7; 3'd3: ufo = 3'd3; 3'd4: ufo = 3'd5; default: ufo = 3'd6;
    endcase
end
logic [2:0] sf_col;
always_comb begin
    logic [2:0] c;
    c = (sx[7:3] == 5'h06) ? (red_cannon ? 3'd1 : 3'd7) : (sx[7:3] == 5'h1B) ? ufo : 3'd0;
    sf_col = c;
    for (int n = 1; n < 8; n++)
        if (n > c && !prom_d[n]) sf_col = n[2:0];
    if (snd1[3]) sf_col = 3'd1;
end

logic [2:0] sh_col;
always_comb begin
    sh_col = prom_d[2:0];
    if ((col_mode == 2'd1 && !prom_d[3]) || col_mode == 2'd2) sh_col = ~col_data;
    if (col_mode == 2'd3) sh_col = 3'd7;
end

// ------------------------------------------------------------------ HeliFire background (MAME next_line / screen_update)
localparam logic [2047:0] RAMP = 2048'hFFFEFCFBFAF9F7F6F5F4F3F1F0EFEEEDEBEAE9E8E7E6E4E3E2E1E0DFDEDDDBDAD9D8D7D6D5D4D3D2D1D0CFCECDCCCBC9C8C7C6C5C5C4C3C2C1C0BFBEBDBCBBBAB9B8B7B6B5B4B4B3B2B1B0AFAEADADACABAAA9A8A7A7A6A5A4A3A2A2A1A09F9E9E9D9C9B9B9A999897979695949493929191908F8F8E8D8C8C8B8A8A8988888786868584848382828180807F7E7E7D7D7C7B7B7A7979787877767675757474737272717170706F6E6E6D6D6C6C6B6B6A6A69696867676666656564646363626261616060605F5F5E5E5D5D5C5C5B5B5A5A5959595858575756565655555454535353525251515150504F4F4F4E4E4D4D4D4C4C4B4B4B4A4A4A49494948484747;
localparam logic [503:0]  LFSR = 504'h0103070F1F3F7FFEFDFBF7EFDFBF7EFCF9F3E7CF9F3E7DFAF5EBD7AF5EBC78F0E1C3870E1D3B77EEDDBB76ECD9B366CC993265CA952A55AA54A850A0408000;
localparam logic [7:0]    SUN  = 8'h50, SEA = 8'h00;
function automatic [7:0] ramp(input [7:0] i);  ramp = RAMP[2047 - 8 * i -: 8];  endfunction
function automatic [7:0] lfsr(input [5:0] k);  lfsr = LFSR[503 - 8 * k -: 8];  endfunction

logic [8:0] mv = 9'd0;                  // MAME m_mv
logic [1:0] sc = 2'd0;                  // MAME m_sc mod 4
logic [7:0] hz;                         // horizon of the line being shown
logic [7:0] star_x;
logic       star_on;
logic [5:0] fl_n = 6'd0;                // (frame / 2) mod 63
logic       fl_half = 1'b0;
logic [2:0] fr8 = 3'd0;                 // frame mod 8 (bit 2 = MAME frame_number & 4)
logic       flash_g, flash_r;           // this frame's flash terms

wire  [8:0] mv_inc = mv + 9'd1;
wire  [8:0] mv_nx  = (sc == 2'd2) ? {1'b0, mv_inc[7:0]} : (mv_inc == (flip ? 9'd255 : 9'd257)) ? 9'd0 : mv_inc;
function automatic [7:0] wave(input [2:0] m);
    case (m) 3'd0, 3'd6, 3'd7: wave = 8'd0; 3'd1, 3'd5: wave = 8'd1; default: wave = 8'd2; endcase
endfunction
wire [7:0] lfsr_fl = lfsr(fl_n);
function automatic [7:0] star_pos(input [7:0] l);  star_pos = {1'b0, l[0], l[1], l[2], l[3], 3'b000};  endfunction

always_ff @(posedge clk) begin
    if (reset) begin
        mv <= 9'd0; sc <= 2'd0; fl_n <= 6'd0; fl_half <= 1'b0; fr8 <= 3'd0;
    end else if (ce_pix && hc == 9'd319) begin
        // the line starting now uses the current mv; step for the next one (one next_line per line, 256 a frame)
        hz      <= 8'd120 + wave(mv[2:0]);
        star_on <= mv[2:0] == 3'd4 || mv[2:0] == 3'd5;
        star_x  <= (mv[2:0] == 3'd4) ? 8'h80 + star_pos(lfsr(6'((10'd5 * mv) % 10'd63)))
                                     : star_pos(lfsr(6'((10'd5 * (mv - 9'd1)) % 10'd63)));
        mv <= mv_nx;
        if (mv_nx == 9'd128) sc <= sc + 2'd1;
        if (vc == 8'd15) begin                                      // vblank ends: MAME screen_vblank (falling edge)
            fr8 <= fr8 + 3'd1;
            fl_half <= ~fl_half;
            if (fl_half) fl_n <= (fl_n == 6'd62) ? 6'd0 : fl_n + 6'd1;
            flash_g <= snd2[5] & lfsr_fl[5];
            flash_r <= snd2[5] & fr8[2];
        end
    end
end

wire [7:0] bx = hc[7:0] ^ {8{crt_flip}};
logic [7:0] bg_r, bg_g, bg_b;
always_comb begin
    if (bx >= hz) begin bg_r = ramp(SUN + bx - hz); bg_g = 8'd0; bg_b = 8'd0; end
    else          begin bg_r = 8'd0; bg_g = 8'd0; bg_b = ramp(SEA + bx); end
    if (star_on && bx == star_x && bx >= hz) bg_g = 8'hC0;
end
wire [2:0] hf_pen = {cram_v[2], cram_v[1] | (flash_g & cram_v[2]), cram_v[0] | (flash_r & (cram_v[1] | (flash_g & cram_v[2])))};

wire       dot = vram_q[sx[2:0]];
wire [2:0] col = dot ? (sfev ? sf_col : sh_col) : 3'd0;
wire       act = !hc[8] && vc >= 8'd16 && vc < 8'd240;

always_ff @(posedge clk) begin
    if (ce_pix) begin
        if (hf && !dot) begin
            video_r <= act ? bg_r : 8'd0;  video_g <= act ? bg_g : 8'd0;  video_b <= act ? bg_b : 8'd0;
        end else if (hf) begin
            video_r <= {8{act & hf_pen[0]}};  video_g <= {8{act & hf_pen[1]}};  video_b <= {8{act & hf_pen[2]}};
        end else begin
            video_r <= {8{act & col[0]}};
            video_g <= {8{act & col[1]}};
            video_b <= {8{act & col[2]}};
        end
        video_hblank <= hc[8];
        video_vblank <= !(vc >= 8'd16 && vc < 8'd240);
        video_hs     <= hc >= 9'd272 && hc < 9'd296;
        video_vs     <= vc >= 8'd244 && vc < 8'd247;
    end
end

n8080_sound sound
(
    .clk(clk), .reset(reset), .pause(pause), .hf(hf), .sfev(sfev),
    .mcs48_0_i(mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .snd1(snd1), .snd2(snd2), .pa(snd_pa), .pd(snd_pd), .audio(audio), .mul_a(mul_a), .mul_b(mul_b), .mul_p(mul_p)
);

endmodule
