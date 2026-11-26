#pragma once

// TCP protocol between a board and RCDAQ (spec.md section 4).
// Every message starts with this 16-byte header; all fields little-endian,
// which is the native byte order of Zynq, ZynqMP and x86, so nobody converts.

#include <bit>
#include <cstdint>

static_assert(std::endian::native == std::endian::little, "the protocol assumes a little-endian host");

namespace zdaq
{
constexpr uint32_t MAGIC       = 0x5A444151;     // "QADZ" in memory
constexpr uint16_t VERSION     = 1;
constexpr uint32_t MAX_PAYLOAD = 1 << 20;        // bytes
constexpr int      DEFAULT_PORT = 5555;

struct Header
{
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t length;     // payload bytes after the header, a multiple of 4
    uint32_t seq;        // per-direction message counter, from 0 per connection
};
static_assert(sizeof(Header) == 16);

// RCDAQ -> board
constexpr uint16_t START = 0x0001;   // u32 run number, u32 flags (0)
constexpr uint16_t STOP  = 0x0002;   // no payload

// board -> RCDAQ
constexpr uint16_t ACK   = 0x8001;   // u32 run, u32 board id, u32 firmware version, u32 status
constexpr uint16_t ERROR = 0x8002;   // u32 code, text padded with NULs to a multiple of 4
constexpr uint16_t END   = 0x8003;   // u32 run, u32 reserved, u64 triggers, u64 sent, u64 dropped
constexpr uint16_t DATA  = 0x8010;   // u32 run, u32 board id, then the firmware event unchanged

// ACK status bits
constexpr uint32_t ST_MASTER = 1u << 0;   // this board is the clock master
constexpr uint32_t ST_LOCKED = 1u << 1;   // MMCM locked

// ERROR codes
constexpr uint32_t E_PROTOCOL = 1;   // bad header, unknown type, bad length
constexpr uint32_t E_STATE    = 2;   // START while running, STOP while not running
constexpr uint32_t E_SOURCE   = 3;   // the data source failed

// Firmware event (7 words): length in bytes (28), timestamp low, high,
// packet counter (= trigger number), and three fixed tags.
constexpr uint32_t EVENT_WORDS = 7;
constexpr uint32_t TAG0 = 0xFEEDC0DE;
constexpr uint32_t TAG1 = 0xDECAFBAD;
constexpr uint32_t TAG2 = 0xF0F0F0F0;
constexpr double   CLOCK_HZ = 125.0e6;   // timestamp ticks per second
} // namespace zdaq
