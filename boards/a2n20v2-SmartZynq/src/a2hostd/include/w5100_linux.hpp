#pragma once
#include <string>
namespace a2 { bool w5100_linux_init(const std::string& ifname); void w5100_linux_poll_rx(); void w5100_linux_close(); }
