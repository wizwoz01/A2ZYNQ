#include "gamepad.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <unistd.h>
#include <vector>
namespace a2 {
Gamepad::Gamepad()=default;Gamepad::~Gamepad(){stop();}
void Gamepad::start(){stop_=false;thread_=std::thread(&Gamepad::run,this);}void Gamepad::stop(){stop_=true;if(thread_.joinable())thread_.join();}PadState Gamepad::state()const{std::lock_guard<std::mutex> l(m_);return state_;}
static int bit_for(unsigned c){switch(c){case BTN_SOUTH:return 0;case BTN_EAST:return 1;case BTN_WEST:return 2;case BTN_NORTH:return 3;case BTN_TL:return 4;case BTN_TR:return 5;case BTN_SELECT:return 6;case BTN_START:return 7;case BTN_DPAD_UP:return 8;case BTN_DPAD_DOWN:return 9;case BTN_DPAD_LEFT:return 10;case BTN_DPAD_RIGHT:return 11;default:return -1;}}
void Gamepad::run(){
 while(!stop_){std::vector<int>fds;for(int i=0;i<32;i++){std::string p="/dev/input/event"+std::to_string(i);int f=open(p.c_str(),O_RDONLY|O_NONBLOCK|O_CLOEXEC);if(f>=0)fds.push_back(f);}if(fds.empty()){sleep(1);continue;}std::vector<pollfd>ps;for(int f:fds)ps.push_back({f,POLLIN,0});while(!stop_){int rc=poll(ps.data(),ps.size(),250);if(rc<0)break;for(auto&p:ps)if(p.revents&POLLIN){input_event e{};while(read(p.fd,&e,sizeof(e))==sizeof(e)){std::lock_guard<std::mutex> l(m_);if(e.type==EV_KEY){int b=bit_for(e.code);if(b>=0){if(e.value)state_.buttons|=1u<<b;else state_.buttons&=~(1u<<b);}}else if(e.type==EV_ABS){switch(e.code){case ABS_X:state_.lx=e.value;break;case ABS_Y:state_.ly=e.value;break;case ABS_RX:state_.rx=e.value;break;case ABS_RY:state_.ry=e.value;break;}}}}}for(int f:fds)close(f);}
}
}
