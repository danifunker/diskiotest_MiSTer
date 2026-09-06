//============================================================================
//  Disk I/O benchmark engine.
//
//  One cycle = a bus-only test followed by 10 transfer sizes (512 B .. 4 MB)
//  x {SEQ READ, SEQ WRITE, RND READ, RND WRITE}, queue depth 1, each test for
//  a fixed time.  hps_io moves at most 32 blocks (16 KB) per request, so a
//  larger transfer is issued as back-to-back 16 KB requests at consecutive
//  LBAs - exactly what a SCSI/IDE controller core does for a big command -
//  and is timed as a whole (IOPS = transfers per second).
//============================================================================
module bench #(parameter WIDE = 1, TIME_SHIFT = 0,   // WIDE: hps_io bus width; TIME_SHIFT: sim only
               AW = WIDE ? 12 : 13, DW = WIDE ? 15 : 7)
(
	input             clk,          // 50 MHz
	input             reset,

	input       [1:0] opt_time,     // 0: 2 s, 1: 1 s, 2: 4 s, 3: 8 s per test
	input             opt_nowrite,
	input             start,        // pulse: (re)start a full cycle

	input             img_mounted,  // pulse from hps_io
	input             img_readonly,
	input      [63:0] img_size,

	output reg [31:0] sd_lba = 0,
	output reg  [5:0] sd_blk_cnt = 0,
	output reg        sd_rd = 0,
	output reg        sd_wr = 0,
	input             sd_ack,
	input    [AW:0]   sd_buff_addr,
	input    [DW:0]   sd_buff_dout,
	input             sd_buff_wr,
	output   [DW:0]   sd_buff_din,

	input       [7:0] val_sel,      // display value port, 2-cycle latency
	output reg [31:0] val,

	output            led_disk,
	output            running
);

`include "rtl/fields.svh"

localparam [19:0] DLY_MOUNT = 20'd1000000 >> TIME_SHIFT;   // settle after (re)mount
localparam [19:0] DLY_START = 20'd500000  >> TIME_SHIFT;   // manual restart
localparam        LIVE_BITS = 17 - TIME_SHIFT;             // live stats every 2^17 us
localparam  [5:0] MAXBLK    = 6'd32;                       // hps_io request limit: 32 x 512 B

//////////////////////////////////////////////////////////////////////
// 1 us timebase

reg  [5:0] us_div = 0;
reg        us_tick = 0;
reg [31:0] us_cnt = 0;
always @(posedge clk) begin
	us_tick <= 0;
	if (us_div == 6'd49) begin
		us_div  <= 0;
		us_tick <= 1;
		us_cnt  <= us_cnt + 1'd1;
	end
	else us_div <= us_div + 1'd1;
end

//////////////////////////////////////////////////////////////////////
// image tracking (survives core reset, like hps_io's own registers)

reg        img_present = 0;
reg        img_ro = 0;
reg [31:0] img_sectors = 0;
reg        img_event = 0;
always @(posedge clk) begin
	img_event <= 0;
	if (img_mounted) begin
		img_sectors <= img_size[40:9];
		img_present <= |img_size[40:9];
		img_ro      <= img_readonly;
		img_event   <= 1;
	end
end
wire img_small = (img_sectors < 32'd32);

//////////////////////////////////////////////////////////////////////
// test decode

localparam [3:0] S_NOIMG = 0, S_SMALL = 1, S_START = 2, S_TINIT = 3, S_LBA = 4, S_XSTART = 5,
                 S_ISSUE = 6, S_WAITACK = 7, S_XFER = 8, S_TEND = 9, S_TENDW = 10, S_DONE = 11,
                 S_TIMEOUT = 12;

reg  [3:0] state = S_NOIMG;
reg  [5:0] test_idx = 0;                     // 0..NTESTS-1 matrix, T_BUS = bus-only
wire [3:0] size_idx = test_idx[5:2];
wire [1:0] kind     = test_idx[1:0];
wire       is_wr    = kind[0];
wire       is_rnd   = kind[1];
wire       is_bus   = (test_idx == T_BUS);

// transfer size in 512-byte blocks: 1,2,4,8,16,32,64,128 (512 B..64 KB), 2048 (1 MB), 8192 (4 MB)
wire  [3:0] lg        = is_bus ? 4'd4 : (size_idx < 4'd8) ? size_idx : (size_idx == 4'd8) ? 4'd11 : 4'd13;
wire [13:0] nblk      = 14'd1 << lg;
wire  [5:0] req_blk   = (nblk > {8'd0, MAXBLK}) ? MAXBLK : nblk[5:0];   // blocks per hps request
wire  [8:0] xfer_reqs = (nblk > {8'd0, MAXBLK}) ? nblk[13:5] : 9'd1;    // requests per transfer
wire        fits      = ({18'd0, nblk} <= img_sectors);

// number of transfer sizes that fit the image (for the test count shown on screen)
wire [3:0] nsizes = (img_sectors >= 32'd8192) ? 4'd10 : (img_sectors >= 32'd2048) ? 4'd9 :
                    (img_sectors >= 32'd128)  ? 4'd8  : (img_sectors >= 32'd64)   ? 4'd7 :
                    (img_sectors >= 32'd32)   ? 4'd6  : 4'd0;

//////////////////////////////////////////////////////////////////////
// main sequencer

reg        wr_ok = 0;
reg [31:0] T_cur = 32'd2000000;
reg [31:0] seq_cursor = 0;
reg [31:0] nchunks = 0;
reg [31:0] lba_next = 0;
reg [31:0] cur_lba = 0;
reg  [8:0] req_left = 0;
reg [31:0] t_start = 0, t_xfer = 0, t_req = 0, t_last = 0;
reg [31:0] reqs = 0, sectors = 0;            // reqs counts completed transfers
reg [22:0] lat_min = 0, lat_max = 0;
reg [39:0] lat_sum = 0;
reg [31:0] rnd = 32'h2545F491;
reg [19:0] start_delay = 0;
reg  [7:0] errs = 0;
reg  [7:0] runs = 0;
reg  [5:0] tests_done = 0;
reg        cur_is_wr = 0;
reg        clr_req = 0;

wire [31:0] T_opt = (opt_time == 2'd1) ? 32'd1000000 :
                    (opt_time == 2'd2) ? 32'd4000000 :
                    (opt_time == 2'd3) ? 32'd8000000 : 32'd2000000;
wire  [3:0] ttime_s = (opt_time == 2'd1) ? 4'd1 : (opt_time == 2'd2) ? 4'd4 : (opt_time == 2'd3) ? 4'd8 : 4'd2;

function [31:0] xorshift(input [31:0] x);
	reg [31:0] a, b;
	begin
		a = x ^ (x << 13);
		b = a ^ (a >> 17);
		xorshift = b ^ (b << 5);
	end
endfunction

wire [63:0] prod     = rnd * nchunks;         // uniform chunk index in [0, nchunks)
wire [31:0] seq_lba  = ((seq_cursor + nblk) > img_sectors) ? 32'd0 : seq_cursor;
wire [31:0] xfer_lba = is_bus ? 32'd0 : is_rnd ? (prod[63:32] << lg) : seq_lba;
wire [22:0] lat      = us_cnt[22:0] - t_xfer[22:0];
wire        req_timeout = ((us_cnt - t_req) > 32'd5000000);
wire        test_over   = ((us_cnt - t_start) >= T_cur);
wire        last_test   = (test_idx == NTESTS - 1);

assign running  = (state >= S_TINIT) && (state <= S_TENDW);
assign led_disk = sd_rd | sd_wr | sd_ack;

reg  calc_start = 0;
wire calc_busy;

always @(posedge clk) begin
	clr_req <= 0;

	if (reset) begin
		state <= S_NOIMG;
		sd_rd <= 0;
		sd_wr <= 0;
		if (img_present) begin
			start_delay <= DLY_START;
			state <= img_small ? S_SMALL : S_START;
		end
	end
	else if (img_event) begin
		sd_rd <= 0;
		sd_wr <= 0;
		start_delay <= DLY_MOUNT;
		state <= !img_present ? S_NOIMG : img_small ? S_SMALL : S_START;
	end
	else if (start && img_present && !img_small) begin
		sd_rd <= 0;
		sd_wr <= 0;
		start_delay <= DLY_START;
		state <= S_START;
	end
	else case (state)
		S_NOIMG, S_SMALL, S_DONE, S_TIMEOUT: ;

		S_START: begin
			if (start_delay == 0) begin
				test_idx   <= T_BUS;               // bus-only test first, then the matrix
				tests_done <= 0;
				errs       <= 0;
				runs       <= runs + 1'd1;
				wr_ok      <= ~opt_nowrite & ~img_ro;
				seq_cursor <= 0;
				clr_req    <= 1;
				state      <= S_TINIT;
			end
			else if (us_tick) start_delay <= start_delay - 1'd1;
		end

		S_TINIT: if (!calc_busy && !clr_req) begin
			if ((is_wr && !wr_ok) || !fits) begin  // skipped test: leave "-" and the last stats
				test_idx <= test_idx + 1'd1;
				if (last_test) state <= S_DONE;
			end
			else begin
				reqs    <= 0;
				sectors <= 0;
				lat_min <= 23'h7FFFFF;
				lat_max <= 0;
				lat_sum <= 0;
				t_start <= us_cnt;
				t_last  <= us_cnt;
				T_cur   <= T_opt >> TIME_SHIFT;
				nchunks <= img_sectors >> lg;
				if (!is_rnd && !is_bus) seq_cursor <= (seq_cursor + 32'd31) & ~32'd31;
				state   <= S_LBA;
			end
		end

		S_LBA: begin                               // pick the start of the next transfer
			lba_next <= xfer_lba;
			rnd      <= xorshift(rnd);
			state    <= S_XSTART;
		end

		S_XSTART: begin
			cur_lba  <= lba_next;
			req_left <= xfer_reqs;
			t_xfer   <= us_cnt;
			if (!is_rnd && !is_bus) seq_cursor <= lba_next + nblk;
			state    <= S_ISSUE;
		end

		S_ISSUE: begin                             // one hps_io request (<= 16 KB)
			sd_lba     <= cur_lba;
			sd_blk_cnt <= req_blk - 1'd1;
			sd_rd      <= ~is_wr;
			sd_wr      <= is_wr;
			cur_is_wr  <= is_wr;
			t_req      <= us_cnt;
			state      <= S_WAITACK;
		end

		S_WAITACK: begin
			if (sd_ack) begin
				sd_rd <= 0;
				sd_wr <= 0;
				state <= S_XFER;
			end
			else if (req_timeout) begin
				sd_rd <= 0;
				sd_wr <= 0;
				errs  <= errs + 1'd1;
				state <= S_TIMEOUT;
			end
		end

		S_XFER: begin
			if (!sd_ack) begin
				cur_lba  <= cur_lba + req_blk;
				req_left <= req_left - 1'd1;
				if (req_left == 9'd1) begin        // transfer complete
					reqs    <= reqs + 1'd1;
					sectors <= sectors + nblk;
					lat_sum <= lat_sum + lat;
					if (lat < lat_min) lat_min <= lat;
					if (lat > lat_max) lat_max <= lat;
					t_last  <= us_cnt;
					state   <= test_over ? S_TEND : S_LBA;
				end
				else state <= S_ISSUE;
			end
			else if (req_timeout) begin
				errs  <= errs + 1'd1;
				state <= S_TIMEOUT;
			end
		end

		S_TEND: if (!calc_busy && !calc_start) state <= S_TENDW;   // final calc is kicked below

		S_TENDW: if (!calc_busy && !calc_start) begin
			tests_done <= tests_done + 1'd1;
			test_idx   <= is_bus ? 6'd0 : test_idx + 1'd1;
			state      <= last_test ? S_DONE : S_TINIT;
		end

		default: state <= S_NOIMG;
	endcase
end

//////////////////////////////////////////////////////////////////////
// run clock (seconds)

reg [19:0] sec_div = 0;
reg [31:0] run_secs = 0;
always @(posedge clk) begin
	if (state == S_START) begin
		sec_div  <= 0;
		run_secs <= 0;
	end
	else if (us_tick) begin
		if (sec_div == 20'd999999) begin
			sec_div <= 0;
			if (running) run_secs <= run_secs + 1'd1;
		end
		else sec_div <= sec_div + 1'd1;
	end
end

//////////////////////////////////////////////////////////////////////
// statistics: KB/s = sectors*512/1024 / s = sectors*500000/us
//             IOPS = transfers*1000000/us, latency avg = lat_sum/transfers,
//             progress = elapsed*16/T.  Live every ~131 ms plus a final pass.

localparam [3:0] C_IDLE = 0, C_MUL = 1, C_D1 = 2, C_D1W = 3, C_D2 = 4, C_D2W = 5,
                 C_D3 = 6, C_D3W = 7, C_D4 = 8, C_D4W = 9, C_WR0 = 10, C_WR1 = 11, C_CLR = 12;

reg  [3:0] cstate = C_IDLE;
reg [31:0] s_elapsed, s_reqs, s_sectors;
reg [39:0] s_lat;
reg [47:0] num1, num2;
reg [31:0] r_kbps = 0, r_iops = 0, lat_avg = 0;
reg  [4:0] prog = 0;
reg  [5:0] c_test;
reg  [6:0] clr_addr;

reg        div_start = 0;
reg [47:0] div_num;
reg [31:0] div_den;
wire [47:0] div_quo;
wire        div_busy;
divider #(48, 32) div(.clk(clk), .start(div_start), .num(div_num), .den(div_den), .quo(div_quo), .busy(div_busy));

assign calc_busy = (cstate != C_IDLE);

wire in_test   = (state >= S_LBA) && (state <= S_XFER);
wire live_tick = us_tick && (us_cnt[LIVE_BITS-1:0] == 0) && in_test;

reg [31:0] res[128];
integer ri;
initial for (ri = 0; ri < 128; ri = ri + 1) res[ri] = 32'hFFFFFFFF;
reg [31:0] res_q = 0;
reg        res_we = 0;
reg  [6:0] res_wa;
reg [31:0] res_wd;
always @(posedge clk) begin
	if (res_we) res[res_wa] <= res_wd;
	res_q <= res[val_sel[6:0]];
end

always @(posedge clk) begin
	div_start  <= 0;
	res_we     <= 0;
	calc_start <= 0;

	if (state == S_START) begin
		prog    <= 0;
		lat_avg <= 0;
	end

	case (cstate)
		C_IDLE: begin
			if (clr_req) begin
				clr_addr <= 0;
				cstate   <= C_CLR;
			end
			else if ((state == S_TEND && !calc_start) || live_tick) begin
				calc_start <= 1;
				s_elapsed  <= (state == S_TEND) ? (t_last - t_start) : (us_cnt - t_start);
				s_reqs     <= reqs;
				s_sectors  <= sectors;
				s_lat      <= lat_sum;
				c_test     <= test_idx;
				cstate     <= C_MUL;
			end
		end

		C_CLR: begin
			res_we   <= 1;
			res_wa   <= clr_addr;
			res_wd   <= 32'hFFFFFFFF;
			clr_addr <= clr_addr + 1'd1;
			if (clr_addr == 7'd127) cstate <= C_IDLE;
		end

		C_MUL: begin
			num1   <= s_sectors * 48'd500000;
			num2   <= s_reqs * 48'd1000000;
			cstate <= (s_elapsed == 0) ? C_IDLE : C_D1;
		end

		C_D1:  begin div_start <= 1; div_num <= num1; div_den <= s_elapsed; cstate <= C_D1W; end
		C_D1W: if (!div_busy && !div_start) begin r_kbps <= div_quo[31:0]; cstate <= C_D2; end

		C_D2:  begin div_start <= 1; div_num <= num2; div_den <= s_elapsed; cstate <= C_D2W; end
		C_D2W: if (!div_busy && !div_start) begin r_iops <= div_quo[31:0]; cstate <= (s_reqs == 0) ? C_D4 : C_D3; end

		C_D3:  begin div_start <= 1; div_num <= {8'd0, s_lat}; div_den <= s_reqs; cstate <= C_D3W; end
		C_D3W: if (!div_busy && !div_start) begin lat_avg <= div_quo[31:0]; cstate <= C_D4; end

		C_D4:  begin div_start <= 1; div_num <= {12'd0, s_elapsed, 4'd0}; div_den <= T_cur; cstate <= C_D4W; end
		C_D4W: if (!div_busy && !div_start) begin
			prog   <= (div_quo > 48'd16) ? 5'd16 : div_quo[4:0];
			cstate <= C_WR0;
		end

		C_WR0: begin res_we <= 1; res_wa <= {c_test, 1'b0}; res_wd <= r_kbps; cstate <= C_WR1; end
		C_WR1: begin res_we <= 1; res_wa <= {c_test, 1'b1}; res_wd <= r_iops; cstate <= C_IDLE; end

		default: cstate <= C_IDLE;
	endcase
end

//////////////////////////////////////////////////////////////////////
// data pattern / verifier

wire [31:0] ver_ok, ver_bad, ver_skip;
pattern #(.WIDE(WIDE)) pattern
(
	.clk(clk),
	.clear(state == S_START),
	.req_lba(sd_lba),
	.verify_en(~cur_is_wr),
	.buff_addr(sd_buff_addr),
	.buff_dout(sd_buff_dout),
	.buff_wr(sd_buff_wr),
	.buff_din(sd_buff_din),
	.ver_ok(ver_ok),
	.ver_bad(ver_bad),
	.ver_skip(ver_skip)
);

//////////////////////////////////////////////////////////////////////
// display value port

wire       wr_ok_now = ~opt_nowrite & ~img_ro;
wire       wr_eff    = running ? wr_ok : wr_ok_now;
wire [5:0] ttot      = 6'd1 + (wr_eff ? {nsizes, 2'b00} : {1'b0, nsizes, 1'b0});   // bus test + sizes x kinds
wire [5:0] tnum      = running ? ((tests_done + 1'd1 > ttot) ? ttot : tests_done + 1'd1) : tests_done;

reg [7:0] state_str;
always_comb begin
	case (state)
		S_NOIMG:   state_str = STR_STATE_NOIMG;
		S_START:   state_str = STR_STATE_START;
		S_DONE:    state_str = STR_STATE_DONE;
		S_TIMEOUT: state_str = STR_STATE_TMO;
		S_SMALL:   state_str = STR_STATE_SMALL;
		default:   state_str = STR_STATE_RUN;
	endcase
end

reg [7:0] sel_d;
always @(posedge clk) begin
	sel_d <= val_sel;
	case (sel_d)
		SRC_IMGMB:   val <= img_sectors >> 11;
		SRC_TNUM:    val <= tnum;
		SRC_TTOT:    val <= ttot;
		SRC_REQS:    val <= reqs;
		SRC_KB:      val <= sectors >> 1;
		SRC_LAVG:    val <= lat_avg;
		SRC_LMIN:    val <= (reqs == 0) ? 32'd0 : lat_min;
		SRC_LMAX:    val <= lat_max;
		SRC_VOK:     val <= ver_ok;
		SRC_VBAD:    val <= ver_bad;
		SRC_VSKIP:   val <= ver_skip;
		SRC_ELAPSED: val <= run_secs;
		SRC_RUNS:    val <= runs;
		SRC_STATE:   val <= state_str;
		SRC_OP:      val <= !in_test ? STR_OP_NONE : is_bus ? STR_OP_BUS : (STR_OP0 + kind);
		SRC_SIZE:    val <= !in_test ? STR_SIZE_NONE : is_bus ? STR_SIZE4 : (STR_SIZE0 + size_idx);
		SRC_BAR:     val <= in_test ? prog : (state == S_DONE) ? 5'd16 : 5'd0;
		SRC_WRMODE:  val <= img_ro ? STR_WR_RO : opt_nowrite ? STR_WR_OFF : STR_WR_ON;
		SRC_TTIME:   val <= ttime_s;
		SRC_ERRS:    val <= errs;
		SRC_LBA:     val <= sd_lba;
		SRC_BUS:     val <= WIDE ? STR_BUS16 : STR_BUS8;
		default:     val <= sel_d[7] ? 32'd0 : res_q;   // 0x00..0x7F: results RAM
	endcase
end

endmodule
