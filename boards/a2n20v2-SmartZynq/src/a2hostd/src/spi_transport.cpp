#include "spi_transport.hpp"
#include "cxx14.hpp"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <stdexcept>
#include <thread>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace a2 {
namespace {
constexpr std::size_t REG_CTRL=0x00, REG_LEN=0x04, REG_DIV=0x08, REG_HOST_READY=0x0c;
constexpr std::size_t TX_BASE=0x10000, RX_BASE=0x20000;
constexpr std::size_t BUFFER_BYTES=8192, XFER_CHUNK=512;
std::string trim(std::string s){while(!s.empty()&&(s.back()=='\n'||s.back()=='\r'||s.back()==' '||s.back()=='\t'))s.pop_back();return s;}
}
std::string SpiTransport::find_uio(const std::string& requested){
    if(!requested.empty()) return requested;
    DIR* dir=::opendir("/sys/class/uio");
    if(dir){
        while(dirent* e=::readdir(dir)){
            if(e->d_name[0]=='.') continue;
            std::ifstream f(std::string("/sys/class/uio/")+e->d_name+"/name");
            std::string n; std::getline(f,n); n=trim(n);
            if(n.find("a2-spi-transport")!=std::string::npos || n.find("a2_spi")!=std::string::npos){
                ::closedir(dir);
                return std::string("/dev/")+e->d_name;
            }
        }
        ::closedir(dir);
    }
    if(path_exists("/dev/uio0")) return "/dev/uio0";
    throw std::runtime_error("A2 SPI UIO device not found");
}
SpiTransport::SpiTransport(std::string path){
    path=find_uio(path); fd_=::open(path.c_str(),O_RDWR|O_SYNC|O_CLOEXEC); if(fd_<0) throw std::runtime_error("open "+path+" failed");
    void* p=::mmap(nullptr,map_size_,PROT_READ|PROT_WRITE,MAP_SHARED,fd_,0); if(p==MAP_FAILED){::close(fd_);fd_=-1;throw std::runtime_error("mmap A2 SPI UIO failed");}
    map_=static_cast<volatile std::uint8_t*>(p); wr(REG_DIV,16); set_host_ready(false);
}
SpiTransport::~SpiTransport(){if(map_)::munmap(const_cast<std::uint8_t*>(map_),map_size_);if(fd_>=0)::close(fd_);}
std::uint32_t SpiTransport::rd(std::size_t o)const{return *reinterpret_cast<volatile std::uint32_t*>(map_+o);}
void SpiTransport::wr(std::size_t o,std::uint32_t v){*reinterpret_cast<volatile std::uint32_t*>(map_+o)=v;__sync_synchronize();}
void SpiTransport::write_buffer(span<const std::uint8_t>d){
    for(std::size_t o=0;o<d.size();o+=4){std::uint32_t v=0;std::memcpy(&v,d.data()+o,std::min<std::size_t>(4,d.size()-o));wr(TX_BASE+o,v);}
}
void SpiTransport::read_buffer(span<std::uint8_t>d){
    for(std::size_t o=0;o<d.size();o+=4){auto v=rd(RX_BASE+o);std::memcpy(d.data()+o,&v,std::min<std::size_t>(4,d.size()-o));}
}
std::vector<std::uint8_t> SpiTransport::exchange(span<const std::uint8_t>tx){
    if(tx.empty()||tx.size()>BUFFER_BYTES) throw std::runtime_error("SPI transfer length out of range");
    write_buffer(tx); wr(REG_CTRL,2); wr(REG_LEN,static_cast<std::uint32_t>(tx.size())); wr(REG_CTRL,1);
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(750);
    // Re-read status after the deadline: if the process was descheduled or
    // stopped past it, the transfer has long finished and must not throw.
    while(true){auto s=rd(REG_CTRL);if((s&1u)==0 && (s&2u))break;if(std::chrono::steady_clock::now()>deadline){s=rd(REG_CTRL);if((s&1u)==0 && (s&2u))break;throw std::runtime_error("FPGA SPI transfer timeout");}std::this_thread::sleep_for(std::chrono::microseconds(25));}
    std::vector<std::uint8_t>rx(tx.size());read_buffer(rx);wr(REG_CTRL,2);return rx;
}
std::uint8_t SpiTransport::reg_read(std::uint8_t r){std::lock_guard<std::mutex> l(mutex_);std::uint8_t t[2]={std::uint8_t(0x80u|(r&0x7fu)),0xff};auto x=exchange(span<const std::uint8_t>(t,2));return x[1];}
void SpiTransport::reg_write(std::uint8_t r,std::uint8_t v){std::lock_guard<std::mutex> l(mutex_);std::uint8_t t[2]={std::uint8_t(r&0x7fu),v};(void)exchange(span<const std::uint8_t>(t,2));}
std::uint32_t SpiTransport::reg_read32(std::uint8_t r){std::uint32_t v=0;for(int i=0;i<4;i++)v|=std::uint32_t(reg_read(r+i))<<(8*i);return v;}
void SpiTransport::reg_write32(std::uint8_t r,std::uint32_t v){for(int i=0;i<4;i++)reg_write(r+i,std::uint8_t(v>>(8*i)));}
void SpiTransport::xfer_write(std::uint8_t space,std::uint32_t addr,span<const std::uint8_t>data){
    std::lock_guard<std::mutex> l(mutex_);std::size_t pos=0;while(pos<data.size()){auto n=std::min<std::size_t>(XFER_CHUNK,data.size()-pos);std::vector<std::uint8_t>t(7+n);t[0]=0x7f;t[1]=std::uint8_t((1u<<4)|((space&7u)<<1));t[2]=addr;t[3]=addr>>8;t[4]=addr>>16;t[5]=n;t[6]=n>>8;std::memcpy(t.data()+7,data.data()+pos,n);(void)exchange(t);addr+=n;pos+=n;}}
void SpiTransport::xfer_read(std::uint8_t space,std::uint32_t addr,span<std::uint8_t>data){
    std::lock_guard<std::mutex> l(mutex_);std::size_t pos=0;while(pos<data.size()){auto n=std::min<std::size_t>(XFER_CHUNK,data.size()-pos);std::vector<std::uint8_t>t(8+n,0xff);t[0]=0x7f;t[1]=std::uint8_t((1u<<4)|((space&7u)<<1)|1u);t[2]=addr;t[3]=addr>>8;t[4]=addr>>16;t[5]=n;t[6]=n>>8;auto x=exchange(t);std::memcpy(data.data()+pos,x.data()+8,n);addr+=n;pos+=n;}}
void SpiTransport::set_host_ready(bool r){wr(REG_HOST_READY,r?1:0);}
std::string SpiTransport::device_id(){std::string s;for(int i=0;i<4;i++)s.push_back(char(reg_read(i)));return s;}
}
