# Two-Zybo DAQ demo, step 1 (one board): PS7 + zdaq_pl + event FIFO.
#
#   vivado -mode batch -nojournal -nolog -source build.tcl
#
# Block design:
#   ps7 (Digilent preset, GP0, FCLK0 = 100 MHz, as zybo_linux/build_xsa.tcl)
#     M_AXI_GP0 -> interconnect -> zdaq_pl registers   0x43C0_0000
#                               -> axi_fifo_mm_s       0x43C1_0000 (event words)
#   zdaq_pl m_axis (shared clock, 125 MHz) -> axis_data_fifo (independent clocks)
#     -> axi_fifo_mm_s AXI_STR_RXD (FCLK0)
# A PL design loaded under Linux must contain processing_system7 and drive
# eth_rst_b (E17) high; both are here.
#
# Results in out/: zdaq.bit, zdaq.bit.bin (for fpgautil), zdaq.xsa,
# ps7_init.tcl (for xsdb over JTAG), reports.

set board digilentinc.com:zybo-z7-20:part0:1.2
set part  xc7z020clg400-1
set here  [file dirname [file normalize [info script]]]
set out   $here/out
file mkdir $out

create_project -in_memory -part $part
set_property board_part $board [current_project]
set_property target_language VHDL [current_project]
set_property source_mgmt_mode All [current_project]
read_vhdl [glob $here/src/*.vhd]
read_xdc  $here/constr/zybo_z7.xdc

create_bd_design -dir $out/bd zdaq
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] $ps
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]

set pl [create_bd_cell -type module -reference zdaq_pl zdaq]

set fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo axis_fifo]
set_property -dict [list CONFIG.IS_ACLK_ASYNC {1} CONFIG.FIFO_DEPTH {4096}] $fifo

set mm [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_fifo_mm_s evt_fifo]
set_property -dict [list \
    CONFIG.C_USE_TX_DATA {0} \
    CONFIG.C_USE_TX_CTRL {0} \
    CONFIG.C_RX_FIFO_DEPTH {4096}] $mm

# registers and event FIFO on GP0 (creates interconnect and reset block)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master /ps7/M_AXI_GP0 Clk_master Auto Clk_slave Auto Clk_xbar Auto intc_ip Auto} \
    [get_bd_intf_pins zdaq/s_axi]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master /ps7/M_AXI_GP0 Clk_master Auto Clk_slave Auto Clk_xbar Auto intc_ip Auto} \
    [get_bd_intf_pins evt_fifo/S_AXI]

# event stream: shared clock -> FCLK0
connect_bd_intf_net [get_bd_intf_pins zdaq/m_axis] [get_bd_intf_pins axis_fifo/S_AXIS]
connect_bd_net [get_bd_pins zdaq/m_axis_aclk]    [get_bd_pins axis_fifo/s_axis_aclk]
connect_bd_net [get_bd_pins zdaq/m_axis_aresetn] [get_bd_pins axis_fifo/s_axis_aresetn]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]       [get_bd_pins axis_fifo/m_axis_aclk]
connect_bd_intf_net [get_bd_intf_pins axis_fifo/M_AXIS] [get_bd_intf_pins evt_fifo/AXI_STR_RXD]

# board pins
create_bd_port -dir I -type clk -freq_hz 125000000 sysclk
create_bd_port -dir I -from 3 -to 0 btn
create_bd_port -dir I -from 3 -to 0 sw
create_bd_port -dir I je_trig
create_bd_port -dir O -from 3 -to 0 led
foreach p {led6_r led6_g led6_b eth_rst_b} { create_bd_port -dir O $p }
foreach p {sysclk btn sw je_trig led led6_r led6_g led6_b eth_rst_b} {
    connect_bd_net [get_bd_ports $p] [get_bd_pins zdaq/$p]
}

# the automation assigns addresses on its own; move the FIFO out of the way first
set_property offset 0x43C10000 [get_bd_addr_segs {ps7/Data/SEG_evt_fifo_Mem0}]
set_property range  64K        [get_bd_addr_segs {ps7/Data/SEG_evt_fifo_Mem0}]
set_property offset 0x43C00000 [get_bd_addr_segs {ps7/Data/SEG_zdaq_reg0}]
set_property range  4K         [get_bd_addr_segs {ps7/Data/SEG_zdaq_reg0}]

validate_bd_design
save_bd_design
set bd [get_files zdaq.bd]
generate_target all $bd
read_vhdl [make_wrapper -files $bd -top]

synth_design -top zdaq_wrapper -part $part
opt_design
place_design
phys_opt_design
route_design

report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt
report_cdc            -file $out/cdc.rpt
report_methodology    -file $out/methodology.rpt
write_bitstream -force $out/zdaq.bit
write_hw_platform -fixed -include_bit -force $out/zdaq.xsa

# bitstream for fpgautil (Linux) and the PS init script for xsdb (JTAG)
set bif [open $out/zdaq.bif w]
puts $bif "all:\n{\n  $out/zdaq.bit\n}"
close $bif
exec bootgen -image $out/zdaq.bif -arch zynq -process_bitstream bin -o $out/zdaq.bit.bin -w on
foreach f [glob -nocomplain $out/bd/zdaq/ip/*ps7*/ps7_init.tcl] { file copy -force $f $out/ps7_init.tcl }

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BUILD DONE  WNS = $wns ns"
