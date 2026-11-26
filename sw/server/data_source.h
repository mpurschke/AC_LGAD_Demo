#pragma once

// Where the events come from: the only board-specific part of the server.
//   SimSource      - software generator, same event format as the firmware
//   AxisFifoSource - the Zybo PL (axi_fifo_mm_s), later
//   DmaSource      - ZCU106, later

#include <cstdint>
#include <vector>

namespace zdaq
{
class DataSource
{
public:
    virtual ~DataSource() = default;

    // file descriptor for poll() that becomes readable when events may be
    // waiting; -1 = none, the server then polls every millisecond
    virtual int fd() const = 0;

    virtual int start(uint32_t run) = 0;      // clear FIFO and counters, enable; 0 = ok
    virtual int stop() = 0;                   // disable; events still buffered stay readable

    // one event into ev (firmware words, unchanged); returns its number of
    // words, 0 if there is none right now, < 0 on an error
    virtual int read_event(std::vector<uint32_t> &ev) = 0;

    // triggers seen, events handed out, triggers dropped since start()
    virtual void counts(uint64_t &trig, uint64_t &sent, uint64_t &dropped) = 0;

    virtual uint32_t board_id() const = 0;
    virtual uint32_t firmware_version() const = 0;
    virtual uint32_t status() const = 0;      // ST_MASTER, ST_LOCKED
};
} // namespace zdaq
