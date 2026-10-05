#include "disk_image.hpp"
#include "disk_menu.hpp"
#include "gamepad.hpp"
#include "network.hpp"
#include "settings.hpp"
#include "spi_transport.hpp"
#include "fpga_spi_compat.hpp"
#include "w5100_linux.hpp"
#include "cxx14.hpp"
extern "C" {
#include "w5100.h"
}
#include "gcr_dsk.h"
#include <sstream>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <vector>
#include <string>
#include <stdexcept>
#include <iostream>
#include <iomanip>
#include <thread>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <fcntl.h>
#include <deque>
#include <cerrno>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
using namespace a2;
namespace {
std::atomic_bool quit_flag(false); void on_signal(int){quit_flag=true;}
constexpr std::uint8_t SPACE_SDRAM=1;
// Disk II saves read the drive's own copy of the track (SPI memory SPACE 6,
// drive*0x2000 + byte) when the bitstream has it: reg 0x2E bit 7 reads 1. The
// SDRAM window older bitstreams offer never held the loaded track, so every
// save from it failed to decode and the writes were lost.
constexpr std::uint8_t SPACE_NIB=6;
bool g_nib_readback=false;
// Hard disk blocks go straight into / out of the card's sector buffer (SPI memory
// SPACE 7) when reg 0x06 bit 2 reads 1. Through the SDRAM window the card could
// copy a block before all of it had landed (reads came back with stale bytes).
constexpr std::uint8_t SPACE_HDD_BUF=7;
bool g_hdd_direct=false;
constexpr std::uint32_t DISK_WINDOW_BASE=0x200000, DISK_WINDOW_STRIDE=0x2000, HDD_WINDOW_BASE=0x204000, HDD_WINDOW_STRIDE=0x200;
constexpr std::size_t TRACK_BYTES=6656, BLOCK_BYTES=512;
const std::uint8_t SLOT_DEFAULT[8]={0,0,3,5,2,4,6,1};
constexpr int DISK_II_CARD=4, DISK_II_HOME=5, DISK_II_STANDARD=6;
// The Disk II follows the slot the card is plugged into (reported by the FPGA
// in reg 0x2E [6:4]); the card that slot normally holds moves to slot 5.
// Slots 1-3 are not offered: slot 1 may hold a real card with $C800 firmware,
// slot 2's SSC and slot 3 (IIe 80-column firmware) own their $C800 space, and
// a IIe never boots slot 3. With the card there the Disk II uses slot 6, where
// most software expects it, and the menu title names the card's slot
// ("SLOT 3 MENU", without DISK); in slot 1 a power-up boots nothing (BASIC,
// PR#6 brings the menu).
bool disk_slot_ok(int s){ return s>=4 && s<=7; }
int phys_slot(SpiTransport&spi){ return (spi.reg_read(0x2E)>>4)&7; }
void slot_map(int disk_slot,std::uint8_t map[8]){
  std::copy(SLOT_DEFAULT,SLOT_DEFAULT+8,map);
  if(disk_slot_ok(disk_slot)&&disk_slot!=DISK_II_HOME){
    map[DISK_II_HOME]=map[disk_slot];
    map[disk_slot]=DISK_II_CARD;
  }
}
void program_slots(SpiTransport&spi,int disk_slot){
  std::uint8_t map[8];
  slot_map(disk_slot,map);
  for(std::size_t i=0;i<8;i++) spi.reg_write(std::uint8_t(0x60+i),map[i]);
  spi.reg_write(0x6b,1);
}
// True when the FPGA already holds the slot map for disk_slot. Reprogramming
// it re-runs the slot setup (0x6B), which must not happen for nothing while
// the Apple's boot scan is reading the slot ROMs.
bool slots_match(SpiTransport&spi,int disk_slot){
  std::uint8_t map[8];
  slot_map(disk_slot,map);
  for(int i=1;i<8;i++) if(spi.reg_read(std::uint8_t(0x60+i))!=map[i]) return false;
  return true;
}
// disk_slot=auto (default): the card's slot as last detected (card_slot), or
// slot 6 when that is 1-3; disk_slot=4..7 pins the Disk II there.
int disk_slot_target(Settings&settings){
  const auto forced=settings.get("disk_slot","auto");
  if(forced!="auto"&&disk_slot_ok(std::atoi(forced.c_str()))) return std::atoi(forced.c_str());
  const int c=std::atoi(settings.get("card_slot","5").c_str());
  if(disk_slot_ok(c)) return c;
  return (c>=1&&c<=3)?DISK_II_STANDARD:DISK_II_HOME;
}
// Record a newly detected card slot; true if it changed.
bool note_card_slot(Settings&settings,int phys){
  if(!phys) return false;
  if(std::atoi(settings.get("card_slot","5").c_str())==phys) return false;
  settings.set("card_slot",std::to_string(phys));
  try{ settings.save(); }catch(...){}
  std::cerr<<"a2hostd: card detected in slot "<<phys;
  if(!disk_slot_ok(phys)) std::cerr<<" - the Disk II uses slot "<<disk_slot_target(settings)<<" (it follows the card to slots 4-7 only)";
  std::cerr<<"\n";
  return true;
}
std::uint8_t vb(int v,int off){return std::uint8_t(0x40+v*0x10+off);}
std::uint8_t hb(int u,int off){return std::uint8_t(0x26+u*4+off);}
// Prove the SPI write path is alive via scratch reg 0x07 before volume work.
bool spi_scratch_ok(SpiTransport&spi){
  const std::uint8_t pat[]={0xA5,0x5A,0xC3,0x3C};
  for(std::uint8_t p:pat){
    spi.reg_write(0x07,p);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    const auto got=spi.reg_read(0x07);
    if(got!=p){
      std::cerr<<"a2hostd: SPI scratch fail wrote=0x"<<std::hex<<unsigned(p)
               <<" read=0x"<<unsigned(got)<<std::dec<<"\n";
      return false;
    }
  }
  return true;
}
void program_floppy(SpiTransport&spi,DriveManager&dm,int v){
    auto d=dm.get(Drive(v));
    if(!d){
      std::cerr<<"a2hostd: floppy "<<v<<" — no Linux image mounted\n";
      spi.reg_write(vb(v,0),0);
      spi.reg_write(vb(v,2),0);
      return;
    }
    std::cerr<<"a2hostd: floppy "<<v<<" Linux image "<<d->path()
             <<" size="<<d->payload_size()<<"\n";
    // Never clear ready/mounted while a track xfer is pending — that drops the
    // handshake and leaves Disk II hung with rd stuck high.
    if((spi.reg_read(vb(v,0xD))&1)||(spi.reg_read(vb(v,0xE))&1)) return;
    const auto size=std::uint32_t(d->payload_size()/512);
    const auto ro=d->writable()?0:1;
    bool ok=false;
    for(int attempt=0; attempt<20; ++attempt){
      // Size first — multi-byte pattern makes "writes stuck" obvious.
      spi.reg_write32(vb(v,4),size);
      spi.reg_write(vb(v,3),std::uint8_t(ro?0xff:0));
      // Write 0xFF not 1: if MOSI bit0 is flaky we still set bit0; HDL uses [0].
      spi.reg_write(vb(v,2),0xff); // mounted
      spi.reg_write(vb(v,0),0xff); // ready
      spi.reg_write(vb(v,2),0xff);
      spi.reg_write(vb(v,0),0xff);
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      const auto size_rb=spi.reg_read32(vb(v,4));
      const auto ready=spi.reg_read(vb(v,0))&1;
      const auto mounted=spi.reg_read(vb(v,2))&1;
      if(size_rb!=size){
        std::cerr<<"a2hostd: floppy "<<v<<" mount attempt "<<attempt
                 <<" size readback 0x"<<std::hex<<size_rb<<" want 0x"<<size
                 <<std::dec<<" — SPI volume writes not sticking\n";
      }else if(mounted&&ready){
        ok=true; break;
      }else if(mounted&&attempt>=5){
        // Prior boards: ready readback stuck 0 while DiskII still saw ready.
        ok=true;
        std::cerr<<"a2hostd: floppy "<<v<<" mounted=1 ready readback=0"
                 <<" — accepting (attempt "<<attempt<<")\n";
        break;
      }else{
        std::cerr<<"a2hostd: floppy "<<v<<" mount write attempt "<<attempt
                 <<" readback ready="<<ready<<" mounted="<<mounted<<" — retry\n";
      }
    }
    if(!ok)
      std::cerr<<"a2hostd: floppy "<<v<<" FAILED to program FPGA mount bits\n";
}
// Hard disk unit u: size, then {readonly, mounted, ready}. The mounted bit is
// never dropped on the way: the card's firmware answers STATUS from it, and a
// boot that catches it at 0 thinks there is no disk. (After every Apple reset
// this runs again, right while the boot scan may be reading the card.)
void program_hdd(SpiTransport&spi,DriveManager&dm,int u){
  auto d=dm.get(Drive(2+u));
  if(!d){ spi.reg_write(hb(u,0),0); return; }
  auto blocks=std::min<std::uint64_t>(0xffff,d->payload_size()/512);
  spi.reg_write(hb(u,1),std::uint8_t(blocks));
  spi.reg_write(hb(u,2),std::uint8_t(blocks>>8));
  spi.reg_write(hb(u,0),std::uint8_t(3|(d->writable()?0:4)));
}
void program_mounts(SpiTransport&spi,DriveManager&dm){
  for(int v=0;v<2;v++) program_floppy(spi,dm,v);
  for(int u=0;u<2;u++) program_hdd(spi,dm,u);
}
void dump_floppy_fpga(SpiTransport&spi){
  for(int v=0;v<2;v++){
    const auto ready=spi.reg_read(vb(v,0))&1;
    const auto active=spi.reg_read(vb(v,1))&1;
    const auto mounted=spi.reg_read(vb(v,2))&1;
    const auto rd=spi.reg_read(vb(v,0xD))&1;
    const auto wr=spi.reg_read(vb(v,0xE))&1;
    const auto lba=spi.reg_read32(vb(v,8));
    std::cerr<<"a2hostd: fpga floppy "<<v
             <<" ready="<<ready<<" mounted="<<mounted<<" active="<<active
             <<" rd="<<rd<<" wr="<<wr<<" lba=0x"<<std::hex<<lba<<std::dec<<"\n";
  }
  // Bus side: live /RES (0x06 b5), our release (0x2E), bus ready (0x30),
  // and the slot map as the FPGA holds it (Disk II=4 in slot 5, HDD=6 in slot 6).
  std::cerr<<"a2hostd: bus sysrst_n="<<((spi.reg_read(0x06)>>5)&1)
           <<" rel="<<(spi.reg_read(0x2E)&1)<<" busready="<<(spi.reg_read(0x30)&1)
           <<" slots=";
  for(int i=1;i<8;i++) std::cerr<<unsigned(spi.reg_read(std::uint8_t(0x60+i)));
  std::cerr<<"\n";
}
// Bus logic analyzer via the FPGA event FIFO (regs 0x70-0x79, trigger
// 0x1A-0x1E). Commands are lines in /run/a2trace.cmd (numbers in hex):
//   arm <mode>                 rolling capture of the last 512 matching cycles
//                              (mode 0 = all cycles, 1 = I/O space only)
//   trig <addr> [mask] [mode]  rolling capture that freezes on the first cycle
//                              matching addr/mask: holds the 512 cycles before it
//   dump                       stop + drain to /run/a2trace.out, restore defaults
//   rd <reg> [n] / wr <reg> <val>   raw register access, results in /run/a2reg.out
void fifo_drain(SpiTransport&spi){
  for(int i=0;i<600 && !(spi.reg_read(0x70)&0x80);i++) spi.reg_write(0x77,1);
}
void trace_poll(SpiTransport&spi){
  std::ifstream f("/run/a2trace.cmd");
  if(!f) return;
  std::vector<std::string> cmds; std::string line;
  while(std::getline(f,line)) if(!line.empty()) cmds.push_back(line);
  f.close(); std::remove("/run/a2trace.cmd");
  for(const auto&c:cmds){
    std::cerr<<"a2hostd: trace cmd '"<<c<<"'\n";
    unsigned a=0,b=0,m=0; char w[8]={0};
    const int n=std::sscanf(c.c_str(),"%7s %x %x %x",w,&a,&b,&m);
    const std::string op(w);
    if(op=="arm"){
      spi.reg_write(0x79,0); spi.reg_write(0x1A,0); fifo_drain(spi);
      spi.reg_write(0x1F,0); spi.reg_write(0x78,std::uint8_t((n>=2?a:1)&7));
      spi.reg_write(0x79,1);
    }else if(op=="trig" && n>=2){
      const unsigned mask=n>=3?b:0xFFFF, mode=n>=4?m:0;
      spi.reg_write(0x79,0); spi.reg_write(0x1A,0); fifo_drain(spi);
      spi.reg_write(0x1F,0); spi.reg_write(0x78,std::uint8_t(mode&7));
      spi.reg_write(0x1B,std::uint8_t(a)); spi.reg_write(0x1C,std::uint8_t(a>>8));
      spi.reg_write(0x1D,std::uint8_t(mask)); spi.reg_write(0x1E,std::uint8_t(mask>>8));
      spi.reg_write(0x1A,1); spi.reg_write(0x79,1);
    }else if(op=="wr" && n>=3){
      spi.reg_write(std::uint8_t(a),std::uint8_t(b));
    }else if(op=="rd" && n>=2){
      std::ofstream o("/run/a2reg.out",std::ios::app);
      for(unsigned i=0;i<(n>=3?b:1u);i++){
        char buf[24];
        std::snprintf(buf,sizeof buf,"%02X=%02X\n",(a+i)&0x7F,unsigned(spi.reg_read(std::uint8_t(a+i))));
        o<<buf;
      }
    }else if(op=="dump"){
      const unsigned trig=spi.reg_read(0x1A);
      spi.reg_write(0x79,0);
      const unsigned st=spi.reg_read(0x70);
      const unsigned cnt=(st&0x40)?512u:(spi.reg_read(0x71)|((spi.reg_read(0x72)&1u)<<8));
      std::ofstream o("/run/a2trace.out");
      o<<"# "<<cnt<<" cycles, trigger "<<((trig&2)?"MATCHED":((trig&1)?"armed, no match":"off"))
       <<", oldest first: addr rw data ctrl[rw inh res irq nmi dma rdy m2sel]\n";
      for(unsigned i=0;i<cnt;i++){
        std::uint8_t d[4]; for(int k=0;k<4;k++) d[k]=spi.reg_read(std::uint8_t(0x73+k));
        spi.reg_write(0x77,1);
        char buf[40];
        std::snprintf(buf,sizeof buf,"%02X%02X %c %02X %02X\n",d[3],d[2],(d[0]&0x80)?'R':'W',d[1],d[0]);
        o<<buf;
      }
      spi.reg_write(0x1A,0); spi.reg_write(0x1F,0); spi.reg_write(0x78,0); spi.reg_write(0x79,1);
    }
  }
}
// Disk II encodes track as LBA=track*13 (13*512=0x1A00 nibblized bytes).
// The Smart-Zynq SPI path has been observed to drop data bit7 on MISO, so a
// real LBA of 0xDD (track 17 — the DiskII default head position) arrives as
// 0x5D and fails a naive "% 13 == 0" check. Recover by trying bit7 overlays.
bool decode_floppy_lba(std::uint32_t raw,std::uint32_t&lba,std::uint32_t&track){
  static const std::uint32_t kOr[]={
    0u, 0x80u, 0x8000u, 0x8080u,
    0x800000u, 0x800080u, 0x808000u, 0x808080u,
    0x80000000u
  };
  for(std::uint32_t mask : kOr){
    const auto cand=raw|mask;
    if(cand%13u!=0) continue;
    const auto t=cand/13u;
    if(t>=35u) continue;
    lba=cand; track=t; return true;
  }
  return false;
}
bool read_floppy_lba(SpiTransport&spi,int v,std::uint32_t&lba,std::uint32_t&track){
  constexpr int kTries=8;
  for(int i=0;i<kTries;i++){
    const auto a=spi.reg_read32(vb(v,8));
    const auto b=spi.reg_read32(vb(v,8));
    if(a!=b) continue;
    if(decode_floppy_lba(a,lba,track)) return true;
  }
  // Last chance: single sample with bit7 recovery (values may still be stable).
  return decode_floppy_lba(spi.reg_read32(vb(v,8)),lba,track);
}
// Log what a save carries: where the written track differs from the track
// served from the image (gaps under 8 bytes merged, first bytes of each range)
// and which sectors decode. Both tracks are kept in /tmp for a closer look.
void describe_save(int v,std::uint32_t track,const std::array<std::uint8_t,TRACK_BYTES>&buf,ImageFile&img){
  std::array<std::uint8_t,TRACK_BYTES> served; served.fill(0);
  std::uint32_t actual=0;
  if(img.read_floppy_track(track,served,actual)!=StatusCode::Ok) return;
  std::ostringstream os;
  std::size_t i=0,ndiff=0; int ranges=0;
  while(i<TRACK_BYTES){
    if(buf[i]==served[i]){ ++i; continue; }
    const std::size_t s=i; std::size_t e=i,quiet=0;
    while(i<TRACK_BYTES&&quiet<8){ if(buf[i]!=served[i]){ e=i; quiet=0; ++ndiff; } else ++quiet; ++i; }
    if(ranges<6){
      os<<" ["<<s<<"-"<<e<<"]";
      for(std::size_t k=s;k<=e&&k<s+10;k++) os<<' '<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(buf[k])<<std::dec;
    }
    ++ranges;
  }
  std::array<std::uint8_t,DSK_TRACK_BYTES> raw{};
  const unsigned mask=gcr_decode_dos_track(buf.data(),TRACK_BYTES,GCR_ORDER_DOS,raw.data());
  std::cerr<<"a2hostd: floppy "<<v<<" save track "<<track<<": "<<ndiff<<" bytes in "<<ranges
           <<" ranges differ from the served track, sectors decoded 0x"<<std::hex<<mask<<std::dec<<os.str()<<"\n";
  const std::string base="/tmp/a2_wb_d"+std::to_string(v)+"_t"+std::to_string(track);
  std::ofstream((base+".nib").c_str(),std::ios::binary).write(reinterpret_cast<const char*>(buf.data()),std::streamsize(TRACK_BYTES));
  std::ofstream((base+"_served.nib").c_str(),std::ios::binary).write(reinterpret_cast<const char*>(served.data()),std::streamsize(TRACK_BYTES));
}
void serve_floppy(SpiTransport&spi,DriveManager&dm,int v){
  auto d=dm.get(Drive(v)); if(!d) return;
  const auto rd=spi.reg_read(vb(v,0xD))&1, wr=spi.reg_read(vb(v,0xE))&1;
  if(!rd&&!wr) return;
  std::uint32_t lba=0, track=0;
  if(!read_floppy_lba(spi,v,lba,track)){
    const auto raw=spi.reg_read32(vb(v,8));
    static int spam=0;
    if(spam<12){
      std::cerr<<"a2hostd: floppy "<<v<<" unstable LBA 0x"<<std::hex<<raw<<std::dec<<" — not acking\n";
      ++spam;
    }
    return;
  }
  constexpr std::size_t n=TRACK_BYTES;
  std::array<std::uint8_t,TRACK_BYTES> buf; buf.fill(0);
  StatusCode st=StatusCode::Ok;
  if(wr){
    buf.fill(0xff);
    if(g_nib_readback)
      spi.xfer_read(SPACE_NIB,v*DISK_WINDOW_STRIDE,span<std::uint8_t>(buf.data(),n));
    else
      spi.xfer_read(SPACE_SDRAM,DISK_WINDOW_BASE+v*DISK_WINDOW_STRIDE,span<std::uint8_t>(buf.data(),n));
    describe_save(v,track,buf,*d);
    st=d->write_floppy_track(track,buf);
  }else{
    std::uint32_t actual=0;
    st=d->read_floppy_track(track,buf,actual);
    if(st==StatusCode::Ok)
      spi.xfer_write(SPACE_SDRAM,DISK_WINDOW_BASE+v*DISK_WINDOW_STRIDE,
                     span<const std::uint8_t>(buf.data(),std::min<std::size_t>(n,actual)));
  }
  if(st!=StatusCode::Ok&&wr){
    // Ack anyway: an unacked save holds the drive's loader forever.
    std::cerr<<"a2hostd: floppy "<<v<<" track "<<track<<" WRITE-BACK FAILED status "<<unsigned(st)<<" — changes on this track lost\n";
    // Keep the track for a look: address fields ($D5 $AA $96) and data fields ($D5 $AA $AD).
    unsigned addr_f=0,data_f=0;
    for(std::size_t i=0;i+2<n;i++) if(buf[i]==0xD5&&buf[i+1]==0xAA){ if(buf[i+2]==0x96) addr_f++; else if(buf[i+2]==0xAD) data_f++; }
    const std::string dump="/tmp/a2_writeback_d"+std::to_string(v)+"_t"+std::to_string(track)+".nib";
    std::ofstream(dump.c_str(),std::ios::binary).write(reinterpret_cast<const char*>(buf.data()),std::streamsize(n));
    std::cerr<<"a2hostd: floppy "<<v<<" track "<<track<<" had "<<addr_f<<" address and "<<data_f<<" data fields ("
             <<(g_nib_readback?"drive copy":"SDRAM window")<<"), saved to "<<dump<<"\n";
  }else if(st!=StatusCode::Ok){
    std::cerr<<"a2hostd: floppy "<<v<<" track "<<track<<" service status "<<unsigned(st)<<" — not acking\n";
    return;
  }
  std::cerr<<"a2hostd: floppy "<<v<<(wr?" saved":" served")<<" track "<<track<<" (lba "<<lba<<")\n";
  spi.reg_write(vb(v,0xF),1);
}
// Swap floppy v to `path` (empty = eject) under a live Apple. Clearing
// `mounted` makes drive_ii write back a dirty track (served here from the old
// image) and drop its cached track, so the next read comes from the new image.
// One line of text under the Apple picture on HDMI (hdl/video/osd_line.sv,
// SPI space 5: byte 0 bit 0 = show, bytes 1-40 = text). Hidden again by osd_poll.
constexpr std::uint8_t SPACE_OSD=5;
// Super Serial Card port on TCP (ssc_net_bridge.sv in the FPGA turns the card's
// serial line into bytes): one client at a time, raw bytes both ways, no telnet
// negotiation; a newer connection replaces an older one. Settings: ssc_port
// (default 6551, 0 = off) and ssc_cr_delay_ms (pause after each CR sent to the
// Apple, for typing a program in through IN#2). The FPGA side, all in SPACE 5:
// a read below 0x100 is the status {room for 256 more, bytes waiting 0-127},
// reads at 0x100+ pop bytes from the card, writes at 0x100+ queue bytes for it;
// reg 0x06 bit 4 = present. (Never a register: reg 0x7F is the XFER opcode.)
class SscNet{
public:
  void start(int port,int cr_delay_ms){
    cr_delay_ms_=cr_delay_ms;
    listen_fd_=::socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
    if(listen_fd_<0) return;
    int one=1; (void)::setsockopt(listen_fd_,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one);
    sockaddr_in a{}; a.sin_family=AF_INET; a.sin_addr.s_addr=INADDR_ANY; a.sin_port=htons(std::uint16_t(port));
    if(::bind(listen_fd_,reinterpret_cast<sockaddr*>(&a),sizeof a)<0||::listen(listen_fd_,2)<0){
      std::cerr<<"a2hostd: SSC serial: cannot listen on port "<<port<<"\n";
      ::close(listen_fd_); listen_fd_=-1; return;
    }
    std::cerr<<"a2hostd: SSC serial (slot 2) on TCP port "<<port<<(cr_delay_ms_?", pause after CR "+std::to_string(cr_delay_ms_)+" ms":"")<<"\n";
  }
  void poll(SpiTransport&spi){
    if(listen_fd_<0) return;
    sockaddr_in peer{}; socklen_t pl=sizeof peer;
    const int fd=::accept4(listen_fd_,reinterpret_cast<sockaddr*>(&peer),&pl,SOCK_CLOEXEC|SOCK_NONBLOCK);
    if(fd>=0){
      if(client_>=0){ std::cerr<<"a2hostd: SSC serial: new client replaces the old one\n"; drop(); }
      client_=fd; pending_.clear(); to_net_=to_apple_=0;
      int one=1; (void)::setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof one);
      char ip[INET_ADDRSTRLEN]={0}; ::inet_ntop(AF_INET,&peer.sin_addr,ip,sizeof ip);
      std::cerr<<"a2hostd: SSC serial: "<<ip<<" connected\n";
    }
    std::uint8_t st=0;
    spi.xfer_read(SPACE_OSD,0,span<std::uint8_t>(&st,1));
    std::uint8_t buf[256];
    const unsigned n=st&0x7F;
    if(n){                                    // from the Apple (dropped when nobody listens)
      spi.xfer_read(SPACE_OSD,0x100,span<std::uint8_t>(buf,n));
      if(client_>=0){
        const ssize_t w=::send(client_,buf,n,MSG_NOSIGNAL|MSG_DONTWAIT);
        if(w<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK) drop(); else if(w>0) to_net_+=unsigned(w);
      }
    }
    if(client_>=0&&pending_.size()<8192){    // to the Apple
      const ssize_t r=::recv(client_,buf,sizeof buf,MSG_DONTWAIT);
      if(r==0||(r<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK)) drop();
      else if(r>0) pending_.insert(pending_.end(),buf,buf+r);
    }
    const auto now=std::chrono::steady_clock::now();
    if(!pending_.empty()&&(st&0x80)&&now>=hold_until_){
      std::size_t k=0; bool cr=false;
      while(k<pending_.size()&&k<sizeof buf){ buf[k]=pending_[k]; if(cr_delay_ms_&&buf[k]==0x0D){ ++k; cr=true; break; } ++k; }
      spi.xfer_write(SPACE_OSD,0x100,span<const std::uint8_t>(buf,k));
      pending_.erase(pending_.begin(),pending_.begin()+std::ptrdiff_t(k));
      to_apple_+=unsigned(k);
      if(cr) hold_until_=now+std::chrono::milliseconds(cr_delay_ms_);
    }
  }
private:
  void drop(){
    if(client_<0) return;
    ::close(client_); client_=-1; pending_.clear();
    std::cerr<<"a2hostd: SSC serial: client gone ("<<to_net_<<" bytes from the Apple, "<<to_apple_<<" to it)\n";
  }
  int listen_fd_=-1, client_=-1, cr_delay_ms_=0;
  std::deque<std::uint8_t> pending_;
  std::chrono::steady_clock::time_point hold_until_{};
  unsigned long to_net_=0, to_apple_=0;
};
std::chrono::steady_clock::time_point osd_until{};
void osd_show(SpiTransport&spi,const std::string&text,int seconds=4){
  std::uint8_t buf[41]; buf[0]=0;
  for(int i=0;i<40;i++) buf[1+i]=std::uint8_t(i<int(text.size())?text[std::size_t(i)]:' ');
  spi.xfer_write(SPACE_OSD,0,span<const std::uint8_t>(buf,sizeof buf));
  const std::uint8_t on=1;
  spi.xfer_write(SPACE_OSD,0,span<const std::uint8_t>(&on,1));
  osd_until=std::chrono::steady_clock::now()+std::chrono::seconds(seconds);
}
void osd_poll(SpiTransport&spi){
  if(osd_until.time_since_epoch().count()&&std::chrono::steady_clock::now()>osd_until){
    const std::uint8_t off=0;
    spi.xfer_write(SPACE_OSD,0,span<const std::uint8_t>(&off,1));
    osd_until={};
  }
}
// The board's KEY1/KEY2 (PS EMIO GPIO 61/62 = Linux GPIO 115/116, idle high).
struct BoardKey{
  int fd{-1}; int idle{-1}; int low_polls{0}; bool down{false};
  explicit BoardKey(int gpio){
    const auto base="/sys/class/gpio/gpio"+std::to_string(gpio);
    if(!path_exists(base)){ std::ofstream("/sys/class/gpio/export")<<gpio; }
    { std::ofstream(base+"/direction")<<"in"; }
    fd=::open((base+"/value").c_str(),O_RDONLY|O_CLOEXEC);
  }
  ~BoardKey(){ if(fd>=0) ::close(fd); }
  // true once per press (held for 3 polls, then released and pressed again)
  bool pressed(){
    if(fd<0) return false;
    char c='1';
    if(::pread(fd,&c,1,0)!=1) return false;
    const int v=c=='0'?0:1;
    if(idle<0){ idle=v; return false; }
    if(v!=idle){ if(++low_polls==3&&!down){ down=true; return true; } }
    else { low_polls=0; down=false; }
    return false;
  }
};
bool swap_floppy(SpiTransport&spi,DriveManager&dm,int v,const std::string&path,std::string&err){
  spi.reg_write(vb(v,2),0);
  const auto t0=std::chrono::steady_clock::now();
  for(;;){
    serve_floppy(spi,dm,v);
    const bool busy=(spi.reg_read(vb(v,0xD))&1)||(spi.reg_read(vb(v,0xE))&1);
    const auto el=std::chrono::steady_clock::now()-t0;
    if(!busy&&el>std::chrono::milliseconds(5)) break;
    if(el>std::chrono::seconds(3)){ std::cerr<<"a2hostd: floppy "<<v<<" still busy after 3 s — swapping anyway\n"; break; }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  bool ok=true;
  if(path.empty()) dm.eject(Drive(v));
  else if(dm.mount(Drive(v),path)!=StatusCode::Ok){
    std::cerr<<"a2hostd: floppy "<<v<<" cannot mount "<<path<<"\n";
    err="CANNOT OPEN THAT IMAGE";
    ok=false;   // the old image stays
  }
  program_floppy(spi,dm,v);
  return ok;
}
void serve_hdd(SpiTransport&spi,DriveManager&dm,int u){
  auto d=dm.get(Drive(2+u)); if(!d) return;
  auto req=spi.reg_read(hb(u,0))&3; if(!req) return;
  auto lba=std::uint32_t(spi.reg_read(hb(u,1)))|(std::uint32_t(spi.reg_read(hb(u,2)))<<8);
  std::array<std::uint8_t,BLOCK_BYTES> buf; buf.fill(0);
  StatusCode st=StatusCode::Ok;
  if(req&2){
    if(g_hdd_direct) spi.xfer_read(SPACE_HDD_BUF,0,buf);
    else spi.xfer_read(SPACE_SDRAM,HDD_WINDOW_BASE+u*HDD_WINDOW_STRIDE,buf);
    st=d->write_blocks(lba,1,buf);
  }else{
    std::uint32_t actual=0;
    st=d->read_blocks(lba,1,buf,actual);
    if(st==StatusCode::Ok){
      if(g_hdd_direct) spi.xfer_write(SPACE_HDD_BUF,0,buf);
      else spi.xfer_write(SPACE_SDRAM,HDD_WINDOW_BASE+u*HDD_WINDOW_STRIDE,buf);
    }
  }
  if(st!=StatusCode::Ok)
    std::cerr<<"a2hostd: HDD "<<u<<" block "<<lba<<" service status "<<unsigned(st)<<"\n";
  spi.reg_write(hb(u,3),1);
}
// Put `path` in hard disk unit u (empty = eject) from the boot menu. A request
// still pending on the unit is served from the old image first; the unit is
// unmounted while the image changes, so ProDOS never reads half of each.
bool swap_hdd(SpiTransport&spi,DriveManager&dm,int u,const std::string&path,std::string&err){
  const auto t0=std::chrono::steady_clock::now();
  while(spi.reg_read(hb(u,0))&3){
    serve_hdd(spi,dm,u);
    if(std::chrono::steady_clock::now()-t0>std::chrono::seconds(3)){
      std::cerr<<"a2hostd: HDD "<<u<<" still busy after 3 s — swapping anyway\n";
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  spi.reg_write(hb(u,0),0);
  bool ok=true;
  if(path.empty()) dm.eject(Drive(2+u));
  else if(dm.mount(Drive(2+u),path)!=StatusCode::Ok){
    std::cerr<<"a2hostd: HDD "<<u<<" cannot mount "<<path<<"\n";
    err="CANNOT OPEN THAT IMAGE";
    ok=false;   // the old image stays
  }
  program_hdd(spi,dm,u);
  return ok;
}
}
int main(int argc,char**argv){
  std::string uio, net_if="eth0";
  std::string root="/media/a2", settings_path="/var/lib/a2host/settings.ini";
  for(int i=1;i<argc;i++){
    std::string a=argv[i];
    if(a=="--uio"&&i+1<argc) uio=argv[++i];
    else if(a=="--root"&&i+1<argc) root=argv[++i];
    else if(a=="--net-if"&&i+1<argc) net_if=argv[++i];
    else if(a=="--settings"&&i+1<argc) settings_path=argv[++i];
    else if(a=="--help"){
      std::cout<<"a2hostd [--uio /dev/uioN] [--root path] [--settings path] [--net-if eth0]\n";
      return 0;
    }
  }
  std::signal(SIGINT,on_signal); std::signal(SIGTERM,on_signal);
  try{
    SpiTransport spi(uio);
    bind_fpga_spi_transport(&spi);
    spi.set_host_ready(false);
    auto id=spi.device_id();
    if(id!="A2FP") throw std::runtime_error("unexpected FPGA companion ID: "+id);

    Settings settings(settings_path); settings.load();
    DriveManager drives;
    std::vector<std::string> roots;
    roots.push_back(root);
    roots.push_back("/media/usb");
    roots.push_back("/mnt/usb");
    roots.push_back("/media/sd");
    roots.push_back("/mnt/sd");
    roots.push_back("/boot");
    // Last disks picked in the slot 5 boot menu, then the fixed names.
    for(int v=0;v<2;v++){
      const auto p=settings.get(v?"disk2_image":"disk1_image","");
      if(!p.empty()&&p!="none"&&path_exists(p)) (void)drives.mount(Drive(v),p);
    }
    // Hard disks: the last ones picked in the menu, else hdd1.* / hdd2.* by name.
    for(int u=0;u<2;u++){
      const auto p=settings.get(u?"hdd2_image":"hdd1_image","");
      if(!p.empty()&&p!="none"&&path_exists(p)) (void)drives.mount(Drive(2+u),p);
    }
    drives.auto_mount(roots);
    if(settings.get("disk2_image","")=="none") drives.eject(Drive(1));
    for(int u=0;u<2;u++)
      if(settings.get(u?"hdd2_image":"hdd1_image","")=="none") drives.eject(Drive(2+u));
    std::cerr<<"a2hostd: "<<drives.status_json()<<"\n";
    // Bring SPI/host_ready/slots up, program mounts, THEN release Apple /RES.
    // Releasing 0x2E before mounts lets Disk II scan with ready=0 and hang.
    spi.reg_write(0x30,1);
    spi.set_host_ready(true);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if(!spi_scratch_ok(spi))
      std::cerr<<"a2hostd: WARNING SPI scratch canary failed — volume writes may fail\n";
    g_nib_readback=(spi.reg_read(0x2E)&0x80)!=0;
    g_hdd_direct=(spi.reg_read(0x06)&0x04)!=0;
    std::cerr<<"a2hostd: "<<(g_hdd_direct?"hard disk blocks go through the card's sector buffer (SPACE 7)"
                                        :"hard disk blocks go through the SDRAM window (old bitstream)")<<"\n";
    std::cerr<<"a2hostd: "<<(g_nib_readback?"Disk II saves read the drive's track copy (SPACE 6)"
                                          :"WARNING old bitstream: Disk II writes cannot be saved (no SPACE 6)")<<"\n";
    // apple_bus tuning (scratch regs; 0 = bitstream default): 0x0C address
    // count, 0x0D data count, 0x0E drive-window/late-pass, 0x0F counter select,
    // 0x07 D0-D7 drive start in 216 MHz clocks after PHI0 (the scratch test
    // above leaves 0x3C there, so it must be rewritten). Nothing else may
    // write these.
    {
      const int a=std::atoi(settings.get("bus_addr_count","0").c_str());
      const int d=std::atoi(settings.get("bus_data_count","0").c_str());
      const int w=std::atoi(settings.get("bus_write_count","0").c_str());
      const int f=std::atoi(settings.get("bus_drive_fine","0").c_str());
      const int r=std::atoi(settings.get("bus_drive_release","0").c_str());
      spi.reg_write(0x0C,std::uint8_t(a)); spi.reg_write(0x0D,std::uint8_t(d));
      spi.reg_write(0x0E,std::uint8_t(w)); spi.reg_write(0x0F,0);
      spi.reg_write(0x07,std::uint8_t(f)); spi.reg_write(0x6F,std::uint8_t(r));
      std::cerr<<"a2hostd: bus tuning addr="<<a<<" data="<<d<<" window="<<w
               <<" drive_fine="<<f<<" drive_release="<<r<<" (0 = bitstream default)\n";
    }
    int disk_slot=disk_slot_target(settings);   // where the slot map puts the Disk II
    program_slots(spi,disk_slot);
    std::cerr<<"a2hostd: Disk II in slot "<<disk_slot<<"\n";
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    program_mounts(spi,drives);
    dump_floppy_fpga(spi);
    // A hello from a slot other than the card's: hold the Apple in reset, move
    // the Disk II, let go. The menu spoiled the power-up byte, so that reset is a
    // cold start and the boot scan finds the drive (and this menu) in its new slot.
    auto last_move=std::chrono::steady_clock::time_point{};
    int last_move_to=0;
    auto slot_check=[&](int menu_slot,const std::function<void(int)>&arm_restart,std::string&notice,int&card_slot){
      card_slot=phys_slot(spi);   // the menu's probes just showed the card its slot
      note_card_slot(settings,card_slot);
      const int target=disk_slot_target(settings);
      if(target==menu_slot) return false;
      const auto now=std::chrono::steady_clock::now();
      if(last_move_to==target&&now-last_move<std::chrono::seconds(20)){
        std::cerr<<"a2hostd: Disk II move to slot "<<target<<" did not take (menu still in slot "<<menu_slot<<")\n";
        notice="CARD IS IN SLOT "+std::to_string(target)+": TURN THE APPLE OFF AND ON";
        return false;
      }
      std::cerr<<"a2hostd: moving the Disk II from slot "<<menu_slot<<" to slot "<<target<<" (card's slot), resetting the Apple\n";
      last_move=now; last_move_to=target;
      spi.reg_write(0x2e,3);   // hold /RES (and keep the release bit)
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      disk_slot=target;
      program_slots(spi,disk_slot);
      arm_restart(disk_slot);  // if the reset does not take, the menu jumps to $Cn00 itself
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      spi.reg_write(0x2e,1);   // let go: cold start
      return true;
    };
    DiskMenu menu(spi,drives,settings,root,[&](int v,const std::string&p,std::string&err){
      return swap_floppy(spi,drives,v,p,err);
    },[&](int u,const std::string&p,std::string&err){
      return swap_hdd(spi,drives,u,p,err);
    },slot_check);
    menu.start();
    { const std::uint8_t off=0; spi.xfer_write(SPACE_OSD,0,span<const std::uint8_t>(&off,1)); }
    // Mid-game disk swap for multi-disk games: the board's KEY1 (next) /
    // KEY2 (previous) put the next disk of the set in drive 1 and say so on HDMI.
    BoardKey key_next(115), key_prev(116);
    auto hot_swap=[&](int step,const char*why){
      const auto cur=drives.get(Drive(0))?drives.get(Drive(0))->path():std::string();
      const auto next=menu.sibling(cur,step);
      if(next.empty()){ osd_show(spi,"NO OTHER DISK TO SWAP IN"); return; }
      std::string err;
      if(!swap_floppy(spi,drives,0,next,err)){ osd_show(spi,"CANNOT OPEN "+path_filename(next)); return; }
      settings.set("disk1_image",next);
      try{ settings.save(); }catch(...){}
      std::cerr<<"a2hostd: "<<why<<": drive 1 = "<<next<<"\n";
      std::string up=path_filename(next);
      for(char&c:up) c=char(std::toupper(static_cast<unsigned char>(c)));
      osd_show(spi,"DRIVE 1: "+up);
    };
    spi.reg_write(0x2e,1); // release Apple reset only after mounts stick

    w5100_init();
    (void)w5100_linux_init(net_if);
    Gamepad pad; pad.start();

    auto status=[&](){ return drives.status_json(); };
    auto command=[&](const std::string&c){
      if(c=="status") return status();
      if(c=="fpga"){ dump_floppy_fpga(spi); return std::string("OK"); }
      if(c=="rescan"){
        drives.auto_mount(roots);
        program_mounts(spi,drives);
        dump_floppy_fpga(spi);
        return std::string("OK");
      }
      return std::string("commands: status, rescan, fpga");
    };
    NetworkServices network(root,status,command);
    network.start(std::stoi(settings.get("telnet_port","23")),
                  std::stoi(settings.get("ftp_port","21")));

    auto last_dump=std::chrono::steady_clock::now();
    auto last_trace_poll=last_dump;
    // Edge-log motor and /RES: the 5 s dump misses short motor-on bursts.
    int last_active[2]={-1,-1}, last_sysrst=-1;
    SscNet ssc;
    if(spi.reg_read(0x06)&0x10){
      const int port=std::atoi(settings.get("ssc_port","6551").c_str());
      if(port>0) ssc.start(port,std::max(0,std::atoi(settings.get("ssc_cr_delay_ms","0").c_str())));
    }else{
      std::cerr<<"a2hostd: SSC serial not bridged by this bitstream\n";
    }
    while(!quit_flag){
      ssc.poll(spi);
      for(int v=0;v<2;v++){
        const int a=spi.reg_read(vb(v,1))&1;
        if(a!=last_active[v]){
          std::cerr<<"a2hostd: floppy "<<v<<" motor "<<(a?"ON":"off")<<"\n";
          last_active[v]=a;
        }
      }
      {
        const int r=(spi.reg_read(0x06)>>5)&1;
        if(r!=last_sysrst){
          std::cerr<<"a2hostd: Apple /RES line "<<(r?"released":"ASSERTED")<<"\n";
          last_sysrst=r;
        }
      }
      // Re-arm FPGA volumes after Apple /RES (flag at reg 0x33).
      if(spi.reg_read(0x33)&1){
        const bool same=slots_match(spi,disk_slot);
        std::cerr<<"a2hostd: Apple reset seen — "<<(same?"slot map intact, ":"reprogramming slots, ")<<"checking mounts\n";
        if(!same) program_slots(spi,disk_slot);
        program_mounts(spi,drives);
        dump_floppy_fpga(spi);
        spi.reg_write(0x33,0);
      }
      // If FPGA dropped mount bits, push again — but NEVER while a transfer is
      // pending (clearing ready mid-rd hangs Disk II forever).
      {
        bool busy=false, need=false;
        for(int v=0;v<2;v++){
          if((spi.reg_read(vb(v,0xD))&1)||(spi.reg_read(vb(v,0xE))&1)) busy=true;
          if(!drives.get(Drive(v))) continue;
          if((spi.reg_read(vb(v,2))&1)==0) need=true; // only require mounted
        }
        if(need && !busy){
          static auto last_repair=std::chrono::steady_clock::time_point{};
          auto now=std::chrono::steady_clock::now();
          if(last_repair.time_since_epoch().count()==0 ||
             now-last_repair>std::chrono::seconds(2)){
            std::cerr<<"a2hostd: FPGA mount bits missing — repairing\n";
            program_mounts(spi,drives);
            dump_floppy_fpga(spi);
            last_repair=now;
          }
        }
      }
      serve_floppy(spi,drives,0);
      serve_floppy(spi,drives,1);
      menu.poll();
      {
        if(key_next.pressed()) hot_swap(1,"KEY1");
        if(key_prev.pressed()) hot_swap(-1,"KEY2");
        osd_poll(spi);
      }
      serve_hdd(spi,drives,0);
      serve_hdd(spi,drives,1);
      w5100_poll();
      w5100_linux_poll_rx();
      auto now=std::chrono::steady_clock::now();
      if(now-last_trace_poll>std::chrono::milliseconds(250)){
        trace_poll(spi);
        last_trace_poll=now;
      }
      if(now-last_dump>std::chrono::seconds(5)){
        dump_floppy_fpga(spi);
        {  // Uthernet II needs the board's Ethernet cabled to the network
          static int last_carrier=-1;
          std::ifstream cf("/sys/class/net/"+net_if+"/carrier");
          int carrier=0; if(cf) cf>>carrier;
          if(carrier!=last_carrier){
            std::cerr<<"a2hostd: "<<net_if<<" link "<<(carrier?"up":"DOWN - no Ethernet cable/network for the Uthernet II")<<"\n";
            last_carrier=carrier;
          }
        }
        // A changed card slot takes effect at the next menu hello (or restart).
        note_card_slot(settings,phys_slot(spi));
        last_dump=now;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    menu.stop();
    spi.reg_write(0x2e,0);
    spi.set_host_ready(false);
    network.stop();
    pad.stop();
    w5100_linux_close();
    settings.save();
  }catch(const std::exception&e){
    std::cerr<<"a2hostd: "<<e.what()<<"\n";
    return 1;
  }
  return 0;
}
