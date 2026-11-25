# AC_LGAD_Demo

A small demonstrator for the readout of AC-coupled LGADs (low gain avalanche diodes),
one of the sensor technologies for ePIC: two FPGA boards that run on one common clock,
time-stamp each trigger with it, and deliver their data over TCP to the RCDAQ data
acquisition, so the two data streams can be combined by timestamp.

The first version runs on two Digilent Zybo Z7 boards (Zynq-7000), with the clock carried
over an HDMI cable. Later the same scheme is meant for ZCU106 boards reading out the actual
ASICs. The board-side server and the RCDAQ plugin are designed to carry over unchanged;
only the part that reads from the firmware is board specific.

The full design (clock distribution, SYNC and trigger, TCP protocol, board server, RCDAQ
plugin, test plan) is in [spec.md](spec.md).

## Status

Step 1 (one Zybo Z7-20, tested over JTAG, no Linux yet):
- 64-bit timestamp counter and event builder on a 125 MHz clock from an MMCM, with the
  second MMCM input already in place for the HDMI clock of a consumer board.
- Triggers from the buttons: BTN0 = one trigger, BTN1 = one trigger every 10 ms while held
  (period adjustable), plus a soft trigger register.
- Events go into a FIFO the processor reads over AXI; a trigger that comes while the FIFO
  is full is dropped and counted, the trigger logic never waits.
- Tested on the board: 5 presses of BTN0 gave exactly 5 events; holding BTN1 for 2.3 s gave
  235 events, all exactly 10.000 ms apart, no drops.
- Event payload, 7 words of 32 bit: length in bytes (28), 64-bit timestamp (low word first),
  packet counter (= trigger number, so a dropped trigger shows as a gap), and the fixed tags
  0xFEEDC0DE, 0xDECAFBAD, 0xF0F0F0F0.
- Linux (PetaLinux 2024.2) on the board loads the bitstream at boot, takes the IP address
  from the switches, and `sw/zdaq_dump` reads the events through /dev/mem.

Next: the board server (TCP, spec section 5), then the second board with the clock over HDMI.

## Board settings

| Control | Function |
|---|---|
| SW3 | on = clock master (provides the clock and the triggers) |
| SW1..0 | board id 0..3, IP address 192.168.80.100 + id |
| BTN0 / BTN1 | one trigger / trigger train while held (clock master only) |
| LD0 / LD1 / LD2 / LD3 | trigger / run enabled / drops since clear / heartbeat |
| LD6 (RGB) | red = MMCM not locked, blue = clock master, green = consumer |

## Layout

| Path | Contents |
|---|---|
| `fw/src/zdaq_pl.vhd` | PL top: MMCM, AXI-Lite registers (map in the file header), clock-domain crossings, LEDs |
| `fw/src/trig_gen.vhd` | trigger sources (buttons, train, soft trigger) |
| `fw/src/evt_gen.vhd` | timestamp counter and event builder (event format in the file header) |
| `fw/src/debounce.vhd` | button and switch debouncer |
| `fw/sim/tb_zdaq.vhd` | self-checking testbench |
| `fw/constr/zybo_z7.xdc` | pins |
| `fw/build.tcl` | block design (PS7 + PL + event FIFO) and bitstream |
| `fw/jtag_test.tcl` | test over JTAG with xsdb, without Linux |
| `linux/rootfs_files/` | boot scripts for the board: `fpgaload` (bitstream, PL clock), `zdaq-net` (IP from the switches) |
| `sw/zdaq_dump.cc` | reads registers and events on the board, first step towards the server |

## Building and testing

Vivado 2024.2 (the free edition covers the Zynq-7020), with the Digilent board files installed.

```
cd fw
bash sim.sh                                              # testbench, ends with "TB PASSED"
vivado -mode batch -nojournal -nolog -source build.tcl   # out/zdaq.bit, .bit.bin, .xsa, ps7_init.tcl
xsdb jtag_test.tcl 60                                    # board in JTAG boot mode: soft triggers, then 60 s of button events
```
