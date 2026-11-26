#include "axis_fifo_source.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace zdaq
{
namespace
{
constexpr off_t REG_BASE  = 0x43C00000;
constexpr off_t FIFO_BASE = 0x43C10000;
constexpr off_t SLCR_BASE = 0xF8000000;

// zdaq_pl registers (word index), see fw/src/zdaq_pl.vhd
constexpr int R_VERSION = 0x00 / 4;
constexpr int R_CONTROL = 0x04 / 4;
constexpr int R_STATUS  = 0x08 / 4;
constexpr int R_TRIGS   = 0x18 / 4;
constexpr int R_DROPS   = 0x20 / 4;

// axi_fifo_mm_s registers (word index)
constexpr int F_RDFR = 0x18 / 4;   // write 0xA5: reset the RX FIFO
constexpr int F_RDFO = 0x1C / 4;   // RX occupancy in words
constexpr int F_RDFD = 0x20 / 4;   // RX data
constexpr int F_RLR  = 0x24 / 4;   // RX length of the next packet in bytes

// SLCR FPGA0_THR_CNT: bit 0 is the FCLK0 gate of the Linux clock driver (1 = off)
constexpr int SLCR_FCLK0_GATE = 0x178 / 4;

constexpr uint32_t CTL_ENABLE = 1u << 0;
constexpr uint32_t CTL_CLEAR  = 1u << 1;

volatile uint32_t *map_page(int fd, off_t base)
{
    void *p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    return p == MAP_FAILED ? nullptr : static_cast<volatile uint32_t *>(p);
}
} // namespace

AxisFifoSource::AxisFifoSource()
{
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (mem_fd < 0)
    {
        err = "cannot open /dev/mem (run as root)";
        return;
    }
    // Check the PL clock before the first PL access: with FCLK0 off the
    // access never completes and the whole board hangs.
    volatile uint32_t *slcr = map_page(mem_fd, SLCR_BASE);
    if (!slcr)
    {
        err = "cannot map the SLCR";
        return;
    }
    bool fclk_off = slcr[SLCR_FCLK0_GATE] & 1;
    munmap(const_cast<uint32_t *>(slcr), 4096);
    if (fclk_off)
    {
        err = "the PL clock FCLK0 is off (fpgaload switches it on before loading)";
        return;
    }
    reg = map_page(mem_fd, REG_BASE);
    fifo = map_page(mem_fd, FIFO_BASE);
    if (!reg || !fifo)
    {
        err = "cannot map the PL registers";
        return;
    }
    uint32_t v = reg[R_VERSION];
    if ((v >> 16) != 0x5A44)
    {
        err = "no DAQ firmware loaded";
        return;
    }
    id = (reg[R_STATUS] >> 4) & 3;
}

AxisFifoSource::~AxisFifoSource()
{
    if (reg)
    {
        reg[R_CONTROL] = 0;
        munmap(const_cast<uint32_t *>(reg), 4096);
    }
    if (fifo)
    {
        munmap(const_cast<uint32_t *>(fifo), 4096);
    }
    if (mem_fd >= 0)
    {
        close(mem_fd);
    }
}

int AxisFifoSource::start(uint32_t)
{
    if (!err.empty())
    {
        return -1;
    }
    reg[R_CONTROL] = 0;                     // stop, then throw away anything left over
    fifo[F_RDFR] = 0xA5;
    reg[R_CONTROL] = CTL_ENABLE | CTL_CLEAR;   // zero timestamp, numbers, counters; enable
    n_sent = 0;
    id = (reg[R_STATUS] >> 4) & 3;
    return 0;
}

int AxisFifoSource::stop()
{
    if (reg)
    {
        reg[R_CONTROL] = 0;                 // no new events; the FIFO keeps what it has
        usleep(1000);                       // let the last event through the clock-crossing FIFO
    }
    return 0;
}

int AxisFifoSource::read_event(std::vector<uint32_t> &ev)
{
    if (fifo[F_RDFO] == 0)
    {
        return 0;
    }
    uint32_t bytes = fifo[F_RLR] & 0x7FFFFF;
    uint32_t n = bytes / 4;
    if (n == 0 || n > 64 || bytes % 4)
    {
        return -1;                          // not an event from our firmware
    }
    ev.resize(n);
    for (uint32_t i = 0; i < n; i++)
    {
        ev[i] = fifo[F_RDFD];
    }
    n_sent++;
    return int(n);
}

void AxisFifoSource::counts(uint64_t &trig, uint64_t &sent, uint64_t &dropped)
{
    // the firmware counters are 32 bit; fine for runs up to 4e9 triggers
    trig = reg ? reg[R_TRIGS] : 0;
    sent = n_sent;
    dropped = reg ? reg[R_DROPS] : 0;
}

uint32_t AxisFifoSource::board_id() const
{
    return id;
}

uint32_t AxisFifoSource::firmware_version() const
{
    return reg ? reg[R_VERSION] : 0;
}

uint32_t AxisFifoSource::status() const
{
    if (!reg)
    {
        return 0;
    }
    uint32_t st = reg[R_STATUS];
    return ((st & 1) ? ST_MASTER : 0) | ((st & 2) ? ST_LOCKED : 0);
}
} // namespace zdaq
