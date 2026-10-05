#include "disk_menu.hpp"
#include "cxx14.hpp"
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

namespace a2 {
namespace {
#include "disk_menu_code.h"   // kDiskMenuCode: $C800-$C9FF of hdl/disk/diskmenu.a65

// Card RAM layout (offset = Apple address - $C800), see diskmenu.a65.
constexpr std::uint8_t SPACE_MENU = 4;
constexpr std::uint32_t CODE = 0x000, SCREEN = 0x200, MB = 0x600;
constexpr std::uint32_t MB_MAGIC = MB + 0, MB_FRAME = MB + 2, MB_CMD = MB + 3, MB_ACK = MB + 4, MB_TARGET = MB + 5,
                        MB_SEQ = MB + 8, MB_SLOT = MB + 11;
constexpr std::uint8_t EVT_HELLO = 1, EVT_KEY = 2;
constexpr std::uint8_t K_LEFT = 0x88, K_TAB = 0x89, K_DOWN = 0x8A, K_UP = 0x8B, K_RETURN = 0x8D,
                       K_RIGHT = 0x95, K_ESC = 0x9B;
constexpr int LIST_ROW = 6, LIST_ROWS = 16;   // rows 1-4: drives and hard disks, row 5: folder or message
constexpr std::uint8_t HDD_CARD = 6;          // card ID of the hard disk in the slot map (regs 0x60-0x67)
constexpr std::uint64_t kFloppy = 143360, kNib = 232960;

std::string lower(std::string s) { for (char& c : s) c = char(std::tolower(static_cast<unsigned char>(c))); return s; }
std::string upper(std::string s) { for (char& c : s) c = char(std::toupper(static_cast<unsigned char>(c))); return s; }
int row_off(int r) { return 128 * (r % 8) + 40 * (r / 8); }

// Primary character set: $80-$FF normal (lower case included), $00-$3F inverse
// upper case / punctuation (there is no inverse lower case).
std::uint8_t scr_normal(char c) {
    auto u = static_cast<unsigned char>(c);
    if (u < 0x20 || u > 0x7E) u = '?';
    return std::uint8_t(u | 0x80);
}
std::uint8_t scr_inverse(char c) {
    auto u = static_cast<unsigned char>(std::toupper(static_cast<unsigned char>(c)));
    if (u >= 0x40 && u <= 0x5F) return std::uint8_t(u - 0x40);
    if (u >= 0x20 && u <= 0x3F) return u;
    return 0x3F;
}
std::string fit(const std::string& s, std::size_t n) {
    return s.size() <= n ? s : s.substr(0, n - 1) + "~";
}
std::uint32_t le32(const std::uint8_t* p) {
    return std::uint32_t(p[0]) | std::uint32_t(p[1]) << 8 | std::uint32_t(p[2]) << 16 | std::uint32_t(p[3]) << 24;
}
// A 5.25" image DriveManager can mount in a Disk II drive.
bool is_floppy_image(const std::string& path, const std::string& name) {
    struct stat st{};
    if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    const auto sz = std::uint64_t(st.st_size);
    const auto ext = lower(path_extension(name));
    if (ext == ".dsk" || ext == ".do" || ext == ".po") return sz >= kFloppy && sz < kFloppy + 0x4000;
    if (ext == ".nib") return sz >= kNib && sz < kNib + 0x4000;
    if (ext == ".2mg") {
        std::uint8_t h[64];
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) return false;
        const bool ok = ::read(fd, h, sizeof h) == ssize_t(sizeof h);
        ::close(fd);
        if (!ok || std::memcmp(h, "2IMG", 4) != 0) return false;
        const auto fmt = le32(h + 12), len = le32(h + 28);
        return (fmt <= 1 && len == kFloppy) || (fmt == 2 && len == kNib);
    }
    return false;
}
// A ProDOS hard disk image DriveManager can mount in a hard disk unit: .hdv,
// a .po that isn't floppy-sized (800K disks too), a ProDOS-order .2mg bigger
// than a floppy. ProDOS uses up to 32 MB (65,535 blocks) of it.
bool is_hdd_image(const std::string& path, const std::string& name) {
    struct stat st{};
    if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    const auto sz = std::uint64_t(st.st_size);
    const auto ext = lower(path_extension(name));
    if (ext == ".hdv") return sz >= 4096 && sz % 512 == 0;
    if (ext == ".po") return sz >= 4096 && sz % 512 == 0 && !(sz >= kFloppy && sz < kFloppy + 0x4000);
    if (ext == ".2mg") {
        std::uint8_t h[64];
        const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) return false;
        const bool ok = ::read(fd, h, sizeof h) == ssize_t(sizeof h);
        ::close(fd);
        if (!ok || std::memcmp(h, "2IMG", 4) != 0) return false;
        const auto fmt = le32(h + 12), len = le32(h + 28);
        return fmt == 1 && len != kFloppy && len >= 4096 && len % 512 == 0;
    }
    return false;
}
std::string stem(const std::string& name) {
    const auto dot = name.rfind('.');
    return lower(dot == std::string::npos ? name : name.substr(0, dot));
}
std::size_t common_prefix(const std::string& a, const std::string& b) {
    std::size_t i = 0;
    while (i < a.size() && i < b.size() && a[i] == b[i]) i++;
    return i;
}
}  // namespace

DiskMenu::DiskMenu(SpiTransport& spi, DriveManager& dm, Settings& settings, std::string root, SwapFn swap, SwapFn swap_hdd, SlotFn slot)
    : spi_(spi), dm_(dm), settings_(settings), root_(std::move(root)), swap_(std::move(swap)), swap_hdd_(std::move(swap_hdd)),
      slot_(std::move(slot)) {
    while (root_.size() > 1 && root_.back() == '/') root_.pop_back();
}

void DiskMenu::start() {
    std::array<std::uint8_t, sizeof kDiskMenuCode> cur{};
    spi_.xfer_read(SPACE_MENU, CODE, cur);
    if (std::memcmp(cur.data(), kDiskMenuCode, cur.size()) != 0) {
        spi_.xfer_write(SPACE_MENU, CODE, span<const std::uint8_t>(kDiskMenuCode, sizeof kDiskMenuCode));
        spi_.xfer_read(SPACE_MENU, CODE, cur);
    }
    if (std::memcmp(cur.data(), kDiskMenuCode, cur.size()) != 0) {
        std::cerr << "a2hostd: boot menu: FPGA has no menu RAM (older bitstream?) - menu off\n";
        enabled_ = false;
        return;
    }
    std::uint8_t seq = 0;
    spi_.xfer_read(SPACE_MENU, MB_SEQ, span<std::uint8_t>(&seq, 1));
    last_seq_ = seq;
    const std::uint8_t mb[5] = {0, 0, frame_, 0, seq};   // magic off while resetting, CMD 0, ACK = SEQ
    spi_.xfer_write(SPACE_MENU, MB_MAGIC, span<const std::uint8_t>(mb, sizeof mb));
    enabled_ = settings_.get("disk_menu", "1") != "0";
    if (enabled_) {
        const std::uint8_t magic[2] = {0xA5, 0x5A};
        spi_.xfer_write(SPACE_MENU, MB_MAGIC, span<const std::uint8_t>(magic, 2));
    }
    std::cerr << "a2hostd: boot menu " << (enabled_ ? "on" : "off (disk_menu=0)") << ", images from " << root_ << "\n";
}

void DiskMenu::stop() {
    const std::uint8_t magic[2] = {0, 0};
    spi_.xfer_write(SPACE_MENU, MB_MAGIC, span<const std::uint8_t>(magic, 2));
    enabled_ = false;
}

void DiskMenu::poll() {
    if (!enabled_) return;
    std::array<std::uint8_t, 5> ev{};   // SEQ, EVT, KEY, SLOT*16, COLD (power-up entry)
    spi_.xfer_read(SPACE_MENU, MB_SEQ, ev);
    if (ev[0] != last_seq_) {
        last_seq_ = ev[0];
        const std::uint8_t seq = ev[0];
        const int slot = (ev[3] >> 4) & 7;
        if (slot) menu_slot_ = slot;
        if (ev[1] == EVT_HELLO) {
            std::string notice;
            auto arm_restart = [&](int slot) {   // CMD 2: JMP ($Cn00) of the new slot
                const std::uint8_t t[2] = {0x00, std::uint8_t(0xC0 | (slot & 7))};
                spi_.xfer_write(SPACE_MENU, MB_TARGET, span<const std::uint8_t>(t, 2));
                const std::uint8_t cmd = 2;
                spi_.xfer_write(SPACE_MENU, MB_CMD, span<const std::uint8_t>(&cmd, 1));
                spi_.xfer_write(SPACE_MENU, MB_ACK, span<const std::uint8_t>(&seq, 1));
            };
            int card = 0;
            if (slot_ && slot_(menu_slot_, arm_restart, notice, card)) {   // Apple is being reset into the card's slot
                session_ = false;
                return;
            }
            card_slot_ = card;
            if (card == 1 && ev[4]) {   // card in slot 1, power-up: no menu and no boot. CMD 4
                session_ = false;         // before the ack: BASIC, the screen left alone ("Apple ][");
                const std::uint8_t cmd = 4;   // PR#6 then brings the menu (COLD = 0)
                spi_.xfer_write(SPACE_MENU, MB_CMD, span<const std::uint8_t>(&cmd, 1));
                spi_.xfer_write(SPACE_MENU, MB_ACK, span<const std::uint8_t>(&seq, 1));
                std::cerr << "a2hostd: card in slot 1: power-up goes to BASIC, PR#6 for the menu\n";
                return;
            }
            on_hello();          // draws the first screen, then the ack lets the Apple run
            if (!notice.empty()) { msg_ = notice; render(); }
            spi_.xfer_write(SPACE_MENU, MB_ACK, span<const std::uint8_t>(&seq, 1));
        } else {
            // Ack first: a swap can take longer than the Apple's send timeout.
            spi_.xfer_write(SPACE_MENU, MB_ACK, span<const std::uint8_t>(&seq, 1));
            if (ev[1] == EVT_KEY) {
                if (!session_) on_hello();   // a2hostd restarted under a running menu
                on_key(ev[2]);
            }
        }
    }
    if (session_ && timeout_s_ > 0 && !touched_) {
        const auto el = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - hello_at_).count();
        const int left = timeout_s_ - int(el);
        if (left <= 0) {
            const auto d1 = mounted_path(0);
            if (!d1.empty()) boot("BOOTING " + path_filename(d1));
            else touched_ = true;   // nothing to boot: wait for the user
        } else if (left != shown_left_) {
            shown_left_ = left;
            render();
        }
    }
}

std::string DiskMenu::sibling(const std::string& cur, int step) const {
    const auto dir = cur.empty() ? root_ : path_parent(cur);
    std::vector<std::string> all;
    if (DIR* d = ::opendir(dir.c_str())) {
        while (dirent* e = ::readdir(d)) {
            const std::string n = e->d_name;
            if (!n.empty() && n[0] != '.' && is_floppy_image(path_join(dir, n), n)) all.push_back(n);
        }
        ::closedir(d);
    }
    if (all.empty()) return std::string();
    std::sort(all.begin(), all.end(), [](const std::string& a, const std::string& b) { return lower(a) < lower(b); });
    const auto name = path_filename(cur), cs = stem(name);
    std::vector<std::string> set;
    for (const auto& n : all) {
        const auto s = stem(n);
        const auto l = common_prefix(s, cs);   // same set: they differ only in a short tail
        if (n == name || (l >= 4 && s.size() - l <= 8 && cs.size() - l <= 8)) set.push_back(n);
    }
    const auto& pool = set.size() >= 2 ? set : all;
    const int n = int(pool.size());
    int i = -1;
    for (int k = 0; k < n; k++) if (pool[std::size_t(k)] == name) i = k;
    if (i < 0) i = step > 0 ? n - 1 : 0;   // not in the pool: start from its first (or last) disk
    const int j = ((i + step) % n + n) % n;
    if (!cur.empty() && pool[std::size_t(j)] == name) return std::string();   // nothing else to swap to
    return path_join(dir, pool[std::size_t(j)]);
}

void DiskMenu::on_hello() {
    session_ = true;
    touched_ = false;
    shown_left_ = -1;
    msg_.clear();
    hello_at_ = std::chrono::steady_clock::now();
    timeout_s_ = std::max(0, std::atoi(settings_.get("disk_menu_timeout", "0").c_str()));
    const std::uint8_t cmd = 0;
    spi_.xfer_write(SPACE_MENU, MB_CMD, span<const std::uint8_t>(&cmd, 1));
    // Open the folder of the disk booted last (a mid-game swap may have left
    // its second disk in drive 1), else of the disk in drive 1, with it selected.
    auto d1 = settings_.get("boot_image", "");
    if (d1.empty() || !path_exists(d1)) d1 = mounted_path(0);
    cwd_.clear();
    const std::string pre = root_ + "/";
    if (d1.compare(0, pre.size(), pre) == 0) {
        const auto par = path_parent(d1.substr(pre.size()));
        if (par != ".") cwd_ = par;
        if (!path_is_dir(path_join(root_, cwd_))) cwd_.clear();
    }
    scan();
    select_path(d1);
    std::cerr << "a2hostd: boot menu opened, " << entries_.size() << " entries in " << path_join(root_, cwd_) << "\n";
    render();
}

void DiskMenu::scan() {
    entries_.clear();
    const auto dir = path_join(root_, cwd_);
    std::vector<Entry> dirs, files;
    if (DIR* d = ::opendir(dir.c_str())) {
        while (dirent* e = ::readdir(d)) {
            const std::string n = e->d_name;
            if (n.empty() || n[0] == '.') continue;
            const auto p = path_join(dir, n);
            if (path_is_dir(p)) dirs.push_back({n, true, false});
            else if (is_floppy_image(p, n)) files.push_back({n, false, false});
            else if (is_hdd_image(p, n)) files.push_back({n, false, true});
        }
        ::closedir(d);
    }
    auto by_name = [](const Entry& a, const Entry& b) { return lower(a.name) < lower(b.name); };
    std::sort(dirs.begin(), dirs.end(), by_name);
    std::sort(files.begin(), files.end(), by_name);
    if (!cwd_.empty()) entries_.push_back({"..", true, false});
    entries_.insert(entries_.end(), dirs.begin(), dirs.end());
    entries_.insert(entries_.end(), files.begin(), files.end());
    sel_ = top_ = 0;
}

std::string DiskMenu::mounted_path(int drive) const {
    auto d = dm_.get(Drive(drive));
    return d ? d->path() : std::string();
}

std::string DiskMenu::entry_path(std::size_t i) const {
    return path_join(path_join(root_, cwd_), entries_[i].name);
}

void DiskMenu::select_path(const std::string& path) {
    for (std::size_t i = 0; i < entries_.size(); i++)
        if (!entries_[i].dir && entry_path(i) == path) { sel_ = i; return; }
}

void DiskMenu::on_key(std::uint8_t key) {
    touched_ = true;
    msg_.clear();
    const std::size_t n = entries_.size();
    switch (key) {
    case K_UP:    if (sel_ > 0) sel_--; break;
    case K_DOWN:  if (sel_ + 1 < n) sel_++; break;
    case K_LEFT:  sel_ = sel_ > std::size_t(LIST_ROWS) ? sel_ - LIST_ROWS : 0; break;
    case K_RIGHT: if (n) sel_ = std::min(n - 1, sel_ + LIST_ROWS); break;
    case K_RETURN:
        if (!n) { msg_ = "NO DISK IMAGES HERE"; break; }
        if (entries_[sel_].name == ".." && entries_[sel_].dir) {
            const auto from = cwd_;
            const auto par = path_parent(cwd_);
            cwd_ = (par == "." || par == "/") ? std::string() : par;
            scan();
            for (std::size_t i = 0; i < entries_.size(); i++)
                if (entries_[i].dir && path_join(cwd_, entries_[i].name) == from) sel_ = i;
        } else if (entries_[sel_].dir) {
            cwd_ = path_join(cwd_, entries_[sel_].name);
            scan();
        } else if (entries_[sel_].hd) {
            choose_hd(false);
            return;
        } else {
            choose(false);
            return;
        }
        break;
    case K_TAB:
        if (n && !entries_[sel_].dir) {
            if (entries_[sel_].hd) choose_hd(true);
            else choose(true);
            return;
        }
        break;
    case K_ESC:
        leave();
        return;
    default: {
        // letter or digit: next entry starting with it
        const char c = char(std::tolower(key & 0x7F));
        if (!std::isalnum(static_cast<unsigned char>(c)) || !n) break;
        for (std::size_t k = 1; k <= n; k++) {
            const auto i = (sel_ + k) % n;
            if (!entries_[i].name.empty() && std::tolower(static_cast<unsigned char>(entries_[i].name[0])) == c) { sel_ = i; break; }
        }
    }
    }
    render();
}

void DiskMenu::choose(bool drive2) {
    const auto p = entry_path(sel_);
    const auto name = entries_[sel_].name;
    std::string err;
    if (!drive2) {
        if (mounted_path(1) == p) {          // the same image in both drives would fight over writes
            swap_(1, std::string(), err);
            settings_.set("disk2_image", "none");
        }
        if (!swap_(0, p, err)) { msg_ = err; render(); return; }
        settings_.set("disk1_image", p);
        settings_.set("boot_image", p);
        try { settings_.save(); } catch (...) {}
        std::cerr << "a2hostd: boot menu: drive 1 = " << p << ", booting\n";
        boot("BOOTING " + name);
        return;
    }
    if (mounted_path(1) == p) {
        if (swap_(1, std::string(), err)) { settings_.set("disk2_image", "none"); msg_ = "DRIVE 2 EJECTED"; }
        else msg_ = err;
    } else if (mounted_path(0) == p) {
        msg_ = "THAT DISK IS IN DRIVE 1";
    } else if (swap_(1, p, err)) {
        settings_.set("disk2_image", p);
        msg_ = "DRIVE 2: " + name;
        std::cerr << "a2hostd: boot menu: drive 2 = " << p << "\n";
    } else {
        msg_ = err;
    }
    try { settings_.save(); } catch (...) {}
    render();
}

// RETURN on a hard disk image: it goes in hard disk unit 1 (out of unit 2 if
// it was there) and the Apple boots the hard disk card. TAB: unit 2, or out of
// it, like floppy drive 2.
void DiskMenu::choose_hd(bool unit2) {
    const auto p = entry_path(sel_);
    const auto name = entries_[sel_].name;
    std::string err;
    if (!unit2) {
        const int slot = hdd_slot();
        if (!slot) { msg_ = "NO HARD DISK CARD IN THE SLOT MAP"; render(); return; }
        if (mounted_path(3) == p) {          // one image in both units would fight over writes
            swap_hdd_(1, std::string(), err);
            settings_.set("hdd2_image", "none");
        }
        if (mounted_path(2) != p && !swap_hdd_(0, p, err)) { msg_ = err; render(); return; }
        settings_.set("hdd1_image", p);
        settings_.set("boot_image", p);
        try { settings_.save(); } catch (...) {}
        std::cerr << "a2hostd: boot menu: hard disk 1 = " << p << ", booting slot " << slot << "\n";
        boot_hd("BOOTING " + name, slot);
        return;
    }
    if (mounted_path(3) == p) {
        if (swap_hdd_(1, std::string(), err)) { settings_.set("hdd2_image", "none"); msg_ = "HARD DISK 2 EJECTED"; }
        else msg_ = err;
    } else if (mounted_path(2) == p) {
        msg_ = "THAT DISK IS HARD DISK 1";
    } else if (swap_hdd_(1, p, err)) {
        settings_.set("hdd2_image", p);
        msg_ = "HARD DISK 2: " + name;
        std::cerr << "a2hostd: boot menu: hard disk 2 = " << p << "\n";
    } else {
        msg_ = err;
    }
    try { settings_.save(); } catch (...) {}
    render();
}

// The slot the hard disk card answers in, from the FPGA's slot map (0 = none).
int DiskMenu::hdd_slot() const {
    for (int s = 1; s < 8; s++)
        if (spi_.reg_read(std::uint8_t(0x60 + s)) == HDD_CARD) return s;
    return 0;
}

void DiskMenu::banner_frame(const std::string& banner) {
    std::array<std::uint8_t, 1024> img;
    img.fill(0xA0);
    put(img, 0, 0, std::string(40, ' '), true);
    put(img, 0, 1, title(), true);
    const auto b = fit(banner, 40);
    put(img, 11, int(40 - b.size()) / 2, b, false);
    spi_.xfer_write(SPACE_MENU, SCREEN, img);
    frame_++;
    spi_.xfer_write(SPACE_MENU, MB_FRAME, span<const std::uint8_t>(&frame_, 1));
}

void DiskMenu::boot(const std::string& banner) {
    session_ = false;
    banner_frame(banner);
    const std::uint8_t cmd = 1;   // after the frame: the Apple draws it, then returns to the boot ROM
    spi_.xfer_write(SPACE_MENU, MB_CMD, span<const std::uint8_t>(&cmd, 1));
}

// Boot the hard disk card: CMD 2 makes the menu draw this frame and JMP ($Cn00)
// of the card, which reads block 0 of unit 1 and runs it, as PR#n does.
void DiskMenu::boot_hd(const std::string& banner, int slot) {
    session_ = false;
    banner_frame(banner);
    const std::uint8_t t[2] = {0x00, std::uint8_t(0xC0 | (slot & 7))};
    spi_.xfer_write(SPACE_MENU, MB_TARGET, span<const std::uint8_t>(t, 2));
    const std::uint8_t cmd = 2;
    spi_.xfer_write(SPACE_MENU, MB_CMD, span<const std::uint8_t>(&cmd, 1));
}

// ESC: no boot. The Apple clears its screen and goes where Ctrl-Reset would,
// which after power-up is the BASIC prompt (PR#n brings the menu back).
void DiskMenu::leave() {
    session_ = false;
    const std::uint8_t cmd = 3;
    spi_.xfer_write(SPACE_MENU, MB_CMD, span<const std::uint8_t>(&cmd, 1));
    std::cerr << "a2hostd: boot menu: ESC, left without booting\n";
}

// The title names the card's slot, with DISK when the Disk II answers there
// too: "SLOT 6 DISK MENU". With the card in slots 1-3 the Disk II can't follow
// it (it stays in slot 6): "SLOT 3 MENU".
std::string DiskMenu::title() const {
    if (card_slot_ && card_slot_ != menu_slot_) return "SLOT " + std::to_string(card_slot_) + " MENU";
    return "SLOT " + std::to_string(menu_slot_) + " DISK MENU";
}

void DiskMenu::put(std::array<std::uint8_t, 1024>& img, int row, int col, const std::string& s, bool inverse) const {
    for (std::size_t i = 0; i < s.size() && col + int(i) < 40; i++)
        img[std::size_t(row_off(row) + col) + i] = inverse ? scr_inverse(s[i]) : scr_normal(s[i]);
}

void DiskMenu::render() {
    std::array<std::uint8_t, 1024> img;
    img.fill(0xA0);
    const auto d1 = mounted_path(0), d2 = mounted_path(1), h1 = mounted_path(2), h2 = mounted_path(3);
    auto shown = [](const std::string& p, std::size_t n) { return fit(p.empty() ? "(EMPTY)" : path_filename(p), n); };
    put(img, 0, 0, std::string(40, ' '), true);
    put(img, 0, 1, title(), true);
    put(img, 1, 0, "DRIVE 1: " + shown(d1, 31), false);
    put(img, 2, 0, "DRIVE 2: " + shown(d2, 31), false);
    put(img, 3, 0, "HARD DISK 1: " + shown(h1, 27), false);
    put(img, 4, 0, "HARD DISK 2: " + shown(h2, 27), false);
    const std::size_t n = entries_.size();
    if (!msg_.empty()) {
        put(img, 5, 0, fit(upper(msg_), 40), true);
    } else if (session_ && timeout_s_ > 0 && !touched_ && !d1.empty()) {
        const int left = shown_left_ > 0 ? shown_left_ : timeout_s_;
        put(img, 5, 0, "DRIVE 1 BOOTS IN " + std::to_string(left) + "  (ANY KEY WAITS)", false);
    } else {
        const auto count = n ? std::to_string(sel_ + 1) + "/" + std::to_string(n) : std::string("0");
        put(img, 5, 0, fit(path_join(root_, cwd_) + "/", 39 - count.size()), false);
        put(img, 5, int(40 - count.size()), count, false);
    }
    if (sel_ < top_) top_ = sel_;
    if (sel_ >= top_ + LIST_ROWS) top_ = sel_ - LIST_ROWS + 1;
    if (!n) put(img, LIST_ROW + 1, 2, "(NO DISK IMAGES IN THIS FOLDER)", false);
    for (int r = 0; r < LIST_ROWS && top_ + r < n; r++) {
        const auto i = top_ + std::size_t(r);
        const auto& e = entries_[i];
        std::string line = "  ";
        if (!e.dir) {                          // 1/2: in floppy drive 1/2, or hard disk 1/2
            const auto p = entry_path(i);
            if (p == (e.hd ? h1 : d1)) line[0] = '1';
            else if (p == (e.hd ? h2 : d2)) line[0] = '2';
        }
        if (e.dir) line += fit(e.name + "/", 38);
        else if (e.hd) { line += fit(e.name, 35); line.resize(38, ' '); line += "HD"; }
        else line += fit(e.name, 38);
        if (i == sel_) line.resize(40, ' ');
        put(img, LIST_ROW + r, 0, line, i == sel_);
    }
    put(img, 22, 0, "RETURN:BOOT  TAB:DRIVE 2  ESC:EXIT", false);
    put(img, 23, 0, "IN GAME: BOARD KEY1=NEXT KEY2=PREV DISK", false);
    spi_.xfer_write(SPACE_MENU, SCREEN, img);
    frame_++;
    spi_.xfer_write(SPACE_MENU, MB_FRAME, span<const std::uint8_t>(&frame_, 1));
}
}  // namespace a2
