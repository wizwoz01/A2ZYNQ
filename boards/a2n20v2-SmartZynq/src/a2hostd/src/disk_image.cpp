#include "disk_image.hpp"
#include "gcr_dsk.h"
#include "cxx14.hpp"
#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sstream>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace a2 {
namespace {
constexpr std::uint64_t kSectorImage=143360, kNibImage=232960;
constexpr std::size_t kTrackBytes=DSK_TRACK_BYTES, kNibTrackBytes=GCR_TRACK_BYTES;
std::uint32_t le32(const std::uint8_t*p){return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|(std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);}
std::string lower(std::string s){for(char&c:s)c=char(std::tolower(static_cast<unsigned char>(c)));return s;}
}
ImageFile::ImageFile(std::string p,bool wr):path_(std::move(p)){
    fd_=::open(path_.c_str(),wr?O_RDWR|O_CLOEXEC:O_RDONLY|O_CLOEXEC);if(fd_<0&&wr)fd_=::open(path_.c_str(),O_RDONLY|O_CLOEXEC);
    if(fd_<0) throw std::runtime_error("open "+path_+": "+std::strerror(errno));
    int flags=::fcntl(fd_,F_GETFL);writable_=flags>=0&&((flags&O_ACCMODE)!=O_RDONLY);detect_format();
}
ImageFile::~ImageFile(){if(fd_>=0)::close(fd_);} 
bool ImageFile::pread_exact(void*p,std::size_t n,std::uint64_t o){auto*q=static_cast<std::uint8_t*>(p);while(n){ssize_t r=::pread(fd_,q,n,off_t(o));if(r<0&&errno==EINTR)continue;if(r<=0)return false;q+=r;o+=r;n-=std::size_t(r);}return true;}
bool ImageFile::pwrite_exact(const void*p,std::size_t n,std::uint64_t o){auto*q=static_cast<const std::uint8_t*>(p);while(n){ssize_t r=::pwrite(fd_,q,n,off_t(o));if(r<0&&errno==EINTR)continue;if(r<=0)return false;q+=r;o+=r;n-=std::size_t(r);}return ::fsync(fd_)==0;}
void ImageFile::detect_format(){
    struct stat st{};if(::fstat(fd_,&st)<0)throw std::runtime_error("fstat failed");data_length_=st.st_size;data_offset_=0;auto ext=lower(path_extension(path_));
    std::array<std::uint8_t,64>h{};if(st.st_size>=64)pread_exact(h.data(),h.size(),0);
    if(std::memcmp(h.data(),"2IMG",4)==0){auto hs=le32(h.data()+8),fmt=le32(h.data()+12),off=le32(h.data()+24),len=le32(h.data()+28);if(hs<64)throw std::runtime_error("invalid 2MG header");if(off==0)off=hs;if(len==0&&std::uint64_t(off)<=std::uint64_t(st.st_size))len=std::uint32_t(st.st_size-off);if(std::uint64_t(off)+len>std::uint64_t(st.st_size))throw std::runtime_error("invalid 2MG payload");data_offset_=off;data_length_=len;format_=(fmt==0?ImageFormat::DosOrder:fmt==1?ImageFormat::ProDosOrder:fmt==2?ImageFormat::Nibble:ImageFormat::Unknown);return;}
    if(ext==".nib"||data_length_==kNibImage){format_=ImageFormat::Nibble;return;}
    if(ext==".do"){format_=ImageFormat::DosOrder;return;}
    if(ext==".dsk"){
        std::array<std::uint8_t,256>b{};bool dos=false,pro=false;
        if(data_length_>=0x11100&&pread_exact(b.data(),b.size(),0x11000))dos=(b[0x34]==35&&b[0x35]==16&&b[0x36]==0&&b[0x37]==1);
        if(!dos&&data_length_>=0x500&&pread_exact(b.data(),b.size(),0x400))pro=((b[4]>>4)==0x0f&&(b[4]&0x0f)>=1&&b[0x23]==0x27&&b[0x24]==0x0d);
        format_=pro?ImageFormat::ProDosOrder:ImageFormat::DosOrder;return;
    }
    if(ext==".po"){format_=(data_length_==kSectorImage)?ImageFormat::ProDosOrder:ImageFormat::Block;return;}
    if(ext==".hdv"||ext==".img"){format_=ImageFormat::Block;return;}
    if(data_length_==kSectorImage){format_=ImageFormat::DosOrder;return;}if((data_length_%512)==0){format_=ImageFormat::Block;return;}format_=ImageFormat::Unknown;
}
StatusCode ImageFile::read_floppy_track(std::uint32_t t,span<std::uint8_t>out,std::uint32_t&actual){
    std::lock_guard<std::mutex> l(mutex_);actual=0;if(t>=35)return StatusCode::OutOfRange;if(out.size()<kNibTrackBytes)return StatusCode::InvalidArgument;
    if(format_==ImageFormat::Nibble){if(data_length_<35*kNibTrackBytes||!pread_exact(out.data(),kNibTrackBytes,data_offset_+std::uint64_t(t)*kNibTrackBytes))return StatusCode::IoError;actual=kNibTrackBytes;return StatusCode::Ok;}
    if(format_!=ImageFormat::DosOrder&&format_!=ImageFormat::ProDosOrder)return StatusCode::UnsupportedFormat;
    std::array<std::uint8_t,kTrackBytes>raw{};if(data_length_<35*kTrackBytes||!pread_exact(raw.data(),raw.size(),data_offset_+std::uint64_t(t)*kTrackBytes))return StatusCode::IoError;
    auto order=format_==ImageFormat::ProDosOrder?GCR_ORDER_PRODOS:GCR_ORDER_DOS;if(gcr_encode_dos_track(raw.data(),std::uint8_t(t),DSK_DEFAULT_VOLUME,order,out.data(),out.size())!=kNibTrackBytes)return StatusCode::ProtocolError;actual=kNibTrackBytes;return StatusCode::Ok;
}
StatusCode ImageFile::write_floppy_track(std::uint32_t t,span<const std::uint8_t>in){
    std::lock_guard<std::mutex> l(mutex_);if(!writable_)return StatusCode::ReadOnly;if(t>=35)return StatusCode::OutOfRange;if(in.size()!=kNibTrackBytes)return StatusCode::InvalidArgument;
    if(format_==ImageFormat::Nibble)return pwrite_exact(in.data(),in.size(),data_offset_+std::uint64_t(t)*kNibTrackBytes)?StatusCode::Ok:StatusCode::IoError;
    if(format_!=ImageFormat::DosOrder&&format_!=ImageFormat::ProDosOrder)return StatusCode::UnsupportedFormat;
    std::array<std::uint8_t,kTrackBytes>raw{};auto off=data_offset_+std::uint64_t(t)*kTrackBytes;if(!pread_exact(raw.data(),raw.size(),off))return StatusCode::IoError;auto order=format_==ImageFormat::ProDosOrder?GCR_ORDER_PRODOS:GCR_ORDER_DOS;auto mask=gcr_decode_dos_track(in.data(),in.size(),order,raw.data());if(mask==0)return StatusCode::ProtocolError;return pwrite_exact(raw.data(),raw.size(),off)?StatusCode::Ok:StatusCode::IoError;
}
StatusCode ImageFile::read_blocks(std::uint32_t b,std::uint32_t c,span<std::uint8_t>out,std::uint32_t&actual){std::lock_guard<std::mutex> l(mutex_);actual=0;std::uint64_t n=std::uint64_t(c)*512,off=std::uint64_t(b)*512;if(c==0||n>out.size())return StatusCode::InvalidArgument;if(off+n>data_length_)return StatusCode::OutOfRange;if(!pread_exact(out.data(),n,data_offset_+off))return StatusCode::IoError;actual=n;return StatusCode::Ok;}
StatusCode ImageFile::write_blocks(std::uint32_t b,std::uint32_t c,span<const std::uint8_t>in){std::lock_guard<std::mutex> l(mutex_);if(!writable_)return StatusCode::ReadOnly;std::uint64_t n=std::uint64_t(c)*512,off=std::uint64_t(b)*512;if(c==0||n>in.size())return StatusCode::InvalidArgument;if(off+n>data_length_)return StatusCode::OutOfRange;return pwrite_exact(in.data(),n,data_offset_+off)?StatusCode::Ok:StatusCode::IoError;}
DriveManager::DriveManager()=default;
StatusCode DriveManager::mount(Drive d,const std::string&p){try{auto im=std::make_shared<ImageFile>(p,true);auto idx=std::size_t(d);if(im->format()==ImageFormat::Unknown)return StatusCode::UnsupportedFormat;if(idx<2&&!(im->format()==ImageFormat::DosOrder||im->format()==ImageFormat::ProDosOrder||im->format()==ImageFormat::Nibble))return StatusCode::UnsupportedFormat;if(idx>=2&&im->format()!=ImageFormat::Block&&!(im->format()==ImageFormat::ProDosOrder&&im->payload_size()!=kSectorImage))return StatusCode::UnsupportedFormat;std::lock_guard<std::mutex> l(mutex_);drives_[idx]=std::move(im);return StatusCode::Ok;}catch(...){return StatusCode::IoError;}}
void DriveManager::eject(Drive d){std::lock_guard<std::mutex> l(mutex_);drives_[std::size_t(d)].reset();}
std::shared_ptr<ImageFile> DriveManager::get(Drive d)const{std::lock_guard<std::mutex> l(mutex_);return drives_[std::size_t(d)];}
std::string DriveManager::status_json()const{std::lock_guard<std::mutex> l(mutex_);std::ostringstream o;o<<"{\"drives\":[";for(std::size_t i=0;i<drives_.size();i++){if(i)o<<',';if(drives_[i])o<<"{\"mounted\":true,\"path\":\""<<drives_[i]->path()<<"\",\"writable\":"<<(drives_[i]->writable()?"true":"false")<<'}';else o<<"{\"mounted\":false}";}o<<"]}";return o.str();}
void DriveManager::auto_mount(const std::vector<std::string>&roots){
  static const std::array<std::vector<std::string>,4>names={{
    {"disk1.dsk","disk1.do","disk1.po","disk1.2mg","disk1.nib","boot.dsk","boot.do","boot.po"},
    {"disk2.dsk","disk2.do","disk2.po","disk2.2mg","disk2.nib"},
    {"hdd1.hdv","hdd1.po","hdd1.2mg"},
    {"hdd2.hdv","hdd2.po","hdd2.2mg"}
  }};
  for(std::size_t d=0;d<4;d++){
    if(get(Drive(d))) continue;
    for(const auto&r:roots)
      for(const auto&n:names[d]){
        auto p=path_join(r,n);
        if(path_exists(p)&&mount(Drive(d),p)==StatusCode::Ok) goto mounted;
      }
    mounted:;
  }
  // Fallback: first loose .dsk/.do/.po/.nib under a root → floppy 0 if still empty.
  if(!get(Drive(0))){
    static const char* exts[]={".dsk",".do",".po",".nib",".2mg"};
    for(const auto&r:roots){
      DIR* dir=::opendir(r.c_str());
      if(!dir) continue;
      while(dirent* e=::readdir(dir)){
        if(e->d_name[0]=='.') continue;
        std::string name=e->d_name;
        auto low=lower(name);
        bool ok=false;
        for(const char* ext:exts){
          auto n=std::strlen(ext);
          if(low.size()>=n&&low.compare(low.size()-n,n,ext)==0){ok=true;break;}
        }
        if(!ok) continue;
        auto p=path_join(r,name);
        if(mount(Drive(0),p)==StatusCode::Ok){::closedir(dir);return;}
      }
      ::closedir(dir);
    }
  }
}
}
