#include "settings.hpp"
#include "cxx14.hpp"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>
namespace a2 {
Settings::Settings(std::string p):path_(std::move(p)){}
void Settings::load(){std::ifstream f(path_.c_str());if(!f)return;std::ostringstream s;s<<f.rdbuf();deserialize(s.str());}
void Settings::save()const{
  std::lock_guard<std::mutex> l(m_);
  mkdir_p(path_parent(path_));
  const std::string t=path_+".tmp";
  {
    std::ofstream f(t.c_str(),std::ios::trunc);
    if(!f) throw std::runtime_error("settings write failed");
    for(std::map<std::string,std::string>::const_iterator it=v_.begin();it!=v_.end();++it)
      f<<it->first<<'='<<it->second<<'\n';
    f.flush();
  }
  if(::rename(t.c_str(),path_.c_str())!=0) throw std::runtime_error("settings rename failed");
}
std::string Settings::get(const std::string&k,const std::string&d)const{std::lock_guard<std::mutex> l(m_);std::map<std::string,std::string>::const_iterator i=v_.find(k);return i==v_.end()?d:i->second;}
void Settings::set(const std::string&k,std::string v){std::lock_guard<std::mutex> l(m_);v_[k]=std::move(v);}
std::string Settings::serialize()const{std::lock_guard<std::mutex> l(m_);std::ostringstream s;for(std::map<std::string,std::string>::const_iterator it=v_.begin();it!=v_.end();++it)s<<it->first<<'='<<it->second<<'\n';return s.str();}
void Settings::deserialize(const std::string&t){std::lock_guard<std::mutex> l(m_);v_.clear();std::istringstream in(t);std::string line;while(std::getline(in,line)){if(line.empty()||line[0]=='#')continue;auto p=line.find('=');if(p==std::string::npos)continue;v_[line.substr(0,p)]=line.substr(p+1);}}
}
