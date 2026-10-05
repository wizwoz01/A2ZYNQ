#include "fpga_spi_compat.hpp"
#include "fpga_spi.h"
#include "spi_transport.hpp"
#include <stdexcept>
namespace { a2::SpiTransport* g_spi=nullptr; a2::SpiTransport& spi(){if(!g_spi)throw std::runtime_error("FPGA SPI transport not bound");return *g_spi;} }
namespace a2 { void bind_fpga_spi_transport(SpiTransport*p){g_spi=p;} }
extern "C" uint8_t fpga_spi_reg_read(uint8_t r){return spi().reg_read(r);}
extern "C" void fpga_spi_reg_write(uint8_t r,uint8_t v){spi().reg_write(r,v);}
extern "C" void fpga_spi_xfer_write(uint8_t s,uint32_t a,const uint8_t*d,uint16_t n){spi().xfer_write(s,a,a2::span<const uint8_t>(d,n));}
extern "C" void fpga_spi_xfer_read(uint8_t s,uint32_t a,uint8_t*d,uint16_t n){spi().xfer_read(s,a,a2::span<uint8_t>(d,n));}
