#pragma once
#include "a2_protocol.hpp"
#include "cxx14.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace a2 {
enum class ImageFormat { Unknown, DosOrder, ProDosOrder, Nibble, TwoMG, Block };
class ImageFile {
public:
    explicit ImageFile(std::string path, bool writable=true);
    ~ImageFile();
    ImageFile(const ImageFile&)=delete; ImageFile& operator=(const ImageFile&)=delete;
    const std::string& path() const { return path_; }
    ImageFormat format() const noexcept { return format_; }
    bool writable() const noexcept { return writable_; }
    std::uint64_t payload_size() const noexcept { return data_length_; }
    StatusCode read_floppy_track(std::uint32_t track, span<std::uint8_t> out, std::uint32_t& actual);
    StatusCode write_floppy_track(std::uint32_t track, span<const std::uint8_t> in);
    StatusCode read_blocks(std::uint32_t block, std::uint32_t count, span<std::uint8_t> out, std::uint32_t& actual);
    StatusCode write_blocks(std::uint32_t block, std::uint32_t count, span<const std::uint8_t> in);
private:
    std::string path_; int fd_{-1}; bool writable_{false};
    ImageFormat format_{ImageFormat::Unknown}; std::uint64_t data_offset_{0}, data_length_{0};
    std::mutex mutex_;
    bool pread_exact(void* p,std::size_t n,std::uint64_t off);
    bool pwrite_exact(const void* p,std::size_t n,std::uint64_t off);
    void detect_format();
};

class DriveManager {
public:
    DriveManager();
    StatusCode mount(Drive drive,const std::string& path);
    void eject(Drive drive);
    std::shared_ptr<ImageFile> get(Drive drive) const;
    std::string status_json() const;
    void auto_mount(const std::vector<std::string>& roots);
private:
    mutable std::mutex mutex_;
    std::array<std::shared_ptr<ImageFile>,4> drives_{};
};
}
