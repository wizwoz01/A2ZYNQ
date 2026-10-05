cmake_minimum_required(VERSION 3.5)
project(a2hostd LANGUAGES C CXX)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(a2hostd
  src/main.cpp src/spi_transport.cpp src/fpga_spi_compat.cpp
  src/disk_image.cpp src/gcr_dsk.c src/w5100.c src/w5100_linux.cpp
  src/settings.cpp src/gamepad.cpp src/network.cpp src/disk_menu.cpp)
target_include_directories(a2hostd PRIVATE include)
target_compile_options(a2hostd PRIVATE -Wall -Wextra -Wpedantic -Werror=return-type)
target_link_libraries(a2hostd PRIVATE pthread)
install(TARGETS a2hostd RUNTIME DESTINATION sbin)
