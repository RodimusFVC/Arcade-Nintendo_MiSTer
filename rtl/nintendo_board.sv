//============================================================================
//
//  Nintendo early arcade hardware — board top
//  Copyright (C) 2026 Rodimus
//
//  Variant 0: Donkey Kong, TKG-04 two-board set (MAME dkong.cpp dkong2b: dkong, dkongo, dkongj..., hacks)
//  Variant 1: Donkey Kong Jr. (MAME dkongjr)
//  Variant 2: Donkey Kong 3 (MAME dkong3)
//  Variant 3: Popeye, TPP2 boards (MAME popeye.cpp tpp2_state / tpp2_noalu_state)
//  Variant 4: Mario Bros. (MAME mario.cpp mario_state)
//  Variant 5: Space Firebird (MAME spacefb.cpp spacefb / spacedem)
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
//  Mario: maincpu 0x00000 (F000-FFFF at 0x6000), soundrom 0x08000 (4K), gfx1 0x10000 (8K), proms 0x12000 (4P, 512),
//    gfx2 0x18000 (24K)
//  Space Firebird: maincpu 0x00000 (16K), audiocpu 0x08000 (1K), sprites 0x0C000 (5K 0x000 / 6K 0x800), bullets
//    0x10000 (4I, 256), proms 0x12000 (3N colour, 32)
//
//============================================================================

module nintendo_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic  [7:0] variant,
    input  logic  [7:0] game_flags2,    // [0] IN2 bit 6 = sound CPU status
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
wire load_snd  = ioctl_wr0 && ioctl_addr[24:13] == 12'h004;        // 0x08000-0x09FFF
wire load_snd2 = ioctl_wr0 && ioctl_addr[24:13] == 12'h005;        // 0x0A000-0x0BFFF
wire load_gfx2 = ioctl_wr0 && ioctl_addr[24:14] == 11'h003;        // 0x0C000-0x0FFFF
wire load_gfx2p = ioctl_wr0 && ioctl_addr[24:15] == 10'h003;       // 0x18000-0x1FFFF (Popeye, 32K)
wire load_gfx1 = ioctl_wr0 && ioctl_addr[24:13] == 12'h008;        // 0x10000-0x11FFF
wire load_prom = ioctl_wr0 && ioctl_addr[24:11] == 14'h0024;       // 0x12000-0x127FF

wire is_dk3 = variant == 8'd2;
wire is_pop = variant == 8'd3;
wire is_mar = variant == 8'd4;
wire is_sfb = variant == 8'd5;

logic [14:0] rom_a, dk_rom_a, dk3_rom_a, pop_rom_a, mar_rom_a, sfb_rom_a;
logic  [7:0] rom_d;
logic [11:0] snd_pa, dk_snd_pa, mar_snd_pa, sfb_snd_pa;
logic [12:0] snd_xa, dk_snd_xa, dk3_snd1_a, dk3_snd2_a, mar_snd_xa;
assign snd_pa = is_mar ? mar_snd_pa : is_sfb ? sfb_snd_pa : dk_snd_pa;
logic  [7:0] snd_pd, snd_xd, snd2_d;
assign snd_xa = is_dk3 ? dk3_snd1_a : is_mar ? mar_snd_xa : dk_snd_xa;
logic [12:0] gfx1_a, dk_gfx1_a, dk3_gfx1_a, mar_gfx1_a, sfb_gfx1_a;
logic [10:0] pop_gfx1_a;
logic [14:0] gfx2_a, dk_gfx2_a, dk3_gfx2_a, pop_gfx2_a, mar_gfx2_a, sfb_gfx2_a;
logic  [7:0] gfx1_d, gfx2_d;
logic  [7:0] pal_a, cc_a, dk_pal_a, dk3_pal_a, dk_cc_a, dk3_cc_a, pop_cc_a, pop_pal_a, mar_pal_a, sfb_pal_a;
logic  [7:0] prom_lo_q, prom_hi_q, prom_cc_q;
assign rom_a  = is_dk3 ? dk3_rom_a  : is_pop ? pop_rom_a : is_mar ? mar_rom_a : is_sfb ? sfb_rom_a : dk_rom_a;
assign gfx1_a = is_dk3 ? dk3_gfx1_a : is_pop ? {2'b00, pop_gfx1_a} : is_mar ? mar_gfx1_a : is_sfb ? sfb_gfx1_a : dk_gfx1_a;
assign gfx2_a = is_dk3 ? dk3_gfx2_a : is_pop ? pop_gfx2_a : is_mar ? mar_gfx2_a : is_sfb ? sfb_gfx2_a : dk_gfx2_a;
assign pal_a  = is_dk3 ? dk3_pal_a  : is_pop ? pop_pal_a : is_mar ? mar_pal_a : is_sfb ? sfb_pal_a : dk_pal_a;
assign cc_a   = is_dk3 ? dk3_cc_a   : is_pop ? pop_cc_a : dk_cc_a;

dpram_dc #(.widthad_a(15)) rom_cpu
(
    .clock_a(clk), .address_a(ioctl_addr[14:0]), .data_a(ioctl_dout), .wren_a(load_cpu),
    .clock_b(clk), .address_b(rom_a), .q_b(rom_d)
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

dpram_dc #(.widthad_a(13)) rom_gfx1
(
    .clock_a(clk), .address_a(ioctl_addr[12:0]), .data_a(ioctl_dout), .wren_a(load_gfx1),
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

/////////////////////////////  Shared CPU / sound chip pool  /////////////////////////////
// One board runs at a time: each CPU is instanced once and driven by the active board (rtl/chip_pool_pkg.sv).

// z80pa_0: main CPU (DK / DK Jr. at 1H, DK3 at 4 MHz)
chip_pool_pkg::z80pa_i_t dk_z80pa_0_i, dk3_z80pa_0_i, pop_z80pa_0_i, mar_z80pa_0_i, sfb_z80pa_0_i, z80pa_0_i;
chip_pool_pkg::z80pa_o_t z80pa_0_o;
assign z80pa_0_i = is_dk3 ? dk3_z80pa_0_i : is_pop ? pop_z80pa_0_i : is_mar ? mar_z80pa_0_i : is_sfb ? sfb_z80pa_0_i :
                   dk_z80pa_0_i;

wire [15:0] z80pa_0_a;
wire  [7:0] z80pa_0_do;
wire        z80pa_0_m1_n, z80pa_0_mreq_n, z80pa_0_iorq_n, z80pa_0_rd_n, z80pa_0_wr_n, z80pa_0_rfsh_n, z80pa_0_busak_n;

T80pa #(.Mode(0)) z80pa_0
(
    .RESET_n (z80pa_0_i.reset_n), .CLK(clk), .CEN_p(z80pa_0_i.cen_p), .CEN_n(z80pa_0_i.cen_n),
    .WAIT_n  (z80pa_0_i.wait_n), .INT_n(z80pa_0_i.int_n), .NMI_n(z80pa_0_i.nmi_n), .BUSRQ_n(z80pa_0_i.busrq_n),
    .M1_n(z80pa_0_m1_n), .MREQ_n(z80pa_0_mreq_n), .IORQ_n(z80pa_0_iorq_n), .RD_n(z80pa_0_rd_n), .WR_n(z80pa_0_wr_n),
    .RFSH_n(z80pa_0_rfsh_n), .HALT_n(), .BUSAK_n(z80pa_0_busak_n), .OUT0(1'b0), .A(z80pa_0_a), .DI(z80pa_0_i.di),
    .DO(z80pa_0_do), .R800_mode(1'b0), .REG(), .DIRSet(1'b0), .DIR(212'd0)
);

assign z80pa_0_o.a = z80pa_0_a;           assign z80pa_0_o.dout = z80pa_0_do;
assign z80pa_0_o.m1_n = z80pa_0_m1_n;     assign z80pa_0_o.mreq_n = z80pa_0_mreq_n; assign z80pa_0_o.iorq_n = z80pa_0_iorq_n;
assign z80pa_0_o.rd_n = z80pa_0_rd_n;     assign z80pa_0_o.wr_n = z80pa_0_wr_n;     assign z80pa_0_o.rfsh_n = z80pa_0_rfsh_n;
assign z80pa_0_o.busak_n = z80pa_0_busak_n;

// mcs48_0: Donkey Kong / Mario Bros. / Space Firebird sound CPU (8035 / 8039; T48 t8039_notri_extrom, Arnim Laeuger)
chip_pool_pkg::mcs48_i_t dk_mcs48_0_i, mar_mcs48_0_i, sfb_mcs48_0_i, mcs48_0_i;
chip_pool_pkg::mcs48_o_t mcs48_0_o;
assign mcs48_0_i = is_mar ? mar_mcs48_0_i : is_sfb ? sfb_mcs48_0_i : dk_mcs48_0_i;

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

// t65_0 / t65_1: RP2A03 6502 cores (DK3 sound #1 / #2; the APUs are on the board, rtl/sound/rp2a03.sv)
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

/////////////////////////////  Boards  /////////////////////////////
// the board not selected is held in reset; its outputs are muxed away

logic        dk_ce_pix, dk3_ce_pix, pop_ce_pix, mar_ce_pix, sfb_ce_pix;
logic  [7:0] dk_r, dk_g, dk_b, dk3_r, dk3_g, dk3_b, pop_r, pop_g, pop_b, mar_r, mar_g, mar_b, sfb_r, sfb_g, sfb_b;
logic        dk_hs, dk_vs, dk_hbl, dk_vbl, dk3_hs, dk3_vs, dk3_hbl, dk3_vbl, pop_hs, pop_vs, pop_hbl, pop_vbl, pop_fld;
logic        mar_hs, mar_vs, mar_hbl, mar_vbl, sfb_hs, sfb_vs, sfb_hbl, sfb_vbl;
logic signed [15:0] dk_audio, dk3_audio, pop_audio, mar_audio, sfb_audio;
logic  [7:0] dk_hs_out, dk3_hs_out, pop_hs_out, mar_hs_out, sfb_hs_out;

assign ce_pix       = is_dk3 ? dk3_ce_pix : is_pop ? pop_ce_pix : is_mar ? mar_ce_pix : is_sfb ? sfb_ce_pix : dk_ce_pix;
assign video_r      = is_dk3 ? dk3_r   : is_pop ? pop_r   : is_mar ? mar_r   : is_sfb ? sfb_r   : dk_r;
assign video_g      = is_dk3 ? dk3_g   : is_pop ? pop_g   : is_mar ? mar_g   : is_sfb ? sfb_g   : dk_g;
assign video_b      = is_dk3 ? dk3_b   : is_pop ? pop_b   : is_mar ? mar_b   : is_sfb ? sfb_b   : dk_b;
assign video_hs     = is_dk3 ? dk3_hs  : is_pop ? pop_hs  : is_mar ? mar_hs  : is_sfb ? sfb_hs  : dk_hs;
assign video_vs     = is_dk3 ? dk3_vs  : is_pop ? pop_vs  : is_mar ? mar_vs  : is_sfb ? sfb_vs  : dk_vs;
assign video_hblank = is_dk3 ? dk3_hbl : is_pop ? pop_hbl : is_mar ? mar_hbl : is_sfb ? sfb_hbl : dk_hbl;
assign video_vblank = is_dk3 ? dk3_vbl : is_pop ? pop_vbl : is_mar ? mar_vbl : is_sfb ? sfb_vbl : dk_vbl;
assign video_field  = is_pop & pop_fld;
assign audio        = is_dk3 ? dk3_audio : is_pop ? pop_audio : is_mar ? mar_audio : is_sfb ? sfb_audio : dk_audio;
assign hs_data_out  = is_dk3 ? dk3_hs_out : is_pop ? pop_hs_out : is_mar ? mar_hs_out : is_sfb ? sfb_hs_out : dk_hs_out;

// Donkey Kong (TKG-04) / Donkey Kong Jr.
dkong_board dkong
(
    .clk(clk), .reset(reset | is_dk3 | is_pop | is_mar | is_sfb), .pause(pause), .crt_flip(crt_flip), .jr(variant == 8'd1),
    .z80pa_0_i(dk_z80pa_0_i), .z80pa_0_o(z80pa_0_o), .mcs48_0_i(dk_mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .in0(in0), .in1(in1), .in2(in2), .dsw0(dsw0), .in2_snd_status(game_flags2[0]),
    .rom_a(dk_rom_a), .rom_d(rom_d), .snd_pa(dk_snd_pa), .snd_pd(snd_pd), .snd_xa(dk_snd_xa), .snd_xd(snd_xd),
    .gfx1_a(dk_gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(dk_gfx2_a), .gfx2_d(gfx2_d),
    .pal_a(dk_pal_a), .prom_lo_d(prom_lo_q), .prom_hi_d(prom_hi_q), .cc_a(dk_cc_a), .prom_cc_d(prom_cc_q[3:0]),
    .ce_pix(dk_ce_pix), .video_r(dk_r), .video_g(dk_g), .video_b(dk_b),
    .video_hs(dk_hs), .video_vs(dk_vs), .video_hblank(dk_hbl), .video_vblank(dk_vbl),
    .audio(dk_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(dk_hs_out), .hs_write(hs_write & ~is_dk3 & ~is_pop & ~is_mar & ~is_sfb)
);

// Donkey Kong 3 (DKC1)
dkong3_board dkong3
(
    .clk(clk), .reset(reset | ~is_dk3), .pause(pause), .crt_flip(crt_flip),
    .z80pa_0_i(dk3_z80pa_0_i), .z80pa_0_o(z80pa_0_o),
    .t65_0_i(t65_0_i), .t65_0_o(t65_0_o), .t65_1_i(t65_1_i), .t65_1_o(t65_1_o),
    .in0(in0), .in1(in1), .dsw0(dsw0), .dsw1(dsw1),
    .rom_a(dk3_rom_a), .rom_d(rom_d), .snd1_a(dk3_snd1_a), .snd1_d(snd_xd), .snd2_a(dk3_snd2_a), .snd2_d(snd2_d),
    .gfx1_a(dk3_gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(dk3_gfx2_a), .gfx2_d(gfx2_d),
    .pal_a(dk3_pal_a), .prom_lo_d(prom_lo_q), .prom_hi_d(prom_hi_q), .cc_a(dk3_cc_a), .prom_cc_d(prom_cc_q[3:0]),
    .ce_pix(dk3_ce_pix), .video_r(dk3_r), .video_g(dk3_g), .video_b(dk3_b),
    .video_hs(dk3_hs), .video_vs(dk3_vs), .video_hblank(dk3_hbl), .video_vblank(dk3_vbl),
    .audio(dk3_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(dk3_hs_out), .hs_write(hs_write & is_dk3)
);

// Popeye (TPP2-CPU / TPP2-VIDEO)
popeye_board popeye
(
    .clk(clk), .reset(reset | ~is_pop), .pause(pause), .crt_flip(crt_flip),
    .z80pa_0_i(pop_z80pa_0_i), .z80pa_0_o(z80pa_0_o),
    .in0(in0), .in1(in1), .in2(in2), .dsw0(dsw0), .dsw1(dsw1),
    .rom_a(pop_rom_a), .rom_d(rom_d), .gfx1_a(pop_gfx1_a), .gfx1_d(gfx1_d), .prom_a(pop_cc_a), .prom_d(prom_cc_q),
    .gfx2_a(pop_gfx2_a), .gfx2_d(gfx2_d), .spal_a(pop_pal_a), .spal_lo(prom_lo_q[3:0]), .spal_hi(prom_hi_q[3:0]),
    .ce_pix(pop_ce_pix), .video_r(pop_r), .video_g(pop_g), .video_b(pop_b),
    .video_hs(pop_hs), .video_vs(pop_vs), .video_hblank(pop_hbl), .video_vblank(pop_vbl), .video_field(pop_fld),
    .audio(pop_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(pop_hs_out), .hs_write(hs_write & is_pop)
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
    .audio(mar_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(mar_hs_out), .hs_write(hs_write & is_mar)
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
    .audio(sfb_audio),
    .hs_address(hs_address), .hs_data_in(hs_data_in), .hs_data_out(sfb_hs_out), .hs_write(hs_write & is_sfb)
);

endmodule
