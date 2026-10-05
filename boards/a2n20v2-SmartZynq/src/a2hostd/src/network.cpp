#include "network.hpp"
#include "cxx14.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <netinet/in.h>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

namespace a2 {
namespace {

int make_listener(std::uint16_t port) {
    const int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    int one = 1;
    (void)::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 ||
        ::listen(fd, 8) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

bool send_all(int fd, const void* data, std::size_t length) {
    const auto* ptr = static_cast<const char*>(data);
    while (length != 0) {
        const ssize_t n = ::send(fd, ptr, length, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        ptr += n;
        length -= static_cast<std::size_t>(n);
    }
    return true;
}

std::string safe_path(const std::string& root, const std::string& requested) {
    std::string relative = requested;
    while (!relative.empty() && relative.front() == '/') relative.erase(relative.begin());
    if (relative.find("..") != std::string::npos) return root;
    const std::string candidate = path_join(root, relative);
    if (candidate == root) return candidate;
    if (candidate.size() > root.size() &&
        candidate.compare(0, root.size(), root) == 0 &&
        (candidate[root.size()] == '/' || root.back() == '/')) {
        return candidate;
    }
    return root;
}

}  // namespace

NetworkServices::NetworkServices(std::string root,
                                 StatusFn status,
                                 CommandFn command)
    : root_(std::move(root)), status_(std::move(status)), command_(std::move(command)) {}

NetworkServices::~NetworkServices() { stop(); }

void NetworkServices::start(std::uint16_t telnet_port, std::uint16_t ftp_port) {
    stop_ = false;
    telnet_ = std::thread(&NetworkServices::telnet_loop, this, telnet_port);
    ftp_ = std::thread(&NetworkServices::ftp_loop, this, ftp_port);
}

void NetworkServices::stop() {
    stop_ = true;
    if (telnet_.joinable()) telnet_.join();
    if (ftp_.joinable()) ftp_.join();
}

void NetworkServices::telnet_loop(std::uint16_t port) {
    const int listener = make_listener(port);
    if (listener < 0) return;
    (void)::fcntl(listener, F_SETFL, O_NONBLOCK);

    while (!stop_) {
        pollfd pfd{listener, POLLIN, 0};
        if (::poll(&pfd, 1, 200) <= 0) continue;

        const int client = ::accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
        if (client < 0) continue;

        std::thread([this, client]() {
            std::string hello = "A2Host Smart Zynq console\r\n" + status_() + "\r\na2> ";
            (void)send_all(client, hello.data(), hello.size());
            std::string line;
            char buffer[256];

            while (!stop_) {
                const ssize_t n = ::recv(client, buffer, sizeof(buffer), 0);
                if (n <= 0) break;
                for (ssize_t i = 0; i < n; ++i) {
                    const char ch = buffer[i];
                    if (ch == '\r') continue;
                    if (ch == '\n') {
                        const std::string response = command_(line) + "\r\na2> ";
                        (void)send_all(client, response.data(), response.size());
                        line.clear();
                    } else if (ch == 8 || ch == 127) {
                        if (!line.empty()) line.pop_back();
                    } else {
                        line.push_back(ch);
                    }
                }
            }
            ::close(client);
        }).detach();
    }

    ::close(listener);
}

void NetworkServices::ftp_loop(std::uint16_t port) {
    const int listener = make_listener(port);
    if (listener < 0) return;
    (void)::fcntl(listener, F_SETFL, O_NONBLOCK);

    while (!stop_) {
        pollfd pfd{listener, POLLIN, 0};
        if (::poll(&pfd, 1, 200) <= 0) continue;
        const int client = ::accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
        if (client >= 0) std::thread(&NetworkServices::ftp_client, this, client).detach();
    }
    ::close(listener);
}

void NetworkServices::ftp_client(int client) {
    auto reply = [client](std::string text) {
        text += "\r\n";
        return send_all(client, text.data(), text.size());
    };

    (void)reply("220 A2Host FTP ready");
    std::string cwd = "/";
    int passive_listener = -1;
    std::string rename_from;
    std::string input;
    char buffer[1024];

    auto accept_data = [&]() -> int {
        if (passive_listener < 0) return -1;
        const int data = ::accept4(passive_listener, nullptr, nullptr, SOCK_CLOEXEC);
        ::close(passive_listener);
        passive_listener = -1;
        return data;
    };

    while (!stop_) {
        const ssize_t n = ::recv(client, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        input.append(buffer, static_cast<std::size_t>(n));

        std::size_t end = 0;
        while ((end = input.find('\n')) != std::string::npos) {
            std::string line = input.substr(0, end);
            input.erase(0, end + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();

            const auto split = line.find(' ');
            std::string cmd = line.substr(0, split);
            const std::string arg = split == std::string::npos ? "" : line.substr(split + 1);
            for (char& ch : cmd) ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));

            if (cmd == "USER") {
                (void)reply("331 Password not required");
            } else if (cmd == "PASS") {
                (void)reply("230 Logged in");
            } else if (cmd == "SYST") {
                (void)reply("215 UNIX Type: L8");
            } else if (cmd == "TYPE") {
                (void)reply("200 Type set");
            } else if (cmd == "PWD") {
                (void)reply("257 \"" + cwd + "\"");
            } else if (cmd == "CWD") {
                const std::string path = safe_path(root_, cwd + "/" + arg);
                if (path_is_dir(path)) {
                    if (path == root_) cwd = "/";
                    else if (path.size() > root_.size()) cwd = path.substr(root_.size());
                    else cwd = "/";
                    (void)reply("250 Directory changed");
                } else {
                    (void)reply("550 Not a directory");
                }
            } else if (cmd == "PASV") {
                if (passive_listener >= 0) ::close(passive_listener);
                passive_listener = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
                if (passive_listener < 0) {
                    (void)reply("425 Cannot open passive socket");
                    continue;
                }
                sockaddr_in addr{};
                addr.sin_family = AF_INET;
                addr.sin_addr.s_addr = INADDR_ANY;
                addr.sin_port = 0;
                if (::bind(passive_listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 ||
                    ::listen(passive_listener, 1) < 0) {
                    ::close(passive_listener);
                    passive_listener = -1;
                    (void)reply("425 Cannot open passive socket");
                    continue;
                }
                socklen_t len = sizeof(addr);
                (void)::getsockname(passive_listener, reinterpret_cast<sockaddr*>(&addr), &len);
                sockaddr_in local{};
                len = sizeof(local);
                (void)::getsockname(client, reinterpret_cast<sockaddr*>(&local), &len);
                const auto ip = ntohl(local.sin_addr.s_addr);
                const auto data_port = ntohs(addr.sin_port);
                std::ostringstream os;
                os << "227 Entering Passive Mode ("
                   << ((ip >> 24) & 255) << ',' << ((ip >> 16) & 255) << ','
                   << ((ip >> 8) & 255) << ',' << (ip & 255) << ','
                   << (data_port >> 8) << ',' << (data_port & 255) << ')';
                (void)reply(os.str());
            } else if (cmd == "LIST") {
                (void)reply("150 Opening data");
                const int data = accept_data();
                if (data >= 0) {
                    const std::string path = safe_path(root_, cwd);
                    DIR* dir = ::opendir(path.c_str());
                    if (dir) {
                        while (dirent* e = ::readdir(dir)) {
                            if (e->d_name[0] == '.' && (e->d_name[1] == 0 || (e->d_name[1] == '.' && e->d_name[2] == 0))) continue;
                            const std::string full = path_join(path, e->d_name);
                            struct stat st;
                            const bool isdir = ::stat(full.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
                            const std::string listing =
                                (isdir ? "drwxr-xr-x 1 a2 a2 0 Jan 01 00:00 "
                                       : "-rw-r--r-- 1 a2 a2 " + std::to_string(static_cast<long long>(st.st_size)) + " Jan 01 00:00 ") +
                                std::string(e->d_name) + "\r\n";
                            (void)send_all(data, listing.data(), listing.size());
                        }
                        ::closedir(dir);
                    }
                    ::close(data);
                }
                (void)reply("226 Done");
            } else if (cmd == "RETR") {
                const std::string path = safe_path(root_, cwd + "/" + arg);
                std::ifstream file(path.c_str(), std::ios::binary);
                if (!file) {
                    (void)reply("550 Open failed");
                    continue;
                }
                (void)reply("150 Opening data");
                const int data = accept_data();
                if (data >= 0) {
                    while (file) {
                        file.read(buffer, sizeof(buffer));
                        if (file.gcount() > 0) {
                            (void)send_all(data, buffer, static_cast<std::size_t>(file.gcount()));
                        }
                    }
                    ::close(data);
                }
                (void)reply("226 Done");
            } else if (cmd == "STOR") {
                const std::string path = safe_path(root_, cwd + "/" + arg);
                std::ofstream file(path.c_str(), std::ios::binary | std::ios::trunc);
                if (!file) {
                    (void)reply("550 Open failed");
                    continue;
                }
                (void)reply("150 Opening data");
                const int data = accept_data();
                if (data >= 0) {
                    ssize_t got = 0;
                    while ((got = ::recv(data, buffer, sizeof(buffer), 0)) > 0) {
                        file.write(buffer, got);
                    }
                    ::close(data);
                }
                (void)reply("226 Done");
            } else if (cmd == "DELE") {
                const int rc = ::unlink(safe_path(root_, cwd + "/" + arg).c_str());
                (void)reply(rc ? "550 Delete failed" : "250 Deleted");
            } else if (cmd == "RNFR") {
                rename_from = safe_path(root_, cwd + "/" + arg);
                (void)reply("350 Ready for RNTO");
            } else if (cmd == "RNTO") {
                const int rc = ::rename(rename_from.c_str(), safe_path(root_, cwd + "/" + arg).c_str());
                (void)reply(rc ? "550 Rename failed" : "250 Renamed");
            } else if (cmd == "MKD") {
                mkdir_p(safe_path(root_, cwd + "/" + arg));
                (void)reply(path_is_dir(safe_path(root_, cwd + "/" + arg)) ? "257 Created" : "550 Create failed");
            } else if (cmd == "QUIT") {
                (void)reply("221 Bye");
                if (passive_listener >= 0) ::close(passive_listener);
                ::close(client);
                return;
            } else {
                (void)reply("502 Command not implemented");
            }
        }
    }

    if (passive_listener >= 0) ::close(passive_listener);
    ::close(client);
}

SocketBridge::~SocketBridge() {
    for (std::map<std::uint32_t,int>::iterator it=sockets_.begin(); it!=sockets_.end(); ++it) {
        ::close(it->second);
    }
}

StatusCode SocketBridge::execute(std::uint32_t op,
                                 std::uint32_t channel,
                                 span<std::uint8_t> data,
                                 std::uint32_t arg,
                                 std::uint32_t& actual) {
    std::lock_guard<std::mutex> lock(m_);
    actual = 0;

    if (op == 0) {
        const int fd = ::socket(AF_INET, (arg & 1u) ? SOCK_DGRAM : SOCK_STREAM, 0);
        if (fd < 0) return StatusCode::IoError;
        auto old = sockets_.find(channel);
        if (old != sockets_.end()) {
            ::close(old->second);
            sockets_.erase(old);
        }
        sockets_[channel] = fd;
        return StatusCode::Ok;
    }

    const auto it = sockets_.find(channel);
    if (it == sockets_.end()) return StatusCode::NotFound;
    const int fd = it->second;

    if (op == 1) {
        if (data.size() < 6) return StatusCode::InvalidArgument;
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        std::memcpy(&addr.sin_addr, data.data(), 4);
        addr.sin_port = htons(static_cast<std::uint16_t>((data[4] << 8) | data[5]));
        return ::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0
                   ? StatusCode::Ok
                   : StatusCode::IoError;
    }
    if (op == 2) {
        const std::size_t count = arg ? std::min<std::size_t>(arg, data.size()) : data.size();
        const ssize_t n = ::send(fd, data.data(), count, MSG_NOSIGNAL);
        if (n < 0) return StatusCode::IoError;
        actual = static_cast<std::uint32_t>(n);
        return StatusCode::Ok;
    }
    if (op == 3) {
        (void)::fcntl(fd, F_SETFL, O_NONBLOCK);
        const std::size_t count = std::min<std::size_t>(arg ? arg : data.size(), data.size());
        const ssize_t n = ::recv(fd, data.data(), count, 0);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return StatusCode::Busy;
        if (n < 0) return StatusCode::IoError;
        actual = static_cast<std::uint32_t>(n);
        return StatusCode::Ok;
    }
    if (op == 4) {
        ::close(fd);
        sockets_.erase(it);
        return StatusCode::Ok;
    }
    return StatusCode::InvalidArgument;
}

}  // namespace a2
