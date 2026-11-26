// zdaq_dump: read the DAQ demo registers and events on the Zybo through /dev/mem.
// First step towards the board server; run as root.
//
//   zdaq_dump [-c] [-s n] [-w seconds] [-p period_ms] [-m mask] [-f pulser_hz] [-q]
//     -c     enable and clear (zero timestamp, counters), empty the FIFO
//     -s n   fire n soft triggers
//     -w s   print events for s seconds (default 0: only what is in the FIFO now)
//     -p ms  set the BTN1 train period
//     -m m   trigger sources: bit0 buttons, bit1 Pmod JE1, bit2 pulser
//     -f hz  set the pulser rate (switch it on with -m 4 or similar)
//     -q     no line per event, only the summary
//
// Build (static, so it does not depend on the libraries in the board's image), e.g. with
// the ARM cross compiler that comes with Vitis:
//   arm-linux-gnueabihf-g++ -std=c++20 -O2 -Wall -Wextra -static -o zdaq_dump zdaq_dump.cc
//
// Event: 7 words, length in bytes (28), timestamp low, high, packet counter,
// 0xFEEDC0DE, 0xDECAFBAD, 0xF0F0F0F0.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace
{
constexpr off_t REG_BASE  = 0x43C00000;
constexpr off_t FIFO_BASE = 0x43C10000;

// zdaq_pl registers (word index)
constexpr int R_VERSION = 0x00 / 4;
constexpr int R_CONTROL = 0x04 / 4;
constexpr int R_STATUS  = 0x08 / 4;
constexpr int R_INPUTS  = 0x0C / 4;
constexpr int R_PERIOD  = 0x10 / 4;
constexpr int R_SRC     = 0x14 / 4;
constexpr int R_PULSE   = 0x28 / 4;
constexpr int R_TRIGS   = 0x18 / 4;
constexpr int R_EVTS    = 0x1C / 4;
constexpr int R_DROPS   = 0x20 / 4;
constexpr int R_SOFT    = 0x24 / 4;

// axi_fifo_mm_s registers (word index)
constexpr int F_RDFR = 0x18 / 4;   // write 0xA5: reset RX FIFO
constexpr int F_RDFO = 0x1C / 4;   // RX occupancy in words
constexpr int F_RDFD = 0x20 / 4;   // RX data
constexpr int F_RLR  = 0x24 / 4;   // RX length of the next packet in bytes

volatile uint32_t *map(int fd, off_t base)
{
    void *p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    if (p == MAP_FAILED)
    {
        perror("mmap");
        exit(1);
    }
    return static_cast<volatile uint32_t *>(p);
}

double now()
{
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + 1e-9 * t.tv_nsec;
}

// one event from the FIFO, empty if there is none
std::vector<uint32_t> get_event(volatile uint32_t *fifo)
{
    std::vector<uint32_t> w;
    if (fifo[F_RDFO] == 0)
    {
        return w;
    }
    uint32_t n = fifo[F_RLR] / 4;
    w.resize(n);
    for (uint32_t i = 0; i < n; i++)
    {
        w[i] = fifo[F_RDFD];
    }
    return w;
}

bool quiet = false;

bool show(const std::vector<uint32_t> &w, uint64_t &prev_ts)
{
    static const uint32_t tags[3] = {0xFEEDC0DE, 0xDECAFBAD, 0xF0F0F0F0};
    bool ok = w.size() == 7 && w[0] == 4 * w.size();
    uint64_t ts = 0;
    for (int i = 0; ok && i < 3; i++)
    {
        ok = w[4 + i] == tags[i];
    }
    if (quiet && ok)
    {
        return true;
    }
    if (w.size() >= 4)
    {
        ts = (uint64_t(w[2]) << 32) | w[1];
        printf("event %8u  ts %15llu  (%.6f s)", w[3], (unsigned long long) ts, ts / 125.0e6);
        if (prev_ts)
        {
            printf("  +%.3f ms", (ts - prev_ts) / 125.0e3);
        }
        prev_ts = ts;
    }
    if (!ok)
    {
        printf("  BAD EVENT (%zu words:", w.size());
        for (auto x : w)
        {
            printf(" %08x", x);
        }
        printf(")");
    }
    printf("\n");
    return ok;
}
} // namespace

int main(int argc, char *argv[])
{
    bool clear = false;
    int soft = 0;
    double watch = 0;
    int period_ms = -1;
    int mask = -1;
    double pulser_hz = -1;
    int c;
    while ((c = getopt(argc, argv, "cs:w:p:m:f:q")) != -1)
    {
        switch (c)
        {
        case 'c': clear = true; break;
        case 's': soft = atoi(optarg); break;
        case 'w': watch = atof(optarg); break;
        case 'p': period_ms = atoi(optarg); break;
        case 'm': mask = int(strtol(optarg, nullptr, 0)); break;
        case 'f': pulser_hz = atof(optarg); break;
        case 'q': quiet = true; break;
        default:
            fprintf(stderr, "usage: %s [-c] [-s n] [-w seconds] [-p period_ms] [-m mask] [-f pulser_hz] [-q]\n",
                    argv[0]);
            return 1;
        }
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0)
    {
        perror("/dev/mem");
        return 1;
    }
    volatile uint32_t *reg = map(fd, REG_BASE);
    volatile uint32_t *fifo = map(fd, FIFO_BASE);

    uint32_t ver = reg[R_VERSION];
    if ((ver >> 16) != 0x5A44)
    {
        fprintf(stderr, "no DAQ firmware loaded (VERSION 0x%08x)\n", ver);
        return 1;
    }
    uint32_t st = reg[R_STATUS];
    printf("VERSION 0x%08x  board id %u  clock master %u  MMCM locked %u  enabled %u  inputs 0x%03x\n",
           ver, (st >> 4) & 3, st & 1, (st >> 1) & 1, (st >> 8) & 1, reg[R_INPUTS]);

    if (period_ms >= 0)
    {
        reg[R_PERIOD] = uint32_t(period_ms) * 125000;
    }
    if (pulser_hz > 0)
    {
        reg[R_PULSE] = uint32_t(125.0e6 / pulser_hz + 0.5);
    }
    if (mask >= 0)
    {
        reg[R_SRC] = uint32_t(mask);
    }
    if (clear)
    {
        fifo[F_RDFR] = 0xA5;
        reg[R_CONTROL] = 3;        // enable + clear
        usleep(1000);
    }
    for (int i = 0; i < soft; i++)
    {
        reg[R_SOFT] = 1;
        usleep(1000);
    }

    uint64_t prev_ts = 0;
    int nev = 0;
    int bad = 0;
    double t_end = now() + watch;
    do
    {
        auto w = get_event(fifo);
        if (w.empty())
        {
            usleep(1000);
            continue;
        }
        nev++;
        if (!show(w, prev_ts))
        {
            bad++;
        }
    } while (now() < t_end || fifo[F_RDFO] != 0);

    printf("%d events read, %d bad;  firmware counts: triggers %u  events %u  dropped %u\n",
           nev, bad, reg[R_TRIGS], reg[R_EVTS], reg[R_DROPS]);
    printf("sources 0x%x, train period %.3f ms, pulser %.1f Hz\n", reg[R_SRC], reg[R_PERIOD] / 125.0e3,
           125.0e6 / (reg[R_PULSE] ? reg[R_PULSE] : 1));
    return bad ? 2 : 0;
}
