#pragma once
#include <cstddef>
#include <cstdint>
#include <mutex>
#include "cxx14.hpp"
#include <string>
#include <vector>

namespace a2 {
class SpiTransport {
public:
    explicit SpiTransport(std::string uio_path = {});
    ~SpiTransport();
    SpiTransport(const SpiTransport&) = delete;
    SpiTransport& operator=(const SpiTransport&) = delete;
    std::uint8_t reg_read(std::uint8_t reg);
    void reg_write(std::uint8_t reg, std::uint8_t value);
    std::uint32_t reg_read32(std::uint8_t reg);
    void reg_write32(std::uint8_t reg, std::uint32_t value);
    void xfer_write(std::uint8_t space, std::uint32_t addr, span<const std::uint8_t> data);
    void xfer_read(std::uint8_t space, std::uint32_t addr, span<std::uint8_t> data);
    void set_host_ready(bool ready);
    std::string device_id();
    static std::string find_uio(const std::string& requested = {});
private:
    std::vector<std::uint8_t> exchange(span<const std::uint8_t> tx);
    void write_buffer(span<const std::uint8_t> data);
    void read_buffer(span<std::uint8_t> data);
    std::uint32_t rd(std::size_t off) const;
    void wr(std::size_t off, std::uint32_t value);
    int fd_{-1}; std::size_t map_size_{0x40000}; volatile std::uint8_t* map_{nullptr};
    std::mutex mutex_;
};
}
