//============================================================================
//
//  chip_pool_pkg — bus types for a multi-board core's shared CPU / sound chip pool
//  Copyright (C) 2026 Rodimus
//
//  Only one board runs at a time, so the CPUs and sound chips are instanced once in rtl/nintendo_board.sv
//  and the active board drives them through these buses (selected by variant). *_i = board to chip,
//  *_o = chip to every board.
//  Nintendo core: z80pa carries BUSRQ / BUSAK (8257 DMA); mcs48 carries T0 / T1, port inputs and the MOVX bus;
//  t65 is the 6502 core of an RP2A03 (its APU, rtl/sound/rp2a03_apu.sv, sits on the board).
//
//============================================================================

package chip_pool_pkg;

// Z80 (T80pa, Mode 0; runtime 8080 mode for the n8080 boards, driven by the dispatcher). RESET_n is on the bus.
typedef struct packed {
    logic        reset_n;
    logic        cen_p;
    logic        cen_n;
    logic        wait_n;
    logic        int_n;
    logic        nmi_n;
    logic        busrq_n;
    logic  [7:0] di;
} z80pa_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
    logic        busak_n;
    logic        inte;                    // IFF1 = the 8080's INTE pin in 8080 mode
} z80pa_o_t;

// 8035 / 8039 (T48 t8039_notri_extrom, EA low, program on pmem)
typedef struct packed {
    logic        reset_n;
    logic        xtal_en;
    logic        int_n;
    logic        t0;
    logic        t1;
    logic  [7:0] p1_in;
    logic  [7:0] p2_in;
    logic  [7:0] db;                    // MOVX read data
    logic  [7:0] pmem_d;
} mcs48_i_t;

typedef struct packed {
    logic  [7:0] p1;
    logic  [7:0] p2;
    logic [11:0] pmem_a;
    logic        rd_n;
    logic        wr_n;
    logic        ale;
    logic  [7:0] db;                    // address (at ALE) / MOVX write data
} mcs48_o_t;

// 6502 (T65, Mode 00). Enable = one CPU cycle.
typedef struct packed {
    logic        res_n;
    logic        enable;
    logic        rdy;
    logic        irq_n;
    logic        nmi_n;
    logic  [7:0] di;
} t65_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        rw;                    // 1 = read
} t65_o_t;

endpackage
