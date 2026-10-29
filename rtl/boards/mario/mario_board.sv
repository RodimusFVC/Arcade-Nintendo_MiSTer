//  Based on MAME mario.cpp (Mirko Buffoni, Couriersud, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module mario_board
(
    input  logic        clk,
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

    output logic [14:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [11:0] snd_pa,
    input  logic  [7:0] snd_pd,
    output logic [12:0] snd_xa,
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
    output logic signed [39:0] mul_a,
    output logic signed [26:0] mul_b,
    input  logic signed [66:0] mul_p,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write,

    output chip_pool_pkg::z80dma_i_t z80dma_0_i,
    input  chip_pool_pkg::z80dma_o_t z80dma_0_o,

    output ram_pool_pkg::pram_i_t [8:0] pr_i,
    input  ram_pool_pkg::pram_o_t [8:0] pr_o
);

wire run = ~pause;

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
wire cpu_we = wr & mreq & ~wr_q;
wire io_we  = wr & iorq & ~m1 & ~iow_q;
wire io_re  = rd & iorq & ~m1 & ~ior_q;

logic [15:0] dma_a;
logic  [7:0] dma_dout, dma_data, mem_q;
logic        dma_busrq, dma_busy, dma_mreq, dma_memw;
logic        dma_rdy;
wire         dma_cs = iorq && !m1 && cpu_a[7:0] == 8'h00 && !busak;

assign z80dma_0_i.reset = reset;
assign z80dma_0_i.cen_p = cen_p & run;
assign z80dma_0_i.cs = dma_cs;
assign z80dma_0_i.wr = io_we;
assign z80dma_0_i.rd = io_re;
assign z80dma_0_i.din = z80pa_0_o.dout;
assign dma_dout = z80dma_0_o.dout;
assign z80dma_0_i.rdy = dma_rdy;
assign dma_busrq = z80dma_0_o.busrq;
assign z80dma_0_i.bai = busak;
assign dma_busy = z80dma_0_o.busy;
assign dma_a = z80dma_0_o.addr;
assign dma_mreq = z80dma_0_o.mreq;
assign dma_memw = z80dma_0_o.memw_s;
assign z80dma_0_i.bus_d = mem_q;
assign dma_data = z80dma_0_o.data;

wire        dma_own = dma_busy & busak;
wire [15:0] bus_a   = dma_own ? dma_a : cpu_a;
wire        bus_we  = dma_own ? dma_memw & dma_mreq : cpu_we;
wire  [7:0] bus_d   = dma_own ? dma_data : z80pa_0_o.dout;

wire sel_rom  = bus_a < 16'h6000 || bus_a[15:12] == 4'hF;
wire sel_ram  = bus_a[15:12] == 4'h6;
wire sel_obj  = bus_a[15:10] == 6'b011100;
wire sel_vram = bus_a[15:10] == 6'b011101;
wire sel_io   = bus_a[15:10] == 6'b011111;

logic [7:0] ram_q, vram_q, obj_q;
logic [31:0] spr_d;
logic  [7:0] spr_a;
logic  [9:0] vram_va;
logic  [7:0] vram_vd;

assign pr_i[6] = '0;
assign pr_i[7] = '0;
assign pr_i[8] = '0;

assign pr_i[0].a_addr = {3'd0, bus_a[11:0]}; assign pr_i[0].a_d = bus_d; assign pr_i[0].a_we = bus_we & sel_ram;
assign pr_i[0].b_addr = {3'd0, hs_address[11:0]}; assign pr_i[0].b_d = hs_data_in; assign pr_i[0].b_we = hs_write & pause;
assign ram_q = pr_o[0].a_q;
assign hs_data_out = pr_o[0].b_q;

assign pr_i[1].a_addr = {5'd0, bus_a[9:0]}; assign pr_i[1].a_d = bus_d; assign pr_i[1].a_we = bus_we & sel_vram;
assign pr_i[1].b_addr = {5'd0, vram_va}; assign pr_i[1].b_d = 8'h00; assign pr_i[1].b_we = 1'b0;
assign vram_q = pr_o[1].a_q;
assign vram_vd = pr_o[1].b_q;

logic [7:0] obj_lane_q[4];
genvar ln;
generate
    for (ln = 0; ln < 4; ln++) begin : objl
        assign pr_i[2 + ln].a_addr = {7'd0, bus_a[9:2]}; assign pr_i[2 + ln].a_d = bus_d; assign pr_i[2 + ln].a_we = bus_we & sel_obj & (bus_a[1:0] == ln);
        assign pr_i[2 + ln].b_addr = {7'd0, spr_a}; assign pr_i[2 + ln].b_d = 8'h00; assign pr_i[2 + ln].b_we = 1'b0;
        assign obj_lane_q[ln] = pr_o[2 + ln].a_q;
        assign spr_d[ln*8 +: 8] = pr_o[2 + ln].b_q;
    end
endgenerate
logic [1:0] obj_lane;
always_ff @(posedge clk) obj_lane <= bus_a[1:0];
assign obj_q = obj_lane_q[obj_lane];

logic [7:0] lat_7e8, scroll, snd_tune, lat_7f0;
always_ff @(posedge clk) begin
    if (reset) begin
        lat_7e8 <= 8'd0; scroll <= 8'd0; snd_tune <= 8'd0; lat_7f0 <= 8'd0;
    end else if (cpu_we && !dma_own && sel_io) begin
        case (cpu_a[9:7])
            3'd2: scroll <= z80pa_0_o.dout + 8'd17;
            3'd4: snd_tune <= z80pa_0_o.dout;
            3'd5: lat_7e8[cpu_a[2:0]] <= z80pa_0_o.dout[0];
            3'd6: lat_7f0[cpu_a[2:0]] <= z80pa_0_o.dout[0];
            default: ;
        endcase
    end
end

wire       gfx_bank  = lat_7e8[0];
wire       spr_bank  = lat_7e8[1];
wire       flip      = lat_7e8[2];
wire       pal_bank  = lat_7e8[3];
wire       nmi_mask  = lat_7e8[4];
assign     dma_rdy   = lat_7e8[5];

logic nmi_q = 1'b0, vblk_q = 1'b0;
always_ff @(posedge clk) begin
    vblk_q <= vblk;
    if (reset || !nmi_mask) nmi_q <= 1'b0;
    else if (vblk && !vblk_q) nmi_q <= 1'b1;
end

logic wait_q = 1'b0;
always_ff @(posedge clk) begin
    if (reset) wait_q <= 1'b0;
    else if (cen_n && run) wait_q <= (mreq | rd | wr) && !rfsh && !busak && cpu_a[15:10] == 6'b011101 && vram_busy && !vblk;
`ifdef SIM_NO_VRAM_WAIT
    wait_q <= 1'b0;
`endif
end

logic [7:0] io_q;
always_comb begin
    case (cpu_a[9:7])
        3'd0:    io_q = in0;
        3'd1:    io_q = in1;
        3'd7:    io_q = dsw0;
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

logic  [7:0] cc_a_nc;
dkong_video video
(
    .clk(clk), .reset(reset),
    .flip(flip), .sprite_bank(spr_bank), .palette_bank({1'b0, pal_bank}), .gfx_bank(gfx_bank), .gfx1_8k(1'b1),
    .dk3(1'b0), .spr256(1'b0), .mario(1'b1), .scroll_y(scroll), .crt_flip(crt_flip),
    .radar(1'b0), .rs_snd2(1'b0), .rs_grid_on(1'b0), .rs_grid_col(3'd0), .rs_ans(1'b0), .gfx3_a(), .gfx3_d(8'd0),
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
    .audio(audio), .mul_a(mul_a), .mul_b(mul_b), .mul_p(mul_p)
);

endmodule
