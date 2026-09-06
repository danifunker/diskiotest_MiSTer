//============================================================================
//
//  DiskIOTest - disk I/O benchmark core for MiSTer
//
//  Measures the hps_io sd_* block-device path (the path every hard-disk
//  emulating core uses): sequential/random, 512 B .. 16 KB requests,
//  read and write, one full cycle, results on screen.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"DiskIOTest;;",
	"-;",
	"SC0,VHDIMGBINRAWHDF,Mount scratch image;",
	"-;",
	"O[2:1],Time per test,2s,1s,4s,8s;",
	"O[3],Write tests,Enabled,Disabled;",
	"-;",
	"T[4],Start / Restart;",
	"-;",
	"-, Write tests overwrite the image!;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J1,Restart;",
	"jn,Start;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0;

wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

// hps_io bus width: 16-bit by default, 8-bit when the DiskIOTest_8bit revision
// defines DISKIO_BUS8 (the ARM samples this once per core start, so it is a build option)
`ifdef DISKIO_BUS8
localparam WIDE = 0;
`else
localparam WIDE = 1;
`endif
localparam AW = WIDE ? 12 : 13;
localparam DW = WIDE ? 15 : 7;

wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire        sd_rd;
wire        sd_wr;
wire        sd_ack;
wire [AW:0] sd_buff_addr;
wire [DW:0] sd_buff_dout;
wire [DW:0] sd_buff_din;
wire        sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .WIDE(WIDE), .VDNUM(1), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ps2_key(ps2_key),
	.joystick_0(joystick_0),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.sd_lba('{sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din}),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;   // 50 MHz
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

///////////////////////   START TRIGGER   ////////////////////////
// OSD "Start / Restart", keyboard Enter, or first gamepad button

reg start_pulse;
always @(posedge clk_sys) begin
	reg old_st, old_key, old_joy;
	old_st  <= status[4];
	old_key <= ps2_key[10];
	old_joy <= joystick_0[4];
	start_pulse <= (status[4] & ~old_st) |
	               ((ps2_key[10] != old_key) && ps2_key[9] && (ps2_key[7:0] == 8'h5A)) |
	               (joystick_0[4] & ~old_joy);
end

///////////////////////   BENCHMARK   ////////////////////////////

wire  [7:0] val_sel;
wire [31:0] val;
wire        led_disk, running;

bench #(.WIDE(WIDE)) bench
(
	.clk(clk_sys),
	.reset(reset),

	.opt_time(status[2:1]),
	.opt_nowrite(status[3]),
	.start(start_pulse),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(sd_buff_din),

	.val_sel(val_sel),
	.val(val),

	.led_disk(led_disk),
	.running(running)
);

assign LED_USER = running;
assign LED_DISK = {1'b1, led_disk};

///////////////////////   VIDEO   ////////////////////////////////

wire        txt_wr;
wire [11:0] txt_addr;
wire  [7:0] txt_data;

text_update text_update
(
	.clk(clk_sys),
	.reset(reset),
	.val_sel(val_sel),
	.val(val),
	.wr(txt_wr),
	.wr_addr(txt_addr),
	.wr_data(txt_data)
);

wire ce_pix, hs, vs, hblank, vblank;

text_video text_video
(
	.clk(clk_sys),
	.wr(txt_wr),
	.wr_addr(txt_addr),
	.wr_data(txt_data),
	.ce_pix(ce_pix),
	.hs(hs),
	.vs(vs),
	.hblank(hblank),
	.vblank(vblank),
	.r(VGA_R),
	.g(VGA_G),
	.b(VGA_B)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE    = ~(hblank | vblank);
assign VGA_HS    = hs;
assign VGA_VS    = vs;

endmodule
