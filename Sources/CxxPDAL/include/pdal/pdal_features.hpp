/*
 * pdal_features.hpp.in is used by cmake to generate pdal_features.hpp
 *
 * Do not edit pdal_features.hpp
 *
 */
#pragma once

#include <string>

/*
 * version settings
 */
#define PDAL_VERSION_MAJOR 2
#define PDAL_VERSION_MINOR 9
#define PDAL_VERSION_PATCH 2

namespace pdal
{

const int pdalVersionMajor { 2 };
const int pdalVersionMinor { 9 };
const int pdalVersionPatch { 2 };
const std::string pdalVersion { "2.9.2" };
const std::string pdalSha { "3c406112187072c75d6432760df6b263dd098165" };

} // namespace pdal

#define PDAL_PLUGIN_INSTALL_PATH "lib"
/*
 * availability of 3rd-party libraries
 */
/* #undef PDAL_HAVE_HDF5 */
/* #undef PDAL_HAVE_ZSTD */
#define PDAL_HAVE_ZLIB
/* #undef PDAL_HAVE_LZMA */
#define PDAL_HAVE_LIBXML2
#define PDAL_LAS_START

/*
 * Debug or Release build?
 */
#define PDAL_BUILD_TYPE "Release"

/*
 * built pdal app as application bundle on OSX?
 */
/* #undef PDAL_APP_BUNDLE */


