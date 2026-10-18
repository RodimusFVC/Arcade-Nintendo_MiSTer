//============================================================================
//
//  Intel 8257 DMA controller (the parts the Nintendo boards use)
//  Copyright (C) 2026 Rodimus
//
//  State machine as MAME i8257_device: SI -> S0 (HRQ, wait HLDA) -> S1 -> S2 -> S3 (read) -> S4 (write, advance);
//  S4 goes straight to S1 while a request is pending, else drops HRQ. One state per ce (the 8257 CLK).
//  Mode register: [3:0] channel enable, [4] rotating priority, [6] TC stop, [7] autoload (ch2 <- ch3).
//  Transfer type from count[15:14]; rev_rw swaps read / write as MAME set_reverse_rw_mode (DK boards).
//  READY tied high, extended write not modelled. Memory and I/O are the board's: addr / memr / memw / ior / iow.
//
//============================================================================

module i8257
(
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,             // 8257 CLK
    input  logic        rev_rw,

    // CPU port
    input  logic        cs,
    input  logic  [3:0] a,
    input  logic        wr,             // one clk strobe
    input  logic        rd,             // one clk strobe (advances the MSB flip-flop / clears TC bits)
    input  logic  [7:0] din,
    output logic  [7:0] dout,

    input  logic  [3:0] drq,
    output logic        hrq,
    input  logic        hlda,

    // transfer bus
    output logic [15:0] addr,
    output logic  [1:0] chan,
    output logic        busy,           // owns the bus (S1-S4)
    output logic        ior,            // one clk strobes
    output logic        iow,
    output logic        memr,
    output logic        memw,
    input  logic  [7:0] mem_d,          // memory data, valid by S3
    input  logic  [7:0] io_d,           // I/O data for channel chan, valid by S3
    output logic  [7:0] data            // transfer byte (to memory / I/O on the write strobe)
);

localparam [2:0] SI = 3'd0, S0 = 3'd1, S1 = 3'd2, S2 = 3'd3, S3 = 3'd4, S4 = 3'd5;
localparam [1:0] T_VERIFY = 2'd0, T_WRITE = 2'd1, T_READ = 2'd2;

logic [15:0] ch_addr[4];
logic [13:0] ch_count[4];
logic  [1:0] ch_mode[4];
logic  [7:0] mode;
logic  [7:0] status;
logic        msb;
logic  [2:0] state;
logic  [1:0] cur, last;
logic        tc;

// request selection: fixed priority 0..3, or rotating starting after the channel served last
function automatic [2:0] pick(input [3:0] r, input rot, input [1:0] lst);   // {found, channel}
    logic [1:0] c;
    pick = 3'd0;
    for (int k = 3; k >= 0; k--) begin
        c = rot ? lst + 2'd1 + 2'(k) : 2'(k);
        if (r[c]) pick = {1'b1, c};
    end
endfunction

wire  [3:0] req = drq & mode[3:0];
wire  [2:0] sel = pick(req, mode[4], last);
// S4: MAME advance() (TC stop may disable this channel) happens before next_channel()
wire        tc_now  = tc || (ch_count[cur] == 14'd0 && ch_mode[cur] == T_READ);
wire        al_now  = mode[7] && cur == 2'd2;
wire  [3:0] en_s4   = mode[3:0] & ~((tc_now && mode[6] && !al_now) ? (4'd1 << cur) : 4'd0);
wire  [2:0] sel_s4  = pick(drq & en_s4, mode[4], cur);

wire [1:0] cur_mode = ch_mode[cur];

// address / channel latched at S1: the strobes come one clock after S3 / S4, when S4 has already advanced the channel
logic [15:0] xfer_addr;
logic  [1:0] xfer_chan;
assign addr = xfer_addr;
assign chan = xfer_chan;
assign busy = (state == S1) || (state == S2) || (state == S3) || (state == S4) || memw || iow;

// register reads
always_comb begin
    if (!a[3]) dout = a[0] ? (msb ? {(rev_rw && ch_mode[a[2:1]] != 2'd0) ? (ch_mode[a[2:1]] == T_WRITE ? 2'b10 : 2'b01)
                                                                         : ch_mode[a[2:1]], ch_count[a[2:1]][13:8]}
                                  : ch_count[a[2:1]][7:0])
                           : (msb ? ch_addr[a[2:1]][15:8] : ch_addr[a[2:1]][7:0]);
    else       dout = status;
end

always_ff @(posedge clk) begin
    ior <= 1'b0; iow <= 1'b0; memr <= 1'b0; memw <= 1'b0;
    if (reset) begin
        state <= SI; mode <= 8'd0; status <= 8'd0; msb <= 1'b0; cur <= 2'd0; last <= 2'd3; hrq <= 1'b0; tc <= 1'b0;
        for (int k = 0; k < 4; k++) begin ch_addr[k] <= 16'd0; ch_count[k] <= 14'd0; ch_mode[k] <= 2'd0; end
    end else begin
        if (cs && wr) begin
            if (!a[3]) begin
                if (!a[0]) begin
                    if (msb) ch_addr[a[2:1]][15:8] <= din; else ch_addr[a[2:1]][7:0] <= din;
                    if (mode[7] && a[2:1] == 2'd2) begin
                        if (msb) ch_addr[3][15:8] <= din; else ch_addr[3][7:0] <= din;
                    end
                end else begin
                    if (msb) begin
                        ch_count[a[2:1]][13:8] <= din[5:0];
                        ch_mode[a[2:1]] <= (rev_rw && din[7:6] != 2'd0) ? (din[7:6] == 2'd1 ? T_READ : T_WRITE) : din[7:6];
                    end else ch_count[a[2:1]][7:0] <= din;
                    if (mode[7] && a[2:1] == 2'd2) begin
                        if (msb) begin ch_count[3][13:8] <= din[5:0]; ch_mode[3] <= ch_mode[2]; end
                        else ch_count[3][7:0] <= din;
                    end
                end
                msb <= ~msb;
            end else if (a == 4'd8)
                mode <= din;
        end
        if (cs && rd) begin
            if (!a[3]) msb <= ~msb;
            else if (a == 4'd8) status <= status & 8'hF0;
        end

        if (ce) begin
            case (state)
                SI: begin
                    tc <= 1'b0;
                    if (sel[2]) begin cur <= sel[1:0]; last <= sel[1:0]; state <= S0; end
                end
                S0: begin
                    hrq <= 1'b1;
                    if (hlda && hrq) state <= S1;
                end
                S1: begin tc <= 1'b0; xfer_addr <= ch_addr[cur]; xfer_chan <= cur; state <= S2; end
                S2: state <= S3;
                S3: begin
                    if (cur_mode == T_WRITE) begin data <= io_d;  ior  <= 1'b1; end
                    if (cur_mode == T_READ)  begin data <= mem_d; memr <= 1'b1; end
                    if (ch_count[cur] == 14'd0 && cur_mode != T_READ) tc <= 1'b1;
                    state <= S4;
                end
                S4: begin
                    if (cur_mode == T_WRITE) memw <= 1'b1;
                    if (cur_mode == T_READ)  iow  <= 1'b1;
                    if (tc_now) begin
                        status[cur] <= 1'b1;
                        if (al_now) begin
                            ch_addr[2] <= ch_addr[3]; ch_count[2] <= ch_count[3]; ch_mode[2] <= ch_mode[3];
                        end else if (mode[6])
                            mode[cur] <= 1'b0;
                    end
                    if (!(al_now && tc_now)) begin
                        ch_count[cur] <= ch_count[cur] - 14'd1;
                        ch_addr[cur]  <= ch_addr[cur] + 16'd1;
                    end
                    tc <= 1'b0;
                    if (hlda && sel_s4[2]) begin
                        cur <= sel_s4[1:0]; last <= sel_s4[1:0]; state <= S1;
                    end else begin
                        hrq <= 1'b0; state <= SI;
                    end
                end
                default: state <= SI;
            endcase
        end
    end
end

endmodule
