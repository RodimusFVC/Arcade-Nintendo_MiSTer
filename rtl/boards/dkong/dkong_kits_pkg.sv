//============================================================================
//
//  dkong_kits_pkg — read-path decoders for the conversion kits on Donkey Kong hardware (MAME dkong.cpp inits)
//  Copyright (C) 2026 Rodimus
//
//  ROM images are stored as dumped; these decode on the CPU read path (MRA index 1 byte 2 = rom_dec):
//    1     init_dkingjr       palette PROMs c-2k / c-2j read inverted (Donkey King Jr., Up Maguila)
//    2, 3  init_drakton / init_strtheat   Epos PAL10H8 on D0-D7, keyed by a 4-bit counter (MAME drakton_decrypt_rom)
//    4-6   init_dkonghs / init_dkongx / dkongike / init_dkong3hs   Braze Technologies kit: 64K ROM with
//          address lines A8-A14 and all data lines swapped by the board layout (MAME braze_decrypt_rom)
//
//============================================================================

package dkong_kits_pkg;

localparam logic [3:0] DEC_DKINGJR = 4'd1, DEC_DRAKTON = 4'd2, DEC_STRTHEAT = 4'd3,
                       DEC_BRAZE = 4'd4, DEC_BRAZE_X = 4'd5, DEC_BRAZE_IKE = 4'd6;

// Braze: CPU address (decrypted space) -> stored ROM address. MAME writes dest[newmem] = f(rom[mem]) with
// newmem[15:8] = bitswap<8>(mem[15:8], 7,2,3,1,0,6,4,5); this is its inverse (checked over all 64K addresses).
function automatic logic [15:0] braze_addr(input logic [15:0] a);
    braze_addr = {a[15], a[10], a[8], a[9], a[13], a[14], a[12], a[11], a[7:0]};
endfunction

// Braze data: MAME bitswap<8>(d, 1,4,5,7,6,0,3,2)
function automatic logic [7:0] braze_data(input logic [7:0] d);
    braze_data = {d[1], d[4], d[5], d[7], d[6], d[0], d[3], d[2]};
endfunction

// Epos: n = XNOR(d, mod), then bitswap<8>(n, bs[0..7]); bank = counter 8-B -> 0-3
function automatic logic [7:0] epos_dec(input logic [7:0] d, input logic strtheat, input logic [1:0] bank);
    logic [7:0] n;
    case ({strtheat, bank})
        3'd0: begin n = ~(d ^ 8'h02); epos_dec = {n[7], n[6], n[1], n[3], n[0], n[4], n[2], n[5]}; end   // Drakton
        3'd1: begin n = ~(d ^ 8'h40); epos_dec = {n[7], n[1], n[4], n[3], n[0], n[6], n[2], n[5]}; end
        3'd2: begin n = ~(d ^ 8'h8A); epos_dec = {n[7], n[6], n[1], n[0], n[3], n[4], n[2], n[5]}; end
        3'd3: begin n = ~(d ^ 8'hC8); epos_dec = {n[7], n[1], n[4], n[0], n[3], n[6], n[2], n[5]}; end
        3'd4: begin n = ~(d ^ 8'h03); epos_dec = {n[0], n[6], n[1], n[7], n[3], n[4], n[2], n[5]}; end   // Street Heat
        3'd5: begin n = ~(d ^ 8'h81); epos_dec = {n[0], n[6], n[4], n[1], n[3], n[7], n[2], n[5]}; end
        3'd6: begin n = ~(d ^ 8'h0A); epos_dec = {n[6], n[3], n[1], n[7], n[0], n[4], n[2], n[5]}; end
        default: begin n = ~(d ^ 8'h88); epos_dec = {n[6], n[3], n[4], n[1], n[0], n[7], n[2], n[5]}; end
    endcase
endfunction

endpackage
