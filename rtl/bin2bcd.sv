//============================================================================
//  32-bit binary to 10-digit BCD (double dabble), 32 cycles.
//============================================================================
module bin2bcd
(
	input             clk,
	input             start,
	input      [31:0] bin,
	output reg [39:0] bcd,
	output reg        busy
);

reg [31:0] sh;
reg  [5:0] cnt;

wire [39:0] adj;
genvar i;
generate
	for (i = 0; i < 10; i = i + 1) begin : dabble
		wire [3:0] d = bcd[i*4 +: 4];
		assign adj[i*4 +: 4] = (d >= 4'd5) ? (d + 4'd3) : d;
	end
endgenerate

always @(posedge clk) begin
	if (start) begin
		bcd  <= 0;
		sh   <= bin;
		cnt  <= 6'd32;
		busy <= 1;
	end
	else if (busy) begin
		bcd <= {adj[38:0], sh[31]};
		sh  <= {sh[30:0], 1'b0};
		cnt <= cnt - 1'd1;
		if (cnt == 1) busy <= 0;
	end
end

endmodule
