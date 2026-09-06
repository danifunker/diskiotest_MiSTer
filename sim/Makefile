# Run from the repo root as `make -C sim <target>`; paths are relative to the root
# because the RTL reads its hex files as rtl/*.hex.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
RTL  := $(ROOT)/rtl/divider.sv $(ROOT)/rtl/bin2bcd.sv $(ROOT)/rtl/pattern.sv \
        $(ROOT)/rtl/text_video.sv $(ROOT)/rtl/text_update.sv $(ROOT)/rtl/bench.sv

.PHONY: run run8 lint clean

# 16-bit hps_io bus (default build)
run: $(ROOT)/sim/tb.vvp
	cd $(ROOT) && vvp -n sim/tb.vvp

# 8-bit hps_io bus (DiskIOTest_8bit revision)
run8: $(ROOT)/sim/tb8.vvp
	cd $(ROOT) && vvp -n sim/tb8.vvp

$(ROOT)/sim/tb.vvp: $(RTL) $(ROOT)/sim/tb.sv $(ROOT)/rtl/fields.svh
	cd $(ROOT) && iverilog -g2012 -o sim/tb.vvp -I. $(RTL) sim/tb.sv

$(ROOT)/sim/tb8.vvp: $(RTL) $(ROOT)/sim/tb.sv $(ROOT)/rtl/fields.svh
	cd $(ROOT) && iverilog -g2012 -P tb.WIDE=0 -o sim/tb8.vvp -I. $(RTL) sim/tb.sv

lint:
	cd $(ROOT) && verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -I. --top-module bench $(RTL)
	cd $(ROOT) && verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -I. --top-module text_update $(RTL)
	cd $(ROOT) && verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -I. --top-module text_video $(RTL)

clean:
	rm -f $(ROOT)/sim/tb.vvp $(ROOT)/sim/tb8.vvp
