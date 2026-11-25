# Two-Zybo DAQ demo: shared clock, TCP readout into RCDAQ

Working spec, started 2026-11-22.
Goal: two Zybo boards make up data on a common clock, each serves its data over
TCP from PetaLinux, RCDAQ collects both and the streams can be combined by
timestamp. The board-side server should carry over to the ZCU106 boards
unchanged, only the part that reads from the firmware is board specific.

Items marked **(check)** are assumptions not yet verified.

## 1. Overview

```
 trigger (internal pulser / Pmod / button)
        |
 +------v---------------+   HDMI cable    +----------------------+
 | Zybo A  (provider)   |  clk  = 125 MHz | Zybo B  (consumer)   |
 |  MMCM <- sysclk 125  |  d0   = SYNC    |  MMCM <- HDMI RX clk |
 |  ts counter, events  |  d1   = TRIGGER |  ts counter, events  |
 |  PetaLinux server    |---------------->|  PetaLinux server    |
 +----------+-----------+                 +-----------+----------+
            | TCP                                     | TCP
            +-------------------+---------------------+
                                |
                     RCDAQ, one device per board
```

- Both boards run their timestamp counter and event logic on the same 125 MHz clock.
- The PS, AXI and Linux side of each board stays on its own clock. The data crosses
  into the AXI clock domain through an asynchronous FIFO.
- Each board is a TCP server. RCDAQ is the only client and opens one connection per
  board and run.

## 2. Clock, sync and trigger over HDMI

Pins from the Digilent master XDC, the same on Z7-10 and Z7-20:

| Signal    | Provider: HDMI TX            | Consumer: HDMI RX                 |
|-----------|------------------------------|-----------------------------------|
| clock     | `hdmi_tx_clk_p/n` H16/H17    | `hdmi_rx_clk_p/n` U18/U19 (MRCC)  |
| SYNC      | `hdmi_tx_p/n[0]`             | `hdmi_rx_p/n[0]`                  |
| TRIGGER   | `hdmi_tx_p/n[1]`             | `hdmi_rx_p/n[1]`                  |
| spare     | `hdmi_tx_p/n[2]`             | `hdmi_rx_p/n[2]`                  |

- IOSTANDARD is `TMDS_33` on both ends. TMDS needs 50 ohm pull-ups to 3.3 V at the
  receiver. **(check)** the Zybo HDMI RX schematic for them; Digilent's dvi2rgb core
  works on this connector, so they are most likely there.
- The provider drives the clock out through an ODDR (D1=1, D2=0) into an OBUFDS. It does
  not drive the clock net directly.
- The consumer passes the received clock through an IBUFDS into the MMCM.
- The other direction (consumer TX to provider RX) is unused for now. A second cable
  could later carry BUSY back to the provider.

**Role selection** (one bitstream if both boards are Z7-20):
- MMCME2 `CLKIN1` = sysclk (K17, 125 MHz), `CLKIN2` = HDMI RX clock, `CLKINSEL` = SW3.
  The provider's clock comes from its own sysclk, the consumer's from the cable.
- The switch is read at reset. A change of the switch resets the MMCM.
- The provider forwards 125 MHz, so both MMCM inputs have the same frequency and the
  MMCM settings are identical in both roles.
- With a Z7-10 as consumer: the same VHDL is built twice, once for each part. The role
  can still come from the switch.
- The provider's HDMI TX must be running before the consumer configures. Otherwise
  the consumer waits for MMCM `locked`.

**SYNC:** a single-clock pulse that zeroes the timestamp counter on both boards.
- The provider issues it when it receives START and applies it to its own counter in
  the same clock cycle on which it would arrive at the consumer. Before that, it is
  delayed by the measured latency (step 5 of the test plan).
- The consumer must already be armed by then. So RCDAQ must start the consumer(s)
  before the provider: the consumer devices are defined first in the RCDAQ setup.
  **(check)** that RCDAQ calls `init()` in the order the devices were defined.
- Each board flags whether it has seen a SYNC since START (DATA frame flags, ACK).

**TRIGGER:**
- The trigger is generated in, or comes into, the provider and is forwarded over d1.
  The consumer sees it a fixed number of clocks later.
- The latency is constant and is measured once. From then on, equal timestamps on the
  two boards (after the offset correction) mean the same trigger.
- Trigger sources on the provider: an internal pulser (fixed period or pseudo-random,
  for the demo), a Pmod input, or BTN0. A register selects the source.

## 3. Firmware per board (PL)

Shared-clock domain (125 MHz from the MMCM):
- 64-bit timestamp counter, zeroed by SYNC.
- The trigger takes a snapshot of the counter. With it go the event number (32 bit,
  zeroed at START) and a made-up payload: N words of a counter pattern or LFSR, plus
  the board ID, so the decoding can be checked.
- This goes out as an AXI-Stream with TLAST at the end of each event.
- If the FIFO is full: the event is dropped and a drop counter incremented, never stalls
  the trigger logic. The next event that does get through carries a "drops before this
  event" flag.

Crossing into the AXI clock domain:
- AXI-Stream data FIFO with independent clocks, into an AXI-Stream FIFO (`axi_fifo_mm_s`)
  on M_AXI_GP0.
- Plus a small AXI-Lite register block:
  - control: enable, FIFO clear, counter clear, trigger source, pulser period
  - status: role, MMCM locked, SYNC seen
  - counters: triggers seen, events written, events dropped
  - firmware version, board ID

Zybo specifics (from earlier work): every PL design loaded under Linux must contain the
PS7 block (without it the FIQ lines into the ARM cores are not tied off and Linux hangs),
and must drive E17 (`eth_rst_b`) high.

Data rate: GP0 plus the AXI-Stream FIFO is good for some tens of MB/s, plenty for the
demo. The ZCU106 version will use DMA. That changes only the source backend in the
server (section 5).

## 4. TCP protocol

- Default port 5555; it can be set on the server's command line.
- **Byte order: little-endian throughout**, not network byte order. Zynq ARM, ZynqMP
  aarch64 and x86 are all little-endian, so neither side converts. The magic word shows
  it if that ever breaks.
- All payload lengths are a multiple of 4 bytes, which keeps the packing into RCDAQ
  32-bit words simple.

### 4.1 Message header (16 bytes, every message, both directions)

| Offset | Type   | Field    | Meaning                                         |
|-------:|--------|----------|-------------------------------------------------|
| 0      | u32    | magic    | 0x5A444151                                      |
| 4      | u16    | version  | protocol version, 1                             |
| 6      | u16    | type     | message type, see 4.2                           |
| 8      | u32    | length   | payload bytes after this header, multiple of 4  |
| 12     | u32    | seq      | per-direction message counter, from 0 per connection |

Receiver rules:
- Wrong magic or version → protocol error, close the connection.
- length > agreed maximum (e.g. 1 MB) → protocol error. On the RCDAQ side the limit
  is `max_length()`.
- A gap in seq → protocol error. Over TCP this cannot happen unless one side has a bug.

### 4.2 Message types

RCDAQ → board:

| Type   | Name  | Payload                        |
|--------|-------|--------------------------------|
| 0x0001 | START | u32 run number, u32 flags (0)  |
| 0x0002 | STOP  | none                           |

Board → RCDAQ:

| Type   | Name  | Payload |
|--------|-------|---------|
| 0x8001 | ACK   | u32 run number (echo), u32 board ID, u32 firmware version, u32 status bits (bit0 role: 1 = provider, bit1 MMCM locked) |
| 0x8002 | ERROR | u32 code, then text padded with NULs to a multiple of 4 |
| 0x8010 | DATA  | see 4.3 |
| 0x8003 | END   | u32 run number, u32 reserved, u64 triggers seen, u64 events sent, u64 events dropped |

Type numbers 0x0003-0x00FF and 0x8004-0x80FF are kept free for later commands: STATUS,
configuration and register access.

### 4.3 DATA payload (one frame = one trigger = one RCDAQ event)

| Offset | Type  | Field                                                  |
|-------:|-------|--------------------------------------------------------|
| 0      | u32   | run number                                             |
| 4      | u32   | board ID                                               |
| 8      | u32   | event number, from 0 at START                          |
| 12     | u32   | flags: bit0 drops before this event, bit1 SYNC seen since START, bit2 role provider |
| 16     | u64   | timestamp, 125 MHz ticks since SYNC                    |
| 24     | u32   | number of data words N                                 |
| 28     | u32   | reserved                                               |
| 32     | u32[N]| data                                                   |

### 4.4 Sequence

```
RCDAQ                                board
  |-- connect ------------------------>|  (init / begin-run; fail -> begin-run fails)
  |-- START(run) --------------------->|  board: FIFO clear, counters clear, enable, (provider: SYNC)
  |<---------------- [stale bytes?] ---|  RCDAQ discards everything up to the ACK
  |<------------------------- ACK -----|
  |<------------------------ DATA -----|  idle loop: select() 2 s, put_data() reads one frame
  |<------------------------ DATA -----|
  |-- STOP --------------------------->|  (endrun) board: disable, send what is in the FIFO
  |<-------------------- DATA... ------|  RCDAQ drains and discards
  |<------------------------- END -----|  counts; RCDAQ prints them / logs lost events
  |-- close -------------------------->|
```

Error cases:
- **The connection drops in a run:** the board disables, clears its FIFO and goes back
  to listening. RCDAQ sees `recv()` = 0 or an error, and marks the device broken with a
  message.
- **A second connection arrives:** it replaces the first. The old connection is closed
  and an active run is stopped. This is how the board recovers after RCDAQ crashes and
  leaves a stale connection.
- **No ACK within 2 s of START:** `init()` returns an error and begin-run fails.
- Both sides set TCP keepalive (idle 5 s, interval 1 s, count 3), so a dead peer is
  noticed within about 10 s.

## 5. Board-side server (PetaLinux, carries over to ZCU106)

- One plain C++ program, single-threaded, with a `poll()` loop over the listening
  socket, the client socket and the data source. POSIX only, no Xilinx libraries, so
  it builds for Zynq (armhf), ZynqMP (aarch64) and x86.
- States: IDLE (no client), CONNECTED, RUNNING.
- **Data source interface**, the only board-specific part:
  ```
  class DataSource
  {
  public:
      virtual int  fd() const = 0;                  // for poll(), -1 if timer driven
      virtual int  start(uint32_t run) = 0;         // clear FIFO + counters, enable
      virtual int  stop() = 0;                      // disable
      virtual int  read_event(std::vector<uint32_t> &ev) = 0;   // one event, 0 = none
      virtual void counts(uint64_t &trig, uint64_t &sent, uint64_t &dropped) = 0;
      virtual ~DataSource() = default;
  };
  ```
  - `SimSource`: pure software generator with a timer and the same frame format. With
    it, the server and the RCDAQ plugin can be tested on a Linux PC before there is any
    firmware.
  - `AxisFifoSource`: the Zybo PL. It reads events from the AXI-Stream FIFO, either
    through the kernel's `axis-fifo` driver, where `read()` returns one TLAST-delimited
    packet, or through UIO + mmap. **(check)** that `axis-fifo` (staging,
    `CONFIG_XIL_AXIS_FIFO`) is in the PetaLinux 2024.2 kernel; otherwise UIO. Control
    and status registers go through UIO + mmap.
  - `DmaSource`: later, for the ZCU106, with whatever the ZCU106 firmware provides.
- Sending: a blocking `send()` with `SO_SNDTIMEO`. While RCDAQ is slow, the server
  waits, the PL FIFO fills, and the firmware drops and counts. That is the intended
  behaviour, and END reports it.
- Command line: `--port`, `--board-id` (default: from the PL register), `--source sim|axis`.
- Started at boot as a service. **(check)** whether our PetaLinux image uses sysvinit
  (the PetaLinux default) or systemd.
- C++ standard: C++20 is fine here. The PetaLinux 2024.2 toolchain is gcc 13
  **(check)**. Built as a PetaLinux app recipe, or by hand with the SDK cross compiler.

## 6. RCDAQ plugin

A new device class next to `daq_device_h2gcroc3`. Name TBD, e.g. `daq_device_zybostream`.
Device arguments: event type, subevent ID, IP, port, trigger flag.

- `init()`: connect (with a timeout); on failure return an error, so begin-run fails.
  Then send START(run number), read and discard frames until the ACK (2 s timeout),
  check the ACK's run number, and print board ID, firmware version and role.
- Trigger handler: as in `h2gcroc3TriggerHandler`, with `select()` and a 2 s timeout,
  but it must get the socket from the device on each call (a pointer or getter). The
  socket is new each run, so a copy made in the constructor would be stale.
- `put_data()`: read exactly one message:
  - the 16-byte header, then exactly `length` bytes, looping over partial `recv()`s
    (TCP has no message boundaries, unlike the UDP datagrams in the H2GCROC3 plugin);
  - `SO_RCVTIMEO` about 1 s, so a frame that stops halfway can't hang RCDAQ;
  - check magic, length against `max_length()`, run number;
  - `recv()` = 0 → the board closed the connection → broken, with a message;
  - copy header plus payload into the subevent unchanged, with a new hitformat number
    for the decoder.
- `endrun()`: send STOP, read and discard until END (timeout about 2 s), print the
  counts (triggers seen, sent, dropped), close the connection.
- C++: same standard as RCDAQ itself. As long as RCDAQ still has to build under C++17,
  avoid C++20-only features in the plugin.

Combining the boards: each board is its own subevent in the same RCDAQ event stream.
The two boards' events for the same trigger have equal timestamps after the offset
correction, so they can be matched offline. Doing that in the event builder is for later.

## 7. Test plan

1. **Software only, on a Linux PC:** the server with `SimSource` plus the RCDAQ plugin.
   Exercise the protocol and the error cases: kill the server in a run, start RCDAQ
   twice, give a wrong IP.
2. **The server on the Zybo Z7-20 PetaLinux, `SimSource`:** the network path, the
   service starting at boot.
3. **One board with firmware:** `AxisFifoSource`, internal pulser, check event numbers
   and the payload pattern, provoke drops by running fast with RCDAQ throttled.
4. **Clock over HDMI:** the consumer locks to the provider's clock. Check MMCM
   `locked`, and pull the cable to see what happens.
5. **SYNC and TRIGGER latency:** both boards in RCDAQ, the pulser on the provider. The
   timestamp difference for the same event number must be constant for the whole run.
   Measure it once and put it into the provider's SYNC delay.
6. **ZCU106:** new PL and `DmaSource` (the ZCU106 firmware). The server's protocol code
   and the RCDAQ plugin stay unchanged.

## 8. Open questions

- Does RCDAQ call `init()` in the order the devices were defined (needed for the SYNC order)?
- A second Z7-20 available? (one bitstream with the role on a switch vs. two builds)
- Port number, maximum frame size, payload size for the demo.
- Should the BUSY go back over a second HDMI cable, or is "drop and count" enough for the demo?
- What the ZCU106 firmware will deliver (DMA type, driver), so that `DmaSource` can be
  planned early.
