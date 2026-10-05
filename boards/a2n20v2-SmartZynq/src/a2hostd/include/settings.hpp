#pragma once
#include <map>
#include <mutex>
#include <string>
namespace a2 {
class Settings {
public:
 explicit Settings(std::string path);
 void load(); void save() const;
 std::string get(const std::string& key,const std::string& def=std::string()) const;
 void set(const std::string& key,std::string value);
 std::string serialize() const; void deserialize(const std::string& text);
private:
 std::string path_; mutable std::mutex m_; std::map<std::string,std::string> v_;
};
}
