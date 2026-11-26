#include "net.h"

#include <cerrno>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

namespace zdaq
{
bool send_msg(int fd, uint16_t type, uint32_t &seq, const void *payload, uint32_t bytes,
              bool (*keep_trying)())
{
    Header h {MAGIC, VERSION, type, bytes, seq};
    iovec iov[2] = {{&h, sizeof h}, {const_cast<void *>(payload), bytes}};
    int niov = bytes ? 2 : 1;
    size_t left = sizeof h + bytes;
    iovec *v = iov;
    while (left > 0)
    {
        ssize_t n = writev(fd, v, niov);
        if (n < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            if ((errno == EAGAIN || errno == EWOULDBLOCK) && keep_trying && keep_trying())
            {
                continue;     // the receiver is slow; wait some more
            }
            return false;
        }
        left -= n;
        while (n > 0 && niov > 0)          // advance over what went out
        {
            if (size_t(n) >= v->iov_len)
            {
                n -= v->iov_len;
                v++;
                niov--;
            }
            else
            {
                v->iov_base = static_cast<char *>(v->iov_base) + n;
                v->iov_len -= n;
                n = 0;
            }
        }
    }
    seq++;
    return true;
}

bool send_all(int fd, const void *buf, size_t bytes, bool (*keep_trying)())
{
    const char *p = static_cast<const char *>(buf);
    while (bytes > 0)
    {
        ssize_t n = ::send(fd, p, bytes, MSG_NOSIGNAL);
        if (n < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            if ((errno == EAGAIN || errno == EWOULDBLOCK) && keep_trying && keep_trying())
            {
                continue;
            }
            return false;
        }
        p += n;
        bytes -= n;
    }
    return true;
}

int recv_exact(int fd, void *buf, size_t n)
{
    char *p = static_cast<char *>(buf);
    while (n > 0)
    {
        ssize_t r = recv(fd, p, n, 0);
        if (r == 0)
        {
            return 0;
        }
        if (r < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            return -1;
        }
        p += r;
        n -= r;
    }
    return 1;
}

int recv_msg(int fd, Header &h, std::vector<uint32_t> &payload, uint32_t &expect_seq,
             std::string &err)
{
    int r = recv_exact(fd, &h, sizeof h);
    if (r <= 0)
    {
        err = r == 0 ? "connection closed" : std::string("receive: ") + strerror(errno);
        return r;
    }
    if (h.magic != MAGIC || h.version != VERSION)
    {
        err = "bad magic or version";
        return -1;
    }
    if (h.length > MAX_PAYLOAD || h.length % 4)
    {
        err = "bad length " + std::to_string(h.length);
        return -1;
    }
    if (h.seq != expect_seq)
    {
        err = "sequence " + std::to_string(h.seq) + ", expected " + std::to_string(expect_seq);
        return -1;
    }
    expect_seq++;
    payload.resize(h.length / 4);
    if (h.length)
    {
        r = recv_exact(fd, payload.data(), h.length);
        if (r <= 0)
        {
            err = r == 0 ? "connection closed in a message" : "payload timed out or failed";
            return r == 0 ? 0 : -1;
        }
    }
    return 1;
}

void set_socket_options(int fd, int send_ms, int recv_ms)
{
    int on = 1, idle = 5, intvl = 1, cnt = 3;
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof on);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    timeval s {send_ms / 1000, (send_ms % 1000) * 1000};
    timeval r {recv_ms / 1000, (recv_ms % 1000) * 1000};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &s, sizeof s);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, sizeof r);
}

const char *type_name(uint16_t type)
{
    switch (type)
    {
    case START: return "START";
    case STOP:  return "STOP";
    case ACK:   return "ACK";
    case ERROR: return "ERROR";
    case END:   return "END";
    case DATA:  return "DATA";
    default:    return "unknown";
    }
}
} // namespace zdaq
