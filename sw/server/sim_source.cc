#include "sim_source.h"
#include "protocol.h"

#include <ctime>
#include <sys/timerfd.h>
#include <unistd.h>

namespace zdaq
{
namespace
{
double now()
{
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + 1e-9 * t.tv_nsec;
}
} // namespace

SimSource::SimSource(double rate, uint32_t board_id, size_t buffer)
    : rate(rate), id(board_id), buffer(buffer)
{
    timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
}

SimSource::~SimSource()
{
    if (timer_fd >= 0)
    {
        close(timer_fd);
    }
}

int SimSource::start(uint32_t)
{
    queue.clear();
    n_trig = n_sent = n_drop = 0;
    t_start = now();
    running = true;
    // wake up every millisecond, or once per trigger if that is slower
    long ns = rate >= 1000 ? 1000000 : long(1e9 / rate);
    itimerspec its {{ns / 1000000000, ns % 1000000000}, {ns / 1000000000, ns % 1000000000}};
    return timerfd_settime(timer_fd, 0, &its, nullptr);
}

int SimSource::stop()
{
    generate();
    running = false;
    itimerspec off {};
    return timerfd_settime(timer_fd, 0, &off, nullptr);
}

void SimSource::generate()
{
    uint64_t expired;
    while (read(timer_fd, &expired, sizeof expired) > 0)
    {
    }
    if (!running)
    {
        return;
    }
    uint64_t due = uint64_t((now() - t_start) * rate);
    for (; n_trig < due; n_trig++)
    {
        if (queue.size() >= buffer)
        {
            n_drop++;                   // buffer full: this trigger is lost
            continue;
        }
        uint64_t ts = uint64_t((n_trig + 1) * CLOCK_HZ / rate);
        queue.push_back({4 * EVENT_WORDS, uint32_t(ts), uint32_t(ts >> 32), uint32_t(n_trig),
                         TAG0, TAG1, TAG2});
    }
}

int SimSource::read_event(std::vector<uint32_t> &ev)
{
    generate();                         // the buffer fills while nobody reads, like the PL FIFO
    if (queue.empty())
    {
        return 0;
    }
    ev = std::move(queue.front());
    queue.pop_front();
    n_sent++;
    return int(ev.size());
}

void SimSource::counts(uint64_t &trig, uint64_t &sent, uint64_t &dropped)
{
    trig = n_trig;
    sent = n_sent;
    dropped = n_drop;
}
} // namespace zdaq
