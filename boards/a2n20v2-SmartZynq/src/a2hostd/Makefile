CXX ?= g++
CXXFLAGS ?= -std=c++14 -O2 -Wall -Wextra -pthread
CFLAGS ?= -std=c11 -O2 -Wall -Wextra
INCLUDES := -Iinclude
SRCS_CXX := src/main.cpp src/spi_transport.cpp src/fpga_spi_compat.cpp \
	src/disk_image.cpp src/w5100_linux.cpp src/settings.cpp \
	src/gamepad.cpp src/network.cpp src/disk_menu.cpp
SRCS_C := src/gcr_dsk.c src/w5100.c
OBJS := $(SRCS_CXX:.cpp=.o) $(SRCS_C:.c=.o)

all: a2hostd

a2hostd: $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) -pthread

%.o: %.cpp
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c -o $@ $<

%.o: %.c
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<

clean:
	rm -f $(OBJS) a2hostd

.PHONY: all clean
