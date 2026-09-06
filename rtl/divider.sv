//============================================================================
//  Serial unsigned divider: quo = num / den.  NW cycles per division.
//  Caller must not divide by zero (result would be all ones).
//============================================================================
module divider #(parameter NW = 48, DW = 32)
(
	input                 clk,
	input                 start,
	input      [NW-1:0]   num,
	input      [DW-1:0]   den,
	output reg [NW-1:0]   quo,
	output reg            busy
);

reg [NW-1:0] n;
reg [DW:0]   r;
reg [DW-1:0] d;
reg [6:0]    cnt;

wire [DW:0] rs = {r[DW-1:0], n[NW-1]};
wire        ge = (rs >= {1'b0, d});

always @(posedge clk) begin
	if (start) begin
		busy <= 1;
		n    <= num;
		d    <= den;
		r    <= 0;
		quo  <= 0;
		cnt  <= NW[6:0];
	end
	else if (busy) begin
		n   <= {n[NW-2:0], 1'b0};
		r   <= ge ? (rs - {1'b0, d}) : rs;
		quo <= {quo[NW-2:0], ge};
		cnt <= cnt - 1'd1;
		if (cnt == 1) busy <= 0;
	end
end

endmodule
