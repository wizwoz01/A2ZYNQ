#pragma once
#include <cstdint>

namespace a2 {
constexpr std::uint32_t kMailboxId = 0x41325053u; // "A2PS"
constexpr std::uint32_t kProtocolVersion = 0x00010000u;
constexpr std::size_t kBufferOffset = 0x1000;
constexpr std::size_t kBufferBytes = 64 * 1024;

enum class Opcode : std::uint32_t {
    Ping = 0x0001,
    GetCapabilities = 0x0002,
    GetBuildInfo = 0x0003,
    StorageRescan = 0x0100,
    GetDriveStatus = 0x0101,
    MountImage = 0x0102,
    EjectImage = 0x0103,
    FloppyReadTrack = 0x0110,
    FloppyWriteTrack = 0x0111,
    BlockRead = 0x0120,
    BlockWrite = 0x0121,
    SettingsLoad = 0x0200,
    SettingsSave = 0x0201,
    InputGetState = 0x0300,
    MenuGetFrame = 0x0310,
    MenuKey = 0x0311,
    NetGetStatus = 0x0400,
    NetTx = 0x0401,
    NetRx = 0x0402,
    CoreUpdatePrepare = 0x0500,
    CoreUpdateCommit = 0x0501,
    Shutdown = 0x7fff
};

enum class StatusCode : std::uint32_t {
    Ok = 0,
    InvalidOpcode = 1,
    InvalidArgument = 2,
    NoMedia = 3,
    IoError = 4,
    ReadOnly = 5,
    OutOfRange = 6,
    Busy = 7,
    ProtocolError = 8,
    NotFound = 9,
    UnsupportedFormat = 10,
    CrcError = 11
};

enum class Drive : std::uint32_t { Floppy1=0, Floppy2=1, Hard1=2, Hard2=3 };

struct Request {
    Opcode opcode{};
    std::uint32_t tag{};
    std::uint32_t arg0{};
    std::uint32_t arg1{};
    std::uint32_t length{};
};

struct Response {
    StatusCode status{StatusCode::Ok};
    std::uint32_t length{};
};
}
