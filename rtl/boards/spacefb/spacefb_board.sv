//============================================================================
//
//  Nintendo Space Firebird board (Gremlin TST-CPU 834-0031 / TST-VIDEO 834-0030; MAME spacefb.cpp)
//  Copyright (C) 2026 Rodimus
//
//  Main Z80 at 3 MHz (MAME SPACEFB_MAIN_CPU_CLOCK = 6 MHz / 2). Memory map (MAME spacefb_main_map):
//    0000-3FFF ROM   8000-83FF object RAM (mirror 3C00)   C000-C7FF RAM (mirror 3000; C800-CFFF open)
//  I/O (global mask 7): R 0 P1, 1 P2, 2 SYSTEM, 3 DSW, 4-7 open; W 0 / 4 port 0 (video: flip, object bank, colour
//  bank), W 1 / 5 port 1 (sound board: spacefb_sound.sv), W 2 / 6 port 2 (star field contrast / background / off).
//  Interrupts (MAME interrupt_callback): IRQ held until acknowledged at lines 0x80 and 0xF0, vector
//  0xC7 | (line bit 6 << 4) | (!line bit 6 << 3): RST 08 at 0x80, RST 10 at 0xF0.
//  Ports 0-2 are cleared on reset (MAME machine_reset).
//  No CPU wait states (MAME has none; the block diagram's "ready" path is not traced yet #unverified).
//
//============================================================================

module spacefb_board
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,
    input  logic        pause,
    input  logic        crt_flip,

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,
    output chip_pool_pkg::mcs48_i_t mcs48_0_i,
    input  chip_pool_pkg::mcs48_o_t mcs48_0_o,

    input  logic  [7:0] in0,            // P1
    input  logic  [7:0] in1,            // P2
    input  logic  [7:0] in2,            // SYSTEM
    input  logic  [7:0] dsw0,           // DSW

    // ROMs (shared blocks in rtl/nintendo_board.sv)
    output logic [14:0] rom_a,
    input  logic  [7:0] rom_d,
    output logic [14:0] gfx2_a,         // sprites 5K (0x000) / 6K (0x800)
    input  logic  [7:0] gfx2_d,
    output logic [12:0] gfx1_a,         // bullets 4I (0x00-0xFF)
    input  logic  [7:0] gfx1_d,
    output logic  [7:0] pal_a,          // colour PROM 3N (0x00-0x1F)
    input  logic  [7:0] pal_d,
    output logic [11:0] snd_pa,         // sound 2708 IC20
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

    input  logic [15:0] hs_address,
    input  logic  [7:0] hs_data_in,
    output logic  [7:0] hs_data_out,
    input  logic        hs_write
);

wire run = ~pause;

// ------------------------------------------------------------------ 3 MHz CPU clock: 6 MHz edges from a phase accumulator
logic [15:0] ph_acc = 16'd0;
logic        phi = 1'b0;
logic        cen_p, cen_n;
always_ff @(posedge clk) begin
    cen_p <= 1'b0; cen_n <= 1'b0;
    if (ph_acc + 16'd6000 >= 16'd49152) begin
        ph_acc <= ph_acc + 16'd6000 - 16'd49152;
        phi <= ~phi;
        if (!phi) cen_p <= 1'b1; else cen_n <= 1'b1;
    end else ph_acc <= ph_acc + 16'd6000;
end

// ------------------------------------------------------------------ Z80
wire [15:0] cpu_a = z80pa_0_o.a;
wire  [7:0] cpu_d = z80pa_0_o.dout;
wire        mreq  = ~z80pa_0_o.mreq_n;
wire        iorq  = ~z80pa_0_o.iorq_n;
wire        m1    = ~z80pa_0_o.m1_n;
wire        rd    = ~z80pa_0_o.rd_n;
wire        wr    = ~z80pa_0_o.wr_n;

logic wr_q = 1'b0, iow_q = 1'b0;
always_ff @(posedge clk) begin wr_q <= wr & mreq; iow_q <= wr & iorq; end
wire cpu_we = wr & mreq & ~wr_q;        // one clock per write cycle
wire io_we  = wr & iorq & ~m1 & ~iow_q;

wire sel_rom = cpu_a[15:14] == 2'b00;                               // 0000-3FFF
wire sel_obj = cpu_a[15:14] == 2'b10;                               // 8000-83FF, mirror 3C00
wire sel_ram = cpu_a[15:14] == 2'b11 && !cpu_a[11];                 // C000-C7FF, mirror 3000

assign rom_a = {1'b0, cpu_a[13:0]};

// ------------------------------------------------------------------ RAMs
logic [7:0] ram_q;
dpram_dc #(.widthad_a(11)) ram
(
    .clock_a(clk), .address_a(cpu_a[10:0]), .data_a(cpu_d), .wren_a(cpu_we & sel_ram), .q_a(ram_q),
    .clock_b(clk), .address_b(hs_address[10:0]), .data_b(hs_data_in), .wren_b(hs_write & pause), .q_b(hs_data_out)
);

// object RAM: four 256-byte pages (x, y, code, attributes), all read at once by the video
logic [7:0] obj_va;
logic [7:0] obj_cq [4];
logic [7:0] obj_vq [4];
genvar pg;
generate
    for (pg = 0; pg < 4; pg++) begin : objp
        dpram_dc #(.widthad_a(8)) obj
        (
            .clock_a(clk), .address_a(cpu_a[7:0]), .data_a(cpu_d), .wren_a(cpu_we && sel_obj && cpu_a[9:8] == pg),
            .q_a(obj_cq[pg]),
            .clock_b(clk), .address_b(obj_va), .q_b(obj_vq[pg])
        );
    end
endgenerate

// ------------------------------------------------------------------ output ports
logic [7:0] port0, port1, port2;
always_ff @(posedge clk) begin
    if (reset) begin port0 <= 8'd0; port1 <= 8'd0; port2 <= 8'd0; end
    else if (io_we) begin
        case (cpu_a[1:0])
            2'd0: port0 <= cpu_d;
            2'd1: port1 <= cpu_d;
            2'd2: port2 <= cpu_d;
            default: ;
        endcase
    end
end

// ------------------------------------------------------------------ interrupts (held until INTA)
logic       irq_80, irq_f0, v2;
logic       int_q = 1'b0;
logic [7:0] int_vec = 8'hFF;
// INTA = M1 + IORQ without MREQ: T80pa's IntCycleD_n has no reset / power-up value, so the first opcode fetch after a
// cold reset can show IORQ low with MREQ (sim: the vector byte replaced opcode 00 -> RST 38 boot)
wire        inta = m1 & iorq & ~mreq;
always_ff @(posedge clk) begin
    if (reset) int_q <= 1'b0;
    else begin
        if (irq_80) begin int_q <= 1'b1; int_vec <= 8'hCF; end
        else if (irq_f0) begin int_q <= 1'b1; int_vec <= 8'hD7; end
        else if (inta) int_q <= 1'b0;
    end
end

// ------------------------------------------------------------------ CPU read data
logic [7:0] io_q;
always_comb begin
    case (cpu_a[2:0])
        3'd0: io_q = in0;
        3'd1: io_q = in1;
        3'd2: io_q = in2;
        3'd3: io_q = dsw0;
        default: io_q = 8'h00;
    endcase
end

always_comb begin
    if (inta)              z80pa_0_i.di = int_vec;
    else if (iorq && !m1)  z80pa_0_i.di = io_q;
    else if (sel_rom)      z80pa_0_i.di = rom_d;
    else if (sel_obj)      z80pa_0_i.di = obj_cq[cpu_a[9:8]];
    else if (sel_ram)      z80pa_0_i.di = ram_q;
    else                   z80pa_0_i.di = 8'h00;
end

assign z80pa_0_i.reset_n = ~reset;
assign z80pa_0_i.cen_p   = cen_p & run;
assign z80pa_0_i.cen_n   = cen_n & run;
assign z80pa_0_i.wait_n  = 1'b1;
assign z80pa_0_i.int_n   = ~int_q;
assign z80pa_0_i.nmi_n   = 1'b1;
assign z80pa_0_i.busrq_n = 1'b1;

// ------------------------------------------------------------------ video
spacefb_video video
(
    .clk(clk), .reset(reset),
    .flip(port0[0]), .crt_flip(crt_flip), .bank(port0[5]), .cref(port0[6]), .port2(port2),
    .ce_pix(ce_pix), .irq_80(irq_80), .irq_f0(irq_f0), .v2(v2),
    .obj_a(obj_va), .obj_x(obj_vq[0]), .obj_y(obj_vq[1]), .obj_code(obj_vq[2]), .obj_attr(obj_vq[3]),
    .gfx2_a(gfx2_a), .gfx2_d(gfx2_d), .gfx1_a(gfx1_a), .gfx1_d(gfx1_d[3:0]), .pal_a(pal_a), .pal_d(pal_d),
    .r(video_r), .g(video_g), .b(video_b),
    .hblank(video_hblank), .vblank(video_vblank), .hsync(video_hs), .vsync(video_vs)
);

// ------------------------------------------------------------------ sound board
spacefb_sound sound
(
    .clk(clk), .reset(reset), .pause(pause),
    .mcs48_0_i(mcs48_0_i), .mcs48_0_o(mcs48_0_o),
    .port1(port1), .v2(v2), .pa(snd_pa), .pd(snd_pd), .audio(audio)
);

endmodule
