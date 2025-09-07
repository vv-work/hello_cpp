cmake_minimum_required(VERSION 3.15)
project(hello_opengl)

find_package(glfw3 3.3 REQUIRED)

add_executable(hello_gl main.cpp)
target_link_libraries(hello_gl PRIVATE glfw)

if (APPLE)
  target_link_libraries(hello_gl PRIVATE "-framework OpenGL")
endif()
