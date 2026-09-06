//============================================================================
//  Test data pattern generator and on-the-fly read verifier.
//
//  No sector buffer is needed: write data (sd_buff_din) is a pure function of
//  (LBA, word index) and read data is compared against the same function as
//  hps_io delivers it.  Every sector starts with "DIOT" + 32-bit LBA so a read
//  can tell whether the sector was ever written by this core:
//     signature present and data matches  -> ver_ok
//     signature present and data differs  -> ver_bad  (real corruption)
//     no signature                        -> ver_skip (foreign data)
//
//  WIDE=1: 16-bit hps_io bus, 256 words per 512-byte block, addr[12:8] = block
//  WIDE=0:  8-bit hps_io bus, 512 bytes per block,           addr[13:9] = block
//  The bytes written to the image are the same in both modes (little-endian
//  words), so an image written by one build verifies in the other.
//============================================================================
module pattern #(parameter WIDE = 1, AW = WIDE ? 12 : 13, DW = WIDE ? 15 : 7)
(
	input             clk,
	input             clear,       // reset verify counters
	input      [31:0] req_lba,     // first LBA of the request in flight
	input             verify_en,   // request in flight is a read
	input    [AW:0]   buff_addr,
	input    [DW:0]   buff_dout,   // hps_io -> core
	input             buff_wr,
	output   [DW:0]   buff_din,    // core -> hps_io
	output reg [31:0] ver_ok = 0,
	output reg [31:0] ver_bad = 0,
	output reg [31:0] ver_skip = 0
);

function [15:0] pat(input [31:0] lba, input [7:0] w);
	reg [15:0] h;
	begin
		h = lba[15:0] ^ lba[31:16];
		case (w)
			8'd0:    pat = 16'h4944;      // 'D','I' (little endian in the file)
			8'd1:    pat = 16'h544F;      // 'O','T'
			8'd2:    pat = lba[15:0];
			8'd3:    pat = lba[31:16];
			default: pat = (h + {w, 8'h00} + 16'h9E37) ^ ({h[7:0], h[15:8]} + {8'h00, w});
		endcase
	end
endfunction

wire  [4:0] blk;      // block within the request
wire  [7:0] w;        // 16-bit word within the block
wire        first;    // first bus word/byte of a block
wire        last;     // last bus word/byte of a block
wire        match;

wire [15:0] p = pat(req_lba + blk, w);

generate
	if (WIDE) begin : g16
		assign blk      = buff_addr[12:8];
		assign w        = buff_addr[7:0];
		assign first    = (buff_addr[7:0] == 8'd0);
		assign last     = (buff_addr[7:0] == 8'd255);
		assign buff_din = p;
		assign match    = (buff_dout == p);
	end
	else begin : g8
		wire [7:0] pb   = buff_addr[0] ? p[15:8] : p[7:0];
		assign blk      = buff_addr[13:9];
		assign w        = buff_addr[8:1];
		assign first    = (buff_addr[8:0] == 9'd0);
		assign last     = (buff_addr[8:0] == 9'd511);
		assign buff_din = pb;
		assign match    = (buff_dout == pb);
	end
endgenerate

wire in_sig = (w < 8'd2);     // "DIOT" signature words

reg sig_ok = 0;
reg mism   = 0;

always @(posedge clk) begin
	if (clear) begin
		ver_ok   <= 0;
		ver_bad  <= 0;
		ver_skip <= 0;
	end
	else if (buff_wr && verify_en) begin
		if (first) begin
			sig_ok <= match;
			mism   <= 0;
		end
		else if (in_sig) begin
			sig_ok <= sig_ok & match;
		end
		else begin
			if (!match) mism <= 1;
			if (last) begin
				if (!sig_ok)             ver_skip <= ver_skip + 1'd1;
				else if (mism || !match) ver_bad  <= ver_bad  + 1'd1;
				else                     ver_ok   <= ver_ok   + 1'd1;
			end
		end
	end
end

endmodule
