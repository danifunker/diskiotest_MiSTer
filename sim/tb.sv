`timescale 1ns/1ps
//============================================================================
//  Testbench: bench + text_update + text_video with a behavioural model of
//  the ARM side of hps_io (poll latency, block transfer timing, a sparse
//  image).  Run from the repo root:  make -C sim run
//============================================================================
module tb;

parameter  WIDE        = 1;        // 1: 16-bit hps_io bus, 0: 8-bit (iverilog -P tb.WIDE=0)
localparam TIME_SHIFT  = 9;        // 1 s test -> ~1.95 ms
localparam AW = WIDE ? 12 : 13;
localparam DW = WIDE ? 15 : 7;
localparam IMG_SECTORS = 8192;     // 4 MB image: the 4 MB transfers fit, sequential tests wrap and re-read written data

reg clk = 0;
always #10 clk = ~clk;             // 50 MHz

reg        reset = 1;
reg  [1:0] opt_time = 2'd1;        // "1 s"
reg        opt_nowrite = 0;
reg        start = 0;
reg        img_mounted = 0;
reg        img_readonly = 0;
reg [63:0] img_size = 0;

wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
wire        sd_rd, sd_wr;
reg         sd_ack = 0;
reg  [AW:0] sd_buff_addr = 0;
reg  [DW:0] sd_buff_dout = 0;
reg         sd_buff_wr = 0;
wire [DW:0] sd_buff_din;
wire  [7:0] val_sel;
wire [31:0] val;
wire        led_disk, running;

bench #(.WIDE(WIDE), .TIME_SHIFT(TIME_SHIFT)) dut
(
	.clk(clk), .reset(reset),
	.opt_time(opt_time), .opt_nowrite(opt_nowrite), .start(start),
	.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
	.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr), .sd_buff_din(sd_buff_din),
	.val_sel(val_sel), .val(val), .led_disk(led_disk), .running(running)
);

wire        txt_wr;
wire [11:0] txt_addr;
wire  [7:0] txt_data;
text_update tu(.clk(clk), .reset(reset), .val_sel(val_sel), .val(val), .wr(txt_wr), .wr_addr(txt_addr), .wr_data(txt_data));

wire ce_pix, hs, vs, hblank, vblank;
wire [7:0] r, g, b;
text_video tv(.clk(clk), .wr(txt_wr), .wr_addr(txt_addr), .wr_data(txt_data),
              .ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank), .r(r), .g(g), .b(b));

//////////////////////////////////////////////////////////////////////
// ARM model

localparam WORDS = IMG_SECTORS * 256;
reg [15:0] mem[0:WORDS-1];             // word address = lba*256 + w
bit sector_written[0:IMG_SECTORS-1];
initial begin
	for (int i = 0; i < WORDS; i++) mem[i] = 16'h0000;
	for (int i = 0; i < IMG_SECTORS; i++) sector_written[i] = 0;
end
int req_count = 0, rd_count = 0, wr_count = 0;
int max_blks = 0;

int lba, blks, base;
bit wr;
always @(posedge clk) begin
	if ((sd_rd || sd_wr) && !sd_ack) begin
		lba  = sd_lba;
		blks = sd_blk_cnt + 1;
		wr   = sd_wr;
		base = lba * 256;
		if (blks > max_blks) max_blks = blks;
		if (lba + blks > IMG_SECTORS) $display("ERROR: request beyond image: lba=%0d blks=%0d", lba, blks);
		if (lba % blks != 0) $display("ERROR: unaligned request lba=%0d blks=%0d", lba, blks);
		// ARM poll + file I/O latency: 30..90 us, writes 50 us more
		repeat ($urandom_range(500, 1500) + (wr ? 1000 : 0)) @(posedge clk);
		sd_ack <= 1;
		@(posedge clk); @(posedge clk);
		sd_buff_addr <= 0;
		@(posedge clk);
		for (int i = 0; i < blks * (WIDE ? 256 : 512); i++) begin
			if (!wr) begin
				if (WIDE) sd_buff_dout <= mem[base + i];
				else      sd_buff_dout <= (i & 1) ? mem[base + i / 2][15:8] : mem[base + i / 2][7:0];
				sd_buff_wr <= 1;                       // data + strobe, then advance (hps_io order)
				@(posedge clk);
				sd_buff_wr <= 0;
				sd_buff_addr <= sd_buff_addr + 1'd1;
				@(posedge clk);
			end
			else begin
				if (WIDE) mem[base + i] = sd_buff_din;            // sample at current address ...
				else if (i & 1) mem[base + i / 2][15:8] = sd_buff_din;
				else            mem[base + i / 2][7:0]  = sd_buff_din;
				sector_written[lba + i / (WIDE ? 256 : 512)] = 1;
				sd_buff_addr <= sd_buff_addr + 1'd1;   // ... then advance (as hps_io does)
				@(posedge clk);
			end
		end
		@(posedge clk);
		sd_ack <= 0;
		req_count++;
		if (wr) wr_count++; else rd_count++;
	end
end

//////////////////////////////////////////////////////////////////////
// helpers

task dump_screen;
	string line;
	byte c;
	$display("---------------------------------- screen ----------------------------------");
	for (int row = 0; row < 30; row++) begin
		line = "";
		for (int col = 0; col < 80; col++) begin
			c = tv.chr_ram[row * 80 + col];
			if (c == 8'h7F) line = {line, "#"};
			else if (c == 8'h1B) line = {line, "."};
			else if (c == 8'h87) line = {line, "-"};
			else if (c == 8'h16) line = {line, ">"};
			else if (c < 32 || c > 126) line = {line, "?"};
			else line = {line, string'(c)};
		end
		$display("%s", line);
	end
	$display("-----------------------------------------------------------------------------");
endtask

function int size_of(input int t);
	case (t / 4)
		8: size_of = 1048576;
		9: size_of = 4194304;
		default: size_of = 512 << (t / 4);
	endcase
endfunction
task print_results;
	$display("test    size kind      KB/s     IOPS");
	for (int t = 0; t < 40; t++)
		$display("%2d  %8d %s  %8d %8d", t, size_of(t),
			(t % 4 == 0) ? "SEQ RD" : (t % 4 == 1) ? "SEQ WR" : (t % 4 == 2) ? "RND RD" : "RND WR",
			dut.res[t * 2], dut.res[t * 2 + 1]);
endtask

task wait_done(input int max_us);
	int n;
	n = 0;
	while (dut.state != dut.S_DONE && dut.state != dut.S_TIMEOUT && n < max_us) begin
		repeat (50) @(posedge clk);
		n++;
	end
	if (dut.state != dut.S_DONE) $display("ERROR: run did not complete (state=%0d)", dut.state);
endtask

int errors = 0;

//////////////////////////////////////////////////////////////////////
// test sequence

initial begin
	$display("=== DiskIOTest bench simulation (WIDE=%0d) ===", WIDE);
	repeat (20) @(posedge clk);
	reset = 0;
	repeat (2000) @(posedge clk);

	// screen should show NO IMAGE before any mount; give the updater time to render everything
	repeat (20000) @(posedge clk);
	dump_screen();

	// mount a 2 MB read/write image
	img_size    = 64'd512 * IMG_SECTORS;
	@(negedge clk); img_mounted = 1; @(negedge clk); img_mounted = 0;

	wait_done(2000000);
	$display("run 1: requests=%0d (rd %0d, wr %0d) max_blks=%0d verify ok=%0d bad=%0d skip=%0d errs=%0d",
		req_count, rd_count, wr_count, max_blks, dut.ver_ok, dut.ver_bad, dut.ver_skip, dut.errs);
	print_results();
	repeat (20000) @(posedge clk);
	dump_screen();

	if (max_blks != 32) begin $display("ERROR: 16 KB requests not seen"); errors++; end
	$display("bus-only test: %0d KB/s %0d IOPS", dut.res[80], dut.res[81]);
	if (dut.res[80] == 0 || dut.res[80] == 32'hFFFFFFFF) begin $display("ERROR: bus-only test has no result"); errors++; end
	if (dut.res[36 * 2 + 1] != 0 && dut.res[36 * 2 + 1] != 32'hFFFFFFFF && dut.res[36 * 2 + 1] > 5000)
		begin $display("ERROR: 4 MB transfers reported as many IOPS - not timed as whole transfers?"); errors++; end
	if (dut.ver_bad != 0) begin $display("ERROR: verify reported bad sectors on clean run"); errors++; end
	if (dut.ver_ok == 0) begin $display("ERROR: verify never matched a written sector"); errors++; end
	if (dut.errs != 0) begin $display("ERROR: timeouts reported"); errors++; end
	for (int t = 0; t < 40; t++)
		if (dut.res[t * 2] == 0 || dut.res[t * 2] == 32'hFFFFFFFF || dut.res[t * 2 + 1] == 0) begin
			$display("ERROR: test %0d has no result", t); errors++;
		end

	// corrupt every written sector, then a read-only run: every signed sector must be flagged bad
	for (int sct = 0; sct < IMG_SECTORS; sct++) if (sector_written[sct]) mem[sct * 256 + 100] = mem[sct * 256 + 100] ^ 16'h0100;
	opt_nowrite = 1;
	@(negedge clk); start = 1; @(negedge clk); start = 0;
	wait_done(2000000);
	$display("run 2 (read only, corrupted image): verify ok=%0d bad=%0d skip=%0d", dut.ver_ok, dut.ver_bad, dut.ver_skip);
	print_results();
	repeat (20000) @(posedge clk);
	dump_screen();
	if (dut.ver_bad == 0) begin $display("ERROR: corruption not detected"); errors++; end
	if (dut.ver_ok != 0) begin $display("ERROR: corrupted sectors passed verification"); errors++; end
	for (int t = 0; t < 40; t++) begin
		if ((t % 2 == 1) && dut.res[t * 2] != 32'hFFFFFFFF) begin $display("ERROR: write test %0d ran with writes disabled", t); errors++; end
		if ((t % 2 == 0) && (dut.res[t * 2] == 0 || dut.res[t * 2] == 32'hFFFFFFFF)) begin $display("ERROR: read test %0d has no result", t); errors++; end
	end

	// unmount mid-run must return to NO IMAGE without hanging
	opt_nowrite = 0;
	@(negedge clk); start = 1; @(negedge clk); start = 0;
	repeat (300000) @(posedge clk);
	if (!running) begin $display("ERROR: run 3 not running before unmount (state=%0d)", dut.state); errors++; end
	img_size = 0; @(negedge clk); img_mounted = 1; @(negedge clk); img_mounted = 0;
	repeat (20000) @(posedge clk);
	if (dut.state != dut.S_NOIMG) begin $display("ERROR: unmount did not stop the run (state=%0d)", dut.state); errors++; end

	if (errors == 0) $display("PASS");
	else $display("FAIL: %0d errors", errors);
	$finish;
end

// safety net
initial begin
	#2_000_000_000;
	$display("ERROR: simulation timeout");
	$finish;
end

endmodule
