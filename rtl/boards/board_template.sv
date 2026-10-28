//============================================================================
//  board_template.sv - start a new Nintendo-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, sound chip, DMA controller, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/nintendo_dispatcher.sv: the Z80 z80pa_0 (T80pa, z80pa_* buses; runtime 8080 mode), the 8035 / 8039 mcs48_0
//  (mcs48_*), the 6502 cores t65_0 / t65_1 (t65_*; the RP2A03 glue + APU, rtl/sound/rp2a03.sv, sits on the board as on
//  PunchOut), the DMA controllers i8257_0 / z80dma_0, the AY ay_0 (ayr_i_t / ayio_o_t), the SN76477 sn76477_0, the shared
//  sound multiplier (mul_a / mul_b / mul_p), the ROM blocks (CPU, sound, sound 2, gfx1, gfx2, palette / colour PROMs;
//  loaded by ioctl index and address) and the board RAM pool pr 0-8 (16K, 1K, 4 x 256, 2K, 4K, 4K).
//  To add a board: copy this file to rtl/boards/<board>/<board>.sv, add it to files.qip (verilator/Makefile picks up
//  rtl/boards/<board>/*.sv), instance it in the dispatcher, put its buses on the pools' variant muxes there and tie
//  what it doesn't use to '0. A RAM bigger than its block = grow the block, never a private dpram_dc / spram. ROM
//  images: load decode by ioctl index and address only, NEVER by a game flag. A RAM / chip that truly can't pool =
//  "// POOL-EXCEPTION: <reason>" on its instance line + a Pool contract row (Claude/ vault note).
//  verilator/common/pool_check.sh (POOL_MODS) enforces it.
//============================================================================

module board_template
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,          // core reset | this board inactive
    input  logic        pause,

    output chip_pool_pkg::z80pa_i_t z80pa_0_i,
    input  chip_pool_pkg::z80pa_o_t z80pa_0_o,

    output logic [15:0] rom_a,          // CPU ROM block read port
    input  logic  [7:0] rom_d,

    output ram_pool_pkg::pram_i_t [8:0] pr_i,
    input  ram_pool_pkg::pram_o_t [8:0] pr_o,

    output logic signed [15:0] audio
);

assign z80pa_0_i = '0;
assign rom_a     = 16'd0;
assign pr_i      = '0;
assign audio     = 16'sd0;

endmodule
