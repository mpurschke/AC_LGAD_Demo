// zdaq_client: test client for zdaq_server, plays the part of RCDAQ.
//
//   zdaq_client host [-p port] [-r run] [-t seconds] [-s slow_us] [-q]
//     -t  how long the run lasts (default 5 s)
//     -s  sleep this long after each event, to provoke drops on the board
//     -q  quiet: no per-event lines, only the summary
//
// connect -> START -> read up to the ACK -> DATA for t seconds -> STOP ->
// read up to END. Checks every message and every event, compares END with
// what arrived, and exits non-zero if anything is wrong.

#include "net.h"
#include "protocol.h"

#include <arpa/inet.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <netdb.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

using namespace zdaq;

namespace
{
double now()
{
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + 1e-9 * t.tv_nsec;
}

int connect_to(const char *host, int port)
{
    addrinfo hints {}, *res;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, std::to_string(port).c_str(), &hints, &res) != 0)
    {
        fprintf(stderr, "cannot resolve %s\n", host);
        return -1;
    }
    int fd = socket(res->ai_family, res->ai_socktype, 0);
    timeval tv {3, 0};                      // connect timeout
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0)
    {
        perror("connect");
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

struct Check
{
    uint32_t run = 0, board = 0;
    uint64_t events = 0, gaps = 0, missing = 0, bad = 0;
    int64_t last_counter = -1;
    uint64_t last_ts = 0;
    bool quiet = false;

    void event(const std::vector<uint32_t> &p)
    {
        events++;
        if (p.size() != 2 + EVENT_WORDS || p[0] != run || p[1] != board || p[2] != 4 * EVENT_WORDS ||
            p[6] != TAG0 || p[7] != TAG1 || p[8] != TAG2)
        {
            bad++;
            fprintf(stderr, "bad DATA frame (%zu words)\n", p.size());
            return;
        }
        uint64_t ts = (uint64_t(p[4]) << 32) | p[3];
        int64_t cnt = p[5];
        if (cnt != last_counter + 1)        // also catches drops before the first event
        {
            gaps++;
            missing += cnt - last_counter - 1;
        }
        if (last_counter >= 0 && ts <= last_ts)
        {
            bad++;
            fprintf(stderr, "timestamp not increasing at event %lld\n", (long long) cnt);
        }
        if (!quiet)
        {
            printf("event %8lld  ts %15llu  (%.6f s)\n", (long long) cnt, (unsigned long long) ts,
                   ts / CLOCK_HZ);
        }
        last_counter = cnt;
        last_ts = ts;
    }
};
} // namespace

int main(int argc, char *argv[])
{
    int port = DEFAULT_PORT;
    uint32_t run = 1;
    double seconds = 5;
    int slow_us = 0;
    bool quiet = false;
    int c;
    while ((c = getopt(argc, argv, "p:r:t:s:q")) != -1)
    {
        switch (c)
        {
        case 'p': port = atoi(optarg); break;
        case 'r': run = uint32_t(atoi(optarg)); break;
        case 't': seconds = atof(optarg); break;
        case 's': slow_us = atoi(optarg); break;
        case 'q': quiet = true; break;
        default:
            fprintf(stderr, "usage: %s host [-p port] [-r run] [-t seconds] [-s slow_us] [-q]\n", argv[0]);
            return 1;
        }
    }
    if (optind >= argc)
    {
        fprintf(stderr, "usage: %s host [-p port] [-r run] [-t seconds] [-s slow_us] [-q]\n", argv[0]);
        return 1;
    }
    int fd = connect_to(argv[optind], port);
    if (fd < 0)
    {
        return 1;
    }
    set_socket_options(fd, 2000, 2000);

    uint32_t tx_seq = 0, rx_seq = 0;
    Header h;
    std::vector<uint32_t> p;
    std::string err;
    uint32_t start_payload[2] = {run, 0};
    send_msg(fd, START, tx_seq, start_payload, sizeof start_payload);

    // everything up to the ACK is stale and discarded; no ACK within 2 s = failure
    int stale = 0;
    for (;;)
    {
        if (recv_msg(fd, h, p, rx_seq, err) <= 0)
        {
            fprintf(stderr, "no ACK: %s\n", err.c_str());
            return 1;
        }
        if (h.type == ACK)
        {
            break;
        }
        if (h.type == ERROR)
        {
            fprintf(stderr, "ERROR %u from the board: %s\n", p[0], reinterpret_cast<char *>(&p[1]));
            return 1;
        }
        stale++;
    }
    if (p.size() < 4 || p[0] != run)
    {
        fprintf(stderr, "bad ACK\n");
        return 1;
    }
    Check chk;
    chk.run = run;
    chk.board = p[1];
    chk.quiet = quiet;
    printf("ACK: run %u, board %u, firmware 0x%08x, %s, MMCM %s%s\n", p[0], p[1], p[2],
           (p[3] & ST_MASTER) ? "clock master" : "consumer", (p[3] & ST_LOCKED) ? "locked" : "NOT locked",
           stale ? (", " + std::to_string(stale) + " stale messages discarded").c_str() : "");

    double t0 = now();
    while (now() - t0 < seconds)
    {
        int r = recv_msg(fd, h, p, rx_seq, err);
        if (r == 0)
        {
            fprintf(stderr, "the board closed the connection: %s\n", err.c_str());
            return 1;
        }
        if (r < 0)
        {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                continue;                   // no data for 2 s, still waiting
            }
            fprintf(stderr, "receive failed: %s\n", err.c_str());
            return 1;
        }
        if (h.type == DATA)
        {
            chk.event(p);
            if (slow_us)
            {
                usleep(slow_us);
            }
        }
        else
        {
            fprintf(stderr, "unexpected %s in the run\n", type_name(h.type));
            chk.bad++;
        }
    }
    double t_run = now() - t0;

    send_msg(fd, STOP, tx_seq, nullptr, 0);
    uint64_t drained = 0;
    for (;;)
    {
        if (recv_msg(fd, h, p, rx_seq, err) <= 0)
        {
            fprintf(stderr, "no END: %s\n", err.c_str());
            return 1;
        }
        if (h.type == END)
        {
            break;
        }
        if (h.type == DATA)
        {
            chk.event(p);
            drained++;
        }
    }
    close(fd);

    uint64_t trig = (uint64_t(p[3]) << 32) | p[2];
    uint64_t sent = (uint64_t(p[5]) << 32) | p[4];
    uint64_t dropped = (uint64_t(p[7]) << 32) | p[6];
    printf("END: run %u, %llu triggers, %llu sent, %llu dropped\n", p[0], (unsigned long long) trig,
           (unsigned long long) sent, (unsigned long long) dropped);
    printf("received %llu events in %.2f s (%.0f/s; %llu after STOP), %llu gaps = %llu missing, %llu bad\n",
           (unsigned long long) chk.events, t_run, chk.events / t_run, (unsigned long long) drained,
           (unsigned long long) chk.gaps, (unsigned long long) chk.missing, (unsigned long long) chk.bad);

    // triggers dropped after the last event that arrived are not a gap, but END counts them
    uint64_t trailing = trig - 1 - chk.last_counter;
    chk.missing += trailing;
    if (trailing)
    {
        printf("%llu triggers dropped after the last event\n", (unsigned long long) trailing);
    }
    bool ok = chk.bad == 0 && sent == chk.events && trig == sent + dropped && chk.missing == dropped;
    printf("%s\n", ok ? "CHECK OK" : "CHECK FAILED");
    return ok ? 0 : 2;
}
