## Zybo Z7-20 (pins the same on the Z7-10), two-board DAQ demo, step 1.
## Pins from Digilent's Zybo-Z7-Master.xdc (github.com/Digilent/digilent-xdc, MIT license)

## 125 MHz system clock
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports sysclk]
create_clock -name sysclk -period 8.000 [get_ports sysclk]

## Buttons: BTN0 = one trigger, BTN1 = trigger train, BTN2/3 spare
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports {btn[2]}]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports {btn[3]}]

## Switches: SW1..0 = board id (IP 192.168.80.100 + id), SW3 = clock master, SW2 spare
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]

## LEDs: LD0 trigger, LD1 enabled, LD2 drops, LD3 heartbeat
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

## RGB LED LD6: red = MMCM not locked, blue = clock master, green = consumer
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports led6_r]
set_property -dict { PACKAGE_PIN F17 IOSTANDARD LVCMOS33 } [get_ports led6_g]
set_property -dict { PACKAGE_PIN M17 IOSTANDARD LVCMOS33 } [get_ports led6_b]

## Ethernet PHY reset; must be driven high when Linux uses the network
set_property -dict { PACKAGE_PIN E17 IOSTANDARD LVCMOS33 } [get_ports eth_rst_b]

## Buttons, switches and LEDs are asynchronous to everything (synchronized inside)
set_false_path -from [get_ports {btn[*] sw[*]}]
set_false_path -to   [get_ports {led[*] led6_* eth_rst_b}]
