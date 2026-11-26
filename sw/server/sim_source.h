#pragma once

// Software stand-in for the firmware: triggers at a fixed rate, events in the
// same format, and a bounded buffer like the PL FIFO, so a slow reader leads
// to dropped triggers (gaps in the packet counter) exactly as on the board.

#include "data_source.h"
#include "protocol.h"

#include <cstdint>
#include <deque>

namespace zdaq
{
class SimSource : public DataSource
{
public:
    // rate in triggers per second; buffer = how many events fit (the PL FIFO
    // holds 4096 words = 585 events of 7 words)
    SimSource(double rate, uint32_t board_id, size_t buffer = 585);
    ~SimSource() override;

    int fd() const override { return timer_fd; }
    int start(uint32_t run) override;
    int stop() override;
    int read_event(std::vector<uint32_t> &ev) override;
    void counts(uint64_t &trig, uint64_t &sent, uint64_t &dropped) override;

    uint32_t board_id() const override { return id; }
    uint32_t firmware_version() const override { return 0x5A440000; }   // 0000 = simulation
    uint32_t status() const override { return ST_MASTER | ST_LOCKED; }

private:
    void generate();       // make the triggers that are due by now

    double rate;
    uint32_t id;
    size_t buffer;
    int timer_fd = -1;
    bool running = false;
    double t_start = 0;
    uint64_t n_trig = 0, n_sent = 0, n_drop = 0;
    std::deque<std::vector<uint32_t>> queue;
};
} // namespace zdaq
