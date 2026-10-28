//============================================================================
//
//  Nintendo Donkey Kong board (TKG-04 two-board set; MAME dkong.cpp dkong2b) and Donkey Kong Jr. (dkongjr)
//  Copyright (C) 2026 Rodimus
//
//  Main Z80 at 1H (3.072 MHz), 8257 DMA copies sprite data into the object RAM, 8035 sound CPU (dkong_sound.sv).
//  Memory map (TKG-04 CPU sheet):
//    0000-5FFF ROM          6000-6FFF RAM (6000-6BFF on the board)   7000-73FF object RAM (two 0x200 banks)
//    7400-77FF video RAM    7800-780F 8257
//    7C00 R IN0 / W sound latch (LS175 3D)     7C80 R IN1
//    7D00 R IN2 / W 7D00-7D07 6H LS259 (data bit 0): sound triggers
//    7D80 R DSW0 / W 7D80-7D87 5H LS259 (data bit 0): 0 sound IRQ, 2 flip, 3 sprite bank, 4 NMI mask, 5 DMA DRQ,
//                                                      6-7 palette bank; DK Jr.: 1 = falling sound
//  DK Jr.: 7C80-7C87 4H LS259 (data bit 0): 0 char ROM bank, 1 -> sound CPU P2.6; 3D is an LS174 (5 bits).
//  /WAIT: a VRAM access while /VRAM BUSY is low (outside h 258-377) waits, except in VBLK (TKG-04 CPU sheet 7F).
//  NMI: set by the VBLK edge while the mask is on, cleared by mask = 0 (8F).
//  Radar Scope (TRS-02, MAME radarscp): DK map; 7C80 W = grid colour (data 2-0, inverted), 7D81 = grid enable;
//  background from dkong_radar.sv (gfx3 timing table); its discrete sound board = dkong_sound.sv Radar Scope mode.
//  Conversion kits (rom_dec, decoders in dkong_kits_pkg.sv; MAME dkong.cpp inits):
//    Donkey King Jr. / Up Maguila: palette PROMs read inverted.
//    Epos (Drakton, Street Heat): every I/O read steps a 4-bit counter (odd port down, even port up; reads return 00);
//      counter 8-B selects one of four PAL decodes for 0000-3FFF. Power-up counter 9 (Drakton) / 8 (Street Heat).
//      Street Heat: 7C00 / 7C80 bits 0-1 = steering dial P1 / P2 while DSW0 bit 6 = 0 .
//    Braze kit (64K ROM + 93C46 in the CPU socket): ROM at 0000-5FFF and 8000-FFFF = kit ROM {A15 select, A14-A0};
//      EEPROM at C000 (C800 on dkongx: bit 0 DI, 1 CLK, 2 CS; read bit 0 = DO); dkongx A15 latch at E000 (data
//      bit 0), dkongike A15 = OSD Game switch (DSW1 bit 0).
//
//============================================================================

module dkong_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,
    input  logic        jr,             // Donkey Kong Jr. board
    input  logic        radar,          // Radar Scope (TRS-02)
    input  logic  [3:0] rom_dec,        // conversion kit (dkong_kits_pkg), 0 = none

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] dsw0,
    input  logic  [7:0] dsw1,           // Braze dkongike: bit 0 = Game switch
    input  logic        in2_snd_status, // IN2 bit 6 = sound CPU P2.4 inverted (DK, Radar Scope)
    input  logic        spr256,         // 16K sprite ROM (Up Maguila): 8-bit sprite codes (dkong_video)
    input  logic        gfx1_8k,        // 8K char ROM region (Street Heat): planes 0x1000 apart, as DK Jr.
    input  logic  [1:0] dial0,          // Street Heat steering dial P1 / P2 (MAME IN4 / IN5)
    input  logic  [1:0] dial1,

    // Braze kit 93C46 (rtl/nintendo_dispatcher.sv)
    output logic        eep_cs,
    output logic        eep_clk,
    output logic        eep_di,
    input  logic        eep_do,

    // ROMs (shared blocks in rtl/nintendo_dispatcher.sv)
    output logic [15:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [11:0] snd_pa,         // 8035 program
    input  logic  [7:0] snd_pd,
    output logic [12:0] snd_xa,         // MOVX data ROM (soundcpu region)
    input  logic  [7:0] snd_xd,
    output logic [12:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] pal_a,          // MAME proms 0x000 c-2k, 0x100 c-2j (same address), 0x200 v-5e
    input  logic  [7:0] prom_lo_d,      // c-2k[pal_a]
    input  logic  [7:0] prom_hi_d,      // c-2j[pal_a]
    output logic  [7:0] cc_a,
    input  logic  [3:0] prom_cc_d,      // v-5e[cc_a]
    output logic [10:0] gfx3_a,         // Radar Scope timing table
    input  logic  [7:0] gfx3_d,

    output logic        ce_pix,
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,

    output logic signed [15:0] audio,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write,

    // pooled 8257 DMA (dispatcher)
    output chip_pool_pkg::i8257_i_t i8257_0_i,
    input  chip_pool_pkg::i8257_o_t i8257_0_o,

    // board RAM pool (dispatcher, ram_pool_pkg)
    output ram_pool_pkg::pram_i_t [8:0] pr_i,
    input  ram_pool_pkg::pram_o_t [8:0] pr_o
);

// ------------------------------------------------------------------ video timing / CPU clock
logic cen_p, cen_n, vram_busy, vblk;
wire  run = ~pause;

// ------------------------------------------------------------------ Z80
wire [15:0] cpu_a    = z80pa_0_o.a;
wire        mreq     = ~z80pa_0_o.mreq_n;
wire        rd       = ~z80pa_0_o.rd_n;
wire        wr       = ~z80pa_0_o.wr_n;
wire        rfsh     = ~z80pa_0_o.rfsh_n;
wire        busak    = ~z80pa_0_o.busak_n;
wire        iorq     = ~z80pa_0_o.iorq_n;
wire        m1       = ~z80pa_0_o.m1_n;

logic wr_q = 1'b0, rd_q = 1'b0, ior_q = 1'b0;
always_ff @(posedge clk) begin wr_q <= wr & mreq; rd_q <= rd & mreq; ior_q <= rd & iorq; end
wire cpu_we = wr & mreq & ~wr_q;        // one clock per write cycle
wire cpu_re = rd & mreq & ~rd_q;
wire io_re  = rd & iorq & ~m1 & ~ior_q; // one clock per I/O read (Epos counter)

// ------------------------------------------------------------------ 8257
logic [15:0] dma_a;
logic  [7:0] dma_dout, dma_data, dma_latch, mem_q;
logic        dma_hrq, dma_busy, dma_memw, dma_iow;
logic  [1:0] dma_chan;
logic        drq;
wire         dma_cs = cpu_a[15:10] == 6'b011110;                    // 7800-7BFF

// 8257 DMA: pooled i8257_0 (dispatcher)
assign i8257_0_i.reset = reset;
assign i8257_0_i.ce = cen_p & run;
assign i8257_0_i.rev_rw = 1'b1;
assign i8257_0_i.cs = dma_cs && !busak;
assign i8257_0_i.a = cpu_a[3:0];
assign i8257_0_i.wr = cpu_we;
assign i8257_0_i.rd = cpu_re;
assign i8257_0_i.din = z80pa_0_o.dout;
assign dma_dout = i8257_0_o.dout;
assign i8257_0_i.drq = {2'b00, drq, drq};
assign dma_hrq = i8257_0_o.hrq;
assign i8257_0_i.hlda = busak;
assign dma_a = i8257_0_o.addr;
assign dma_chan = i8257_0_o.chan;
assign dma_busy = i8257_0_o.busy;
assign dma_iow = i8257_0_o.iow;
assign dma_memw = i8257_0_o.memw;
assign i8257_0_i.mem_d = mem_q;
assign i8257_0_i.io_d = dma_latch;
assign dma_data = i8257_0_o.data;
always_ff @(posedge clk) if (dma_iow) dma_latch <= dma_data;       // 8257 I/O channel latch

// ------------------------------------------------------------------ bus (CPU or DMA)
wire        dma_own = dma_busy & busak;
wire [15:0] bus_a   = dma_own ? dma_a : cpu_a;
wire        bus_we  = dma_own ? dma_memw : cpu_we;
wire  [7:0] bus_d   = dma_own ? dma_data : z80pa_0_o.dout;

wire sel_ram  = bus_a[15:12] == 4'h6;
wire sel_obj  = bus_a[15:10] == 6'b011100;                         // 7000-73FF
wire sel_vram = bus_a[15:10] == 6'b011101;                         // 7400-77FF
wire sel_io   = bus_a[15:10] == 6'b011111;                         // 7C00-7FFF

logic [7:0] ram_q, vram_q, obj_q;
logic [31:0] spr_d;
logic  [7:0] spr_a;
logic  [9:0] vram_va;
logic  [7:0] vram_vd;

assign pr_i[6] = '0;
assign pr_i[7] = '0;
assign pr_i[8] = '0;

// work RAM: pool block 0 (port B = hiscore)
assign pr_i[0].a_addr = {3'd0, bus_a[11:0]}; assign pr_i[0].a_d = bus_d; assign pr_i[0].a_we = bus_we & sel_ram;
assign pr_i[0].b_addr = {3'd0, hs_address[11:0]}; assign pr_i[0].b_d = hs_data_in; assign pr_i[0].b_we = hs_write & pause;
assign ram_q = pr_o[0].a_q;
assign hs_data_out = pr_o[0].b_q;

// video RAM: pool block 1 (port B = tilemap)
assign pr_i[1].a_addr = {5'd0, bus_a[9:0]}; assign pr_i[1].a_d = bus_d; assign pr_i[1].a_we = bus_we & sel_vram;
assign pr_i[1].b_addr = {5'd0, vram_va}; assign pr_i[1].b_d = 8'h00; assign pr_i[1].b_we = 1'b0;
assign vram_q = pr_o[1].a_q;
assign vram_vd = pr_o[1].b_q;

// object RAM as four byte lanes: one 32-bit sprite entry per video read
logic [7:0] obj_lane_q[4];
genvar ln;
generate
    for (ln = 0; ln < 4; ln++) begin : objl
        // object RAM lane ln: pool block 2 + ln (port B = sprite engine)
        assign pr_i[2 + ln].a_addr = {7'd0, bus_a[9:2]}; assign pr_i[2 + ln].a_d = bus_d; assign pr_i[2 + ln].a_we = bus_we & sel_obj & (bus_a[1:0] == ln);
        assign pr_i[2 + ln].b_addr = {7'd0, spr_a}; assign pr_i[2 + ln].b_d = 8'h00; assign pr_i[2 + ln].b_we = 1'b0;
        assign obj_lane_q[ln] = pr_o[2 + ln].a_q;
        assign spr_d[ln*8 +: 8] = pr_o[2 + ln].b_q;
    end
endgenerate
logic [1:0] obj_lane;
always_ff @(posedge clk) obj_lane <= bus_a[1:0];
assign obj_q = obj_lane_q[obj_lane];

// ------------------------------------------------------------------ latches
logic [7:0] snd_latch, lat_6h, lat_5h, lat_4h;
logic [2:0] grid_col;
always_ff @(posedge clk) begin
    if (reset) begin
        snd_latch <= 8'd0; lat_6h <= 8'd0; lat_5h <= 8'd0; lat_4h <= 8'd0; grid_col <= 3'd0;
    end else if (cpu_we && !dma_own && sel_io) begin
        case (cpu_a[8:7])
            2'd0: snd_latch <= z80pa_0_o.dout;
            2'd1: begin lat_4h[cpu_a[2:0]] <= z80pa_0_o.dout[0]; grid_col <= ~z80pa_0_o.dout[2:0]; end
            2'd2: lat_6h[cpu_a[2:0]] <= z80pa_0_o.dout[0];
            2'd3: lat_5h[cpu_a[2:0]] <= z80pa_0_o.dout[0];
            default: ;
        endcase
    end
end

wire       snd_irq   = lat_5h[0];
wire       flip      = lat_5h[2];
wire       spr_bank  = lat_5h[3];
wire       nmi_mask  = lat_5h[4];
assign     drq       = lat_5h[5];
wire [1:0] pal_bank  = lat_5h[7:6];

// ------------------------------------------------------------------ conversion kits (dkong_kits_pkg)
wire dkingjr  = rom_dec == dkong_kits_pkg::DEC_DKINGJR;
wire strtheat = rom_dec == dkong_kits_pkg::DEC_STRTHEAT;
wire epos     = rom_dec == dkong_kits_pkg::DEC_DRAKTON || strtheat;
wire brz_x    = rom_dec == dkong_kits_pkg::DEC_BRAZE_X;
wire brz_ike  = rom_dec == dkong_kits_pkg::DEC_BRAZE_IKE;
wire braze    = rom_dec == dkong_kits_pkg::DEC_BRAZE || brz_x || brz_ike;

// Epos: I/O read at an odd port counts down, even port up; counter 8-B picks the decode (other values keep it)
logic [3:0] epos_cnt  = 4'd9;
logic [1:0] epos_bank = 2'd1;
wire  [3:0] epos_nxt  = cpu_a[0] ? epos_cnt - 4'd1 : epos_cnt + 4'd1;
always_ff @(posedge clk) begin
    if (reset) begin
        epos_cnt  <= strtheat ? 4'd8 : 4'd9;
        epos_bank <= strtheat ? 2'd0 : 2'd1;
    end else if (epos && io_re) begin
        epos_cnt <= epos_nxt;
        if (epos_nxt[3:2] == 2'b10) epos_bank <= epos_nxt[1:0];
    end
end

// Braze: A15 latch (dkongx, E000), EEPROM pins (C000; dkongx C800)
wire [15:0] eep_addr = brz_x ? 16'hC800 : 16'hC000;
wire        sel_eep  = braze && cpu_a == eep_addr;
logic brz_a15 = 1'b0, eep_cs_q = 1'b0, eep_clk_q = 1'b0, eep_di_q = 1'b0;
always_ff @(posedge clk) begin
    if (reset) begin
        brz_a15 <= 1'b0; eep_cs_q <= 1'b0; eep_clk_q <= 1'b0; eep_di_q <= 1'b0;
    end else if (cpu_we && !dma_own && braze) begin
        if (brz_x && cpu_a == 16'hE000) brz_a15 <= z80pa_0_o.dout[0];
        if (cpu_a == eep_addr) {eep_cs_q, eep_clk_q, eep_di_q} <= z80pa_0_o.dout[2:0];
    end
end
assign eep_cs  = eep_cs_q;
assign eep_clk = eep_clk_q;
assign eep_di  = eep_di_q;
wire brz_sel15 = brz_ike ? dsw1[0] : brz_a15;

// NMI: VBLK edge sets it while the mask is on
logic nmi_q = 1'b0, vblk_q = 1'b0;
always_ff @(posedge clk) begin
    vblk_q <= vblk;
    if (reset || !nmi_mask) nmi_q <= 1'b0;
    else if (vblk && !vblk_q) nmi_q <= 1'b1;
end

// /WAIT: VRAM access while the video board is fetching (outside VBLK)
logic wait_q = 1'b0;
always_ff @(posedge clk) begin
    if (reset) wait_q <= 1'b0;
    else if (cen_n && run) wait_q <= (mreq | rd | wr) && !rfsh && !busak && cpu_a[15:10] == 6'b011101 && vram_busy && !vblk;
`ifdef SIM_NO_VRAM_WAIT
    wait_q <= 1'b0;                     // sim only: MAME has no VRAM wait states (compare runs)
`endif
end

// ------------------------------------------------------------------ CPU read data
logic       snd_status;
logic [7:0] io_q;
wire wheel = strtheat && !dsw0[6];
always_comb begin
    case (cpu_a[8:7])
        2'd0: io_q = wheel ? {in0[7:2], dial0} : in0;
        2'd1: io_q = wheel ? {in1[7:2], dial1} : in1;
        2'd2: io_q = in2_snd_status ? (in2 | {1'b0, ~snd_status, 6'd0}) : in2;
        2'd3: io_q = dsw0;
    endcase
end

assign rom_a = braze ? dkong_kits_pkg::braze_addr({brz_sel15, cpu_a[14:0]}) : {1'b0, cpu_a[14:0]};
wire  sel_rom = cpu_a < 16'h6000 || (braze && cpu_a[15]);
logic [7:0] rom_q;
always_comb begin
    if (braze)                         rom_q = dkong_kits_pkg::braze_data(rom_d);
    else if (epos && cpu_a < 16'h4000) rom_q = dkong_kits_pkg::epos_dec(rom_d, strtheat, epos_bank);
    else                               rom_q = rom_d;
end

always_comb begin
    if (epos && iorq && !m1)   z80pa_0_i.di = 8'h00;
    else if (sel_eep)   z80pa_0_i.di = {7'd0, eep_do};
    else if (sel_rom)   z80pa_0_i.di = rom_q;
    else if (sel_ram)   z80pa_0_i.di = ram_q;
    else if (sel_obj)   z80pa_0_i.di = obj_q;
    else if (sel_vram)  z80pa_0_i.di = vram_q;
    else if (dma_cs)    z80pa_0_i.di = dma_dout;
    else if (sel_io)    z80pa_0_i.di = io_q;
    else                z80pa_0_i.di = 8'hFF;
end
assign mem_q = sel_ram ? ram_q : sel_obj ? obj_q : sel_vram ? vram_q : (bus_a < 16'h6000) ? rom_q : 8'hFF;

assign z80pa_0_i.reset_n = ~reset;
assign z80pa_0_i.cen_p   = cen_p & run;
assign z80pa_0_i.cen_n   = cen_n & run;
assign z80pa_0_i.wait_n  = ~wait_q;
assign z80pa_0_i.int_n   = 1'b1;
assign z80pa_0_i.nmi_n   = ~nmi_q;
assign z80pa_0_i.busrq_n = ~dma_hrq;

// ------------------------------------------------------------------ video

dkong_video video
(
    .clk(clk), .reset(reset),
    .flip(flip), .sprite_bank(spr_bank), .palette_bank(pal_bank), .gfx_bank(jr & lat_4h[0]), .gfx1_8k(jr | gfx1_8k), .dk3(1'b0), .spr256(spr256), .mario(1'b0), .scroll_y(8'd0), .crt_flip(crt_flip),
    .radar(radar), .rs_snd2(lat_6h[2]), .rs_grid_on(lat_5h[1]), .rs_grid_col(grid_col), .rs_ans(mcs48_0_o.p2[5]),
    .gfx3_a(gfx3_a), .gfx3_d(gfx3_d),
    .ce_pix(ce_pix), .cpu_cen_p(cen_p), .cpu_cen_n(cen_n), .vram_busy(vram_busy), .vblank_hw(vblk),
    .vram_a(vram_va), .vram_d(vram_vd), .spr_a(spr_a), .spr_d(spr_d),
    .gfx1_a(gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(gfx2_a), .gfx2_d(gfx2_d),
    .cprom_a(cc_a), .cprom_d(prom_cc_d), .pal_a(pal_a),
    .pal_lo_d(dkingjr ? ~prom_lo_d : prom_lo_d), .pal_hi_d(dkingjr ? ~prom_hi_d : prom_hi_d),
    .r(video_r), .g(video_g), .b(video_b), .hblank(video_hblank), .vblank(video_vblank), .hsync(video_hs), .vsync(video_vs)
);

// ------------------------------------------------------------------ sound board
dkong_sound sound
(
    .clk(clk), .reset(reset), .pause(pause), .jr(jr), .rs(radar),
    .mcs48_0_i(mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .tune(snd_latch), .sfx(lat_6h), .irq(snd_irq), .lat4h1(lat_4h[1]), .snd9(lat_5h[1]),
    .pa(snd_pa), .pd(snd_pd), .xa(snd_xa), .xd(snd_xd),
    .status(snd_status),
    .audio(audio)
);

endmodule
