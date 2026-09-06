//============================================================================
//  Display update engine: walks the generated field table forever and
//  rewrites the dynamic cells of the character RAM.
//    kind 0 (NUM): unsigned value right-aligned, leading zeros blanked,
//                  all-ones shown as "-", overflow shown as all 9s
//    kind 1 (STR): 16-char string slot (value = slot number)
//    kind 2 (BAR): value cells of block glyph, remainder dots
//  Value fetch: val_sel -> val with up to 3 cycles latency.
//============================================================================
module text_update
(
	input             clk,
	input             reset,

	output reg  [7:0] val_sel = 0,
	input      [31:0] val,

	output reg        wr = 0,
	output reg [11:0] wr_addr,
	output reg  [7:0] wr_data
);

`include "rtl/fields.svh"

reg [7:0] str_rom[512];
initial $readmemh("rtl/strings.hex", str_rom);
reg [8:0] str_addr;
reg [7:0] str_q;
always @(posedge clk) str_q <= str_rom[str_addr];

reg         bcd_start = 0;
reg  [31:0] value;
wire [39:0] bcd;
wire        bcd_busy;
bin2bcd b2b(.clk(clk), .start(bcd_start), .bin(value), .bcd(bcd), .busy(bcd_busy));

reg  [7:0] fidx = 0;
reg [31:0] desc;
wire [1:0] kind  = desc[1:0];
wire [4:0] row   = desc[6:2];
wire [6:0] col   = desc[13:7];
wire [4:0] width = desc[18:14];
wire [7:0] src   = desc[26:19];
wire [11:0] base = {row, 6'b0} + {row, 4'b0} + col;   // row*80 + col

reg  [4:0] i;
reg  [2:0] wait_cnt;
reg        leading;
reg        overflow;
reg  [3:0] state = 0;

wire [4:0] didx  = width - 1'd1 - i;          // digit index for cell i
wire [3:0] digit = bcd[didx*4 +: 4];

integer k;
reg ovf;
always_comb begin
	ovf = 0;
	for (k = 0; k < 10; k = k + 1)
		if ((k >= width) && (bcd[k*4 +: 4] != 0)) ovf = 1;
end

localparam [3:0] S_LOAD = 0, S_SEL = 1, S_WAIT = 2, S_DISPATCH = 3, S_BCD = 4, S_BCDW = 5,
           S_NUM = 6, S_STR0 = 7, S_STR1 = 8, S_BAR = 9, S_NEXT = 10;

always @(posedge clk) begin
	wr        <= 0;
	bcd_start <= 0;

	if (reset) begin
		fidx  <= 0;
		state <= S_LOAD;
	end
	else case (state)
		S_LOAD: begin
			desc  <= field_desc(fidx);
			state <= S_SEL;
		end

		S_SEL: begin
			val_sel  <= src;
			wait_cnt <= 3;
			state    <= S_WAIT;
		end

		S_WAIT: begin
			wait_cnt <= wait_cnt - 1'd1;
			if (wait_cnt == 0) begin
				value <= val;
				state <= S_DISPATCH;
			end
		end

		S_DISPATCH: begin
			i <= 0;
			case (kind)
				2'd0: begin bcd_start <= 1; state <= S_BCD; end
				2'd1: begin str_addr <= {value[4:0], 4'd0}; state <= S_STR0; end
				default: state <= S_BAR;
			endcase
		end

		S_BCD: state <= S_BCDW;

		S_BCDW: if (!bcd_busy) begin
			overflow <= ovf;
			leading  <= 1;
			state    <= S_NUM;
		end

		S_NUM: begin
			wr      <= 1;
			wr_addr <= base + i;
			if (&value)        wr_data <= (i == width - 1) ? 8'h2D : 8'h20;   // "-"
			else if (overflow) wr_data <= 8'h39;                               // "9"
			else if (digit == 0 && leading && (i != width - 1)) wr_data <= 8'h20;
			else begin
				wr_data <= 8'h30 + digit;
				leading <= 0;
			end
			i <= i + 1'd1;
			if (i == width - 1) state <= S_NEXT;
		end

		S_STR0: state <= S_STR1;

		S_STR1: begin
			wr       <= 1;
			wr_addr  <= base + i;
			wr_data  <= str_q;
			str_addr <= str_addr + 1'd1;
			i        <= i + 1'd1;
			state    <= (i == width - 1) ? S_NEXT : S_STR0;
		end

		S_BAR: begin
			wr      <= 1;
			wr_addr <= base + i;
			wr_data <= ({27'd0, i} < value) ? 8'h7F : 8'h1B;
			i       <= i + 1'd1;
			if (i == width - 1) state <= S_NEXT;
		end

		S_NEXT: begin
			fidx  <= (fidx == FIELD_COUNT - 1) ? 8'd0 : fidx + 1'd1;
			state <= S_LOAD;
		end

		default: state <= S_LOAD;
	endcase
end

endmodule
