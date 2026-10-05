#pragma once
#include <array>
#include <cstddef>
#include <type_traits>
#include <cstdint>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace a2 {

template <typename T>
class span {
public:
    span() : p_(nullptr), n_(0) {}
    span(T* p, std::size_t n) : p_(p), n_(n) {}
    template <std::size_t N>
    span(T (&a)[N]) : p_(a), n_(N) {}
    span(std::vector<typename std::remove_const<T>::type>& v) : p_(v.data()), n_(v.size()) {}
    span(const std::vector<typename std::remove_const<T>::type>& v) : p_(v.data()), n_(v.size()) {}
    template <std::size_t N>
    span(std::array<typename std::remove_const<T>::type, N>& a) : p_(a.data()), n_(N) {}
    template <std::size_t N>
    span(const std::array<typename std::remove_const<T>::type, N>& a) : p_(a.data()), n_(N) {}
    T* data() const { return p_; }
    std::size_t size() const { return n_; }
    bool empty() const { return n_ == 0; }
    T* begin() const { return p_; }
    T* end() const { return p_ + n_; }
    T& operator[](std::size_t i) const { return p_[i]; }
private:
    T* p_;
    std::size_t n_;
};

inline bool path_exists(const std::string& p) {
    return ::access(p.c_str(), F_OK) == 0;
}

inline bool path_is_dir(const std::string& p) {
    struct stat st;
    return ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

inline std::string path_join(std::string a, const std::string& b) {
    if (b.empty()) return a;
    if (a.empty()) return b;
    if (a.back() != '/') a += '/';
    if (b.front() == '/') return a + b.substr(1);
    return a + b;
}

inline std::string path_extension(const std::string& p) {
    const auto slash = p.find_last_of("/\\");
    const auto base = slash == std::string::npos ? 0 : slash + 1;
    const auto dot = p.find_last_of('.');
    if (dot == std::string::npos || dot < base) return std::string();
    return p.substr(dot);
}

inline std::string path_filename(const std::string& p) {
    const auto slash = p.find_last_of("/\\");
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

inline std::string path_parent(const std::string& p) {
    const auto slash = p.find_last_of("/\\");
    if (slash == std::string::npos) return ".";
    if (slash == 0) return "/";
    return p.substr(0, slash);
}

inline void mkdir_p(const std::string& p) {
    if (p.empty() || p == "." || p == "/") return;
    mkdir_p(path_parent(p));
    (void)::mkdir(p.c_str(), 0755);
}

}  // namespace a2
