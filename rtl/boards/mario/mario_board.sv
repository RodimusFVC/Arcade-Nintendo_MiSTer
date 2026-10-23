//============================================================================
//
//  Nintendo Mario Bros. board (TMA1-CPU / TMA1-VIDEO; MAME mario.cpp mario_state)
//  Copyright (C) 2026 Rodimus
//
//  TMA1-CPU (Mario_Bros_Schematics.pdf p13-16): Z80A 5E at 4 MHz from its own 8 MHz crystal (X1 -> 3D LS74 / 2), Z80A
//  DMA 5D on the same clock (BUSRQ / BAI), /WAIT = VRAM BUSY through 2B / 4D LS74 (cleared in VBLK), NMI from VBLK
//  (4D LS74) gated by NMI EI. Same structure as DKC1 (rtl/boards/dkong/dkong3_board.sv).
//  Memory map (MAME mario_map):
//    0000-5FFF ROM 7F / 7E / 7D   6000-6FFF RAM 7A / 7B (6800-6FFF battery-backed)   7000-73FF sprite RAM (2 banks)
//    7400-77FF video RAM   F000-FFFF ROM 7C (read at ROM 6000, MRA placement)
//    7C00 R IN0   7C80 R IN1   7F80 R DSW   7D00 W Y scroll (MAME: + 17)   7E00 W sound latch
//    7E80-7E87 2L LS259 (data bit 0): 0 T ROM (char bank), 1 2PSL (sprite bank), 2 FLIP, 3 CREF 0 (palette bank),
//                                     4 NMI EI, 5 DMA SET (RDY), 6 / 7 coin counters
//    7C00 / 7C80 / 7F00-7F07 W sound triggers         I/O port 00: Z80 DMA
//  Video = dkong_video.sv in Mario mode (TMA1-VIDEO: 24 MHz crystal / 2 = 12M, 6.000 MHz dots, DK raster logic).
//  Sound: rtl/boards/mario/mario_sound.sv (pooled 8039 + DAC path; walk / skid discrete circuits not yet).
//
//============================================================================

module mario_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] dsw0,

    // ROMs (shared blocks in rtl/nintendo_board.sv)
    output logic [14:0] rom_a,          // F000-FFFF read at ROM 6000 (MRA placement)
    input  logic  [7:0] rom_d,
    output logic [11:0] snd_pa,         // soundrom 6K (program)
    input  logic  [7:0] snd_pd,
    output logic [12:0] snd_xa,         // soundrom 6K (MOVX data)
    input  logic  [7:0] snd_xd,
    output logic [12:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] pal_a,          // proms 0x12000: 4P 28S42, first 256 = Nintendo monitor half
    input  logic  [7:0] prom_d,

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

wire sel_rom  = bus_a < 16'h6000 || bus_a[15:12] == 4'hF;            // 0000-5FFF, F000-FFFF
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

// sprite RAM (two 2148s) as four byte lanes: one 32-bit entry per video read
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
logic [7:0] lat_7e8, scroll, snd_tune, lat_7f0;
always_ff @(posedge clk) begin
    if (reset) begin
        lat_7e8 <= 8'd0; scroll <= 8'd0; snd_tune <= 8'd0; lat_7f0 <= 8'd0;
    end else if (cpu_we && !dma_own && sel_io) begin
        case (cpu_a[9:7])
            3'd2: scroll <= z80pa_0_o.dout + 8'd17;                // MAME scroll_w: set_scrolly(data + 17)
            3'd4: snd_tune <= z80pa_0_o.dout;                      // 7E00 7J LS374
            3'd5: lat_7e8[cpu_a[2:0]] <= z80pa_0_o.dout[0];
            3'd6: lat_7f0[cpu_a[2:0]] <= z80pa_0_o.dout[0];        // 7F00-7F07 7M LS259
            default: ;                                             // 7C00 / 7C80 writes = walk triggers (mario_sound)
        endcase
    end
end

wire       gfx_bank  = lat_7e8[0];      // T ROM
wire       spr_bank  = lat_7e8[1];      // 2 PSL
wire       flip      = lat_7e8[2];
wire       pal_bank  = lat_7e8[3];      // CREF 0
wire       nmi_mask  = lat_7e8[4];
assign     dma_rdy   = lat_7e8[5];

// NMI: VBLK edge sets it while the mask is on
logic nmi_q = 1'b0, vblk_q = 1'b0;
always_ff @(posedge clk) begin
    vblk_q <= vblk;
    if (reset || !nmi_mask) nmi_q <= 1'b0;
    else if (vblk && !vblk_q) nmi_q <= 1'b1;
end

// /WAIT: VRAM access while the video board is fetching (LS74 2B / 4D clocked by the CPU clock, cleared in VBLK)
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
    case (cpu_a[9:7])
        3'd0:    io_q = in0;            // 7C00
        3'd1:    io_q = in1;            // 7C80
        3'd7:    io_q = dsw0;           // 7F80
        default: io_q = 8'h00;
    endcase
end

assign rom_a = bus_a[15] ? {3'b110, bus_a[11:0]} : bus_a[14:0];

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
logic  [7:0] cc_a_nc;
dkong_video video
(
    .clk(clk), .reset(reset),
    .flip(flip), .sprite_bank(spr_bank), .palette_bank({1'b0, pal_bank}), .gfx_bank(gfx_bank), .gfx1_8k(1'b1),
    .dk3(1'b0), .mario(1'b1), .scroll_y(scroll), .crt_flip(crt_flip),
    .ce_pix(ce_pix), .cpu_cen_p(), .cpu_cen_n(), .vram_busy(vram_busy), .vblank_hw(vblk),
    .vram_a(vram_va), .vram_d(vram_vd), .spr_a(spr_a), .spr_d(spr_d),
    .gfx1_a(gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(gfx2_a), .gfx2_d(gfx2_d),
    .cprom_a(cc_a_nc), .cprom_d(4'd0), .pal_a(pal_a), .pal_lo_d(prom_d), .pal_hi_d(8'd0),
    .r(video_r), .g(video_g), .b(video_b), .hblank(video_hblank), .vblank(video_vblank), .hsync(video_hs), .vsync(video_vs)
);

mario_sound sound
(
    .clk(clk), .reset(reset), .pause(pause),
    .mcs48_0_i(mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .tune(snd_tune), .lat1(lat_7f0[6:3]), .lat3(lat_7f0[2:1]), .irq(lat_7f0[0]),
    .walk0(cpu_we && !dma_own && sel_io && cpu_a[9:7] == 3'd0), .walk1(cpu_we && !dma_own && sel_io && cpu_a[9:7] == 3'd1),
    .sound7(~lat_7f0[7]),
    .pa(snd_pa), .pd(snd_pd), .xa(snd_xa), .xd(snd_xd),
    .audio(audio)
);

endmodule
