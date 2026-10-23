//============================================================================
//
//  Nintendo Donkey Kong 3 board (DKC1-CPU / DKC1-Video; MAME dkong.cpp dkong3)
//  Copyright (C) 2026 Rodimus
//
//  Main Z80 at 4 MHz from its own 8 MHz crystal (LS74 3H / 2; DKC1-CPU sheet), not the video's 1H. A Z80 DMA
//  (z80dma.sv, same 4 MHz clock) copies the sprite list 6900 -> 7000 every frame (burst, 0x1A0 bytes, RDY = 7E85).
//  Memory map (MAME dkong3_map):
//    0000-5FFF ROM   6000-6FFF RAM   7000-73FF object RAM (two 0x200 banks)   7400-77FF video RAM   8000-9FFF ROM
//    7C00 R IN0 / W sound latch 1   7C80 R IN1 / W sound latch 2   7D00 R DSW0 / W sound latch 3
//    7D80 R DSW1 / W bit 0 = 2A03 reset (low = held)
//    7E80-7E87 (data bit 0): 0 coin counter, 1 char bank (inverted), 2 flip, 3 sprite bank, 4 NMI mask, 5 DMA RDY,
//                            6-7 palette bank
//    I/O port 00: Z80 DMA
//  Video = dkong_video.sv in DK3 mode (TKG-04 timing; DKC1-Video is the same raster logic).
//  Sound: two RP2A03 (pooled T65 cores + rp2a03.sv) on their own 21.477 MHz crystal (CPU = / 12), NMI = VBLANK,
//    held in reset while 7D80 bit 0 = 0. Each: 0000-07FF RAM (mirrored to 7FFF), 8000-9FFF ROM (mirrored to FFFF),
//    $4016 / $4017 = sound latch 1 / 2 (#1), latch 3 / none (#2). AUX A / B of both chips (100 Ohm pad loads) are
//    summed with equal weights into the LM3900 chain (6P; mixing resistors not legible on the 150 dpi scan), DC-blocked.
//
//============================================================================

module dkong3_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,
    output chip_pool_pkg::t65_i_t   t65_0_i,        // RP2A03 #1 (5J)
    input  chip_pool_pkg::t65_o_t   t65_0_o,
    output chip_pool_pkg::t65_i_t   t65_1_i,        // RP2A03 #2
    input  chip_pool_pkg::t65_o_t   t65_1_o,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] dsw0,
    input  logic  [7:0] dsw1,

    // ROMs (shared blocks in rtl/nintendo_board.sv)
    output logic [14:0] rom_a,          // 8000-9FFF read at ROM 6000 (MRA placement)
    input  logic  [7:0] rom_d,
    output logic [12:0] snd1_a,         // 2A03 #1 ROM (soundcpu slot)
    input  logic  [7:0] snd1_d,
    output logic [12:0] snd2_a,         // 2A03 #2 ROM
    input  logic  [7:0] snd2_d,
    output logic [12:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] pal_a,          // proms 0x000 1d, 0x200 1c (first 256 of each, as MAME)
    input  logic  [7:0] prom_lo_d,
    input  logic  [7:0] prom_hi_d,
    output logic  [7:0] cc_a,
    input  logic  [3:0] prom_cc_d,      // proms 0x400 2n

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
    input  logic        hs_write
);

wire run = ~pause;

// ------------------------------------------------------------------ 4 MHz CPU clock: 8 MHz edges from a phase accumulator
logic [15:0] ph_acc = 16'd0;
logic        phi = 1'b0;
logic        cen_p, cen_n;
always_ff @(posedge clk) begin
    cen_p <= 1'b0; cen_n <= 1'b0;
    if (ph_acc + 16'd8000 >= 16'd49152) begin
        ph_acc <= ph_acc + 16'd8000 - 16'd49152;
        phi <= ~phi;
        if (!phi) cen_p <= 1'b1; else cen_n <= 1'b1;
    end else ph_acc <= ph_acc + 16'd8000;
end

logic vram_busy, vblk;

// ------------------------------------------------------------------ Z80
wire [15:0] cpu_a    = z80pa_0_o.a;
wire        mreq     = ~z80pa_0_o.mreq_n;
wire        iorq     = ~z80pa_0_o.iorq_n;
wire        m1       = ~z80pa_0_o.m1_n;
wire        rd       = ~z80pa_0_o.rd_n;
wire        wr       = ~z80pa_0_o.wr_n;
wire        rfsh     = ~z80pa_0_o.rfsh_n;
wire        busak    = ~z80pa_0_o.busak_n;

logic wr_q = 1'b0, rd_q = 1'b0, iow_q = 1'b0, ior_q = 1'b0;
always_ff @(posedge clk) begin wr_q <= wr & mreq; rd_q <= rd & mreq; iow_q <= wr & iorq; ior_q <= rd & iorq; end
wire cpu_we = wr & mreq & ~wr_q;        // one clock per write cycle
wire io_we  = wr & iorq & ~m1 & ~iow_q;
wire io_re  = rd & iorq & ~m1 & ~ior_q;

// ------------------------------------------------------------------ Z80 DMA (I/O port 00)
logic [15:0] dma_a;
logic  [7:0] dma_dout, dma_data, mem_q;
logic        dma_busrq, dma_busy, dma_mreq, dma_memw;
logic        dma_rdy;
wire         dma_cs = iorq && !m1 && cpu_a[7:0] == 8'h00 && !busak;

z80dma dma
(
    .clk(clk), .reset(reset), .cen_p(cen_p & run),
    .cs(dma_cs), .wr(io_we), .rd(io_re), .din(z80pa_0_o.dout), .dout(dma_dout),
    .rdy(dma_rdy), .busrq(dma_busrq), .bai(busak),
    .busy(dma_busy), .addr(dma_a), .mreq(dma_mreq), .iorq(), .memr(), .memw_s(dma_memw), .bus_d(mem_q), .data(dma_data)
);

// ------------------------------------------------------------------ bus (CPU or DMA)
wire        dma_own = dma_busy & busak;
wire [15:0] bus_a   = dma_own ? dma_a : cpu_a;
wire        bus_we  = dma_own ? dma_memw & dma_mreq : cpu_we;
wire  [7:0] bus_d   = dma_own ? dma_data : z80pa_0_o.dout;

wire sel_rom  = bus_a < 16'h6000 || bus_a[15:13] == 3'b100;           // 0000-5FFF, 8000-9FFF
wire sel_ram  = bus_a[15:12] == 4'h6;
wire sel_obj  = bus_a[15:10] == 6'b011100;                         // 7000-73FF
wire sel_vram = bus_a[15:10] == 6'b011101;                         // 7400-77FF
wire sel_io   = bus_a[15:10] == 6'b011111;                         // 7C00-7FFF

logic [7:0] ram_q, vram_q, obj_q;
logic [31:0] spr_d;
logic  [7:0] spr_a;
logic  [9:0] vram_va;
logic  [7:0] vram_vd;

dpram_dc #(.widthad_a(12)) ram
(
    .clock_a(clk), .address_a(bus_a[11:0]), .data_a(bus_d), .wren_a(bus_we & sel_ram), .q_a(ram_q),
    .clock_b(clk), .address_b(hs_address[11:0]), .data_b(hs_data_in), .wren_b(hs_write & pause), .q_b(hs_data_out)
);

dpram_dc #(.widthad_a(10)) vram
(
    .clock_a(clk), .address_a(bus_a[9:0]), .data_a(bus_d), .wren_a(bus_we & sel_vram), .q_a(vram_q),
    .clock_b(clk), .address_b(vram_va), .q_b(vram_vd)
);

// object RAM as four byte lanes: one 32-bit sprite entry per video read
logic [7:0] obj_lane_q[4];
genvar ln;
generate
    for (ln = 0; ln < 4; ln++) begin : objl
        dpram_dc #(.widthad_a(8)) obj
        (
            .clock_a(clk), .address_a(bus_a[9:2]), .data_a(bus_d), .wren_a(bus_we & sel_obj & (bus_a[1:0] == ln)),
            .q_a(obj_lane_q[ln]),
            .clock_b(clk), .address_b(spr_a), .q_b(spr_d[ln*8 +: 8])
        );
    end
endgenerate
logic [1:0] obj_lane;
always_ff @(posedge clk) obj_lane <= bus_a[1:0];
assign obj_q = obj_lane_q[obj_lane];

// ------------------------------------------------------------------ latches
logic [7:0] snd_lat1, snd_lat2, snd_lat3, lat_7e8;
logic       snd_run;
always_ff @(posedge clk) begin
    if (reset) begin
        snd_lat1 <= 8'd0; snd_lat2 <= 8'd0; snd_lat3 <= 8'd0; lat_7e8 <= 8'd0; snd_run <= 1'b0;
    end else if (cpu_we && !dma_own && sel_io) begin
        case (cpu_a[9:7])
            3'd0: snd_lat1 <= z80pa_0_o.dout;
            3'd1: snd_lat2 <= z80pa_0_o.dout;
            3'd2: snd_lat3 <= z80pa_0_o.dout;
            3'd3: snd_run  <= z80pa_0_o.dout[0];
            3'd5: lat_7e8[cpu_a[2:0]] <= z80pa_0_o.dout[0];
            default: ;
        endcase
    end
end

wire       gfx_bank  = ~lat_7e8[1];
wire       flip      = lat_7e8[2];
wire       spr_bank  = lat_7e8[3];
wire       nmi_mask  = lat_7e8[4];
assign     dma_rdy   = lat_7e8[5];
wire [1:0] pal_bank  = lat_7e8[7:6];

// NMI: VBLK edge sets it while the mask is on
logic nmi_q = 1'b0, vblk_q = 1'b0;
always_ff @(posedge clk) begin
    vblk_q <= vblk;
    if (reset || !nmi_mask) nmi_q <= 1'b0;
    else if (vblk && !vblk_q) nmi_q <= 1'b1;
end

// /WAIT: VRAM access while the video board is fetching (LS74 2D clocked by the CPU clock, cleared in VBLK)
logic wait_q = 1'b0;
always_ff @(posedge clk) begin
    if (reset) wait_q <= 1'b0;
    else if (cen_n && run) wait_q <= (mreq | rd | wr) && !rfsh && !busak && cpu_a[15:10] == 6'b011101 && vram_busy && !vblk;
`ifdef SIM_NO_VRAM_WAIT
    wait_q <= 1'b0;                     // sim only: MAME has no VRAM wait states (compare runs)
`endif
end

// ------------------------------------------------------------------ CPU read data
logic [7:0] io_q;
always_comb begin
    case (cpu_a[8:7])
        2'd0: io_q = in0;
        2'd1: io_q = in1;
        2'd2: io_q = dsw0;
        2'd3: io_q = dsw1;
    endcase
end

assign rom_a = bus_a[15] ? {2'b11, bus_a[12:0]} : bus_a[14:0];

always_comb begin
    if (iorq && !m1)    z80pa_0_i.di = dma_dout;
    else if (sel_rom)   z80pa_0_i.di = rom_d;
    else if (sel_ram)   z80pa_0_i.di = ram_q;
    else if (sel_obj)   z80pa_0_i.di = obj_q;
    else if (sel_vram)  z80pa_0_i.di = vram_q;
    else if (sel_io)    z80pa_0_i.di = io_q;
    else                z80pa_0_i.di = 8'hFF;
end
assign mem_q = sel_ram ? ram_q : sel_obj ? obj_q : sel_vram ? vram_q : sel_rom ? rom_d : 8'hFF;

assign z80pa_0_i.reset_n = ~reset;
assign z80pa_0_i.cen_p   = cen_p & run;
assign z80pa_0_i.cen_n   = cen_n & run;
assign z80pa_0_i.wait_n  = ~wait_q;
assign z80pa_0_i.int_n   = 1'b1;
assign z80pa_0_i.nmi_n   = ~nmi_q;
assign z80pa_0_i.busrq_n = ~dma_busrq;

// ------------------------------------------------------------------ video
dkong_video video
(
    .clk(clk), .reset(reset),
    .flip(flip), .sprite_bank(spr_bank), .palette_bank(pal_bank), .gfx_bank(gfx_bank), .gfx1_8k(1'b1), .dk3(1'b1), .mario(1'b0), .scroll_y(8'd0),
    .crt_flip(crt_flip),
    .ce_pix(ce_pix), .cpu_cen_p(), .cpu_cen_n(), .vram_busy(vram_busy), .vblank_hw(vblk),
    .vram_a(vram_va), .vram_d(vram_vd), .spr_a(spr_a), .spr_d(spr_d),
    .gfx1_a(gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(gfx2_a), .gfx2_d(gfx2_d),
    .cprom_a(cc_a), .cprom_d(prom_cc_d), .pal_a(pal_a), .pal_lo_d(prom_lo_d), .pal_hi_d(prom_hi_d),
    .r(video_r), .g(video_g), .b(video_b), .hblank(video_hblank), .vblank(video_vblank), .hsync(video_hs), .vsync(video_vs)
);

// ------------------------------------------------------------------ sound: two RP2A03
// CPU clock 21477272 / 12 = 1789773 Hz from the 49.152 MHz system clock
logic [25:0] apu_acc = 26'd0;
logic        apu_ce = 1'b0;
always_ff @(posedge clk) begin
    apu_ce <= 1'b0;
    if (run) begin
        if (apu_acc + 26'd1789773 >= 26'd49152000) begin apu_acc <= apu_acc + 26'd1789773 - 26'd49152000; apu_ce <= 1'b1; end
        else apu_acc <= apu_acc + 26'd1789773;
    end
end

wire        snd_reset = reset | ~snd_run;
logic [15:0] s_a[2];
logic        s_rw[2];
logic  [7:0] s_do[2], s_di[2], s_ram_q[2];
logic [15:0] s_aux_a[2], s_aux_b[2];

rp2a03 apu0
(
    .clk(clk), .reset(snd_reset), .ce(apu_ce), .nmi_n(~vblk),
    .t65_i(t65_0_i), .t65_o(t65_0_o),
    .ext_a(s_a[0]), .ext_rw(s_rw[0]), .ext_dout(s_do[0]), .ext_din(s_di[0]), .aux_a(s_aux_a[0]), .aux_b(s_aux_b[0])
);
rp2a03 apu1
(
    .clk(clk), .reset(snd_reset), .ce(apu_ce), .nmi_n(~vblk),
    .t65_i(t65_1_i), .t65_o(t65_1_o),
    .ext_a(s_a[1]), .ext_rw(s_rw[1]), .ext_dout(s_do[1]), .ext_din(s_di[1]), .aux_a(s_aux_a[1]), .aux_b(s_aux_b[1])
);

// RAM: written on every write below 8000 (APU register writes included: the external bus sees them)
genvar sc;
generate
    for (sc = 0; sc < 2; sc++) begin : sram
        dpram_dc #(.widthad_a(11)) ram
        (
            .clock_a(clk), .address_a(s_a[sc][10:0]), .data_a(s_do[sc]), .wren_a(apu_ce && !s_rw[sc] && !s_a[sc][15]),
            .q_a(s_ram_q[sc]),
            .clock_b(clk), .address_b(11'd0), .q_b()
        );
    end
endgenerate

assign snd1_a = s_a[0][12:0];
assign snd2_a = s_a[1][12:0];
always_comb begin
    s_di[0] = s_a[0][15] ? snd1_d : (s_a[0] == 16'h4016) ? snd_lat1 : (s_a[0] == 16'h4017) ? snd_lat2 : s_ram_q[0];
    s_di[1] = s_a[1][15] ? snd2_d : (s_a[1] == 16'h4016) ? snd_lat3 : (s_a[1] == 16'h4017) ? 8'h00   : s_ram_q[1];
end

// mix: four AUX pads (20000 per volt each, 0..~1.2 V), DC blocker (~9 Hz at the CPU clock rate)
logic [17:0] mix_sum;
logic signed [31:0] mix_lp = 32'sd0;
logic signed [18:0] mix_hp;
always_ff @(posedge clk) begin
    mix_sum <= {2'b00, s_aux_a[0]} + {2'b00, s_aux_b[0]} + {2'b00, s_aux_a[1]} + {2'b00, s_aux_b[1]};
    if (apu_ce) mix_lp <= mix_lp + (((32'($signed({1'b0, mix_sum})) <<< 15) - mix_lp) >>> 15);
end
assign mix_hp = $signed({1'b0, mix_sum}) - 19'(mix_lp >>> 15);
assign audio  = (mix_hp > 19'sd32767) ? 16'sd32767 : (mix_hp < -19'sd32768) ? -16'sd32768 : mix_hp[15:0];

endmodule
