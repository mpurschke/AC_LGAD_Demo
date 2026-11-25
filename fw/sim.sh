# Compile and run the self-checking testbench in xsim:  bash sim.sh
set -e
# uses the Vivado in PATH, else VIVADO_ROOT (the directory that contains Vivado/2024.2)
command -v xvhdl >/dev/null || source ${VIVADO_ROOT:-/data/purschke/vivado_2024.2}/Vivado/2024.2/settings64.sh
cd "$(dirname "$0")" && mkdir -p sim_run && cd sim_run
xvlog $XILINX_VIVADO/data/verilog/src/glbl.v
xvhdl ../src/debounce.vhd ../src/trig_gen.vhd ../src/evt_gen.vhd ../src/zdaq_pl.vhd
xvhdl -2008 ../sim/tb_zdaq.vhd
xelab -debug typical -L unisim -L xpm tb_zdaq glbl -s tb_zdaq
xsim tb_zdaq -runall
