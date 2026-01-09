cmake_minimum_required(VERSION 3.16)
project(LiveMTRX-sdl LANGUAGES C OBJC)

set(CMAKE_C_STANDARD 11)
set(SOURCE_FILES
    src/main.c
    src/sim.c
    src/renderer.m
)

add_executable(${PROJECT_NAME} ${SOURCE_FILES})

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED sdl2)
include_directories(${SDL2_INCLUDE_DIRS} src)
link_directories(${SDL2_LIBRARY_DIRS})

if(APPLE)
    find_library(METAL_FRAMEWORK Metal)
    find_library(FOUNDATION_FRAMEWORK Foundation)
    find_library(QUARTZCORE_FRAMEWORK QuartzCore)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${SDL2_LIBRARIES} ${METAL_FRAMEWORK} ${FOUNDATION_FRAMEWORK} ${QUARTZCORE_FRAMEWORK})
else()
    target_link_libraries(${PROJECT_NAME} PRIVATE ${SDL2_LIBRARIES})
endif()

# Helpful compile flags for ObjC files
set_source_files_properties(src/renderer.m PROPERTIES LANGUAGE OBJC)

message(STATUS "SDL2 include: ${SDL2_INCLUDE_DIRS}")

# ---- Metal shaders offline compilation ----
set(SHADER_DIR ${CMAKE_SOURCE_DIR}/src/shaders)
set(SHADER_OUT_DIR ${CMAKE_BINARY_DIR}/shaders)
file(MAKE_DIRECTORY ${SHADER_OUT_DIR})

set(METAL_SOURCES
    ${SHADER_DIR}/glyph.vert.metal
    ${SHADER_DIR}/glyph.frag.metal
    ${SHADER_DIR}/bright_extract.metal
    ${SHADER_DIR}/blur_h.metal
    ${SHADER_DIR}/blur_v.metal
    ${SHADER_DIR}/phosphor.metal
    ${SHADER_DIR}/crt_final.metal
)

set(AIR_FILES "")
foreach(SRC ${METAL_SOURCES})
    get_filename_component(NAME ${SRC} NAME_WE)
    set(AIR ${SHADER_OUT_DIR}/${NAME}.air)
    add_custom_command(
        OUTPUT ${AIR}
        COMMAND xcrun -sdk macosx metal -c ${SRC} -o ${AIR}
        DEPENDS ${SRC}
        COMMENT "Compiling Metal shader ${SRC}"
        VERBATIM
    )
    list(APPEND AIR_FILES ${AIR})
endforeach()

set(METALLIB ${SHADER_OUT_DIR}/crt.metallib)
add_custom_command(
    OUTPUT ${METALLIB}
    COMMAND xcrun -sdk macosx metallib ${AIR_FILES} -o ${METALLIB}
    DEPENDS ${AIR_FILES}
    COMMENT "Linking Metal library ${METALLIB}"
    VERBATIM
)

add_custom_target(shaders ALL DEPENDS ${METALLIB})
add_dependencies(${PROJECT_NAME} shaders)

# Copy metallib next to the executable (simple, works with CMake builds)
add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${METALLIB} $<TARGET_FILE_DIR:${PROJECT_NAME}>/crt.metallib
    COMMENT "Copying crt.metallib to output dir"
)
