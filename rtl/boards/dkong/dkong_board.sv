//============================================================================
//
//  Nintendo Donkey Kong board (TKG-04 two-board set; MAME dkong.cpp dkong2b) and Donkey Kong Jr. (dkongjr)
//  Copyright (C) 2026 Rodimus
//
//  Main Z80 at 1H (3.072 MHz), 8257 DMA copies sprite data into the object RAM, 8035 sound CPU (dkong_sound.sv).
//  Memory map (MAME dkong_map / TKG-04 CPU sheet):
//    0000-5FFF ROM          6000-6FFF RAM (6000-6BFF on the board)   7000-73FF object RAM (two 0x200 banks)
//    7400-77FF video RAM    7800-780F 8257
//    7C00 R IN0 / W sound latch (LS175 3D)     7C80 R IN1
//    7D00 R IN2 / W 7D00-7D07 6H LS259 (data bit 0): sound triggers
//    7D80 R DSW0 / W 7D80-7D87 5H LS259 (data bit 0): 0 sound IRQ, 2 flip, 3 sprite bank, 4 NMI mask, 5 DMA DRQ,
//                                                      6-7 palette bank; DK Jr.: 1 = falling sound
//  DK Jr.: 7C80-7C87 4H LS259 (data bit 0): 0 char ROM bank, 1 -> sound CPU P2.6; 3D is an LS174 (5 bits).
//  /WAIT: a VRAM access while /VRAM BUSY is low (outside h 258-377) waits, except in VBLK (TKG-04 CPU sheet 7F).
//  NMI: set by the VBLK edge while the mask is on, cleared by mask = 0 (8F).
//
//============================================================================

module dkong_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,
    input  logic        jr,             // Donkey Kong Jr. board

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] dsw0,
    input  logic        in2_snd_status, // IN2 bit 6 = sound CPU P2.4 inverted (DK, Radar Scope)

    // ROMs (shared blocks in rtl/nintendo_board.sv)
    output logic [14:0] rom_a,
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

logic wr_q = 1'b0, rd_q = 1'b0;
always_ff @(posedge clk) begin wr_q <= wr & mreq; rd_q <= rd & mreq; end
wire cpu_we = wr & mreq & ~wr_q;        // one clock per write cycle
wire cpu_re = rd & mreq & ~rd_q;

// ------------------------------------------------------------------ 8257
logic [15:0] dma_a;
logic  [7:0] dma_dout, dma_data, dma_latch, mem_q;
logic        dma_hrq, dma_busy, dma_memw, dma_iow;
logic  [1:0] dma_chan;
logic        drq;
wire         dma_cs = cpu_a[15:10] == 6'b011110;                    // 7800-7BFF

i8257 dma
(
    .clk(clk), .reset(reset), .ce(cen_p & run), .rev_rw(1'b1),
    .cs(dma_cs && !busak), .a(cpu_a[3:0]), .wr(cpu_we), .rd(cpu_re), .din(z80pa_0_o.dout), .dout(dma_dout),
    .drq({2'b00, drq, drq}), .hrq(dma_hrq), .hlda(busak),
    .addr(dma_a), .chan(dma_chan), .busy(dma_busy), .ior(), .iow(dma_iow), .memr(), .memw(dma_memw),
    .mem_d(mem_q), .io_d(dma_latch), .data(dma_data)
);
always_ff @(posedge clk) if (dma_iow) dma_latch <= dma_data;       // MAME p8257_ctl_w / p8257_ctl_r

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
logic [7:0] snd_latch, lat_6h, lat_5h, lat_4h;
always_ff @(posedge clk) begin
    if (reset) begin
        snd_latch <= 8'd0; lat_6h <= 8'd0; lat_5h <= 8'd0; lat_4h <= 8'd0;
    end else if (cpu_we && !dma_own && sel_io) begin
        case (cpu_a[8:7])
            2'd0: snd_latch <= z80pa_0_o.dout;
            2'd1: lat_4h[cpu_a[2:0]] <= z80pa_0_o.dout[0];
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
always_comb begin
    case (cpu_a[8:7])
        2'd0: io_q = in0;
        2'd1: io_q = in1;
        2'd2: io_q = in2_snd_status ? (in2 | {1'b0, ~snd_status, 6'd0}) : in2;
        2'd3: io_q = dsw0;
    endcase
end

assign rom_a = cpu_a[14:0];

always_comb begin
    if (cpu_a < 16'h6000)      z80pa_0_i.di = rom_d;
    else if (sel_ram)   z80pa_0_i.di = ram_q;
    else if (sel_obj)   z80pa_0_i.di = obj_q;
    else if (sel_vram)  z80pa_0_i.di = vram_q;
    else if (dma_cs)    z80pa_0_i.di = dma_dout;
    else if (sel_io)    z80pa_0_i.di = io_q;
    else                z80pa_0_i.di = 8'hFF;
end
assign mem_q = sel_ram ? ram_q : sel_obj ? obj_q : sel_vram ? vram_q : (bus_a < 16'h6000) ? rom_d : 8'hFF;

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
    .flip(flip), .sprite_bank(spr_bank), .palette_bank(pal_bank), .gfx_bank(jr & lat_4h[0]), .gfx1_8k(jr), .dk3(1'b0), .mario(1'b0), .scroll_y(8'd0), .crt_flip(crt_flip),
    .ce_pix(ce_pix), .cpu_cen_p(cen_p), .cpu_cen_n(cen_n), .vram_busy(vram_busy), .vblank_hw(vblk),
    .vram_a(vram_va), .vram_d(vram_vd), .spr_a(spr_a), .spr_d(spr_d),
    .gfx1_a(gfx1_a), .gfx1_d(gfx1_d), .gfx2_a(gfx2_a), .gfx2_d(gfx2_d),
    .cprom_a(cc_a), .cprom_d(prom_cc_d), .pal_a(pal_a), .pal_lo_d(prom_lo_d), .pal_hi_d(prom_hi_d),
    .r(video_r), .g(video_g), .b(video_b), .hblank(video_hblank), .vblank(video_vblank), .hsync(video_hs), .vsync(video_vs)
);

// ------------------------------------------------------------------ sound board
dkong_sound sound
(
    .clk(clk), .reset(reset), .pause(pause), .jr(jr),
    .mcs48_0_i(mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .tune(snd_latch), .sfx(lat_6h), .irq(snd_irq), .lat4h1(lat_4h[1]), .snd9(lat_5h[1]),
    .pa(snd_pa), .pd(snd_pd), .xa(snd_xa), .xd(snd_xd),
    .status(snd_status),
    .audio(audio)
);

endmodule
