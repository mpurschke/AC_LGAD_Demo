# make          native build (zdaq_server, zdaq_client), for tests on a PC
# make arm      zdaq_server.arm and zdaq_client.arm for the Zynq, static, with the
#               ARM cross compiler (default: the one that comes with Vitis)

CXXFLAGS = -std=c++20 -O2 -Wall -Wextra
ARM_CXX ?= $(shell command -v arm-linux-gnueabihf-g++ 2>/dev/null || \
             echo /data/purschke/vivado_2024.2/Vitis/2024.2/gnu/aarch32/lin/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-g++)

SERVER = zdaq_server.cc net.cc sim_source.cc
CLIENT = zdaq_client.cc net.cc
HEADERS = protocol.h net.h data_source.h sim_source.h

all: zdaq_server zdaq_client

zdaq_server: $(SERVER) $(HEADERS)
	$(CXX) $(CXXFLAGS) -o $@ $(SERVER)

zdaq_client: $(CLIENT) $(HEADERS)
	$(CXX) $(CXXFLAGS) -o $@ $(CLIENT)

arm: zdaq_server.arm zdaq_client.arm

zdaq_server.arm: $(SERVER) $(HEADERS)
	$(ARM_CXX) $(CXXFLAGS) -static -o $@ $(SERVER)

zdaq_client.arm: $(CLIENT) $(HEADERS)
	$(ARM_CXX) $(CXXFLAGS) -static -o $@ $(CLIENT)

clean:
	rm -f zdaq_server zdaq_client zdaq_server.arm zdaq_client.arm

.PHONY: all arm clean
