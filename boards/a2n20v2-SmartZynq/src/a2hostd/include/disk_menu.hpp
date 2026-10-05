#pragma once
#include "disk_image.hpp"
#include "settings.hpp"
#include "spi_transport.hpp"
#include <array>
#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace a2 {
// Disk II boot menu. The Disk II card's boot ROM calls a small 6502 program in
// its $C800 RAM (hdl/disk/diskmenu.a65, SPI space 4) that shows screens drawn
// here and forwards keys; this lists the disk images under the root folder,
// mounts the pick and tells the Apple to boot it. Floppies boot from the Disk
// II; hard disk images go in the hard disk card's unit 1 and the menu jumps to
// that card's $Cn00 (the hard disk is never booted by the power-up scan).
class DiskMenu {
public:
    // Swap floppy drive 0/1, or hard disk unit 0/1, to `path` (empty = eject).
    // Returns false with `err` set.
    using SwapFn = std::function<bool(int drive, const std::string& path, std::string& err)>;
    // Called on each hello with the slot the menu runs from. Returns true when
    // it is resetting the Apple to move the Disk II to the card's slot (the
    // menu then comes back from the new slot); it calls arm_restart(new_slot)
    // while the Apple is held in reset, so a reset that does not take still
    // ends up booting the new slot. May set a notice for the menu. Sets
    // card_slot to the card's physical slot (0 = unknown) for the title.
    using SlotFn = std::function<bool(int menu_slot, const std::function<void(int)>& arm_restart, std::string& notice, int& card_slot)>;
    DiskMenu(SpiTransport& spi, DriveManager& dm, Settings& settings, std::string root, SwapFn swap, SwapFn swap_hdd, SlotFn slot);
    void start();   // load the 6502 code, reset the mailbox, publish the magic
    void stop();    // withdraw the magic: the boot ROM boots straight through
    void poll();    // main loop: answer the Apple
    // The disk a mid-game swap puts in the drive after `cur` (step +1) or
    // before it (-1): the other disks of the same set (names that differ only
    // near the end: ultima31/ultima32, OREGON_A/OREGON_B, "... Disk 1 of 3"),
    // or every image in the folder when there is no set. Empty if none.
    std::string sibling(const std::string& cur, int step) const;

private:
    struct Entry { std::string name; bool dir; bool hd; };
    void on_hello();
    void on_key(std::uint8_t key);
    void scan();
    void render();
    void boot(const std::string& banner);
    void boot_hd(const std::string& banner, int slot);
    void banner_frame(const std::string& banner);
    int hdd_slot() const;
    void leave();
    std::string title() const;
    void put(std::array<std::uint8_t, 1024>& img, int row, int col, const std::string& s, bool inverse) const;
    std::string mounted_path(int drive) const;
    std::string entry_path(std::size_t i) const;
    void select_path(const std::string& path);
    void choose(bool drive2);
    void choose_hd(bool unit2);

    SpiTransport& spi_;
    DriveManager& dm_;
    Settings& settings_;
    std::string root_;
    SwapFn swap_;
    SwapFn swap_hdd_;
    SlotFn slot_;
    int menu_slot_{5};
    int card_slot_{0};             // the card's physical slot at the last hello (0 = unknown)
    bool enabled_{false};
    int last_seq_{-1};
    std::uint8_t frame_{0};
    // session
    std::string cwd_;              // folder shown, relative to root_
    std::vector<Entry> entries_;
    std::size_t sel_{0}, top_{0};
    std::string msg_;
    bool touched_{false};          // a key was pressed this session (stops the auto-boot countdown)
    int timeout_s_{0};
    int shown_left_{-1};
    std::chrono::steady_clock::time_point hello_at_;
    bool session_{false};
};
}
