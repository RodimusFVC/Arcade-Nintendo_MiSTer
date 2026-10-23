//============================================================================
//
//  Nintendo Popeye board (TPP2-CPU / TPP2-VIDEO; MAME popeye.cpp tpp2_state, tpp2_noalu_state)
//  Copyright (C) 2026 Rodimus
//
//  Main Z80 at 4 MHz from its own 8 MHz crystal (TPP2-CPU sheet 1: LS109 5F / 2), async to the 20.16 MHz video.
//  Program ROM read through the board's address / data scramble (PLAs 6E / 6F / 6H; MAME tpp2_state::decrypt_rom):
//    ROM address = bitswap(A, 15,14,13,12,11,10,8,7,6,3,9,5,4,2,1,0) ^ 0x3F, data = bitswap(D, 3,4,2,5,1,6,0,7)
//  Memory map (MAME tpp2 maincpu_program_map):
//    0000-7FFF ROM   8800-8FFF RAM (8C00-8E7F = sprite DMA source; 8C00-8C03 = scroll x / y / -, palette bank)
//    A000-A3FF text codes (W)   A400-A7FF text colours (W)   C000-DFFF background nibbles (W; A12 = high nibble)
//    E000-E001 protection ALU 7K (W 0 = shift, W 1 = data, R 0 = shifted data, R 1 = status 0; MAME protection_*)
//    I/O 00 W AY address / R P1, 01 W AY data / R P2, 02 R SYSTEM (bit 4 = field), 03 R AY data
//  NMI enable / watchdog enable = A8 / A9 of the Z80 refresh address (I register; MAME refresh_w). NMI at vblank.
//  Watchdog (MAME tpp2 screen_vblank): a 4-bit vblank counter, cleared while NMI is enabled or the watchdog is
//  off; its bit 2 holds the CPU and the AY in reset.
//  AY-3-8910 7L at 2 MHz: port A = DSW0 with bit 7 = the DSW1 switch picked by port B bits 1-3, port B bit 0 = flip.
//  Sprite DMA (TPP2-CPU sheet 1: 1L LS74 on VB -> BUSRQ; 1F / 2F / 2E LS161 count, 3E / 4E PLAs drive AD0-AD9, 1E LS138
//  /DMCS0-3 = byte lane, DM0-7 = entry): at vblank the CPU is held off the bus and 8C00-8E7F (0x280 bytes) is copied
//  into the video board's sprite RAM; bytes 0 / 1 / 3 are the scroll x / y and palette bank latches (ROHVCK).
//  One byte per CPU clock (#unverified: the counter clock was not traced); MAME copies instantly.
//  Sound: rtl/boards/popeye/popeye_sound.sv (AY channels into the TPP2-CPU output network).
//
//============================================================================

module popeye_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,

    input  logic  [7:0] in0,            // P1
    input  logic  [7:0] in1,            // P2
    input  logic  [7:0] in2,            // SYSTEM (bit 4 from the board)
    input  logic  [7:0] dsw0,
    input  logic  [7:0] dsw1,

    // ROMs (shared blocks in rtl/nintendo_board.sv)
    output logic [14:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [10:0] gfx1_a,
    input  logic  [7:0] gfx1_d,
    output logic [14:0] gfx2_a,
    input  logic  [7:0] gfx2_d,
    output logic  [7:0] spal_a,         // proms 0x12000 5B (low nibble) / 0x12200 5A (high nibble)
    input  logic  [3:0] spal_lo,
    input  logic  [3:0] spal_hi,
    output logic  [7:0] prom_a,         // proms 0x12400: 0x00 background 4A, 0x20 text 3A
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

// AY clock 2 MHz: every other CPU clock (5F second half)
logic ay_ph = 1'b0;
always_ff @(posedge clk) if (cen_p) ay_ph <= ~ay_ph;
wire ay_cen = cen_p & ay_ph & run;

// ------------------------------------------------------------------ Z80
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
wire cpu_we = wr & mreq & ~wr_q;        // one clock per write cycle
wire io_we  = wr & iorq & ~m1 & ~iow_q;

wire sel_rom  = !cpu_a[15];
wire sel_ram  = cpu_a[15:11] == 5'b10001;                           // 8800-8FFF
wire sel_txt  = cpu_a[15:11] == 5'b10100;                           // A000-A7FF (A10: colour)
wire sel_bg   = cpu_a[15:13] == 3'b110;                             // C000-DFFF
wire sel_prot = cpu_a[15:1]  == 15'h7000;                           // E000-E001

logic vbl_start, field;

// program ROM scramble
assign rom_a = {cpu_a[14:10], cpu_a[8], cpu_a[7], cpu_a[6], cpu_a[3], cpu_a[9], cpu_a[5], cpu_a[4], cpu_a[2], cpu_a[1], cpu_a[0]}
               ^ 15'h003F;
wire [7:0] rom_q = {rom_d[3], rom_d[4], rom_d[2], rom_d[5], rom_d[1], rom_d[6], rom_d[0], rom_d[7]};

// ------------------------------------------------------------------ RAMs
logic [7:0] ram_q;
logic [9:0] txt_va;
logic [7:0] txt_code_q, txt_col_q;
logic [11:0] bg_va;
logic [7:0] bg_lo_q, bg_hi_q;

// 8800-8FFF (7H TMM2016); port A: CPU or sprite DMA, port B: hiscore
logic       dma_req = 1'b0, dma_go = 1'b0;
logic [9:0] dma_n;
wire        dma_own = dma_req & busak;

dpram_dc #(.widthad_a(11)) ram
(
    .clock_a(clk), .address_a(dma_own ? 11'h400 + {1'b0, dma_n} : cpu_a[10:0]), .data_a(cpu_d),
    .wren_a(cpu_we & sel_ram & ~dma_own), .q_a(ram_q),
    .clock_b(clk), .address_b(hs_address[10:0]), .data_b(hs_data_in), .wren_b(hs_write & pause), .q_b(hs_data_out)
);

// sprite RAM (2T..1U): four byte lanes, one 32-bit entry per video read
logic [7:0] spr_a;
logic [31:0] spr_d;
wire        dma_wr = dma_go & cen_p & run;
genvar ln;
generate
    for (ln = 0; ln < 4; ln++) begin : sprl
        dpram_dc #(.widthad_a(8)) spr
        (
            .clock_a(clk), .address_a(dma_n[9:2]), .data_a(ram_q), .wren_a(dma_wr && dma_n[1:0] == ln),
            .clock_b(clk), .address_b(spr_a), .q_b(spr_d[ln*8 +: 8])
        );
    end
endgenerate

// text codes (5P / 5R) and colours (5S, low nibble)
dpram_dc #(.widthad_a(10)) txt_code
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a(cpu_d), .wren_a(cpu_we & sel_txt & ~cpu_a[10]),
    .clock_b(clk), .address_b(txt_va), .q_b(txt_code_q)
);
dpram_dc #(.widthad_a(10)) txt_col
(
    .clock_a(clk), .address_a(cpu_a[9:0]), .data_a({4'h0, cpu_d[3:0]}), .wren_a(cpu_we & sel_txt & cpu_a[10]),
    .clock_b(clk), .address_b(txt_va), .q_b(txt_col_q)
);

// background nibbles (8P / 8S): C000-CFFF low, D000-DFFF high
dpram_dc #(.widthad_a(12)) bg_lo
(
    .clock_a(clk), .address_a(cpu_a[11:0]), .data_a({4'h0, cpu_d[3:0]}), .wren_a(cpu_we & sel_bg & ~cpu_a[12]),
    .clock_b(clk), .address_b(bg_va), .q_b(bg_lo_q)
);
dpram_dc #(.widthad_a(12)) bg_hi
(
    .clock_a(clk), .address_a(cpu_a[11:0]), .data_a({4'h0, cpu_d[3:0]}), .wren_a(cpu_we & sel_bg & cpu_a[12]),
    .clock_b(clk), .address_b(bg_va), .q_b(bg_hi_q)
);

// ------------------------------------------------------------------ protection ALU (7K)
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

// ------------------------------------------------------------------ refresh latch: NMI enable (A8), watchdog enable (A9)
logic nmi_en = 1'b0, wd_en = 1'b0;
always_ff @(posedge clk) begin
    if (reset) begin nmi_en <= 1'b0; wd_en <= 1'b0; end
    else if (rfsh && mreq) begin nmi_en <= cpu_a[8]; wd_en <= cpu_a[9]; end
end

// ------------------------------------------------------------------ vblank: NMI, watchdog, sprite DMA
logic       nmi_q = 1'b0;
logic [3:0] wd_cnt = 4'd0;
logic       wd_reset = 1'b0;
logic [7:0] scroll_x, scroll_y, pal_bank;

wire [3:0] wd_nx = (nmi_en || !wd_en) ? 4'd0 : wd_cnt + 4'd1;

always_ff @(posedge clk) begin
    if (reset) begin
        nmi_q <= 1'b0; wd_cnt <= 4'd0; wd_reset <= 1'b0; dma_req <= 1'b0; dma_go <= 1'b0;
        scroll_x <= 8'd0; scroll_y <= 8'd0; pal_bank <= 8'd0;
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
        // DMA: RAM address follows dma_n once the bus is granted; data is taken on the next CPU clock
        dma_go <= dma_own;
        if (dma_wr) begin
            case (dma_n)
                10'd0: scroll_x <= ram_q;
                10'd1: scroll_y <= ram_q;
                10'd3: pal_bank <= ram_q;
                default: ;
            endcase
            dma_n <= dma_n + 10'd1;
            if (dma_n == 10'h27F) begin dma_req <= 1'b0; dma_go <= 1'b0; end
        end
    end
end

// ------------------------------------------------------------------ AY-3-8910 (7L)
wire       cpu_reset = reset | wd_reset;
wire       ay_wr_a   = iorq && !m1 && wr && cpu_a[1:0] == 2'd0;
wire       ay_wr_d   = iorq && !m1 && wr && cpu_a[1:0] == 2'd1;
wire       ay_rd     = iorq && !m1 && rd && cpu_a[1:0] == 2'd3;
logic [7:0] ay_dout, ay_portb, ay_a, ay_b, ay_c;
logic [9:0] ay_sound;
wire  [2:0] dswbit = ay_portb[3:1];

jt49_bus ay
(
    .rst_n(~cpu_reset), .clk(clk), .clk_en(ay_cen),
    .bdir(ay_wr_a | ay_wr_d), .bc1(ay_wr_a | ay_rd), .din(cpu_d), .dout(ay_dout), .sel(1'b1),
    .sound(ay_sound), .sample(), .A(ay_a), .B(ay_b), .C(ay_c),
    .IOA_in({dsw1[dswbit], dsw0[6:0]}), .IOA_out(), .IOB_in(8'hFF), .IOB_out(ay_portb)
);
wire flip = ay_portb[0];

popeye_sound sound
(
    .clk(clk), .reset(cpu_reset), .ce(ay_cen), .ch_a(ay_a), .ch_b(ay_b), .ch_c(ay_c), .audio(audio)
);

// ------------------------------------------------------------------ CPU read data
logic [7:0] io_q;
always_comb begin
    case (cpu_a[1:0])
        2'd0: io_q = in0;
        2'd1: io_q = in1;
        2'd2: io_q = {in2[7:5], field, in2[3:0]};
        2'd3: io_q = ay_dout;
    endcase
end

always_comb begin
    if (iorq && !m1)    z80pa_0_i.di = io_q;
    else if (sel_rom)   z80pa_0_i.di = rom_q;
    else if (sel_ram)   z80pa_0_i.di = ram_q;
    else if (sel_prot)  z80pa_0_i.di = prot_q;
    else                z80pa_0_i.di = 8'h00;     // write-only text / background RAM, empty 8000-87FF
end

assign z80pa_0_i.reset_n = ~cpu_reset;
assign z80pa_0_i.cen_p   = cen_p & run;
assign z80pa_0_i.cen_n   = cen_n & run;
assign z80pa_0_i.wait_n  = 1'b1;        // /WAIT pulled up (R77)
assign z80pa_0_i.int_n   = 1'b1;
assign z80pa_0_i.nmi_n   = ~nmi_q;
assign z80pa_0_i.busrq_n = ~dma_req;

// ------------------------------------------------------------------ video
popeye_video video
(
    .clk(clk), .reset(reset),
    .flip(flip), .crt_flip(crt_flip), .scroll_x(scroll_x), .scroll_y(scroll_y), .pal_bank(pal_bank[3:0]),
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
