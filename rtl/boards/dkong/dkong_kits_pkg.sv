//  Based on MAME dkong.cpp (Couriersud, BSD-3-Clause)
//  Copyright (C) 2026 Rodimus

package dkong_kits_pkg;

localparam logic [3:0] DEC_DKINGJR = 4'd1, DEC_DRAKTON = 4'd2, DEC_STRTHEAT = 4'd3,
                       DEC_BRAZE = 4'd4, DEC_BRAZE_X = 4'd5, DEC_BRAZE_IKE = 4'd6;

function automatic logic [15:0] braze_addr(input logic [15:0] a);
    braze_addr = {a[15], a[10], a[8], a[9], a[13], a[14], a[12], a[11], a[7:0]};
endfunction

function automatic logic [7:0] braze_data(input logic [7:0] d);
    braze_data = {d[1], d[4], d[5], d[7], d[6], d[0], d[3], d[2]};
endfunction

function automatic logic [7:0] epos_dec(input logic [7:0] d, input logic strtheat, input logic [1:0] bank);
    logic [7:0] n;
    case ({strtheat, bank})
        3'd0: begin n = ~(d ^ 8'h02); epos_dec = {n[7], n[6], n[1], n[3], n[0], n[4], n[2], n[5]}; end
        3'd1: begin n = ~(d ^ 8'h40); epos_dec = {n[7], n[1], n[4], n[3], n[0], n[6], n[2], n[5]}; end
        3'd2: begin n = ~(d ^ 8'h8A); epos_dec = {n[7], n[6], n[1], n[0], n[3], n[4], n[2], n[5]}; end
        3'd3: begin n = ~(d ^ 8'hC8); epos_dec = {n[7], n[1], n[4], n[0], n[3], n[6], n[2], n[5]}; end
        3'd4: begin n = ~(d ^ 8'h03); epos_dec = {n[0], n[6], n[1], n[7], n[3], n[4], n[2], n[5]}; end
        3'd5: begin n = ~(d ^ 8'h81); epos_dec = {n[0], n[6], n[4], n[1], n[3], n[7], n[2], n[5]}; end
        3'd6: begin n = ~(d ^ 8'h0A); epos_dec = {n[6], n[3], n[1], n[7], n[0], n[4], n[2], n[5]}; end
        default: begin n = ~(d ^ 8'h88); epos_dec = {n[6], n[3], n[4], n[1], n[0], n[7], n[2], n[5]}; end
    endcase
endfunction

endpackage
