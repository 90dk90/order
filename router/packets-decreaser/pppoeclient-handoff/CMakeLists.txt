# SPDX-License-Identifier: Apache-2.0
# Out-of-tree Digi build for Hi-Jiajun pppoeclient + soft-handoff (Option B).
#
# On Digi (vpp-dev 26.06-release):
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j$(nproc)
# Artifact: build/lib/x86_64-linux-gnu/vpp_plugins/pppoeclient_plugin.so
#
# DO NOT install/restart VPP without explicit approval (flaps Digi PPPoE).
cmake_minimum_required(VERSION 3.16 FATAL_ERROR)
project(pppoeclient-pd-handoff C)

find_package(VPP REQUIRED)

# Keep build artifacts inside the build tree (VPP cmake defaults can
# otherwise land .so under /vpp_plugins when CMAKE_LIBRARY_OUTPUT_DIRECTORY
# is unset). Never install into Digi's live plugin path from this script.
if(NOT CMAKE_LIBRARY_OUTPUT_DIRECTORY)
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
endif()
if(NOT CMAKE_RUNTIME_OUTPUT_DIRECTORY)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
endif()

# <pppoeclient/...> resolves to ./pppoeclient/ sources and to generated
# API headers under ${CMAKE_CURRENT_BINARY_DIR}/pppoeclient/.
include_directories(${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${CMAKE_CURRENT_BINARY_DIR})

add_vpp_plugin(pppoeclient
  SOURCES
    pppoeclient/node.c
    pppoeclient/pppoeclient.c
    pppoeclient/pppoeclient_api.c
    pppoeclient/pppox/cli.c
    pppoeclient/pppox/node.c
    pppoeclient/pppox/pppox.c
    pppoeclient/pppox/pppox_api.c
    pppoeclient/pppox/pppd/auth.c
    pppoeclient/pppox/pppd/ccp.c
    pppoeclient/pppox/pppd/chap-md5.c
    pppoeclient/pppox/pppd/chap-new.c
    pppoeclient/pppox/pppd/ecp.c
    pppoeclient/pppox/pppd/fsm.c
    pppoeclient/pppox/pppd/ipcp.c
    pppoeclient/pppox/pppd/ipv6cp.c
    pppoeclient/pppox/pppd/lcp.c
    pppoeclient/pppox/pppd/magic.c
    pppoeclient/pppox/pppd/md5.c
    pppoeclient/pppox/pppd/options.c
    pppoeclient/pppox/pppd/sys-vpp.c
    pppoeclient/pppox/pppd/upap.c
    pppoeclient/pppox/pppd/utils.c

  API_FILES
    pppoeclient/pppoeclient.api
    pppoeclient/pppox/pppox.api

  INSTALL_HEADERS
    pppoeclient/pppoeclient.h
    pppoeclient/pppoeclient_error.def
)
