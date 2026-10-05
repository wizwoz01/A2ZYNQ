/*
 * cardtest.c -- checks the A2Zynq virtual cards in slots 2-7 on a real Apple II.
 *
 * Built for the plain 6502 (my IIe is unenhanced) as a ProDOS SYSTEM
 * program; mkdisks.py puts it on "CardTest.dsk" and on the hard disk image
 * "hdd1.po". It finds the Disk II and hard disk slots from their ROMs (they
 * move with the card), tests each card's registers, plays a tone on every
 * sound chip, shows a SuperSprite picture, writes and reads back a file on
 * the boot disk, and saves everything it printed to CARDTEST.LOG.
 */
#include <stdio.h>
#include <errno.h>
#include <stdarg.h>
#include <string.h>
#include <conio.h>
#include <dio.h>
#include <device.h>
#include <apple2.h>

unsigned char __fastcall__ io_rd(unsigned addr);
void __fastcall__ io_wr(unsigned addr, unsigned char value);
void __fastcall__ delay_ms(unsigned ms);

#define DEVSEL(s) (0xC080u + (s) * 16u)     /* $C0n0, n = slot + 8 */
#define SLOTROM(s) (0xC000u + (s) * 256u)   /* $Cn00 */

static char logbuf[3500];
static unsigned loglen;
static unsigned char fails, warns;
static char line[100];                /* say() formats here */
static char msg[80];                  /* messages for check()/warn() */
static unsigned char buf[512], buf2[512];

/* print to the screen and keep a copy for CARDTEST.LOG */
static void say(const char *fmt, ...)
{
    va_list ap;
    unsigned n;
    va_start(ap, fmt);
    vsprintf(line, fmt, ap);
    va_end(ap);
    printf("%s\n", line);
    n = strlen(line);
    if (loglen + n + 2 < sizeof logbuf) {
        memcpy(logbuf + loglen, line, n);
        loglen += n;
        logbuf[loglen++] = '\r';
    }
}

static void check(unsigned char ok, const char *what)
{
    say(ok ? " OK   %s" : " FAIL %s", what);
    if (!ok) ++fails;
}

static void warn(const char *what)
{
    say(" NOTE %s", what);
    ++warns;
}

/* ---- slot 2: Super Serial Card (6551 ACIA, firmware ROM) ---- */
static void test_ssc(void)
{
    unsigned b = DEVSEL(2), r = SLOTROM(2);
    unsigned char c, k, st;
    unsigned i;
    say("SLOT 2  SUPER SERIAL CARD");
    check(io_rd(r + 5) == 0x38 && io_rd(r + 7) == 0x18 && io_rd(r + 0x0B) == 0x01 && io_rd(r + 0x0C) == 0x31,
          "FIRMWARE ROM ID");
    sprintf(msg, "DIP SWITCHES SW1=%02X SW2=%02X", io_rd(b + 1), io_rd(b + 2));
    say(" INFO %s", msg);
    io_wr(b + 9, 0);                         /* programmed reset */
    io_wr(b + 0x0B, 0x1E);                   /* 9600 baud, 8N1 */
    io_wr(b + 0x0A, 0x0B);                   /* no parity, DTR on, IRQs off */
    c = io_rd(b + 0x0B);
    k = io_rd(b + 0x0A);
    sprintf(msg, "ACIA CONTROL/COMMAND READ BACK (%02X %02X)", c, k);
    check(c == 0x1E && k == 0x0B, msg);
    io_wr(b + 0x0B, 0x1F);
    io_wr(b + 0x0A, 0x09);
    c = io_rd(b + 0x0B);
    k = io_rd(b + 0x0A);
    sprintf(msg, "SECOND PATTERN READ BACK (%02X %02X)", c, k);
    check(c == 0x1F && k == 0x09, msg);
    st = io_rd(b + 9);
    sprintf(msg, "TRANSMITTER READY (STATUS %02X)", st);
    check(st & 0x10, msg);
    io_wr(b + 8, 'A');
    for (i = 0; i < 50; ++i) {               /* one byte at 9600 baud is ~1 ms */
        if (io_rd(b + 9) & 0x10) break;
        delay_ms(1);
    }
    check(i < 50, "SENDS A BYTE");
    warn("RECEIVE NOT TESTABLE: NO SERIAL WIRING");
    io_wr(b + 9, 0);
}

/* ---- slot 3: Uthernet II (W5100, indirect mode) ---- */
static void w_addr(unsigned a)
{
    io_wr(DEVSEL(3) + 5, a >> 8);
    io_wr(DEVSEL(3) + 6, a & 0xFF);
}

static void test_uthernet(void)
{
    unsigned b = DEVSEL(3), a;
    unsigned char mr, i, bad = 0;
    say("SLOT 3  UTHERNET II");
    mr = io_rd(b + 4);
    io_wr(b + 4, 0x03);                      /* indirect bus, auto-increment */
    check(io_rd(b + 4) == 0x03, "MODE REGISTER");
    w_addr(0x4000);                          /* socket 0 TX buffer */
    for (i = 0; i < 64; ++i) io_wr(b + 7, (unsigned char)(i * 13 + 7));
    a = (io_rd(b + 5) << 8) | io_rd(b + 6);
    sprintf(msg, "ADDRESS AUTO-INCREMENT (%04X)", a);
    check(a == 0x4040, msg);
    w_addr(0x4000);
    for (i = 0; i < 64; ++i)
        if (io_rd(b + 7) != (unsigned char)(i * 13 + 7)) ++bad;
    sprintf(msg, "BUFFER WRITE/READ 64 BYTES (%u BAD)", bad);
    check(bad == 0, msg);
    w_addr(0x0009);
    sprintf(msg, "MAC %02X:%02X:%02X:%02X:%02X:%02X", io_rd(b + 7), io_rd(b + 7), io_rd(b + 7),
            io_rd(b + 7), io_rd(b + 7), io_rd(b + 7));
    say(" INFO %s", msg);
    io_wr(b + 4, mr & 0x7F);
}

/* ---- Mockingboard: two 6522 VIAs, each driving an AY-3-8910 ---- */
static unsigned via;                         /* $Cn00 left, $Cn80 right */

static void psg_wr(unsigned char reg, unsigned char v)
{
    io_wr(via + 1, reg); io_wr(via + 0, 7); io_wr(via + 0, 4);
    io_wr(via + 1, v);   io_wr(via + 0, 6); io_wr(via + 0, 4);
}

static unsigned char psg_rd(unsigned char reg)
{
    unsigned char v;
    io_wr(via + 1, reg); io_wr(via + 0, 7); io_wr(via + 0, 4);
    io_wr(via + 3, 0x00);                    /* port A in */
    io_wr(via + 0, 5);
    v = io_rd(via + 1);
    io_wr(via + 0, 4);
    io_wr(via + 3, 0xFF);
    return v;
}

static void test_mockingboard(unsigned char slot)
{
    unsigned char side, h1, h2, c, k;
    unsigned i;
    say("SLOT %u  MOCKINGBOARD", slot);
    for (side = 0; side < 2; ++side) {
        const char *nm = side ? "RIGHT" : "LEFT";
        via = SLOTROM(slot) + side * 0x80u;
        io_wr(via + 3, 0x5A);
        io_wr(via + 2, 0xA5);
        c = io_rd(via + 3);
        k = io_rd(via + 2);
        sprintf(msg, "%s 6522 DDR READ BACK (%02X %02X)", nm, c, k);
        check(c == 0x5A && k == 0xA5, msg);
        io_wr(via + 0x0E, 0x7F);             /* no interrupts */
        io_wr(via + 0x0B, 0x00);             /* T1 one-shot */
        io_wr(via + 6, 0xFF);
        io_wr(via + 5, 0xFF);                /* start T1 from $FFFF */
        h1 = io_rd(via + 5);
        delay_ms(3);
        h2 = io_rd(via + 5);
        sprintf(msg, "%s TIMER 1 COUNTS (%02X -> %02X)", nm, h1, h2);
        check(h1 != h2, msg);
        for (i = 0; i < 120 && !(io_rd(via + 0x0D) & 0x40); ++i) delay_ms(1);
        check(i < 120, side ? "RIGHT TIMER 1 TIMEOUT FLAG" : "LEFT TIMER 1 TIMEOUT FLAG");
        io_rd(via + 4);                      /* reading T1 low clears the flag */
        check(!(io_rd(via + 0x0D) & 0x40), side ? "RIGHT FLAG CLEARED BY READ" : "LEFT FLAG CLEARED BY READ");
        io_wr(via + 3, 0xFF);
        io_wr(via + 2, 0x07);
        io_wr(via + 0, 0); io_wr(via + 0, 4);  /* AY reset */
        psg_wr(2, 0x5A);
        psg_wr(7, 0x3E);
        c = psg_rd(2);
        k = psg_rd(7);
        sprintf(msg, "%s AY-3-8910 REGISTERS READ BACK (%02X %02X)", nm, c, k);
        check(c == 0x5A && k == 0x3E, msg);
    }
    say(" LISTEN: LOW TONE LEFT, THEN HIGH RIGHT");
    for (side = 0; side < 2; ++side) {
        via = SLOTROM(slot) + side * 0x80u;
        psg_wr(0, side ? 97 : 145);          /* 660 / 440 Hz at 1.02 MHz */
        psg_wr(1, 0);
        psg_wr(7, 0x3E);                     /* tone A only */
        psg_wr(8, 15);
        delay_ms(800);
        psg_wr(8, 0);
    }
}

/* ---- SuperSprite: TMS9918A (F18A) + AY-3-8910 ---- */
static unsigned ssb;

static void vdp_reg(unsigned char r, unsigned char v) { io_wr(ssb + 1, v); io_wr(ssb + 1, 0x80 | r); }
static void vdp_waddr(unsigned a) { io_wr(ssb + 1, a & 0xFF); io_wr(ssb + 1, ((a >> 8) & 0x3F) | 0x40); }
static void vdp_raddr(unsigned a) { io_wr(ssb + 1, a & 0xFF); io_wr(ssb + 1, (a >> 8) & 0x3F); }
static void ssp_psg_wr(unsigned char r, unsigned char v) { io_wr(ssb + 0x0E, r); io_wr(ssb + 0x0C, v); }
static unsigned char ssp_psg_rd(unsigned char r) { io_wr(ssb + 0x0E, r); return io_rd(ssb + 0x0E); }

static void test_supersprite(unsigned char slot)
{
    unsigned i, bad = 0, next = 0;
    unsigned char c;
    ssb = DEVSEL(slot);
    say("SLOT %u  SUPERSPRITE", slot);
    io_rd(ssb + 1);                          /* status read resets the address latch */
    vdp_reg(1, 0x80);                        /* 16K, display off */
    vdp_waddr(0x3800);
    for (i = 0; i < 256; ++i) io_wr(ssb, (unsigned char)(i * 7 + 0x35));
    vdp_raddr(0x3800);
    for (i = 0; i < 256; ++i) {
        c = io_rd(ssb);
        if (c != (unsigned char)(i * 7 + 0x35)) ++bad;
        if (c == (unsigned char)((i + 1) * 7 + 0x35)) ++next;
    }
    sprintf(msg, "VDP VIDEO RAM WRITE/READ 256 (%u BAD)", bad);
    check(bad == 0, msg);
    if (bad && next > bad / 2) warn("READS RETURN THE NEXT BYTE");
    io_rd(ssb + 1);
    for (i = 0; i < 100 && !(io_rd(ssb + 1) & 0x80); ++i) delay_ms(1);
    check(i < 100, "VDP FRAME FLAG (60 HZ)");
    ssp_psg_wr(2, 0xA5);
    ssp_psg_wr(7, 0x3E);
    c = ssp_psg_rd(2);
    sprintf(msg, "AY-3-8910 REGISTER READ BACK (%02X)", c);
    check(c == 0xA5, msg);

    /* picture: graphics I, a green block over the middle of the Apple screen */
    vdp_reg(0, 0x00);
    vdp_reg(2, 0x0E);                        /* names $3800 */
    vdp_reg(3, 0x80);                        /* colors $2000 */
    vdp_reg(4, 0x00);                        /* patterns $0000 */
    vdp_reg(5, 0x76);                        /* sprite attributes $3B00 */
    vdp_reg(6, 0x03);
    vdp_reg(7, 0x00);
    vdp_waddr(0x0000);
    for (i = 0; i < 16; ++i) io_wr(ssb, i < 8 ? 0x00 : 0xFF);   /* char 0 empty, char 1 solid */
    vdp_waddr(0x2000);
    for (i = 0; i < 32; ++i) io_wr(ssb, 0x30);                  /* light green on transparent */
    vdp_waddr(0x3B00);
    io_wr(ssb, 0xD0);                                           /* no sprites */
    vdp_waddr(0x3800);
    for (i = 0; i < 768; ++i) {
        unsigned char row = i / 32, col = i % 32;
        io_wr(ssb, (row >= 8 && row < 16 && col >= 8 && col < 24) ? 1 : 0);
    }
    io_wr(ssb + 6, 0);                       /* mix the VDP over the Apple picture */
    vdp_reg(1, 0xC0);                        /* display on */
    say(" LOOK: GREEN BOX MID-SCREEN FOR 3 SEC");
    say(" LISTEN: MIDDLE TONE (SUPERSPRITE)");
    ssp_psg_wr(0, 194);
    ssp_psg_wr(1, 0);
    ssp_psg_wr(7, 0x3E);
    ssp_psg_wr(8, 15);
    delay_ms(3000);
    ssp_psg_wr(8, 0);
    vdp_reg(1, 0x80);
    io_wr(ssb + 5, 0);                       /* Apple picture only */
}

/* ---- ProDOS block devices: Disk II and hard disk ---- */
static unsigned char is_disk2(unsigned char s)
{
    unsigned r = SLOTROM(s);
    return io_rd(r + 1) == 0x20 && io_rd(r + 3) == 0x00 && io_rd(r + 5) == 0x03 && io_rd(r + 0xFF) == 0x00;
}

static void test_devices(unsigned char disk_slot, unsigned char hdd_slot)
{
    unsigned char dev, s, d, err, e2, cmp, n, hd;
    unsigned blocks, k, j;
    dhandle_t h;
    char name[16];
    unsigned char seen_disk = 0, seen_hdd = 0;
    for (dev = getfirstdevice(); dev != INVALID_DEVICE; dev = getnextdevice(dev)) {
        s = dev & 7;
        d = ((dev >> 3) & 1) + 1;
        if (s != disk_slot && s != hdd_slot) continue;
        hd = (s == hdd_slot);
        if (hd) seen_hdd = 1; else seen_disk = 1;
        say("SLOT %u  %s DRIVE %u", s, hd ? "HARD DISK" : "DISK II", d);
        h = dio_open(dev);
        if (!h) {
            if (hd && d == 1) check(0, "OPEN FAILED");
            else warn("EMPTY");
            continue;
        }
        blocks = dio_query_sectcount(h);
        err = dio_read(h, 2, buf);
        if (err) {
            sprintf(msg, "READ BLOCK 2: ERROR %02X%s", err, hd && d == 2 ? " (NO 2ND IMAGE)" : "");
            if (hd && d == 1) check(0, msg); else warn(msg);
            dio_close(h);
            continue;
        }
        if ((buf[4] >> 4) == 0x0F) {
            n = buf[4] & 15;
            memcpy(name, buf + 5, n);
            name[n] = 0;
            sprintf(msg, "READ VOLUME /%s (%u BLOCKS)", name, blocks);
        } else {
            strcpy(name, "");
            sprintf(msg, "READ BLOCK 2 (NOT PRODOS, %u BLOCKS)", blocks);
        }
        check(1, msg);
        if (hd && d == 1) {                      /* raw look at what the card returns */
            sprintf(msg, "B2 %02X%02X %02X%02X %02X %02X%02X%02X%02X%02X%02X",
                    buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7], buf[8], buf[9], buf[10]);
            say(" INFO %s", msg);
            sprintf(msg, "B2+23 %02X %02X %02X%02X %02X%02X %02X%02X",
                    buf[0x23], buf[0x24], buf[0x25], buf[0x26], buf[0x27], buf[0x28], buf[0x29], buf[0x2A]);
            say(" INFO %s", msg);
            err = dio_read(h, 2, buf2);
            check(!err && memcmp(buf, buf2, 512) == 0, "BLOCK 2 READS THE SAME TWICE");
            strcpy(msg, "SUMS");
            for (k = 0; k < 8; ++k) {
                unsigned sum = 0;
                if (dio_read(h, k, buf2)) { strcat(msg, " ERR"); continue; }
                for (j = 0; j < 512; ++j) sum += buf2[j];
                sprintf(msg + strlen(msg), " %04X", sum);
            }
            say(" INFO %s", msg);
        }
        if (hd && strcmp(name, "HDTEST") == 0) {   /* our own image: write test on its last block */
            k = blocks - 1;
            e2 = 0;
            cmp = 0;
            err = dio_read(h, k, buf);               /* keep the old block */
            if (!err) {
                for (j = 0; j < 512; ++j) buf2[j] = (unsigned char)(j ^ 0x5A);
                err = dio_write(h, k, buf2);
                if (!err) {
                    memset(buf2, 0, sizeof buf2);
                    err = dio_read(h, k, buf2);
                    for (j = 0; j < 512 && !err; ++j)
                        if (buf2[j] != (unsigned char)(j ^ 0x5A)) cmp = 1;
                }
                e2 = dio_write(h, k, buf);           /* put the old block back */
            }
            sprintf(msg, "WRITE/READ BACK BLOCK %u (ERR %02X%s)", k, err ? err : e2, cmp ? ", MISMATCH" : "");
            check(!err && !e2 && !cmp, msg);
        }
        dio_close(h);
    }
    if (!seen_disk) { say("SLOT %u  DISK II", disk_slot); check(0, "NOT IN THE PRODOS DEVICE LIST"); }
    if (!seen_hdd) { say("SLOT %u  HARD DISK", hdd_slot); check(0, "NOT IN THE PRODOS DEVICE LIST"); }
}

/* write and read back a file on the boot volume (exercises the drive's writes) */
static void test_file(void)
{
    FILE *f;
    unsigned i, j, bad = 0;
    unsigned char ok = 0;
    say("BOOT DISK FILE TEST");
    _filetype = PRODOS_T_BIN;
    _auxtype = 0;
    f = fopen("WTEST", "wb");
    if (f) {
        for (j = 0; j < 16; ++j) {           /* 8 KB, over several tracks */
            for (i = 0; i < 512; ++i) buf[i] = (unsigned char)(i + j * 3);
            if (fwrite(buf, 1, 512, f) != 512) break;
        }
        ok = (j == 16);
        fclose(f);
    }
    sprintf(msg, ok ? "WRITE 8 KB FILE" : "WRITE 8 KB FILE (PRODOS ERROR $%02X)", _oserror);
    check(ok, msg);
    f = ok ? fopen("WTEST", "rb") : NULL;
    if (f) {
        for (j = 0; j < 16; ++j) {
            if (fread(buf, 1, 512, f) != 512) { bad = 9999; break; }
            for (i = 0; i < 512; ++i) if (buf[i] != (unsigned char)(i + j * 3)) ++bad;
        }
        fclose(f);
        sprintf(msg, "READ IT BACK (%u BAD BYTES)", bad);
        check(bad == 0, msg);
    }
    remove("WTEST");
}

int main(void)
{
    unsigned char s, disk_slot = 0, hdd_slot = 0, mb, ssp;
    FILE *f;
    clrscr();
    say("A2ZYNQ CARD TEST - SLOTS 2 TO 7");
    for (s = 4; s <= 7; ++s) if (is_disk2(s)) disk_slot = s;
    hdd_slot = disk_slot == 6 ? 5 : 6;
    mb = disk_slot == 4 ? 5 : 4;
    ssp = disk_slot == 7 ? 5 : 7;
    say("DISK II SLOT %u, HARD DISK SLOT %u", disk_slot, hdd_slot);
    test_ssc();
    test_uthernet();
    test_mockingboard(mb);
    test_devices(disk_slot, hdd_slot);
    test_supersprite(ssp);
    test_file();
    say("DONE: %u FAILED, %u NOTES", fails, warns);
    _filetype = PRODOS_T_TXT;
    _auxtype = 0;
    remove("CARDTEST.LOG");
    f = fopen("CARDTEST.LOG", "wb");
    if (f) {
        fwrite(logbuf, 1, loglen, f);
        fclose(f);
        printf("SAVED CARDTEST.LOG\n");
    } else {
        printf("COULD NOT SAVE CARDTEST.LOG ($%02X)\n", _oserror);
    }
    printf("PRESS A KEY");
    cgetc();
    return 0;
}
