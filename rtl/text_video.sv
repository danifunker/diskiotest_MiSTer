//============================================================================
//  80x30 text mode on 640x480 (25 MHz pixel clock from a 50 MHz clk).
//  8x8 font, every glyph line doubled -> 8x16 cells.
//  Character RAM is initialised with the generated static screen and is
//  written by text_update; colours come from a static attribute ROM.
//============================================================================
module text_video
(
	input             clk,        // 50 MHz
	input             wr,
	input      [11:0] wr_addr,    // row*80 + col
	input       [7:0] wr_data,

	output reg        ce_pix,
	output reg        hs,
	output reg        vs,
	output reg        hblank,
	output reg        vblank,
	output reg  [7:0] r,
	output reg  [7:0] g,
	output reg  [7:0] b
);

localparam H_ACT = 640, H_FP = 16, H_SYNC = 96, H_TOT = 800;
localparam V_ACT = 480, V_FP = 10, V_SYNC = 2,  V_TOT = 525;

reg [7:0] chr_ram[4096];
reg [3:0] att_rom[4096];
reg [7:0] font[2048];
initial begin
	$readmemh("rtl/screen_chr.hex", chr_ram);
	$readmemh("rtl/screen_att.hex", att_rom);
	$readmemh("rtl/font8x8.hex", font);
end

reg [9:0] hc = 0;
reg [9:0] vc = 0;

initial ce_pix = 0;
always @(posedge clk) ce_pix <= ~ce_pix;

// character RAM write port
always @(posedge clk) if (wr) chr_ram[wr_addr] <= wr_data;

// look-ahead position: the cell 8 pixels ahead of the one being drawn
wire [9:0] hf = (hc >= H_TOT - 8) ? (hc - (H_TOT - 8)) : (hc + 10'd8);
wire [9:0] vf = (hc >= H_TOT - 8) ? ((vc == V_TOT - 1) ? 10'd0 : vc + 1'd1) : vc;
wire [4:0] trow = vf[8:4];
wire [11:0] row_base = {trow, 6'b0} + {trow, 4'b0};   // trow * 80

reg [11:0] rd_addr;
reg  [7:0] chr_q;
reg  [3:0] att_q;
reg [10:0] font_addr;
reg  [7:0] font_q;
reg  [7:0] glyph_next, glyph;
reg  [3:0] att_next, att;

always @(posedge clk) begin
	chr_q  <= chr_ram[rd_addr];
	att_q  <= att_rom[rd_addr];
	font_q <= font[font_addr];
end

wire de = (hc < H_ACT) && (vc < V_ACT);
wire pix = de & glyph[~hc[2:0]];

function [23:0] palette(input [3:0] c);
	case (c)
		4'd0:  palette = 24'h000000;
		4'd1:  palette = 24'h4060E0;
		4'd2:  palette = 24'h00AA00;
		4'd3:  palette = 24'h00AAAA;
		4'd4:  palette = 24'hAA0000;
		4'd5:  palette = 24'hAA00AA;
		4'd6:  palette = 24'hAA5500;
		4'd7:  palette = 24'hB0B0B0;
		4'd8:  palette = 24'h7880A0;
		4'd9:  palette = 24'h5555FF;
		4'd10: palette = 24'h55FF55;
		4'd11: palette = 24'h55FFFF;
		4'd12: palette = 24'hFF5555;
		4'd13: palette = 24'hFF55FF;
		4'd14: palette = 24'hFFFF55;
		default: palette = 24'hFFFFFF;
	endcase
endfunction

localparam [23:0] BG = 24'h0C1030;

always @(posedge clk) if (ce_pix) begin
	if (hc == H_TOT - 1) begin
		hc <= 0;
		vc <= (vc == V_TOT - 1) ? 10'd0 : vc + 1'd1;
	end
	else hc <= hc + 1'd1;

	case (hc[2:0])
		3'd3: rd_addr    <= row_base + hf[9:3];
		3'd4: font_addr  <= {chr_q, vf[3:1]};
		3'd5: begin glyph_next <= font_q; att_next <= att_q; end
		3'd7: begin glyph <= glyph_next; att <= att_next; end
		default: ;
	endcase

	hs     <= (hc >= H_ACT + H_FP) && (hc < H_ACT + H_FP + H_SYNC);
	vs     <= (vc >= V_ACT + V_FP) && (vc < V_ACT + V_FP + V_SYNC);
	hblank <= (hc >= H_ACT);
	vblank <= (vc >= V_ACT);

	{r, g, b} <= pix ? palette(att) : BG;
end

endmodule
