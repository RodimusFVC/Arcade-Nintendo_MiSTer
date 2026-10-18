//============================================================================
//
//  Zilog Z80 DMA (Z8410), the parts the Nintendo boards use
//  Copyright (C) 2026 Rodimus
//
//  From the Zilog Z80 CPU Peripherals User Manual (UM008101), DMA chapter:
//    WR0-WR6 base bytes and their follow bytes in manual order; commands C3 reset, C7 / CB reset timing, CF load,
//    D3 continue, 87 / 83 enable / disable DMA, B3 force ready, 8B reinit status, BF read status.
//    Sequential transfer only (no search / simultaneous), A <-> B, memory or I/O, increment / decrement / fixed.
//    Byte, continuous and burst modes; standard Z80 timing (memory 3 T, I/O 4 T) or the WR1 / WR2 cycle-length byte.
//    Block length N moves N + 1 bytes, byte counter stops at N, address counters at start +- (N + 1) (Table 11).
//    The first byte uses the start address; stepping starts at the second byte.
//  Not modelled: search / match, interrupts and vectors, pulse generation, read sequence, half-cycle early ends.
//
//============================================================================

module z80dma
(
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_p,          // CLK rising (one T state per cen_p)

    // CPU port (I/O write / read of the DMA)
    input  logic        cs,
    input  logic        wr,             // one clk strobe
    input  logic        rd,             // one clk strobe
    input  logic  [7:0] din,
    output logic  [7:0] dout,

    input  logic        rdy,
    output logic        busrq,
    input  logic        bai,            // BUSAK from the CPU

    // transfer bus
    output logic        busy,           // owns the bus
    output logic [15:0] addr,
    output logic        mreq,           // with rd / wr below
    output logic        iorq,
    output logic        memr,           // read cycle in progress
    output logic        memw_s,         // one clk write strobe
    input  logic  [7:0] bus_d,          // read data, valid by the cycle's last T
    output logic  [7:0] data            // byte being written
);

// ------------------------------------------------------------------ registers
logic [15:0] a_start, b_start, len;
logic        a_io, b_io, dir_ab;        // dir_ab: A -> B
logic  [1:0] a_step, b_step;            // 00 dec, 01 inc, 1x fixed
logic  [1:0] a_cl, b_cl;                // cycle length code (00 = 4, 01 = 3, 10 = 2)
logic        a_vt, b_vt;                // variable timing programmed
logic  [1:0] mode;                      // 00 byte, 01 continuous, 10 burst
logic        rdy_hi, auto_restart, enabled, force_rdy, eob;

// follow-byte pointer bits, written in this order (manual figures 40-46)
localparam int F_A_LO = 0, F_A_HI = 1, F_LEN_LO = 2, F_LEN_HI = 3, F_A_TIM = 4, F_B_TIM = 5, F_MASK = 6,
               F_MATCH = 7, F_B_LO = 8, F_B_HI = 9, F_INTC = 10, F_PULSE = 11, F_VEC = 12, F_RMASK = 13;
logic [13:0] follow;

function automatic int first_set(input logic [13:0] f);
    first_set = 14;
    for (int i = 13; i >= 0; i--) if (f[i]) first_set = i;
endfunction

// ------------------------------------------------------------------ transfer counters
logic [15:0] a_cnt, b_cnt, byte_cnt;

function automatic [15:0] stepped(input [15:0] x, input [1:0] st);
    stepped = st[1] ? x : st[0] ? x + 16'd1 : x - 16'd1;
endfunction
function automatic [2:0] tlen(input io, input vt, input [1:0] cl);
    if (!vt) tlen = io ? 3'd4 : 3'd3;
    else case (cl) 2'b00: tlen = 3'd4; 2'b01: tlen = 3'd3; default: tlen = 3'd2; endcase
endfunction

wire src_a  = dir_ab;
wire rdy_on = force_rdy | (rdy == rdy_hi);

typedef enum logic [2:0] {D_IDLE, D_REQ, D_READ, D_WRITE, D_HOLD, D_REL} dst_t;
dst_t        st;
logic  [2:0] t;                         // T state within the cycle
logic  [7:0] latch;

// ------------------------------------------------------------------ CPU writes and the transfer engine
always_ff @(posedge clk) begin
    memw_s <= 1'b0;
    if (reset) begin
        follow <= 14'd0; enabled <= 1'b0; force_rdy <= 1'b0; eob <= 1'b0; st <= D_IDLE; busrq <= 1'b0;
        a_vt <= 1'b0; b_vt <= 1'b0; mode <= 2'b01; rdy_hi <= 1'b0; auto_restart <= 1'b0;
        a_io <= 1'b0; b_io <= 1'b0; a_step <= 2'b01; b_step <= 2'b01; dir_ab <= 1'b1;
    end else begin
        if (cs && wr) begin
            if (follow != 14'd0) begin
                case (first_set(follow))
                    F_A_LO:   a_start[7:0]  <= din;
                    F_A_HI:   a_start[15:8] <= din;
                    F_LEN_LO: len[7:0]      <= din;
                    F_LEN_HI: len[15:8]     <= din;
                    F_A_TIM:  a_cl          <= din[1:0];
                    F_B_TIM:  b_cl          <= din[1:0];
                    F_B_LO:   b_start[7:0]  <= din;
                    F_B_HI:   b_start[15:8] <= din;
                    F_INTC:   follow[F_PULSE] <= din[3] | din[2];   // pulse control byte, then vector
                    default: ;
                endcase
                if (first_set(follow) == F_INTC) follow[F_VEC] <= din[4];
                follow[first_set(follow)] <= 1'b0;
            end else if (!din[7] && din[1:0] != 2'b00) begin            // WR0
                dir_ab <= din[2];
                follow[F_A_LO] <= din[3]; follow[F_A_HI] <= din[4]; follow[F_LEN_LO] <= din[5]; follow[F_LEN_HI] <= din[6];
            end else if (!din[7] && din[2:0] == 3'b100) begin           // WR1
                a_io <= din[3]; a_step <= din[5:4]; a_vt <= din[6]; follow[F_A_TIM] <= din[6];
            end else if (!din[7] && din[2:0] == 3'b000) begin           // WR2
                b_io <= din[3]; b_step <= din[5:4]; b_vt <= din[6]; follow[F_B_TIM] <= din[6];
            end else if (din[7] && din[1:0] == 2'b00) begin             // WR3
                follow[F_MASK] <= din[3]; follow[F_MATCH] <= din[4];
                if (din[6]) enabled <= 1'b1;
            end else if (din[7] && din[1:0] == 2'b01) begin             // WR4
                mode <= din[6:5];
                follow[F_B_LO] <= din[2]; follow[F_B_HI] <= din[3]; follow[F_INTC] <= din[4];
            end else if (din[7] && din[2:0] == 3'b010 && !din[6]) begin // WR5
                rdy_hi <= din[3]; auto_restart <= din[5];
            end else if (din[7] && din[1:0] == 2'b11) begin             // WR6 commands
                case (din)
                    8'hC3: begin enabled <= 1'b0; force_rdy <= 1'b0; auto_restart <= 1'b0; a_vt <= 1'b0; b_vt <= 1'b0;
                                 follow <= 14'd0; end
                    8'hC7: a_vt <= 1'b0;
                    8'hCB: b_vt <= 1'b0;
                    8'hCF: begin a_cnt <= a_start; b_cnt <= b_start; byte_cnt <= 16'd0; force_rdy <= 1'b0; eob <= 1'b0; end
                    8'hD3: begin byte_cnt <= 16'd0; eob <= 1'b0; end
                    8'h87: enabled <= 1'b1;
                    8'h83: enabled <= 1'b0;
                    8'hB3: force_rdy <= 1'b1;
                    8'h8B: eob <= 1'b0;
                    8'hBB: follow[F_RMASK] <= 1'b1;
                    default: ;
                endcase
            end
        end

        // transfer engine: one T state per cen_p
        if (cen_p) case (st)
            D_IDLE: if (enabled && rdy_on) begin busrq <= 1'b1; st <= D_REQ; end
            D_REQ:  if (bai) begin t <= 3'd1; st <= D_READ; end
            D_READ: begin
                if (t == tlen(src_a ? a_io : b_io, src_a ? a_vt : b_vt, src_a ? a_cl : b_cl)) begin
                    latch <= bus_d; t <= 3'd1; st <= D_WRITE;
                end else t <= t + 3'd1;
            end
            D_WRITE: begin
                if (t == 3'd2) memw_s <= 1'b1;
                if (t == tlen(src_a ? b_io : a_io, src_a ? b_vt : a_vt, src_a ? b_cl : a_cl)) begin
                    a_cnt <= stepped(a_cnt, a_step);
                    b_cnt <= stepped(b_cnt, b_step);
                    if (byte_cnt == len) begin                              // end of block
                        eob <= 1'b1;
                        if (auto_restart) begin a_cnt <= a_start; b_cnt <= b_start; byte_cnt <= 16'd0; end
                        else enabled <= 1'b0;
                    end else byte_cnt <= byte_cnt + 16'd1;
                    // byte mode releases after every byte; burst when Ready drops; continuous only at the end
                    if (byte_cnt == len && !auto_restart || mode == 2'b00 || (mode == 2'b10 && !rdy_on)) begin
                        busrq <= 1'b0; st <= D_REL;
                    end else begin t <= 3'd1; st <= rdy_on ? D_READ : D_HOLD; end
                end else t <= t + 3'd1;
            end
            D_HOLD: if (rdy_on) st <= D_READ;                               // continuous: keep the bus, wait for Ready
            D_REL:  if (!bai) st <= D_IDLE;
            default: st <= D_IDLE;
        endcase
    end
end

// ------------------------------------------------------------------ bus outputs
wire rd_port_a = src_a;                 // read cycle uses the source port
assign busy  = st == D_READ || st == D_WRITE;
assign addr  = (st == D_READ) == rd_port_a ? a_cnt : b_cnt;
assign memr  = st == D_READ;
assign mreq  = busy && !((st == D_READ) == rd_port_a ? a_io : b_io);
assign iorq  = busy &&  ((st == D_READ) == rd_port_a ? a_io : b_io);
assign data  = latch;

// status byte (BF): [5] end of block (active low), [4] match (none), [3] interrupt pending (none), [1] Ready, [0] request
assign dout = {2'b00, ~eob, 1'b1, 1'b1, 1'b0, rdy_on, busrq};

endmodule
