// zdaq_server: TCP data server on a board (spec.md sections 4 and 5).
//
//   zdaq_server [--port 5555] [--source sim|axis] [--rate 100] [--board-id 0]
//     sim : software events at --rate, board id from --board-id
//     axis: the Zybo PL event FIFO (root); board id from the switches
//
// One client at a time (RCDAQ). A new connection replaces the old one: the
// old one is closed and a running run stopped, so the board recovers by
// itself when RCDAQ crashes and leaves a stale connection.
// States: no client -> connected -> running (START) -> connected (STOP).
// Single-threaded: one poll() loop over the listening socket, the client
// and the data source.

#include "net.h"
#include "protocol.h"
#include "axis_fifo_source.h"
#include "sim_source.h"

#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <getopt.h>
#include <memory>
#include <netinet/in.h>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

using namespace zdaq;

namespace
{
volatile sig_atomic_t quit = 0;
int listen_fd = -1;

void logmsg(const char *fmt, ...)
{
    timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    char ts[32];
    strftime(ts, sizeof ts, "%F %T", localtime(&t.tv_sec));
    fprintf(stderr, "%s.%03ld zdaq_server: ", ts, t.tv_nsec / 1000000);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

// called while a send waits for a slow client: give up if a new client is
// waiting to replace this one, or if we are told to quit
bool keep_trying()
{
    if (quit)
    {
        return false;
    }
    pollfd p {listen_fd, POLLIN, 0};
    return poll(&p, 1, 0) == 0;
}

class Server
{
public:
    Server(DataSource &src) : src(src) {}

    void accept_client();
    void handle_client();
    void pump();                 // send what the source has, a bounded batch at a time
    void drop_client(const char *why);
    bool running() const { return run_active; }
    int client() const { return cfd; }

private:
    bool send(uint16_t type, const std::vector<uint32_t> &payload);
    void send_error(uint32_t code, const std::string &text);
    void start(uint32_t run);
    void stop();
    bool send_event(const std::vector<uint32_t> &ev);   // into the batch
    bool flush();                                        // send the batch

    DataSource &src;
    int cfd = -1;
    uint32_t tx_seq = 0, rx_seq = 0;
    bool run_active = false;
    uint32_t run = 0;
    uint64_t frames = 0;
    std::string peer;
    std::vector<uint32_t> ev;
    std::vector<uint32_t> batch;      // complete DATA messages (header + payload), sent together
    static constexpr size_t BATCH_WORDS = 16384 / 4;
};

void Server::accept_client()
{
    sockaddr_in a {};
    socklen_t len = sizeof a;
    int fd = accept(listen_fd, reinterpret_cast<sockaddr *>(&a), &len);
    if (fd < 0)
    {
        return;
    }
    if (cfd >= 0)
    {
        drop_client("replaced by a new connection");
    }
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
    peer = std::string(ip) + ":" + std::to_string(ntohs(a.sin_port));
    cfd = fd;
    tx_seq = rx_seq = 0;
    set_socket_options(cfd, 1000, 1000);
    logmsg("client %s connected", peer.c_str());
}

void Server::drop_client(const char *why)
{
    if (cfd < 0)
    {
        return;
    }
    if (run_active)
    {
        src.stop();
        while (src.read_event(ev) > 0)      // discard what was left
        {
        }
        run_active = false;
        logmsg("run %u aborted", run);
    }
    close(cfd);
    cfd = -1;
    batch.clear();
    logmsg("client %s dropped: %s", peer.c_str(), why);
}

bool Server::send(uint16_t type, const std::vector<uint32_t> &payload)
{
    if (!flush())
    {
        return false;
    }
    if (!send_msg(cfd, type, tx_seq, payload.data(), uint32_t(4 * payload.size()), keep_trying))
    {
        drop_client(quit ? "server stopping" : "send failed");
        return false;
    }
    return true;
}

void Server::send_error(uint32_t code, const std::string &text)
{
    std::vector<uint32_t> p((text.size() + 4) / 4 + 1, 0);    // code + text + at least one NUL
    p[0] = code;
    memcpy(&p[1], text.data(), text.size());
    logmsg("error to client: %s", text.c_str());
    send(ERROR, p);
}

void Server::start(uint32_t r)
{
    if (run_active)
    {
        send_error(E_STATE, "START while run " + std::to_string(run) + " is active");
        return;
    }
    if (src.start(r) != 0)
    {
        send_error(E_SOURCE, "data source failed to start");
        return;
    }
    run = r;
    run_active = true;
    frames = 0;
    logmsg("run %u started", run);
    send(ACK, {run, src.board_id(), src.firmware_version(), src.status()});
}

void Server::stop()
{
    if (!run_active)
    {
        send_error(E_STATE, "STOP without a run");
        return;
    }
    src.stop();
    while (cfd >= 0 && src.read_event(ev) > 0)     // send what is still buffered
    {
        if (!send_event(ev))
        {
            return;
        }
    }
    if (cfd < 0)
    {
        return;
    }
    run_active = false;
    uint64_t trig, sent, dropped;
    src.counts(trig, sent, dropped);
    logmsg("run %u stopped: %llu triggers, %llu events sent, %llu dropped", run,
           (unsigned long long) trig, (unsigned long long) frames, (unsigned long long) dropped);
    send(END, {run, 0, uint32_t(trig), uint32_t(trig >> 32), uint32_t(frames), uint32_t(frames >> 32),
               uint32_t(dropped), uint32_t(dropped >> 32)});
}

bool Server::send_event(const std::vector<uint32_t> &e)
{
    Header h {MAGIC, VERSION, DATA, uint32_t(4 * (2 + e.size())), tx_seq++};
    const uint32_t *hw = reinterpret_cast<const uint32_t *>(&h);
    batch.insert(batch.end(), hw, hw + sizeof h / 4);
    batch.push_back(run);
    batch.push_back(src.board_id());
    batch.insert(batch.end(), e.begin(), e.end());
    frames++;
    return batch.size() < BATCH_WORDS || flush();
}

bool Server::flush()
{
    if (batch.empty() || cfd < 0)
    {
        return cfd >= 0;
    }
    bool ok = send_all(cfd, batch.data(), 4 * batch.size(), keep_trying);
    batch.clear();
    if (!ok)
    {
        drop_client(quit ? "server stopping" : "send failed");
    }
    return ok;
}

void Server::pump()
{
    for (int i = 0; i < 1000 && run_active && cfd >= 0; i++)
    {
        int n = src.read_event(ev);
        if (n < 0)
        {
            send_error(E_SOURCE, "data source read failed");
            drop_client("data source failed");
            return;
        }
        if (n == 0)
        {
            break;
        }
        if (!send_event(ev))
        {
            return;
        }
    }
    flush();
}

void Server::handle_client()
{
    Header h;
    std::vector<uint32_t> p;
    std::string err;
    int r = recv_msg(cfd, h, p, rx_seq, err);
    if (r <= 0)
    {
        if (r < 0)
        {
            send_error(E_PROTOCOL, err);
        }
        drop_client(err.c_str());
        return;
    }
    switch (h.type)
    {
    case START:
        if (p.size() < 1)
        {
            send_error(E_PROTOCOL, "START without a run number");
            drop_client("bad START");
            return;
        }
        start(p[0]);
        break;
    case STOP:
        stop();
        break;
    default:
        send_error(E_PROTOCOL, std::string("unexpected message type ") + std::to_string(h.type));
        drop_client("protocol error");
    }
}

void on_signal(int)
{
    quit = 1;
}

void usage(const char *me)
{
    fprintf(stderr, "usage: %s [--port %d] [--source sim|axis] [--rate triggers_per_s] [--board-id n]\n",
            me, DEFAULT_PORT);
}
} // namespace

int main(int argc, char *argv[])
{
    int port = DEFAULT_PORT;
    std::string source = "sim";
    double rate = 100;
    uint32_t board_id = 0;
    static option opts[] = {
        {"port", required_argument, nullptr, 'p'},
        {"source", required_argument, nullptr, 's'},
        {"rate", required_argument, nullptr, 'r'},
        {"board-id", required_argument, nullptr, 'b'},
        {"help", no_argument, nullptr, 'h'},
        {nullptr, 0, nullptr, 0}};
    int c;
    while ((c = getopt_long(argc, argv, "p:s:r:b:h", opts, nullptr)) != -1)
    {
        switch (c)
        {
        case 'p': port = atoi(optarg); break;
        case 's': source = optarg; break;
        case 'r': rate = atof(optarg); break;
        case 'b': board_id = uint32_t(atoi(optarg)); break;
        default: usage(argv[0]); return c == 'h' ? 0 : 1;
        }
    }

    std::unique_ptr<DataSource> src;
    if (source == "sim")
    {
        src = std::make_unique<SimSource>(rate, board_id);
    }
    else if (source == "axis")
    {
        auto a = std::make_unique<AxisFifoSource>();
        if (!a->error().empty())
        {
            fprintf(stderr, "axis source: %s\n", a->error().c_str());
            return 1;
        }
        board_id = a->board_id();
        src = std::move(a);
    }
    else
    {
        fprintf(stderr, "unknown source '%s' (sim or axis)\n", source.c_str());
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa {};
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);

    listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int on = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    sockaddr_in a {};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(listen_fd, reinterpret_cast<sockaddr *>(&a), sizeof a) < 0 || listen(listen_fd, 4) < 0)
    {
        perror("bind/listen");
        return 1;
    }
    if (source == "sim")
    {
        logmsg("listening on port %d, source sim (rate %g/s, board id %u)", port, rate, board_id);
    }
    else
    {
        logmsg("listening on port %d, source %s (firmware 0x%08x, board id %u)", port, source.c_str(),
               src->firmware_version(), board_id);
    }

    Server s(*src);
    while (!quit)
    {
        pollfd p[3];
        int n = 0;
        p[n++] = {listen_fd, POLLIN, 0};
        int ci = -1, si = -1;
        int polled_client = s.client();      // a new connection may replace it below
        if (s.client() >= 0)
        {
            ci = n;
            p[n++] = {s.client(), POLLIN, 0};
        }
        if (s.running() && src->fd() >= 0)
        {
            si = n;
            p[n++] = {src->fd(), POLLIN, 0};
        }
        int timeout = s.running() ? (si < 0 ? 1 : 100) : 1000;
        if (poll(p, n, timeout) < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            perror("poll");
            break;
        }
        if (p[0].revents & POLLIN)
        {
            s.accept_client();
        }
        if (ci >= 0 && s.client() == polled_client && (p[ci].revents & (POLLIN | POLLHUP | POLLERR)))
        {
            s.handle_client();
        }
        if (s.running())
        {
            s.pump();
        }
    }
    s.drop_client("server stopping");
    close(listen_fd);
    logmsg("stopped");
    return 0;
}
