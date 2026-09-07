cmake_minimum_required(VERSION 3.21)

project(logos_apk_check VERSION 0.1 LANGUAGES CXX)

find_package(Qt6 6.11 REQUIRED COMPONENTS Gui Qml Quick)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(logos_apk_check main.cpp)

qt_add_qml_module(logos_apk_check
    URI LogosApkCheck
    VERSION 1.0
    QML_FILES Main.qml
)

target_link_libraries(logos_apk_check PRIVATE Qt6::Gui Qt6::Quick)

set_target_properties(logos_apk_check PROPERTIES
    QT_ANDROID_PACKAGE_NAME "io.logos.apkcheck"
    QT_ANDROID_VERSION_CODE 1
)
