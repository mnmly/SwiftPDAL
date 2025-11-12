//
//  pdal_wrapper.h
//  PDAL-Swift
//
//  Created by HIROAKI YAMANE on 08/04/2025.
//

#ifndef PDAL_WRAPPER_H
#define PDAL_WRAPPER_H


#include <stddef.h> // For size_t
#include <stdint.h>
#include <stdbool.h> // For bool type
#include <string>
#include "pdal_common.h"
#include "pdal/Dimension.hpp"
#include "pdal/util/Bounds.hpp"

// Dimension flags to indicate which fields are available
#define PDAL_DIM_X                  (1 << 0)  // 0x0001
#define PDAL_DIM_Y                  (1 << 1)  // 0x0002
#define PDAL_DIM_Z                  (1 << 2)  // 0x0004
#define PDAL_DIM_RED                (1 << 3)  // 0x0008
#define PDAL_DIM_GREEN              (1 << 4)  // 0x0010
#define PDAL_DIM_BLUE               (1 << 5)  // 0x0020
#define PDAL_DIM_INTENSITY          (1 << 6)  // 0x0040
#define PDAL_DIM_RETURN_NUMBER      (1 << 7)  // 0x0080
#define PDAL_DIM_NUMBER_OF_RETURNS  (1 << 8)  // 0x0100
#define PDAL_DIM_CLASSIFICATION     (1 << 9)  // 0x0200
#define PDAL_DIM
#define PDAL_DIM_EDGE_OF_FLIGHT     (1 << 11) // 0x0800
#define PDAL_DIM_SCAN_ANGLE         (1 << 12) // 0x1000
#define PDAL_DIM_USER_DATA          (1 << 13) // 0x2000
#define PDAL_DIM_POINT_SOURCE_ID    (1 << 14) // 0x4000
#define PDAL_DIM_GPS_TIME           (1 << 15) // 0x8000

typedef struct {
    pdal::Dimension::Type sourceType;
    std::string name;
    size_t outputSize;
    size_t offset;
} PDALDimensionInfo;

// Opaque pointer type for PDAL Pipeline (C doesn't have classes directly)
typedef void* PDALPipeline;

// Function to create a PDAL Pipeline
PDALPipeline pdal_pipeline_create();

// Function to parse a PDAL JSON pipeline string
int pdal_pipeline_parse_json(PDALPipeline pipeline, const char* json_string);

// Function to execute the PDAL Pipeline
int pdal_pipeline_execute(PDALPipeline pipeline);

// Function to get metadata as a JSON string (needs buffer management)
int pdal_pipeline_get_metadata_json(PDALPipeline pipeline, char* buffer, size_t buffer_size);

// New function to read LAS file and extract points as separate arrays
int pdal_read_binary(const std::string& reader_name_backup, const std::string& filename, const char** outData, size_t* outSize, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox);

void pdal_free_data(const char* data, PDALDimensionInfo* dimList);

// ============================================================================
// STREAMING API
// ============================================================================

// Structure representing a chunk of point data during streaming
typedef struct {
    const char* data;           // Pointer to chunk data (temporary, valid only during callback)
    size_t pointCount;          // Number of points in this chunk
    size_t stride;              // Bytes per point
    bool isComplete;            // True if this is the final chunk
    size_t totalPointsSoFar;    // Total points delivered so far (including this chunk)
    size_t estimatedTotalPoints;// Estimated total (0 if unknown)
} ChunkData;


// Opaque pointer to a PointView (for reusing loaded point data)
typedef void* PDALPointViewPtr;

// Load file info and retain the PointViewPtr for later streaming
// Returns 0 on success, negative error code on failure
// IMPORTANT: You must call pdal_free_point_view() when done to free the PointViewPtr
int pdal_load_info(const std::string& reader_name_backup, const std::string& filename, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox, PDALPointViewPtr* outView);


// C-compatible callback function type for streaming chunks with context pointer
// Returns: true to continue loading, false to cancel
// Using raw parameters instead of ChunkData struct for Swift @convention(c) compatibility
// Note: Dimension info is retrieved separately via context, not passed in each callback
typedef bool (*ProgressCallback)(const char* data,
                                  size_t pointCount,
                                  size_t stride,
                                  bool isComplete,
                                  size_t totalPointsSoFar,
                                  size_t estimatedTotalPoints,
                                  void* context);

// Streaming reader function - calls callback for each chunk of points
// Parameters:
//   reader_name_backup: Fallback reader name if inference fails
//   filename: Path to point cloud file
//   chunkSize: Number of points per chunk (e.g., 10000)
//   onChunk: Callback function called for each chunk
//   bbox: Output parameter for bounds
// Returns: 0 on success, negative error code on failure
int pdal_read_binary_stream_progressive(
    const std::string& reader_name_backup,
    const std::string& filename,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    PDALBounds& bbox);

// Streaming reader that reuses a pre-loaded PointViewPtr from pdal_load_info
// This avoids re-reading the file - use this after calling pdal_load_info
// Parameters:
//   view: PointViewPtr obtained from pdal_load_info
//   chunkSize: Number of points per chunk (e.g., 10000)
//   onChunk: Callback function called for each chunk
//   context: User context pointer passed to callback
// Returns: 0 on success, negative error code on failure
int pdal_read_binary_stream_from_view(
    PDALPointViewPtr view,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context);

// Free a PointViewPtr obtained from pdal_load_info
void pdal_free_point_view(PDALPointViewPtr view);

// Function to destroy the PDAL Pipeline and release resources
void pdal_pipeline_destroy(PDALPipeline pipeline);


#endif // PDAL_WRAPPER_H
