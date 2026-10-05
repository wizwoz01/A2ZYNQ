#pragma once
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
namespace a2 {
struct PadState { std::uint32_t buttons{}; std::int16_t lx{},ly{},rx{},ry{}; };
class Gamepad {
public: Gamepad(); ~Gamepad(); void start(); void stop(); PadState state()const;
private: void run(); mutable std::mutex m_; PadState state_{}; std::atomic_bool stop_{false}; std::thread thread_;
};
}
