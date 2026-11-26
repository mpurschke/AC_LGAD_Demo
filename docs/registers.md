# Messages, registers and commands

Quick reference for firmware version 0x5A440003 and protocol version 1. The full design is in
[spec.md](../spec.md).

## TCP messages

Every message starts with a 16-byte header, all fields little-endian:

| Offset | Type | Field |
|-------:|------|-------|
| 0 | u32 | magic 0x5A444151 |
| 4 | u16 | protocol version, 1 |
| 6 | u16 | message type (below) |
| 8 | u32 | payload length in bytes, a multiple of 4 |
| 12 | u32 | sequence number, per direction, from 0 per connection |

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| 0x0001 | START | RCDAQ → board | u32 run number, u32 flags (0) |
| 0x0002 | STOP | RCDAQ → board | none |
| 0x8001 | ACK | board → RCDAQ | u32 run, u32 board id, u32 firmware version, u32 status (bit0 clock master, bit1 MMCM locked) |
| 0x8002 | ERROR | board → RCDAQ | u32 code (1 protocol, 2 state, 3 data source), text padded with NULs |
| 0x8003 | END | board → RCDAQ | u32 run, u32 reserved, u64 triggers, u64 events sent, u64 dropped |
| 0x8010 | DATA | board → RCDAQ | u32 run, u32 board id, then the firmware event (below) |

Types 0x0003-0x00FF and 0x8004-0x80FF are free for later commands (configuration, register
access). There is no network command for the trigger sources or the pulser yet; START only
enables the firmware and zeroes timestamp and counters, the source settings stay as they are.

## Firmware event

7 words of 32 bit:

| Word | Contents |
|-----:|----------|
| 0 | length of the event in bytes (28) |
| 1 | timestamp bits 31..0 (125 MHz ticks since clear) |
| 2 | timestamp bits 63..32 |
| 3 | packet counter = trigger number (a dropped trigger leaves a gap) |
| 4 | 0xFEEDC0DE |
| 5 | 0xDECAFBAD |
| 6 | 0xF0F0F0F0 |

## Firmware registers

Base address 0x43C0_0000. Times are in clocks of the shared 125 MHz clock (8 ns).

| Offset | Name | Access | Contents |
|-------:|------|--------|----------|
| 0x00 | VERSION | RO | 0x5A440003 |
| 0x04 | CONTROL | RW | bit0 enable; bit1 clear (write 1: zero timestamp, numbers, counters; reads 0) |
| 0x08 | STATUS | RO | bit0 clock master (SW3), bit1 MMCM locked, bits 5..4 board id (SW1..0), bit8 enabled, bit9 drops since clear |
| 0x0C | INPUTS | RO | bits 3..0 switches, bits 11..8 buttons (raw) |
| 0x10 | TRAIN_PERIOD | RW | spacing of the BTN1 train (default 1,250,000 = 10 ms) |
| 0x14 | TRIG_SRC | RW | trigger sources: bit0 buttons, bit1 Pmod JE1, bit2 pulser (default 0x3) |
| 0x18 | TRIG_COUNT | RO | triggers while enabled |
| 0x1C | EVT_COUNT | RO | events written into the FIFO |
| 0x20 | DROP_COUNT | RO | triggers dropped because the FIFO was full |
| 0x24 | SOFT_TRIG | WO | any write: one trigger (works on a consumer too) |
| 0x28 | PULSE_PERIOD | RW | spacing of the pulser (default 125,000 = 1 kHz) |

Buttons, JE1 and the pulser act only on the clock master; the soft trigger always works.
The event FIFO (`axi_fifo_mm_s`) is at 0x43C1_0000.

## Board controls

| Control | Function |
|---------|----------|
| SW3 | on = clock master |
| SW1..0 | board id 0..3, IP address 192.168.80.100 + id |
| BTN0 | one trigger per press (debounced, so on a 1 ms grid) |
| BTN1 | trigger train while held |
| Pmod JE pin 1 | hardware trigger, 3.3 V LVCMOS, rising edge, 8 ns resolution, not debounced (pin 5 GND, pin 6 3.3 V) |
| LD0 / LD1 / LD2 / LD3 | trigger / enabled / drops since clear / heartbeat |
| LD6 | red = MMCM not locked, blue = clock master, green = consumer |

## Commands on the board

```
zdaq_dump -m 4 -f 50000 -q     # trigger source: pulser only, at 50 kHz
zdaq_dump -m 3 -q              # back to buttons + JE1
zdaq_dump -c -s 5              # enable + clear, 5 soft triggers, print the events
zdaq_dump -c -w 30             # enable + clear, print events for 30 s (press the buttons)
zdaq_dump -p 20                # BTN1 train every 20 ms
zdaq_server --source axis      # TCP server on port 5555 with the firmware events
zdaq_server --source sim --rate 1000   # same with simulated events
```

From a PC (`sw/server`, built with `make`):

```
zdaq_client 192.168.80.100 -t 20       # one run of 20 s, one line per event, checks everything
zdaq_client 192.168.80.100 -t 5 -q     # summary only
```
