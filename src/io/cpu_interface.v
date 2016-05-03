`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2015/12/15 21:16:02
// Design Name: 
// Module Name: cpu_interface
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
// 0~128MB: main memory
// 0xc000000~ : vmem (Block RAM)
// 0xd000000~ : clock
// 0xe000000~ : keyboard
//////////////////////////////////////////////////////////////////////////////////


module cpu_interface(
    // ddr Inouts
    inout [15:0]                         ddr2_dq,
    inout [1:0]                        ddr2_dqs_n,
    inout [1:0]                        ddr2_dqs_p,

    input rst,
    input [29:0] instr_addr,
    input dmem_read_in, 
    input dmem_write_in,
    input [29:0] dmem_addr,
    input [31:0] data_from_reg,
    input [3:0] dc_byte_w_en,
    input clk_from_ip,

    output ui_clk,
    output [31:0] instr_data_out,
    output [31:0] dmem_data_out,
    output mem_stall,

    // ddr Outputs
    output [12:0]                       ddr2_addr,
    output [2:0]                      ddr2_ba,
    output                                       ddr2_ras_n,
    output                                       ddr2_cas_n,
    output                                       ddr2_we_n,
    output [0:0]                        ddr2_ck_p,
    output [0:0]                        ddr2_ck_n,
    output [0:0]                       ddr2_cke,
    output [0:0]           ddr2_cs_n,
    output [1:0]                        ddr2_dm,
    output [0:0]                       ddr2_odt
);
localparam VMEM_START   = 32'hc0000000;
localparam TIMER_START  = 32'hd0000000;
localparam KBD_START    = 32'he0000000;
localparam LOADER_START    = 32'hf0000000;

wire [255:0] block_from_ram;
wire ram_rdy;
wire ram_en;
wire ram_write;
wire [29:0] ram_addr;
wire [255:0] block_from_dc_to_ram;

wire [31:0] dc_data_out;
wire [31:0] loader_data;

reg dc_read_in, dc_write_in;

always @ (*) begin
    // data R/W redirect
    dc_read_in = dmem_read_in;
    dc_write_in = dmem_write_in;
    dmem_data_out = dc_data_out;
    if(dmem_addr[31:28] == 4'hc) begin // VMEM
        dc_read_in = 0;
        dc_write_in = 0;
        dmem_data_out = 32'd0; // never read
    end
    if(dmem_addr[31:28] == 4'hd) begin // timer
        dc_read_in = 0;
        dc_write_in = 0;
        dmem_data_out = 32'd0; // not added now
    end
    else if(dmem_addr[31:28] == 4'he) begin //keyborad
        dc_read_in = 0;
        dc_write_in = 0;
        dmem_data_out = 32'd0; // not added now
    end

    // instruction fetch redirect
    ic_addr = instr_addr;
    instr_data_out = ic_data_out;
    if(instr_addr[31:28] == 4'hf) begin
        instr_data_out = loader_data;
    end
end

cache_manage_unit u_cm_0 (
    .clk             ( ui_clk               ),
    .rst             ( ~rst                 ), // !! make rst seem low active
    .dc_read_in      ( dc_read_in           ),
    .dc_write_in     ( dc_write_in          ),
    .dc_byte_w_en_in ( dc_byte_w_en         ),
    .ic_addr         ( ic_addr              ),
    .dc_addr         ( dmem_addr            ),
    .data_from_reg   ( data_from_reg        ),

    .ram_ready       ( ram_rdy              ),
    .block_from_ram  ( block_from_ram       ),

    .mem_stall       ( mem_stall            ),
    .dc_data_out     ( dc_data_out        ),
    .ic_data_out     ( ic_data_out          ),

    .ram_en_out      ( ram_en               ),
    .ram_write_out   ( ram_write            ),
    .ram_addr_out    ( ram_addr             ),
    .dc_data_wb      ( block_from_dc_to_ram )
);

ddr_ctrl ddr_ctrl_0(
    // Inouts
    .ddr2_dq                    (ddr2_dq                        ),
    .ddr2_dqs_n                 (ddr2_dqs_n                     ),
    .ddr2_dqs_p                 (ddr2_dqs_p                     ),

    // original signals
    .clk_from_ip                (clk_from_ip                    ),
    .rst                        (rst                            ),
    .ram_en                     (ram_en                         ),
    .ram_write                  (ram_write                      ),
    .ram_addr                   (ram_addr[29:0]                 ),
    .data_to_ram                (block_from_dc_to_ram           ),

    .ram_rdy                    (ram_rdy                        ),
    .block_out                  (block_from_ram                 ),
    .ui_clk                     (ui_clk                         ),
    // Outputs
    .ddr2_addr                  (ddr2_addr                      ),
    .ddr2_ba                    (ddr2_ba                        ),
    .ddr2_ras_n                 (ddr2_ras_n                     ),
    .ddr2_cas_n                 (ddr2_cas_n                     ),
    .ddr2_we_n                  (ddr2_we_n                      ),
    .ddr2_ck_p                  (ddr2_ck_p                      ),
    .ddr2_ck_n                  (ddr2_ck_n                      ),
    .ddr2_cke                   (ddr2_cke                       ),
    .ddr2_cs_n                  (ddr2_cs_n                      ),
    .ddr2_dm                    (ddr2_dm                        ),
    .ddr2_odt                   (ddr2_odt                       )
);


endmodule
