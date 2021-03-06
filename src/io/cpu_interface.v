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
    inout [15:0] ddr2_dq,
    inout [1:0] ddr2_dqs_n,
    inout [1:0] ddr2_dqs_p,

    input rst,
    input [29:0] instr_addr,
    input dmem_read_in,
    input dmem_write_in,
    input [29:0] dmem_addr,
    input [31:0] data_from_reg,
    input [3:0] dmem_byte_w_en,
    input clk_for_ddr,
    input pixel_clk,
    input manual_clk,
    input clk_pipeline,

    output ui_clk,
    output reg sync_manual_clk,
    output reg [31:0] instr_data_out,
    output reg [31:0] dmem_data_out,
    output mem_stall,

    // ddr Outputs
    output [12:0] ddr2_addr,
    output [2:0] ddr2_ba,
    output ddr2_ras_n,
    output ddr2_cas_n,
    output ddr2_we_n,
    output [0:0] ddr2_ck_p,
    output [0:0] ddr2_ck_n,
    output [0:0] ddr2_cke,
    output [0:0] ddr2_cs_n,
    output [1:0] ddr2_dm,
    output [0:0] ddr2_odt,

    input  [12:0] loader_addr,
    output [31:0] loader_data_o,

    //debug:
    output [127:0] data_to_mig,
    output [255:0] buffer_of_ddrctrl,
    output [26:0] addr_to_mig,
    output cache_stall,
    output reg trap_stall,

    // VGA outputs
    output [3:0] VGA_R,
    output [3:0] VGA_G,
    output [3:0] VGA_B,
    output VGA_HS,
    output VGA_VS
);

localparam VMEM_START   = 32'hc0000000;
localparam TIMER_START  = 32'hd0000000;
localparam KBD_START    = 32'he0000000;
localparam LOADER_START = 32'hf0000000;

wire [255:0] block_from_ram;
wire ram_rdy;
wire ram_en;
wire ram_write;
wire [29:0] ram_addr;
wire [255:0] block_from_dc_to_ram;

wire [31:0] dc_data_out;
wire [31:0] ic_data_out;
wire [31:0] loader_instr;
wire [31:0] loader_data;
reg [29:0] ic_addr;

reg ic_read_in, dc_read_in, dc_write_in;
reg loader_wen;  // accessing loader mapping area & writing request
reg [14:0] vga_addr; // 2**15 is enough for vga mem
reg [7:0] char_to_vga;

// debug variables
wire [127:0] data_from_mig;

wire [2:0] cache_status;
wire [2:0] cache_counter;
wire mig_rdy;
wire mig_wdf_rdy;
wire mig_ddr_inited;
wire mig_data_end;
wire mig_data_valid;
wire ddr_ctrl_reading;
wire ddr_ctrl_writing;

reg [127:0] debug_queue [63:0];
reg [5:0] dbg_que_start;
reg [5:0] dbg_que_end;
reg dbg_status;
reg [6:0] miss_count;

wire [127:0] que_input = {
    data_to_mig[31:0],
    data_from_mig[31:0],

    5'd0,
    addr_to_mig,

    cache_status,
    cache_counter,
    mig_rdy,
    mig_wdf_rdy,
    mig_ddr_inited,
    mig_data_end,
    mig_data_valid,
    ddr_ctrl_reading,
    ddr_ctrl_writing,
    miss_count,
    12'd0
};

// vga_wen is synchronized by pixel_clk to avoid race between wen, addr & char.
// vga_stall is a combinational logic which just indicates the address to write
// falls in text memory.
// vga_stall_cnt is used to stall enough pixel cycles, whose value can be
// considered simply as a
// cycle counter as well as the following semantic meaning:
//   0 - initial state, nothing happened
//   1 - starting / during the 1st pixel cycle to write;
//   2 - starting / during the 2nd pixel cycle to write;
//   3 - writing finished and the counter will spin on this value to ensure that
//       pipeline retrieves from stalling.
reg vga_wen;
reg vga_stall;
reg [1:0] vga_stall_cnt;
reg loader_en;
// reg loaded;

// As vga_stall is a combinational logic, the pipeline will stall immediately
// while the vga_wen needs a posedge of pixel_clk to become active.
// At that time, the address and char data are stable. `vga_stall_cnt < 3'
// ensures that the pipeline will recover as soon as the writing finishes.
assign mem_stall = cache_stall
        | (vga_stall && (vga_stall_cnt < 3))
        | trap_stall;

wire text_mem_clk = ui_clk;  // The clock driving text memory

always @ (posedge ui_clk) begin
    sync_manual_clk <= manual_clk;
end

always @ (posedge text_mem_clk) begin
    if (!rst || !vga_stall) begin  // when reseted (low-active)
              //  or not accessing vmem, keep this initial state
        vga_wen <= 0;
        vga_stall_cnt <= 0;
    end
    else if (vga_stall) begin
        if (vga_stall_cnt >= 2) begin
            // spin state, disabling write enable, allowing the pipeline to go
            // on,and expecting the pipeline to reset the state.
            vga_wen <= 0;
            vga_stall_cnt <= 3;
        end
        else begin
            vga_wen <= 1;
            vga_stall_cnt <= vga_stall_cnt + 1;
        end
    end
end

always @ (*) begin
    // data R/W redirect
    // default value, which have the least effects on the memory system.
    ic_read_in    = 1;
    dc_read_in    = 0;
    dc_write_in   = 0;
    dmem_data_out = 0;
    vga_stall     = 0;
    loader_wen    = 0;
    loader_en     = 0;
    trap_stall    = 0;

    if (dmem_addr[29:26] == 4'hc) begin // VMEM
        vga_stall = dmem_write_in;
    end
    else if (dmem_addr[29:26] == 4'hd) begin // timer
        // TODO dmem_data_out = timer_data
        // now use 0xdxxx to trap!
        if (dmem_addr[25:18] == 8'hdd) begin
            trap_stall = dmem_read_in | dmem_write_in;
        end
        else begin
            if (dmem_addr[25:0] == 26'h3000001) begin
                dmem_data_out = {26'd0, dbg_que_start};
            end
            else if (dmem_addr[25:0] == 26'h3000002) begin
                dmem_data_out = {26'd0, dbg_que_end};
            end
            else begin
                if (dmem_addr[1:0] == 0) begin
                    dmem_data_out = debug_queue[dmem_addr[7:2]][31:0];
                end
                else if (dmem_addr[1:0] == 1) begin
                    dmem_data_out = debug_queue[dmem_addr[7:2]][63:32];
                end
                else if (dmem_addr[1:0] == 2) begin
                    dmem_data_out = debug_queue[dmem_addr[7:2]][95:64];
                end
                else begin
                    dmem_data_out = debug_queue[dmem_addr[7:2]][127:96];
                end
            end
        end
    end
    else if (dmem_addr[29:26] == 4'he) begin //keyborad
        // TODO dmem_data_out = kb_data, and needs further consideration.
    end
    else if (dmem_addr[29:26] == 4'hf) begin  // loader
        loader_en = 1;
        loader_wen  = dmem_write_in;
        dmem_data_out = loader_data;
    end
    else begin  // data cache
        dc_read_in    = dmem_read_in;
        dc_write_in   = dmem_write_in;
        dmem_data_out = dc_data_out;
    end

    // instruction fetch redirect
    ic_addr = instr_addr;
    instr_data_out = ic_data_out;
    if (instr_addr[29:26] == 4'hf) begin
        loader_en = 1;
        ic_read_in = 0;
        instr_data_out = loader_instr;
    end

    // vga ddr calculate

    vga_addr[14:2] = dmem_addr[12:0]; //dmem_addr is four byte aligned
    case(dmem_byte_w_en)
        4'b1000: begin
            vga_addr[1:0] = 2'd0;
            char_to_vga = data_from_reg[7:0];
        end
        4'b0100: begin
            vga_addr[1:0] = 2'd1;
            char_to_vga = data_from_reg[15:8];
        end
        4'b0010: begin
            vga_addr[1:0] = 2'd2;
            char_to_vga = data_from_reg[23:16];
        end
        4'b0001: begin
            vga_addr[1:0] = 2'd3;
            char_to_vga = data_from_reg[31:24];
        end
        default: begin // remove latch, but should never be encountered
            vga_addr[1:0] = 2'd3;
            char_to_vga = data_from_reg[31:24];
        end
    endcase
end

cache_manage_unit u_cm_0 (
    .clk             ( clk_pipeline         ),
    .rst             ( ~rst                 ), // !! make rst seem low active
    .ic_read_in      ( ic_read_in           ),
    .dc_read_in      ( dc_read_in           ),
    .dc_write_in     ( dc_write_in          ),
    .dc_byte_w_en_in ( dmem_byte_w_en       ),
    .ic_addr         ( ic_addr              ),
    .dc_addr         ( dmem_addr            ),
    .data_from_reg   ( data_from_reg        ),

    .ram_ready       ( ram_rdy              ),
    .block_from_ram  ( block_from_ram       ),

    .mem_stall       ( cache_stall          ),
    .dc_data_out     ( dc_data_out          ),
    .ic_data_out     ( ic_data_out          ),

    .status          ( cache_status         ),
    .counter         ( cache_counter        ),
    .ram_en_out      ( ram_en               ),
    .ram_write_out   ( ram_write            ),
    .ram_addr_out    ( ram_addr             ),
    .dc_data_wb      ( block_from_dc_to_ram )
);

ddr_ctrl ddr_ctrl_0(

    // Inouts
    .ddr2_dq             ( ddr2_dq              ),
    .ddr2_dqs_n          ( ddr2_dqs_n           ),
    .ddr2_dqs_p          ( ddr2_dqs_p           ),
    // original signals
    .clk_from_ip         ( clk_for_ddr          ),
    .rst                 ( rst                  ),
    .ram_en              ( ram_en               ),
    .ram_write           ( ram_write            ),
    .ram_addr            ( ram_addr[29:0]       ),
    .data_to_ram         ( block_from_dc_to_ram ),
    .ram_rdy             ( ram_rdy              ),
    .block_out           ( block_from_ram       ),
    .ui_clk              ( ui_clk               ),
    // Outputs
    .ddr2_addr           ( ddr2_addr            ),
    .ddr2_ba             ( ddr2_ba              ),
    .ddr2_ras_n          ( ddr2_ras_n           ),
    .ddr2_cas_n          ( ddr2_cas_n           ),
    .ddr2_we_n           ( ddr2_we_n            ),
    .ddr2_ck_p           ( ddr2_ck_p            ),
    .ddr2_ck_n           ( ddr2_ck_n            ),
    .ddr2_cke            ( ddr2_cke             ),
    .ddr2_cs_n           ( ddr2_cs_n            ),
    .ddr2_dm             ( ddr2_dm              ),
    .ddr2_odt            ( ddr2_odt             ),
    // debug ports
    .go                  ( go                   ),
    .data_to_mig         ( data_to_mig          ),
    .data_from_mig       ( data_from_mig        ),
    .buffer              ( buffer_of_ddrctrl    ),
    .addr_to_mig         ( addr_to_mig          ),
    .mig_rdy             ( mig_rdy              ),
    .mig_wdf_rdy         ( mig_wdf_rdy          ),
    .init_calib_complete ( mig_ddr_inited       ),
    .mig_data_end        ( mig_data_end         ),
    .mig_data_valid      ( mig_data_valid       ),
    .reading             ( ddr_ctrl_reading     ),
    .writing             ( ddr_ctrl_writing     )
);

assign loader_data_o = loader_data;

wire [12:0] ld_real_addr = loader_en ? dmem_addr[12:0] : loader_addr[12:0];

loader_mem loader (         // use dual port Block RAM
    // Data port
    .addra ( ld_real_addr       ),
    .dina  ( data_from_reg      ),
    .douta ( loader_data        ),
    .clka  ( clk_pipeline       ),
    .wea   ( loader_wen         ),
    // Instr port (read-only)
    .addrb ( instr_addr[12:0]   ), // lower 28 bits of initial address
                                   // must start at 0
    .dinb  ( 0                  ), // not used
    .doutb ( loader_instr       ),
    .clkb  ( clk_pipeline       ),
    .web   ( 0                  )  // not used
);

vga #(
    .DATA_ADDR_WIDTH( 15 ),

    .h_disp         (1280),
    .h_front        ( 48 ),
    .h_sync         (112 ),
    .h_back         (248 ),
    .v_disp         (1024),
    .v_front        ( 1  ),
    .v_sync         ( 3  ),
    .v_back         ( 38 )

    /*
    .h_disp         (1680),
    .h_front        (104 ),
    .h_sync         (184 ),
    .h_back         (288 ),
    .v_disp         (1050),
    .v_front        ( 1  ),
    .v_sync         ( 3  ),
    .v_back         ( 33 )
    */
) vga0 (
    .RESET      ( rst            ),
    .DATA_ADDR  ( vga_addr[14:0] ),
    .DATA_IN    ( char_to_vga    ),
    .WR_EN      ( vga_wen        ),
    .pixel_clk  ( pixel_clk      ),
    .cpu_clk    ( text_mem_clk   ),
    .VGA_R      ( VGA_R          ),
    .VGA_G      ( VGA_G          ),
    .VGA_B      ( VGA_B          ),
    .VGA_HS     ( VGA_HS         ),
    .VGA_VS     ( VGA_VS         )
);

initial begin
    dbg_status <= 0;
    dbg_que_start <= 0;
    dbg_que_end <= 0;
    miss_count <= 0;
end

always @ (posedge cache_stall) begin
    miss_count <= miss_count + 1;
end

always @ (posedge clk_pipeline) begin
    if (!rst) begin
        dbg_status <= 0;
        dbg_que_start <= 0;
        dbg_que_end <= 0;
    end
    else begin
        if (!cache_stall) begin
            dbg_status <= 0; // update start only if status = 0
        end
        else begin
            if (!dbg_status) begin
                dbg_status <= 1;
                dbg_que_start <= dbg_que_end;
            end
            debug_queue[dbg_que_end] <= que_input;
            dbg_que_end <= dbg_que_end + 1;  //warning: always overwrite the last line
            // of last record!!
        end
    end
end


endmodule
