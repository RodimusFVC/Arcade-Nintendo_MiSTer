//============================================================================
//
//  Nintendo early arcade hardware — dispatcher (pools: ROM, RAM, CPUs, sound multiplier; boards in rtl/boards/)
//  Copyright (C) 2026 Rodimus
//
//  Variant 0: Donkey Kong, TKG-04 two-board set (MAME dkong.cpp dkong2b: dkong, dkongo, dkongj..., hacks)
//  Variant 1: Donkey Kong Jr. (MAME dkongjr)
//  Variant 2: Donkey Kong 3 (MAME dkong3)
//  Variant 3: Popeye, TPP2 boards (MAME popeye.cpp)
//  Variant 4: Mario Bros. (MAME mario.cpp)
//  Variant 5: Space Firebird (MAME spacefb.cpp spacefb / spacedem)
//  Variant 6: Radar Scope, TRS-02 (MAME dkong.cpp radarscp; DK board + dkong_radar.sv background)
//  Variant 7: Sky Skipper, TNX1 (MAME popeye.cpp; Popeye board with the tnx1 gate)
//  Variant 8: Space Fever / SF-HiSplitter / Space Launcher (MAME n8080.cpp spacefev; the 8080 runs on the pooled Z80)
//  Variant 9: Sheriff / Bandido (MAME n8080.cpp sheriff)
//  Variant 10: HeliFire (MAME n8080.cpp helifire)
//  Variants 0 / 1 / 2 also run the conversion kits on DK hardware (rom_dec: Donkey King Jr., Epos, Braze)
//
//  ioctl index 0 (MRA), images stored as dumped; tools/gen_mra.py places MAME regions:
//    0x00000 - 0x07FFF  maincpu  (DK3: 8000-9FFF at 0x6000)
//    0x08000 - 0x09FFF  soundcpu (8035 program 0x000-0xFFF + MOVX ROM 0x1000-0x17FF; DK3 2A03 #1 8000-9FFF)
//    0x0A000 - 0x0BFFF  2nd sound CPU (DK3 2A03 #2 8000-9FFF)
//    0x0C000 - 0x0FFFF  gfx2     (sprites, four quarters: 0x800 apart on DK / Jr., 0x1000 on DK3)
//    0x10000 - 0x11FFF  gfx1     (chars, two bitplane halves)
//    0x12000 - 0x124FF  proms    (0x000 palette A: c-2k / 1d, 0x200 palette B: c-2j / 1c, 0x400 char colour codes)
//  Popeye: maincpu 0x00000 (32K), gfx1 0x10000 (2K), proms 0x12000 sprite palette 5B (low nibbles), 0x12100 timing
//    PROM 7J, 0x12200 sprite palette 5A (high nibbles), 0x12400 (0x00 background 4A, 0x20 text 3A), gfx2 0x18000 (32K)
//    (Sky Skipper: same places, gfx2 16K)
//  Mario: maincpu 0x00000 (F000-FFFF at 0x6000), soundrom 0x08000 (4K), gfx1 0x10000 (8K), proms 0x12000 (4P, 512),
//    gfx2 0x18000 (24K)
//  Space Firebird: maincpu 0x00000 (16K), audiocpu 0x08000 (1K), sprites 0x0C000 (5K 0x000 / 6K 0x800), bullets
//    0x10000 (4I, 256), proms 0x12000 (3N colour, 32)
//  Radar Scope: DK layout + gfx3 (radar / star timing table, 2K) at 0x11000 (read on gfx1 port A after the load)
//  n8080: maincpu 0x00000 (16K), 8035 0x08000 (1K), colour PROM 0x10000 (Sheriff 1K, Space Fever 32) in the gfx1 block
//  Braze kits (DK / DK Jr. / DK3 boards, rom_dec 4-6): kit ROM 0x0000-0x7FFF at index 0 0x00000, 0x8000-0xFFFF on
//    ioctl index 5 (CPU ROM block upper half; the original maincpu ROMs are not loaded). 93C46 (jotego jt9346) contents = MRA
//    <nvram index="4" size="128">, filled with FF while index 0 loads (MAME eeprom default; the NVRAM file comes after).
//
//============================================================================

module nintendo_dispatcher
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,
    input  logic  [7:0] game_flags2,    // [0] IN2 bit 6 = sound CPU status, [1] steering dial, [2] 16K sprite ROM (DK / Jr.), [3] 8K char ROM (DK)
    input  logic  [3:0] rom_dec,        // conversion kit decode (rtl/boards/dkong/dkong_kits_pkg.sv)
    input  logic  [1:0] dial0,          // Street Heat steering dial P1 / P2
    input  logic  [1:0] dial1,
    output logic        ce_pix,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] dsw0,
    input  logic  [7:0] dsw1,
    input  logic  [7:0] coin,

    input  logic [24:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,
    input  logic        ioctl_wr0,
    input  logic        ioctl_wr5,      // index 5: Braze kit ROM 8000-FFFF

    // Braze kit EEPROM image (ioctl index 4: load / save)
    input  logic  [6:0] nv_addr,
    input  logic  [7:0] nv_din,
    input  logic        nv_we,
    output logic  [7:0] nv_dout,

    input  logic        crt_flip,
    input  logic  [3:0] h_adj,
    input  logic  [3:0] v_adj,

    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,
    output logic        video_field,    // interlaced boards: field being shown (VGA_F1)

    output logic signed [15:0] audio,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

/////////////////////////////  Shared ROM blocks  /////////////////////////////

wire load_cpu  = ioctl_wr0 && ioctl_addr[24:15] == 10'h000;        // 0x00000-0x07FFF
// The Braze kit ROM's upper half loads on ioctl index 5: at index 0 0x20000 the MRA's zero padding from 0x12500 would
// run through 0x18000-0x1FFFF (Popeye's gfx2 load window) and wipe the DK sprite ROM.
wire load_cpuh = ioctl_wr5 && ioctl_addr[24:15] == 10'h000;        // index 5 0x0000-0x7FFF (Braze kit ROM 8000-FFFF)
wire load_snd  = ioctl_wr0 && ioctl_addr[24:13] == 12'h004;        // 0x08000-0x09FFF
wire load_snd2 = ioctl_wr0 && ioctl_addr[24:13] == 12'h005;        // 0x0A000-0x0BFFF
wire load_gfx2 = ioctl_wr0 && ioctl_addr[24:14] == 11'h003;        // 0x0C000-0x0FFFF
wire load_gfx2p = ioctl_wr0 && ioctl_addr[24:15] == 10'h003;       // 0x18000-0x1FFFF (Popeye, 32K)
wire load_gfx1 = ioctl_wr0 && ioctl_addr[24:13] == 12'h008;        // 0x10000-0x11FFF
wire load_prom = ioctl_wr0 && ioctl_addr[24:11] == 14'h0024;       // 0x12000-0x127FF

wire is_dk3 = variant == 8'd2;
wire is_sky = variant == 8'd7;
wire is_pop = variant == 8'd3 || is_sky;           // Popeye board runs both
wire is_mar = variant == 8'd4;
wire is_sfb = variant == 8'd5;
wire is_rs  = variant == 8'd6;
wire is_n80 = variant == 8'd8 || variant == 8'd9 || variant == 8'd10;   // n8080 board (8 Space Fever, 9 Sheriff, 10 HeliFire)

logic [15:0] rom_a, dk_rom_a, dk3_rom_a;
logic [14:0] pop_rom_a, mar_rom_a, sfb_rom_a, n80_rom_a;
logic  [7:0] rom_d;
logic [11:0] snd_pa, dk_snd_pa, mar_snd_pa, sfb_snd_pa, n80_snd_pa;
logic [12:0] snd_xa, dk_snd_xa, dk3_snd1_a, dk3_snd2_a, mar_snd_xa;
assign snd_pa = is_mar ? mar_snd_pa : is_sfb ? sfb_snd_pa : is_n80 ? n80_snd_pa : dk_snd_pa;
logic  [7:0] snd_pd, snd_xd, snd2_d;
assign snd_xa = is_dk3 ? dk3_snd1_a : is_mar ? mar_snd_xa : dk_snd_xa;
logic [12:0] gfx1_a, dk_gfx1_a, dk3_gfx1_a, mar_gfx1_a, sfb_gfx1_a, n80_gfx1_a;
logic [10:0] pop_gfx1_a;
logic [14:0] gfx2_a, dk_gfx2_a, dk3_gfx2_a, pop_gfx2_a, mar_gfx2_a, sfb_gfx2_a;
logic  [7:0] gfx1_d, gfx2_d;
logic  [7:0] pal_a, cc_a, dk_pal_a, dk3_pal_a, dk_cc_a, dk3_cc_a, pop_cc_a, pop_pal_a, mar_pal_a, sfb_pal_a;
logic  [7:0] prom_lo_q, prom_hi_q, prom_cc_q;
assign rom_a  = is_dk3 ? dk3_rom_a  : is_pop ? {1'b0, pop_rom_a} : is_mar ? {1'b0, mar_rom_a} : is_sfb ? {1'b0, sfb_rom_a} :
                is_n80 ? {1'b0, n80_rom_a} : dk_rom_a;
assign gfx1_a = is_dk3 ? dk3_gfx1_a : is_pop ? {2'b00, pop_gfx1_a} : is_mar ? mar_gfx1_a : is_sfb ? sfb_gfx1_a : is_n80 ? n80_gfx1_a : dk_gfx1_a;
assign gfx2_a = is_dk3 ? dk3_gfx2_a : is_pop ? pop_gfx2_a : is_mar ? mar_gfx2_a : is_sfb ? sfb_gfx2_a : dk_gfx2_a;
assign pal_a  = is_dk3 ? dk3_pal_a  : is_pop ? pop_pal_a : is_mar ? mar_pal_a : is_sfb ? sfb_pal_a : dk_pal_a;
assign cc_a   = is_dk3 ? dk3_cc_a   : is_pop ? pop_cc_a : dk_cc_a;

dpram_dc #(.widthad_a(16)) rom_cpu
(
    .clock_a(clk), .address_a({load_cpuh, ioctl_addr[14:0]}), .data_a(ioctl_dout), .wren_a(load_cpu | load_cpuh),
    .clock_b(clk), .address_b(rom_a), .q_b(rom_d)
);

// Braze kit 93C46, 128 x 8 (jotego jt9346). Second port: FF fill during the index 0 load, then the MRA NVRAM
// image (index 4) / save.
// jt9346 is used unmodified. It takes a start bit only as DI going 0 -> 1 between two clocks, but the Braze kits clock
// their reads with DI held at 1, so the next command's start bit (DI = 1 again) would be missed. On each CS rising edge
// this wrapper clocks one 0 in first; a 93C46 ignores 0s before the start bit (datasheet; MAME eepromser).
// DO reads 1 while CS is low (open output with a pull-up, as MAME eepromser).
logic dk_eep_cs, dk_eep_clk, dk_eep_di, dk3_eep_cs, dk3_eep_clk, dk3_eep_di, eep_sdo;
wire  eep_cs   = is_dk3 ? dk3_eep_cs : dk_eep_cs;
wire  eep_do   = eep_cs ? eep_sdo : 1'b1;
wire  eep_fill = ioctl_wr0 && ioctl_addr[24:7] == 18'd0;
logic       eep_cs_q = 1'b0;
logic [1:0] eep_pre  = 2'd0;            // 2: clock low, DI 0; 1: clock high, DI 0 (the leading 0); 0: CPU pins
always_ff @(posedge clk) begin
    eep_cs_q <= eep_cs;
    if (eep_cs && !eep_cs_q) eep_pre <= 2'd2;
    else if (eep_pre != 2'd0) eep_pre <= eep_pre - 2'd1;
end
wire  eep_sclk = eep_pre == 2'd0 ? (is_dk3 ? dk3_eep_clk : dk_eep_clk) : eep_pre == 2'd1;
wire  eep_sdi  = eep_pre == 2'd0 ? (is_dk3 ? dk3_eep_di  : dk_eep_di)  : 1'b0;
jt9346 #(.AW(7), .CW(7), .DW(8)) eeprom
(
    .rst(reset), .clk(clk),
    .sclk(eep_sclk), .sdi(eep_sdi), .sdo(eep_sdo),
    .scs(eep_cs),
    .dump_clk(clk), .dump_addr(eep_fill ? ioctl_addr[6:0] : nv_addr), .dump_we(eep_fill | nv_we),
    .dump_din(eep_fill ? 8'hFF : nv_din), .dump_dout(nv_dout),
    .dump_clr(1'b0), .dump_flag()
);

// sound ROM: port A = 8035 program once the download is over, port B = MOVX data
dpram_dc #(.widthad_a(13)) rom_snd
(
    .clock_a(clk), .address_a(reset ? ioctl_addr[12:0] : {1'b0, snd_pa}), .data_a(ioctl_dout), .wren_a(load_snd), .q_a(snd_pd),
    .clock_b(clk), .address_b(snd_xa), .q_b(snd_xd)
);

// second sound CPU ROM (DK3 2A03 #2)
dpram_dc #(.widthad_a(13)) rom_snd2
(
    .clock_a(clk), .address_a(ioctl_addr[12:0]), .data_a(ioctl_dout), .wren_a(load_snd2),
    .clock_b(clk), .address_b(dk3_snd2_a), .q_b(snd2_d)
);

// gfx1 block: port A = download, then Radar Scope's gfx3 table (0x11000)
logic [10:0] rs_gfx3_a;
logic  [7:0] gfx3_q;
dpram_dc #(.widthad_a(13)) rom_gfx1
(
    .clock_a(clk), .address_a(reset ? ioctl_addr[12:0] : {2'b10, rs_gfx3_a}), .data_a(ioctl_dout), .wren_a(load_gfx1),
    .q_a(gfx3_q),
    .clock_b(clk), .address_b(gfx1_a), .q_b(gfx1_d)
);

dpram_dc #(.widthad_a(15)) rom_gfx2
(
    .clock_a(clk), .address_a(load_gfx2p ? ioctl_addr[14:0] : {1'b0, ioctl_addr[13:0]}), .data_a(ioctl_dout),
    .wren_a(load_gfx2 | load_gfx2p),
    .clock_b(clk), .address_b(gfx2_a), .q_b(gfx2_d)
);

// palette PROMs 512 deep (DK3 1d / 1c); every board reads the first 256 entries, as MAME
dpram_dc #(.widthad_a(9)) prom_lo
(
    .clock_a(clk), .address_a(ioctl_addr[8:0]), .data_a(ioctl_dout), .wren_a(load_prom && ioctl_addr[10:9] == 2'd0),
    .clock_b(clk), .address_b({1'b0, pal_a}), .q_b(prom_lo_q)
);
dpram_dc #(.widthad_a(9)) prom_hi
(
    .clock_a(clk), .address_a(ioctl_addr[8:0]), .data_a(ioctl_dout), .wren_a(load_prom && ioctl_addr[10:9] == 2'd1),
    .clock_b(clk), .address_b({1'b0, pal_a}), .q_b(prom_hi_q)
);
dpram_dc #(.widthad_a(8)) prom_cc
(
    .clock_a(clk), .address_a(ioctl_addr[7:0]), .data_a(ioctl_dout), .wren_a(load_prom && ioctl_addr[10:8] == 3'd4),
    .clock_b(clk), .address_b(cc_a), .q_b(prom_cc_q)
);

/////////////////////////////  Board RAM pool  /////////////////////////////
// One board runs at a time, so its RAMs share these blocks (ram_pool_pkg; the board drives pr_i, every board sees pr_o).
//   pr 0  16K  work RAM (DK / DK Jr. / Radar Scope / DK3 / Mario / Popeye 4K, Space Firebird 2K; port B hiscore) or
//              the n8080 RAM 4000-7FFF (port B = video)
//   pr 1  1K   video RAM (DK / DK3 / Mario), Popeye text codes, n8080 HeliFire colour RAM
//   pr 2-5 256 object RAM lanes (DK / DK3 / Mario), Popeye sprite lanes, Space Firebird object pages
//   pr 6  2K   DK3 2A03 #1 RAM, Popeye text colours (1K)
//   pr 7  4K   DK3 2A03 #2 RAM (2K), Popeye background low nibbles
//   pr 8  4K   Popeye background high nibbles
ram_pool_pkg::pram_i_t [8:0] dk_pr_i, dk3_pr_i, pop_pr_i, mar_pr_i, sfb_pr_i, n80_pr_i, pr_i;
ram_pool_pkg::pram_o_t [8:0] pr_o;
assign pr_i = is_dk3 ? dk3_pr_i : is_pop ? pop_pr_i : is_mar ? mar_pr_i : is_sfb ? sfb_pr_i : is_n80 ? n80_pr_i : dk_pr_i;

dpram_dc #(.widthad_a(14)) pr_0
(
    .clock_a(clk), .address_a(pr_i[0].a_addr[13:0]), .data_a(pr_i[0].a_d), .wren_a(pr_i[0].a_we), .q_a(pr_o[0].a_q),
    .clock_b(clk), .address_b(pr_i[0].b_addr[13:0]), .data_b(pr_i[0].b_d), .wren_b(pr_i[0].b_we), .q_b(pr_o[0].b_q)
);
dpram_dc #(.widthad_a(10)) pr_1
(
    .clock_a(clk), .address_a(pr_i[1].a_addr[9:0]), .data_a(pr_i[1].a_d), .wren_a(pr_i[1].a_we), .q_a(pr_o[1].a_q),
    .clock_b(clk), .address_b(pr_i[1].b_addr[9:0]), .data_b(pr_i[1].b_d), .wren_b(pr_i[1].b_we), .q_b(pr_o[1].b_q)
);
dpram_dc #(.widthad_a(8)) pr_2
(
    .clock_a(clk), .address_a(pr_i[2].a_addr[7:0]), .data_a(pr_i[2].a_d), .wren_a(pr_i[2].a_we), .q_a(pr_o[2].a_q),
    .clock_b(clk), .address_b(pr_i[2].b_addr[7:0]), .data_b(pr_i[2].b_d), .wren_b(pr_i[2].b_we), .q_b(pr_o[2].b_q)
);
dpram_dc #(.widthad_a(8)) pr_3
(
    .clock_a(clk), .address_a(pr_i[3].a_addr[7:0]), .data_a(pr_i[3].a_d), .wren_a(pr_i[3].a_we), .q_a(pr_o[3].a_q),
    .clock_b(clk), .address_b(pr_i[3].b_addr[7:0]), .data_b(pr_i[3].b_d), .wren_b(pr_i[3].b_we), .q_b(pr_o[3].b_q)
);
dpram_dc #(.widthad_a(8)) pr_4
(
    .clock_a(clk), .address_a(pr_i[4].a_addr[7:0]), .data_a(pr_i[4].a_d), .wren_a(pr_i[4].a_we), .q_a(pr_o[4].a_q),
    .clock_b(clk), .address_b(pr_i[4].b_addr[7:0]), .data_b(pr_i[4].b_d), .wren_b(pr_i[4].b_we), .q_b(pr_o[4].b_q)
);
dpram_dc #(.widthad_a(8)) pr_5
(
    .clock_a(clk), .address_a(pr_i[5].a_addr[7:0]), .data_a(pr_i[5].a_d), .wren_a(pr_i[5].a_we), .q_a(pr_o[5].a_q),
    .clock_b(clk), .address_b(pr_i[5].b_addr[7:0]), .data_b(pr_i[5].b_d), .wren_b(pr_i[5].b_we), .q_b(pr_o[5].b_q)
);
dpram_dc #(.widthad_a(11)) pr_6
(
    .clock_a(clk), .address_a(pr_i[6].a_addr[10:0]), .data_a(pr_i[6].a_d), .wren_a(pr_i[6].a_we), .q_a(pr_o[6].a_q),
    .clock_b(clk), .address_b(pr_i[6].b_addr[10:0]), .data_b(pr_i[6].b_d), .wren_b(pr_i[6].b_we), .q_b(pr_o[6].b_q)
);
dpram_dc #(.widthad_a(12)) pr_7
(
    .clock_a(clk), .address_a(pr_i[7].a_addr[11:0]), .data_a(pr_i[7].a_d), .wren_a(pr_i[7].a_we), .q_a(pr_o[7].a_q),
    .clock_b(clk), .address_b(pr_i[7].b_addr[11:0]), .data_b(pr_i[7].b_d), .wren_b(pr_i[7].b_we), .q_b(pr_o[7].b_q)
);
dpram_dc #(.widthad_a(12)) pr_8
(
    .clock_a(clk), .address_a(pr_i[8].a_addr[11:0]), .data_a(pr_i[8].a_d), .wren_a(pr_i[8].a_we), .q_a(pr_o[8].a_q),
    .clock_b(clk), .address_b(pr_i[8].b_addr[11:0]), .data_b(pr_i[8].b_d), .wren_b(pr_i[8].b_we), .q_b(pr_o[8].b_q)
);

/////////////////////////////  Shared sound multiplier  /////////////////////////////
// One signed 40 x 27 multiplier for the boards' analog sound models (Mario, Space Firebird, n8080). Only one board runs;
// each issues its products in the 256 clocks between its 192 kHz steps: a / b in clock t, product in clock t + 2.
logic signed [39:0] mar_mul_a, sfb_mul_a, n80_mul_a, mul_a, mul_ar;
logic signed [26:0] mar_mul_b, sfb_mul_b, n80_mul_b, mul_b, mul_br;
logic signed [66:0] mul_p;
assign mul_a = is_mar ? mar_mul_a : is_sfb ? sfb_mul_a : n80_mul_a;
assign mul_b = is_mar ? mar_mul_b : is_sfb ? sfb_mul_b : n80_mul_b;
always_ff @(posedge clk) begin
    mul_ar <= mul_a;
    mul_br <= mul_b;
    mul_p  <= mul_ar * mul_br;
end

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////
// One board runs at a time: each CPU is instanced once and driven by the active board (rtl/chip_pool_pkg.sv).

// z80pa_0: main CPU of every board, stock T80pa (DK / DK Jr. at 1H, DK3 at 4 MHz; the n8080 boards' 8080 runs on it
// unchanged: Space Fever / Sheriff / HeliFire sim byte-identical to an 8080-mode core)
chip_pool_pkg::z80pa_i_t dk_z80pa_0_i, dk3_z80pa_0_i, pop_z80pa_0_i, mar_z80pa_0_i, sfb_z80pa_0_i, n80_z80pa_0_i, z80pa_0_i;
chip_pool_pkg::z80pa_o_t z80pa_0_o;
assign z80pa_0_i = is_dk3 ? dk3_z80pa_0_i : is_pop ? pop_z80pa_0_i : is_mar ? mar_z80pa_0_i : is_sfb ? sfb_z80pa_0_i : is_n80 ? n80_z80pa_0_i :
                   dk_z80pa_0_i;

wire [15:0] z80pa_0_a;
wire  [7:0] z80pa_0_do;
wire [211:0] z80pa_0_reg;
wire        z80pa_0_m1_n, z80pa_0_mreq_n, z80pa_0_iorq_n, z80pa_0_rd_n, z80pa_0_wr_n, z80pa_0_rfsh_n, z80pa_0_busak_n;

T80pa #(.Mode(0)) z80pa_0
(
    .RESET_n (z80pa_0_i.reset_n), .CLK(clk), .CEN_p(z80pa_0_i.cen_p), .CEN_n(z80pa_0_i.cen_n),
    .WAIT_n  (z80pa_0_i.wait_n), .INT_n(z80pa_0_i.int_n), .NMI_n(z80pa_0_i.nmi_n), .BUSRQ_n(z80pa_0_i.busrq_n),
    .M1_n(z80pa_0_m1_n), .MREQ_n(z80pa_0_mreq_n), .IORQ_n(z80pa_0_iorq_n), .RD_n(z80pa_0_rd_n), .WR_n(z80pa_0_wr_n),
    .RFSH_n(z80pa_0_rfsh_n), .HALT_n(), .BUSAK_n(z80pa_0_busak_n), .OUT0(1'b0), .A(z80pa_0_a), .DI(z80pa_0_i.di),
    .DO(z80pa_0_do), .R800_mode(1'b0), .REG(z80pa_0_reg), .DIRSet(1'b0), .DIR(212'd0)
);

assign z80pa_0_o.a = z80pa_0_a;           assign z80pa_0_o.dout = z80pa_0_do;
assign z80pa_0_o.m1_n = z80pa_0_m1_n;     assign z80pa_0_o.mreq_n = z80pa_0_mreq_n; assign z80pa_0_o.iorq_n = z80pa_0_iorq_n;
assign z80pa_0_o.rd_n = z80pa_0_rd_n;     assign z80pa_0_o.wr_n = z80pa_0_wr_n;     assign z80pa_0_o.rfsh_n = z80pa_0_rfsh_n;
assign z80pa_0_o.busak_n = z80pa_0_busak_n;
assign z80pa_0_o.inte = z80pa_0_reg[210];   // IFF1 = the 8080's INTE pin (n8080 interrupt latch)

// mcs48_0: Donkey Kong / Mario Bros. / Space Firebird sound CPU (8035 / 8039; T48 t8039_notri_extrom, Arnim Laeuger)
chip_pool_pkg::mcs48_i_t dk_mcs48_0_i, mar_mcs48_0_i, sfb_mcs48_0_i, n80_mcs48_0_i, mcs48_0_i;
chip_pool_pkg::mcs48_o_t mcs48_0_o;
assign mcs48_0_i = is_mar ? mar_mcs48_0_i : is_sfb ? sfb_mcs48_0_i : is_n80 ? n80_mcs48_0_i : dk_mcs48_0_i;

wire  [7:0] mcu_p1, mcu_p2, mcu_db;
wire [11:0] mcu_pa;
wire        mcu_rd_n, mcu_wr_n, mcu_ale;

t8039_notri_extrom #(
    .gate_port_input_g (0),
    .ram_addr_width_g  (7)
) mcs48_0 (
    .xtal_i(clk), .xtal_en_i(mcs48_0_i.xtal_en), .reset_n_i(mcs48_0_i.reset_n),
    .t0_i(mcs48_0_i.t0), .t0_o(), .t0_dir_o(), .int_n_i(mcs48_0_i.int_n), .ea_i(1'b0),
    .rd_n_o(mcu_rd_n), .psen_n_o(), .wr_n_o(mcu_wr_n), .ale_o(mcu_ale),
    .db_i(mcs48_0_i.db), .db_o(mcu_db), .db_dir_o(), .t1_i(mcs48_0_i.t1),
    .p2_i(mcs48_0_i.p2_in), .p2_o(mcu_p2), .p2l_low_imp_o(), .p2h_low_imp_o(),
    .p1_i(mcs48_0_i.p1_in), .p1_o(mcu_p1), .p1_low_imp_o(), .prog_n_o(),
    .pmem_addr_o(mcu_pa), .pmem_data_i(mcs48_0_i.pmem_d)
);

assign mcs48_0_o.p1 = mcu_p1;  assign mcs48_0_o.p2 = mcu_p2;  assign mcs48_0_o.pmem_a = mcu_pa;
assign mcs48_0_o.rd_n = mcu_rd_n;  assign mcs48_0_o.wr_n = mcu_wr_n;  assign mcs48_0_o.ale = mcu_ale;  assign mcs48_0_o.db = mcu_db;

// t65_0 / t65_1: RP2A03 6502 cores, stock T65 (DK3 sound #1 / #2; the APUs are on the board, rtl/sound/rp2a03.sv)
chip_pool_pkg::t65_i_t t65_0_i, t65_1_i;
chip_pool_pkg::t65_o_t t65_0_o, t65_1_o;

wire [23:0] t65_0_a24, t65_1_a24;
T65 t65_0
(
    .Mode(2'b00), .Res_n(t65_0_i.res_n), .Enable(t65_0_i.enable), .Clk(clk), .Rdy(t65_0_i.rdy), .Abort_n(1'b1),
    .IRQ_n(t65_0_i.irq_n), .NMI_n(t65_0_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_0_o.rw), .Sync(), .EF(), .MF(), .XF(),
    .ML_n(), .VP_n(), .VDA(), .VPA(), .A(t65_0_a24), .DI(t65_0_i.di), .DO(t65_0_o.dout), .Regs(), .NMI_ack()
);
T65 t65_1
(
    .Mode(2'b00), .Res_n(t65_1_i.res_n), .Enable(t65_1_i.enable), .Clk(clk), .Rdy(t65_1_i.rdy), .Abort_n(1'b1),
    .IRQ_n(t65_1_i.irq_n), .NMI_n(t65_1_i.nmi_n), .SO_n(1'b1), .R_W_n(t65_1_o.rw), .Sync(), .EF(), .MF(), .XF(),
    .ML_n(), .VP_n(), .VDA(), .VPA(), .A(t65_1_a24), .DI(t65_1_i.di), .DO(t65_1_o.dout), .Regs(), .NMI_ack()
);
assign t65_0_o.a = t65_0_a24[15:0];
assign t65_1_o.a = t65_1_a24[15:0];

// i8257_0: Donkey Kong / DK Jr. / Radar Scope sprite DMA (8257, rtl/cpu/i8257.sv)
chip_pool_pkg::i8257_i_t i8257_0_i;
chip_pool_pkg::i8257_o_t i8257_0_o;
i8257 i8257_0
(
    .clk(clk), .reset(i8257_0_i.reset), .ce(i8257_0_i.ce), .rev_rw(i8257_0_i.rev_rw), .cs(i8257_0_i.cs), .a(i8257_0_i.a),
    .wr(i8257_0_i.wr), .rd(i8257_0_i.rd), .din(i8257_0_i.din), .drq(i8257_0_i.drq), .hlda(i8257_0_i.hlda),
    .mem_d(i8257_0_i.mem_d), .io_d(i8257_0_i.io_d), .dout(i8257_0_o.dout), .hrq(i8257_0_o.hrq), .addr(i8257_0_o.addr),
    .chan(i8257_0_o.chan), .busy(i8257_0_o.busy), .ior(i8257_0_o.ior), .iow(i8257_0_o.iow), .memr(i8257_0_o.memr),
    .memw(i8257_0_o.memw), .data(i8257_0_o.data)
);

// z80dma_0: Donkey Kong 3 / Mario Bros. sprite DMA (Z80 DMA, rtl/cpu/z80dma.sv)
chip_pool_pkg::z80dma_i_t dk3_z80dma_0_i, mar_z80dma_0_i, z80dma_0_i;
chip_pool_pkg::z80dma_o_t z80dma_0_o;
assign z80dma_0_i = is_dk3 ? dk3_z80dma_0_i : mar_z80dma_0_i;
z80dma z80dma_0
(
    .clk(clk), .reset(z80dma_0_i.reset), .cen_p(z80dma_0_i.cen_p), .cs(z80dma_0_i.cs), .wr(z80dma_0_i.wr), .rd(z80dma_0_i.rd),
    .din(z80dma_0_i.din), .rdy(z80dma_0_i.rdy), .bai(z80dma_0_i.bai), .bus_d(z80dma_0_i.bus_d), .dout(z80dma_0_o.dout),
    .busrq(z80dma_0_o.busrq), .busy(z80dma_0_o.busy), .addr(z80dma_0_o.addr), .mreq(z80dma_0_o.mreq),
    .iorq(z80dma_0_o.iorq), .memr(z80dma_0_o.memr), .memw_s(z80dma_0_o.memw_s), .data(z80dma_0_o.data)
);

// ay_0: Popeye / Sky Skipper AY-3-8910 (jotego jt49_bus)
chip_pool_pkg::ayr_i_t  ay_0_i;
chip_pool_pkg::ayio_o_t ay_0_o;
jt49_bus ay_0
(
    .clk(clk), .rst_n(ay_0_i.rst_n), .clk_en(ay_0_i.ce), .bdir(ay_0_i.bdir), .bc1(ay_0_i.bc1), .din(ay_0_i.din),
    .IOA_in(ay_0_i.ioa_in), .IOB_in(ay_0_i.iob_in), .dout(ay_0_o.dout), .A(ay_0_o.a), .B(ay_0_o.b), .C(ay_0_o.c),
    .IOA_out(ay_0_o.ioa_out), .IOB_out(ay_0_o.iob_out), .sound(ay_0_o.sound), .sel(1'b1), .sample()
);

// sn76477_0: Space Fever / Sheriff SN76477 (rtl/sound/sn76477.sv); output stage centre-to-peak = 150K / 47K
chip_pool_pkg::sn76477_i_t sn76477_0_i;
chip_pool_pkg::sn76477_o_t sn76477_0_o;
sn76477 #(.C2P(32'd20574012)) sn76477_0
(
    .clk(clk), .reset(sn76477_0_i.reset), .step(sn76477_0_i.step), .enable(sn76477_0_i.enable), .vco_sel(sn76477_0_i.vco_sel),
    .mixer(sn76477_0_i.mixer), .env(sn76477_0_i.env), .vco_v(sn76477_0_i.vco_v), .os_c(sn76477_0_i.os_c),
    .os_d(sn76477_0_i.os_d), .slf_c(sn76477_0_i.slf_c), .slf_d(sn76477_0_i.slf_d), .vco_c(sn76477_0_i.vco_c),
    .vco_d(sn76477_0_i.vco_d), .nf_c(sn76477_0_i.nf_c), .nf_d(sn76477_0_i.nf_d), .ad_c(sn76477_0_i.ad_c),
    .ad_d(sn76477_0_i.ad_d), .noise_f(sn76477_0_i.noise_f), .fs(sn76477_0_i.fs), .vout(sn76477_0_o.vout)
);

/////////////////////////////  Boards  /////////////////////////////
// the board not selected is held in reset; its outputs are muxed away

logic        dk_ce_pix, dk3_ce_pix, pop_ce_pix, mar_ce_pix, sfb_ce_pix, n80_ce_pix;
logic  [7:0] dk_r, dk_g, dk_b, dk3_r, dk3_g, dk3_b, pop_r, pop_g, pop_b, mar_r, mar_g, mar_b, sfb_r, sfb_g, sfb_b, n80_r, n80_g, n80_b;
logic        dk_hs, dk_vs, dk_hbl, dk_vbl, dk3_hs, dk3_vs, dk3_hbl, dk3_vbl, pop_hs, pop_vs, pop_hbl, pop_vbl, pop_fld;
logic        mar_hs, mar_vs, mar_hbl, mar_vbl, sfb_hs, sfb_vs, sfb_hbl, sfb_vbl, n80_hs, n80_vs, n80_hbl, n80_vbl;
logic signed [15:0] dk_audio, dk3_audio, pop_audio, mar_audio, sfb_audio, n80_audio;
logic  [7:0] dk_hs_out, dk3_hs_out, pop_hs_out, mar_hs_out, sfb_hs_out, n80_hs_out;

assign ce_pix       = is_dk3 ? dk3_ce_pix : is_pop ? pop_ce_pix : is_mar ? mar_ce_pix : is_sfb ? sfb_ce_pix : is_n80 ? n80_ce_pix : dk_ce_pix;
assign video_r      = is_dk3 ? dk3_r   : is_pop ? pop_r   : is_mar ? mar_r   : is_sfb ? sfb_r   : is_n80 ? n80_r : dk_r;
assign video_g      = is_dk3 ? dk3_g   : is_pop ? pop_g   : is_mar ? mar_g   : is_sfb ? sfb_g   : is_n80 ? n80_g : dk_g;
assign video_b      = is_dk3 ? dk3_b   : is_pop ? pop_b   : is_mar ? mar_b   : is_sfb ? sfb_b   : is_n80 ? n80_b : dk_b;
assign video_hs     = is_dk3 ? dk3_hs  : is_pop ? pop_hs  : is_mar ? mar_hs  : is_sfb ? sfb_hs  : is_n80 ? n80_hs : dk_hs;
assign video_vs     = is_dk3 ? dk3_vs  : is_pop ? pop_vs  : is_mar ? mar_vs  : is_sfb ? sfb_vs  : is_n80 ? n80_vs : dk_vs;
assign video_hblank = is_dk3 ? dk3_hbl : is_pop ? pop_hbl : is_mar ? mar_hbl : is_sfb ? sfb_hbl : is_n80 ? n80_hbl : dk_hbl;
assign video_vblank = is_dk3 ? dk3_vbl : is_pop ? pop_vbl : is_mar ? mar_vbl : is_sfb ? sfb_vbl : is_n80 ? n80_vbl : dk_vbl;
assign video_field  = is_pop & pop_fld;
assign audio        = is_dk3 ? dk3_audio : is_pop ? pop_audio : is_mar ? mar_audio : is_sfb ? sfb_audio : is_n80 ? n80_audio : dk_audio;
assign hs_data_out  = is_dk3 ? dk3_hs_out : is_pop ? pop_hs_out : is_mar ? mar_hs_out : is_sfb ? sfb_hs_out : is_n80 ? n80_hs_out : dk_hs_out;

// Donkey Kong (TKG-04) / Donkey Kong Jr.
dkong_board dkong
(
    .clk(clk), .reset(reset | is_dk3 | is_pop | is_mar | is_sfb | is_n80), .pause(pause), .crt_flip(crt_flip), .jr(variant == 8'd1), .radar(is_rs),
    .rom_dec(rom_dec),
    .z80pa_0_i(dk_z80pa_0_i), .z80pa_0_o(z80pa_0_o), .mcs48_0_i(dk_mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .in0(in0), .in1(in1), .in2(in2), .dsw0(dsw0), .dsw1(dsw1), .in2_snd_status(game_flags2[0]), .spr256(game_flags2[2]), .gfx1_8k(game_flags2[3]), .dial0(dial0), .dial1(dial1),
    .eep_cs(dk_eep_cs), .eep_clk(dk_eep_clk), .eep_di(dk_eep_di), .eep_do(eep_do),
    .rom_a(dk_rom_a), .rom_d(rom_d), .snd_pa(dk_snd_pa), .snd_pd(snd_pd), .snd_xa(dk_snd_xa), .snd_xd(snd_xd),
    .gfx1_a(dk_gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(dk_gfx2_a), .gfx2_d(gfx2_d),
    .pal_a(dk_pal_a), .prom_lo_d(prom_lo_q), .prom_hi_d(prom_hi_q), .cc_a(dk_cc_a), .prom_cc_d(prom_cc_q[3:0]),
    .gfx3_a(rs_gfx3_a), .gfx3_d(gfx3_q),
    .ce_pix(dk_ce_pix), .video_r(dk_r), .video_g(dk_g), .video_b(dk_b),
    .video_hs(dk_hs), .video_vs(dk_vs), .video_hblank(dk_hbl), .video_vblank(dk_vbl),
    .audio(dk_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(dk_hs_out), .hs_write(hs_write & ~is_dk3 & ~is_pop & ~is_mar & ~is_sfb & ~is_n80),
    .i8257_0_i(i8257_0_i), .i8257_0_o(i8257_0_o),
    .pr_i(dk_pr_i), .pr_o(pr_o)
);

// Donkey Kong 3 (DKC1)
dkong3_board dkong3
(
    .clk(clk), .reset(reset | ~is_dk3), .pause(pause), .crt_flip(crt_flip),
    .rom_dec(rom_dec), .eep_cs(dk3_eep_cs), .eep_clk(dk3_eep_clk), .eep_di(dk3_eep_di), .eep_do(eep_do),
    .z80pa_0_i(dk3_z80pa_0_i), .z80pa_0_o(z80pa_0_o),
    .t65_0_i(t65_0_i), .t65_0_o(t65_0_o), .t65_1_i(t65_1_i), .t65_1_o(t65_1_o),
    .in0(in0), .in1(in1), .dsw0(dsw0), .dsw1(dsw1),
    .rom_a(dk3_rom_a), .rom_d(rom_d), .snd1_a(dk3_snd1_a), .snd1_d(snd_xd), .snd2_a(dk3_snd2_a), .snd2_d(snd2_d),
    .gfx1_a(dk3_gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(dk3_gfx2_a), .gfx2_d(gfx2_d),
    .pal_a(dk3_pal_a), .prom_lo_d(prom_lo_q), .prom_hi_d(prom_hi_q), .cc_a(dk3_cc_a), .prom_cc_d(prom_cc_q[3:0]),
    .ce_pix(dk3_ce_pix), .video_r(dk3_r), .video_g(dk3_g), .video_b(dk3_b),
    .video_hs(dk3_hs), .video_vs(dk3_vs), .video_hblank(dk3_hbl), .video_vblank(dk3_vbl),
    .audio(dk3_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(dk3_hs_out), .hs_write(hs_write & is_dk3),
    .z80dma_0_i(dk3_z80dma_0_i), .z80dma_0_o(z80dma_0_o),
    .pr_i(dk3_pr_i), .pr_o(pr_o)
);

// Popeye (TPP2-CPU / TPP2-VIDEO)
popeye_board popeye
(
    .clk(clk), .reset(reset | ~is_pop), .pause(pause), .crt_flip(crt_flip), .tnx1(is_sky),
    .z80pa_0_i(pop_z80pa_0_i), .z80pa_0_o(z80pa_0_o),
    .in0(in0), .in1(in1), .in2(in2), .dsw0(dsw0), .dsw1(dsw1),
    .rom_a(pop_rom_a), .rom_d(rom_d), .gfx1_a(pop_gfx1_a), .gfx1_d(gfx1_d), .prom_a(pop_cc_a), .prom_d(prom_cc_q),
    .gfx2_a(pop_gfx2_a), .gfx2_d(gfx2_d), .spal_a(pop_pal_a), .spal_lo(prom_lo_q[3:0]), .spal_hi(prom_hi_q[3:0]),
    .ce_pix(pop_ce_pix), .video_r(pop_r), .video_g(pop_g), .video_b(pop_b),
    .video_hs(pop_hs), .video_vs(pop_vs), .video_hblank(pop_hbl), .video_vblank(pop_vbl), .video_field(pop_fld),
    .audio(pop_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(pop_hs_out), .hs_write(hs_write & is_pop),
    .ay_0_i(ay_0_i), .ay_0_o(ay_0_o),
    .pr_i(pop_pr_i), .pr_o(pr_o)
);

// Mario Bros. (TMA1-CPU / TMA1-VIDEO)
mario_board mario
(
    .clk(clk), .reset(reset | ~is_mar), .pause(pause), .crt_flip(crt_flip),
    .z80pa_0_i(mar_z80pa_0_i), .z80pa_0_o(z80pa_0_o), .mcs48_0_i(mar_mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .in0(in0), .in1(in1), .dsw0(dsw0),
    .snd_pa(mar_snd_pa), .snd_pd(snd_pd), .snd_xa(mar_snd_xa), .snd_xd(snd_xd),
    .rom_a(mar_rom_a), .rom_d(rom_d), .gfx1_a(mar_gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(mar_gfx2_a), .gfx2_d(gfx2_d),
    .pal_a(mar_pal_a), .prom_d(prom_lo_q),
    .ce_pix(mar_ce_pix), .video_r(mar_r), .video_g(mar_g), .video_b(mar_b),
    .video_hs(mar_hs), .video_vs(mar_vs), .video_hblank(mar_hbl), .video_vblank(mar_vbl),
    .audio(mar_audio), .mul_a(mar_mul_a), .mul_b(mar_mul_b), .mul_p(mul_p),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(mar_hs_out), .hs_write(hs_write & is_mar),
    .z80dma_0_i(mar_z80dma_0_i), .z80dma_0_o(z80dma_0_o),
    .pr_i(mar_pr_i), .pr_o(pr_o)
);

// Space Firebird (TST-CPU / TST-VIDEO)
spacefb_board spacefb
(
    .clk(clk), .reset(reset | ~is_sfb), .pause(pause), .crt_flip(crt_flip),
    .z80pa_0_i(sfb_z80pa_0_i), .z80pa_0_o(z80pa_0_o), .mcs48_0_i(sfb_mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .in0(in0), .in1(in1), .in2(in2), .dsw0(dsw0),
    .rom_a(sfb_rom_a), .rom_d(rom_d), .gfx2_a(sfb_gfx2_a), .gfx2_d(gfx2_d), .gfx1_a(sfb_gfx1_a), .gfx1_d(gfx1_d),
    .pal_a(sfb_pal_a), .pal_d(prom_lo_q), .snd_pa(sfb_snd_pa), .snd_pd(snd_pd),
    .ce_pix(sfb_ce_pix), .video_r(sfb_r), .video_g(sfb_g), .video_b(sfb_b),
    .video_hs(sfb_hs), .video_vs(sfb_vs), .video_hblank(sfb_hbl), .video_vblank(sfb_vbl),
    .audio(sfb_audio), .mul_a(sfb_mul_a), .mul_b(sfb_mul_b), .mul_p(mul_p),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(sfb_hs_out), .hs_write(hs_write & is_sfb),
    .pr_i(sfb_pr_i), .pr_o(pr_o)
);

// Nintendo 8080 boards (Space Fever family, Sheriff, HeliFire): the 8080 code runs on the pooled Z80
n8080_board n8080
(
    .clk(clk), .reset(reset | ~is_n80), .pause(pause), .crt_flip(crt_flip), .sfev(variant == 8'd8), .hf(variant == 8'd10),
    .z80pa_0_i(n80_z80pa_0_i), .z80pa_0_o(z80pa_0_o), .mcs48_0_i(n80_mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .in0(in0), .in1(in1), .in2(in2), .in3(dsw0),
    .rom_a(n80_rom_a), .rom_d(rom_d), .prom_a(n80_gfx1_a), .prom_d(gfx1_d), .snd_pa(n80_snd_pa), .snd_pd(snd_pd),
    .ce_pix(n80_ce_pix), .video_r(n80_r), .video_g(n80_g), .video_b(n80_b),
    .video_hs(n80_hs), .video_vs(n80_vs), .video_hblank(n80_hbl), .video_vblank(n80_vbl),
    .audio(n80_audio), .mul_a(n80_mul_a), .mul_b(n80_mul_b), .mul_p(mul_p),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(n80_hs_out), .hs_write(hs_write & is_n80),
    .sn76477_0_i(sn76477_0_i), .sn76477_0_o(sn76477_0_o),
    .pr_i(n80_pr_i), .pr_o(pr_o)
);

endmodule
