#include "w5100_linux.hpp"
extern "C" {
#include "w5100.h"
}
#include <array>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <iostream>
#include <arpa/inet.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
namespace { int g_fd=-1; int g_ifindex=0; std::string g_ifname; std::array<unsigned char,6> g_mac{}; }
namespace a2 {
bool w5100_linux_init(const std::string& ifname){
    g_ifname=ifname.empty()?"eth0":ifname;g_fd=::socket(AF_PACKET,SOCK_RAW|SOCK_CLOEXEC,htons(ETH_P_ALL));if(g_fd<0){std::cerr<<"a2hostd: raw Ethernet unavailable: "<<std::strerror(errno)<<"\n";return false;}
    ifreq ifr{};std::strncpy(ifr.ifr_name,g_ifname.c_str(),IFNAMSIZ-1);if(::ioctl(g_fd,SIOCGIFINDEX,&ifr)<0){std::cerr<<"a2hostd: interface "<<g_ifname<<" unavailable\n";::close(g_fd);g_fd=-1;return false;}g_ifindex=ifr.ifr_ifindex;
    if(::ioctl(g_fd,SIOCGIFHWADDR,&ifr)==0)std::memcpy(g_mac.data(),ifr.ifr_hwaddr.sa_data,6);
    sockaddr_ll a{};a.sll_family=AF_PACKET;a.sll_protocol=htons(ETH_P_ALL);a.sll_ifindex=g_ifindex;if(::bind(g_fd,reinterpret_cast<sockaddr*>(&a),sizeof(a))<0){::close(g_fd);g_fd=-1;return false;}
    packet_mreq mr{};mr.mr_ifindex=g_ifindex;mr.mr_type=PACKET_MR_PROMISC;(void)::setsockopt(g_fd,SOL_PACKET,PACKET_ADD_MEMBERSHIP,&mr,sizeof(mr));
    std::cerr<<"a2hostd: Uthernet II bridged to "<<g_ifname<<" (raw Ethernet frames)\n";return true;
}
void w5100_linux_poll_rx(){if(g_fd<0)return;std::array<unsigned char,2048>b{};for(int k=0;k<8;k++){sockaddr_ll sa{};socklen_t sl=sizeof(sa);ssize_t n=::recvfrom(g_fd,b.data(),b.size(),MSG_DONTWAIT,reinterpret_cast<sockaddr*>(&sa),&sl);if(n<0){if(errno==EAGAIN||errno==EWOULDBLOCK)return;return;}if(sa.sll_pkttype==PACKET_OUTGOING)continue;if(n>=14)w5100_macraw_rx(b.data(),std::uint32_t(n));}}
void w5100_linux_close(){if(g_fd>=0){::close(g_fd);g_fd=-1;}}
}
extern "C" void w5100_bridge_tx(const uint8_t*frame,uint32_t len){if(g_fd>=0)(void)::send(g_fd,frame,len,MSG_DONTWAIT);}
extern "C" bool w5100_bridge_dongle_mac(uint8_t mac[6]){if(g_fd<0)return false;std::memcpy(mac,g_mac.data(),6);return true;}
extern "C" void w5100_bridge_set_dongle_mac(const uint8_t[6]){if(g_fd<0)return;packet_mreq mr{};mr.mr_ifindex=g_ifindex;mr.mr_type=PACKET_MR_PROMISC;(void)::setsockopt(g_fd,SOL_PACKET,PACKET_ADD_MEMBERSHIP,&mr,sizeof(mr));}
extern "C" void w5100_bridge_set_promiscuous(void){if(g_fd<0)return;packet_mreq mr{};mr.mr_ifindex=g_ifindex;mr.mr_type=PACKET_MR_PROMISC;(void)::setsockopt(g_fd,SOL_PACKET,PACKET_ADD_MEMBERSHIP,&mr,sizeof(mr));}
