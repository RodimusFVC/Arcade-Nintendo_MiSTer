//  Based on MAME popeye.cpp (smf, Nicola Salmoria, Couriersud, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

module popeye_board
(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,
    input  logic        tnx1,

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,

    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] dsw0,
    input  logic  [7:0] dsw1,

    output logic [14:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [10:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] spal_a,
    input  logic  [3:0] spal_lo,
    input  logic  [3:0] spal_hi,
    output logic  [7:0] prom_a,
    input  logic  [7:0] prom_d,

    output logic        ce_pix,
    output logic  [7:0] video_r,
    output logic  [7:0] video_g,
    output logic  [7:0] video_b,
    output logic        video_hs,
    output logic        video_vs,
    output logic        video_hblank,
    output logic        video_vblank,
    output logic        video_field,

    output logic signed [15:0] audio,

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write,

    output chip_pool_pkg::ayr_i_t  ay_0_i,
    input  chip_pool_pkg::ayio_o_t ay_0_o,

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

logic ay_ph = 1'b0;
always_ff @(posedge clk) if (cen_p) ay_ph <= ~ay_ph;
wire ay_cen = cen_p & ay_ph & run;

wire [15:0] cpu_a = z80pa_0_o.a;
wire  [7:0] cpu_d = z80pa_0_o.dout;
wire        mreq  = ~z80pa_0_o.mreq_n;
wire        iorq  = ~z80pa_0_o.iorq_n;
wire        m1    = ~z80pa_0_o.m1_n;
wire        rd    = ~z80pa_0_o.rd_n;
wire        wr    = ~z80pa_0_o.wr_n;
wire        rfsh  = ~z80pa_0_o.rfsh_n;
wire        busak = ~z80pa_0_o.busak_n;

logic wr_q = 1'b0, iow_q = 1'b0;
always_ff @(posedge clk) begin wr_q <= wr & mreq; iow_q <= wr & iorq; end
wire cpu_we = wr & mreq & ~wr_q;
wire io_we  = wr & iorq & ~m1 & ~iow_q;

wire sel_rom  = !cpu_a[15];
wire sel_ram  = tnx1 ? cpu_a[15:12] == 4'h8 && cpu_a[11:10] != 2'b10
                     : cpu_a[15:11] == 5'b10001;
wire sel_txt  = cpu_a[15:11] == 5'b10100;
wire sel_bg   = tnx1 ? cpu_a[15:12] == 4'hC : cpu_a[15:13] == 3'b110;
wire bg_hi_w  = tnx1 ? cpu_d[7] : cpu_a[12];
wire sel_prot = cpu_a[15:1]  == 15'h7000;

logic vbl_start, field;

assign rom_a = tnx1 ? {cpu_a[14:10], cpu_a[8], cpu_a[7], cpu_a[0], cpu_a[1], cpu_a[2], cpu_a[4], cpu_a[5], cpu_a[9], cpu_a[3], cpu_a[6]}
                      ^ 15'h00FC
                    : {cpu_a[14:10], cpu_a[8], cpu_a[7], cpu_a[6], cpu_a[3], cpu_a[9], cpu_a[5], cpu_a[4], cpu_a[2], cpu_a[1], cpu_a[0]}
                      ^ 15'h003F;
wire [7:0] rom_q = {rom_d[3], rom_d[4], rom_d[2], rom_d[5], rom_d[1], rom_d[6], rom_d[0], rom_d[7]};

logic [7:0] ram_q;
logic [9:0] txt_va;
logic [7:0] txt_code_q, txt_col_q;
logic [11:0] bg_va;
logic [7:0] bg_lo_q, bg_hi_q;

logic       dma_req = 1'b0, dma_go = 1'b0;
logic [9:0] dma_n;
wire        dma_own = dma_req & busak;

assign pr_i[0].a_addr = {3'd0, (dma_own ? 12'hC00 + {2'b00, dma_n} : cpu_a[11:0])}; assign pr_i[0].a_d = cpu_d; assign pr_i[0].a_we = cpu_we & sel_ram & ~dma_own;
assign pr_i[0].b_addr = {3'd0, hs_address[11:0]}; assign pr_i[0].b_d = hs_data_in; assign pr_i[0].b_we = hs_write & pause;
assign ram_q = pr_o[0].a_q;
assign hs_data_out = pr_o[0].b_q;

logic [7:0] spr_a;
logic [31:0] spr_d;
wire        dma_wr = dma_go & cen_p & run;
genvar ln;
generate
    for (ln = 0; ln < 4; ln++) begin : sprl
        assign pr_i[2 + ln].a_addr = {7'd0, dma_n[9:2]}; assign pr_i[2 + ln].a_d = ram_q; assign pr_i[2 + ln].a_we = dma_wr && dma_n[1:0] == ln;
        assign pr_i[2 + ln].b_addr = {7'd0, spr_a}; assign pr_i[2 + ln].b_d = 8'h00; assign pr_i[2 + ln].b_we = 1'b0;
        assign spr_d[ln*8 +: 8] = pr_o[2 + ln].b_q;
    end
endgenerate

assign pr_i[1].a_addr = {5'd0, cpu_a[9:0]}; assign pr_i[1].a_d = cpu_d; assign pr_i[1].a_we = cpu_we & sel_txt & ~cpu_a[10];
assign pr_i[1].b_addr = {5'd0, txt_va}; assign pr_i[1].b_d = 8'h00; assign pr_i[1].b_we = 1'b0;
assign txt_code_q = pr_o[1].b_q;
assign pr_i[6].a_addr = {5'd0, cpu_a[9:0]}; assign pr_i[6].a_d = {4'h0, cpu_d[3:0]}; assign pr_i[6].a_we = cpu_we & sel_txt & cpu_a[10];
assign pr_i[6].b_addr = {5'd0, txt_va}; assign pr_i[6].b_d = 8'h00; assign pr_i[6].b_we = 1'b0;
assign txt_col_q = pr_o[6].b_q;

assign pr_i[7].a_addr = {3'd0, cpu_a[11:0]}; assign pr_i[7].a_d = {4'h0, cpu_d[3:0]}; assign pr_i[7].a_we = cpu_we & sel_bg & ~bg_hi_w;
assign pr_i[7].b_addr = {3'd0, bg_va}; assign pr_i[7].b_d = 8'h00; assign pr_i[7].b_we = 1'b0;
assign bg_lo_q = pr_o[7].b_q;
assign pr_i[8].a_addr = {3'd0, cpu_a[11:0]}; assign pr_i[8].a_d = {4'h0, cpu_d[3:0]}; assign pr_i[8].a_we = cpu_we & sel_bg & bg_hi_w;
assign pr_i[8].b_addr = {3'd0, bg_va}; assign pr_i[8].b_d = 8'h00; assign pr_i[8].b_we = 1'b0;
assign bg_hi_q = pr_o[8].b_q;

logic [7:0] prot0, prot1;
logic [2:0] prot_shift;
always_ff @(posedge clk) begin
    if (reset) begin
        prot0 <= 8'd0; prot1 <= 8'd0; prot_shift <= 3'd0;
    end else if (cpu_we && sel_prot) begin
        if (!cpu_a[0]) prot_shift <= cpu_d[2:0];
        else begin prot0 <= prot1; prot1 <= cpu_d; end
    end
end
wire [15:0] prot_pair = {prot1, prot0} << prot_shift;
wire  [7:0] prot_q    = cpu_a[0] ? 8'h00 : prot_pair[15:8];

logic nmi_en = 1'b0, wd_en = 1'b0;
always_ff @(posedge clk) begin
    if (reset) begin nmi_en <= 1'b0; wd_en <= 1'b0; end
    else if (rfsh && mreq) begin nmi_en <= cpu_a[8]; wd_en <= cpu_a[9]; end
end

logic       nmi_q = 1'b0;
logic [3:0] wd_cnt = 4'd0;
logic       wd_reset = 1'b0;
logic [7:0] scroll_x, scroll_y, scroll_h, pal_bank;

wire [3:0] wd_nx = (nmi_en || !wd_en || tnx1) ? 4'd0 : wd_cnt + 4'd1;

always_ff @(posedge clk) begin
    if (reset) begin
        nmi_q <= 1'b0; wd_cnt <= 4'd0; wd_reset <= 1'b0; dma_req <= 1'b0; dma_go <= 1'b0;
        scroll_x <= 8'd0; scroll_y <= 8'd0; scroll_h <= 8'd0; pal_bank <= 8'd0;
    end else begin
        if (!nmi_en) nmi_q <= 1'b0;
        if (vbl_start) begin
            if (nmi_en) nmi_q <= 1'b1;
            if (run) begin
                wd_cnt <= wd_nx;
                if (wd_nx[2] != wd_cnt[2]) wd_reset <= wd_nx[2];
            end
            dma_req <= 1'b1; dma_n <= 10'd0;
        end
        dma_go <= dma_own;
        if (dma_wr) begin
            case (dma_n)
                10'd0: scroll_x <= ram_q;
                10'd1: scroll_y <= ram_q;
                10'd2: scroll_h <= ram_q;
                10'd3: pal_bank <= ram_q;
                default: ;
            endcase
            dma_n <= dma_n + 10'd1;
            if (dma_n == 10'h27F) begin dma_req <= 1'b0; dma_go <= 1'b0; end
        end
    end
end

wire       cpu_reset = reset | wd_reset;
wire       ay_wr_a   = iorq && !m1 && wr && cpu_a[1:0] == 2'd0;
wire       ay_wr_d   = iorq && !m1 && wr && cpu_a[1:0] == 2'd1;
wire       ay_rd     = iorq && !m1 && rd && cpu_a[1:0] == 2'd3;
logic [7:0] ay_dout, ay_portb, ay_a, ay_b, ay_c;
logic [9:0] ay_sound;
wire  [2:0] dswbit = ay_portb[3:1];

assign ay_0_i.rst_n = ~cpu_reset;
assign ay_0_i.ce = ay_cen;
assign ay_0_i.bdir = ay_wr_a | ay_wr_d;
assign ay_0_i.bc1 = ay_wr_a | ay_rd;
assign ay_0_i.din = cpu_d;
assign ay_dout = ay_0_o.dout;
assign ay_sound = ay_0_o.sound;
assign ay_a = ay_0_o.a;
assign ay_b = ay_0_o.b;
assign ay_c = ay_0_o.c;
assign ay_0_i.ioa_in = {dsw1[dswbit], dsw0[6:0]};
assign ay_0_i.iob_in = 8'hFF;
assign ay_portb = ay_0_o.iob_out;
wire flip = ay_portb[0];

popeye_sound sound
(
    .clk(clk), .reset(cpu_reset), .ce(ay_cen), .ch_a(ay_a), .ch_b(ay_b), .ch_c(ay_c), .audio(audio)
);

logic [7:0] io_q;
always_comb begin
    case (cpu_a[1:0])
        2'd0: io_q = in0;
        2'd1: io_q = in1;
        2'd2: io_q = {in2[7:5], field & ~tnx1, in2[3:0]};
        2'd3: io_q = ay_dout;
    endcase
end

always_comb begin
    if (iorq && !m1)    z80pa_0_i.di = io_q;
    else if (sel_rom)   z80pa_0_i.di = rom_q;
    else if (sel_ram)   z80pa_0_i.di = ram_q;
    else if (sel_prot)  z80pa_0_i.di = prot_q;
    else                z80pa_0_i.di = 8'h00;
end

assign z80pa_0_i.reset_n = ~cpu_reset;
assign z80pa_0_i.cen_p   = cen_p & run;
assign z80pa_0_i.cen_n   = cen_n & run;
assign z80pa_0_i.wait_n  = 1'b1;
assign z80pa_0_i.int_n   = 1'b1;
assign z80pa_0_i.nmi_n   = ~nmi_q;
assign z80pa_0_i.busrq_n = ~dma_req;

popeye_video video
(
    .clk(clk), .reset(reset),
    .tnx1(tnx1), .flip(flip), .crt_flip(crt_flip), .scroll_x(scroll_x), .scroll_y(scroll_y), .scroll_h(scroll_h[0]),
    .pal_bank(pal_bank[3:0]),
    .ce_pix(ce_pix), .vblank_start(vbl_start), .field(field),
    .txt_a(txt_va), .txt_code(txt_code_q), .txt_col(txt_col_q[3:0]),
    .bg_a(bg_va), .bg_lo(bg_lo_q[3:0]), .bg_hi(bg_hi_q[3:0]),
    .gfx1_a(gfx1_a), .gfx1_d(gfx1_d), .prom_a(prom_a), .prom_d(prom_d),
    .spr_a(spr_a), .spr_d(spr_d), .gfx2_a(gfx2_a), .gfx2_d(gfx2_d), .spal_a(spal_a), .spal_lo(spal_lo), .spal_hi(spal_hi),
    .r(video_r), .g(video_g), .b(video_b),
    .hblank(video_hblank), .vblank(video_vblank), .hsync(video_hs), .vsync(video_vs)
);
assign video_field = field;

endmodule
