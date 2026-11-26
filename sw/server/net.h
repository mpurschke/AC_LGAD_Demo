#pragma once

// Message I/O on a TCP socket, shared by the board server and the test client.

#include "protocol.h"

#include <cstdint>
#include <string>
#include <vector>

namespace zdaq
{
// Send one message (header + payload). Loops over partial sends; with a send
// timeout on the socket it keeps retrying as long as keep_trying() says so.
// Returns false if the connection failed or keep_trying() gave up.
bool send_msg(int fd, uint16_t type, uint32_t &seq, const void *payload, uint32_t bytes,
              bool (*keep_trying)() = nullptr);

// Send a buffer that already holds complete messages; same retry rules as send_msg.
bool send_all(int fd, const void *buf, size_t bytes, bool (*keep_trying)() = nullptr);

// Receive exactly n bytes: 1 = done, 0 = the peer closed, -1 = error or timeout.
int recv_exact(int fd, void *buf, size_t n);

// Receive one message and check magic, version, length and sequence number.
// 1 = ok, 0 = the peer closed, -1 = error (text in err).
int recv_msg(int fd, Header &h, std::vector<uint32_t> &payload, uint32_t &expect_seq,
             std::string &err);

// Socket options: TCP keepalive (idle 5 s, interval 1 s, 3 probes),
// send / receive timeouts in milliseconds (0 = none), TCP_NODELAY.
void set_socket_options(int fd, int send_ms, int recv_ms);

// Name of a message type, for log lines
const char *type_name(uint16_t type);
} // namespace zdaq
