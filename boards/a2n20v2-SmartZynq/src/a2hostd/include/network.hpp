#pragma once
#include "a2_protocol.hpp"
#include "cxx14.hpp"
#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
namespace a2 {
class NetworkServices {
public:
 using StatusFn=std::function<std::string()>; using CommandFn=std::function<std::string(const std::string&)>;
 NetworkServices(std::string root,StatusFn status,CommandFn command);~NetworkServices();
 void start(std::uint16_t telnet_port=23,std::uint16_t ftp_port=21);void stop();
private:
 void telnet_loop(std::uint16_t);void ftp_loop(std::uint16_t);void ftp_client(int);
 std::string root_;StatusFn status_;CommandFn command_;std::atomic_bool stop_{false};std::thread telnet_,ftp_;
};
class SocketBridge {
public:
 ~SocketBridge();
 StatusCode execute(std::uint32_t op,std::uint32_t channel,span<std::uint8_t> data,std::uint32_t arg,std::uint32_t& actual);
private:std::mutex m_;std::map<std::uint32_t,int> sockets_;
};
}
