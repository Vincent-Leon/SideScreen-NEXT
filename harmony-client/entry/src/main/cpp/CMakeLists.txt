cmake_minimum_required(VERSION 3.5.0)
project(SideScreenNext)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_compile_options(-Wall -fexceptions -fno-rtti)
add_definitions(-D_GNU_SOURCE)
set(CMAKE_CXX_STANDARD 17)

add_library(entry SHARED
    napi_init.cpp)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libnative_window.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
    libhilog_ndk.z.so)
