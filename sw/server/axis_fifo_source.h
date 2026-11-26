#pragma once

// Data source for the Zybo PL: the zdaq_pl registers and the event FIFO
// (axi_fifo_mm_s), both mapped through /dev/mem (needs root). No interrupt
// yet, so fd() is -1 and the server looks at the FIFO every millisecond.

#include "data_source.h"
#include "protocol.h"

#include <cstdint>
#include <string>

namespace zdaq
{
class AxisFifoSource : public DataSource
{
public:
    AxisFifoSource();
    ~AxisFifoSource() override;

    // empty if the board is usable, else the reason (no firmware, PL clock off, ...)
    const std::string &error() const { return err; }

    int fd() const override { return -1; }
    int start(uint32_t run) override;
    int stop() override;
    int read_event(std::vector<uint32_t> &ev) override;
    void counts(uint64_t &trig, uint64_t &sent, uint64_t &dropped) override;

    uint32_t board_id() const override;
    uint32_t firmware_version() const override;
    uint32_t status() const override;

private:
    int mem_fd = -1;
    volatile uint32_t *reg = nullptr;     // 0x43C0_0000
    volatile uint32_t *fifo = nullptr;    // 0x43C1_0000
    uint64_t n_sent = 0;
    uint32_t id = 0;                      // read at start(): a register read costs ~1 us
    std::string err;
};
} // namespace zdaq
