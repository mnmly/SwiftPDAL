//
//  pdal_wrapper.cpp
//  PDAL-Swift
//
//  Created by HIROAKI YAMANE on 08/04/2025.
//

// pdal_wrapper.cpp
#include "include/pdal_wrapper.h"

#include <cstdlib>
#include <unistd.h>

// Platform-specific includes
#if defined(PDAL_IOS)
// iOS minimal implementation
#include <vector>
#include <algorithm>
#include <cstring>
#include <limits>
// iOS version doesn't include full PDAL
#else
// macOS full implementation
#include <pdal/PipelineManager.hpp>
#include <pdal/PipelineWriter.hpp>
#include <pdal/PDALUtils.hpp>
#include <pdal/StageFactory.hpp>
#include <pdal/PointTable.hpp>
#include <pdal/PointView.hpp>
#include <pdal/Options.hpp>
#include <pdal/Dimension.hpp>
#include <sstream>
#include <cstring>
#include <vector>
#include <algorithm>
#include <limits>

using namespace pdal;
#endif

// Defined in pdal_static_plugins.cpp. Referencing it here (a TU that
// the Swift side reaches via every public entry point) keeps the
// anchor TU linked into CxxPDAL.a, which in turn forces ld to pull
// each anchored stage's `.o` out of libpdalcpp.a on iOS. See
// pdal_static_plugins.cpp for the full rationale.
namespace swiftpdal { void ensureStaticPluginsLinked(); }
namespace {
struct StaticPluginAnchor {
    StaticPluginAnchor() { swiftpdal::ensureStaticPluginsLinked(); }
};
static StaticPluginAnchor g_staticPluginAnchor;
} // namespace

PDALPipeline pdal_pipeline_create() {
    return static_cast<PDALPipeline>(new pdal::PipelineManager());
}

int pdal_pipeline_parse_json(PDALPipeline pipeline_ptr, const char* json_string) {
    if (!pipeline_ptr || !json_string) return PDAL_ERR_NOT_IMPLEMENTED; 

    pdal::PipelineManager* pipeline = static_cast<pdal::PipelineManager*>(pipeline_ptr);
    std::stringstream ss(json_string);
    try {
        pipeline->readPipeline(ss);
        return 0; // Success
    } catch (const pdal_error& e) {
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}

int pdal_pipeline_execute(PDALPipeline pipeline_ptr) {
    if (!pipeline_ptr) return PDAL_ERR_NOT_IMPLEMENTED;

    pdal::PipelineManager* pipeline = static_cast<pdal::PipelineManager*>(pipeline_ptr);
    try {
        pipeline->execute();
        return 0; // Success
    } catch (const pdal_error& e) {
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}

int pdal_pipeline_get_metadata_json(PDALPipeline pipeline_ptr, char* buffer, size_t buffer_size) {
    if (!pipeline_ptr || !buffer || buffer_size == 0) return PDAL_ERR_NOT_IMPLEMENTED;

    pdal::PipelineManager* pipeline = static_cast<pdal::PipelineManager*>(pipeline_ptr);
    std::stringstream ss;
    try {
        MetadataNode root = pipeline->getMetadata().clone("metadata");
        Utils::toJSON(root, ss);
        std::string metadata_json = ss.str();

        if (metadata_json.length() + 1 > buffer_size) {
            return PDAL_ERR_STD_EXCEPTION; // Buffer too small
        }
        strcpy(buffer, metadata_json.c_str());
        return 0; // Success
    } catch (const pdal_error& e) {
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}

void pdal_free_data(const char* data, PDALDimensionInfo* dimList, size_t dimCount) {
    if (data) free(const_cast<char*>(data));
    if (dimList) {
        for (size_t i = 0; i < dimCount; i++) {
            free((void*)dimList[i].name);  // Free each string
        }
        delete[] dimList;
    }
}

static std::string resolveDimension(const DimensionMap& mappings, const std::string& standardName) {
    for (const auto& pair : mappings) {
        if (strcasecmp(pair.second.c_str(), standardName.c_str()) == 0) {
            return pair.first;
        }
    }
    return standardName;
}

static Stage* createConfiguredStage(
    const std::string& reader_name_backup,
    const std::string& filename,
    StageFactory& factory,
    Stage** outFilter,
    Stage** outFlipFilter,
    const DimensionMap& dimensionMap = {},
    bool applyTransformation = true)
{
    // 1. Resolve Reader
    std::string inferredReaderName = factory.inferReaderDriver(filename);
    std::string reader_name = (filename.ends_with(".pts")) ? "readers.text" :
                              (!inferredReaderName.empty() ? inferredReaderName : reader_name_backup);

    Stage* reader = factory.createStage(reader_name);
    if (!reader) return nullptr;

    // 2. Configure Reader Options
    Options options;
    options.add("filename", filename);
    if (filename.ends_with(".xyz")) {
        options.add("skip", 0);
        options.add("separator", " ");
        options.add("header", "X Y Z Red Green Blue");
    } else if (filename.ends_with(".pts")) {
        options.add("skip", 1);
        options.add("separator", " ");
        options.add("header", "X Y Z Intensity Red Green Blue");
    }
    reader->setOptions(options);

    Stage* finalStage = reader;
    
    // 2. Handle Dimension Mapping (Fix for the "0 Y" issue)
    std::string originalZ = dimensionMap.empty() ? "Z" : resolveDimension(dimensionMap, "Z");

    // Add this after reader configuration to drop NoData points
    Options rangeOptions;
    rangeOptions.add("limits", originalZ + "!(-9999:-9999)");
    Stage* rangeFilter = factory.createStage("filters.range");
    rangeFilter->setOptions(rangeOptions);
    rangeFilter->setInput(*finalStage);
    finalStage = rangeFilter;

    // If the mapper found a specific mapping (e.g., "band_1" instead of just "Z")
    if (originalZ != "Z") {
        Stage* assignFilter = factory.createStage("filters.assign");
        if (assignFilter) {
            Options assignOptions;
            // Using the "value" syntax from your examples
            // Resulting string: "Z = band_1"
            assignOptions.add("value", "Z = " + originalZ);
            
            assignFilter->setOptions(assignOptions);
            assignFilter->setInput(*finalStage);
            finalStage = assignFilter;
        }
    }
    

    // 3. Logic: Reprojection
    bool needsTransformOnly = applyTransformation &&
                             (filename.ends_with(".xyz") || reader_name == "readers.ply" || reader_name == "readers.las" || reader_name == "readers.text");

    // Probe the source for a spatial reference before adding
    // filters.reprojection. The filter errors out at prepare() with
    // "source data has no spatial reference and none is specified with
    // the 'in_srs' option" if the source lacks SRS — common for E57
    // and PLY files with local coordinates. PDAL readers populate
    // getSpatialReference() during initialize()/prepare(); we probe in
    // a throwaway PointTable and silently swallow probe failures
    // (treat as "no SRS").
    if (!needsTransformOnly) {
        Stage* probe = factory.createStage(reader_name);
        if (probe) {
            Options probeOpts;
            probeOpts.add("filename", filename);
            probe->setOptions(probeOpts);
            try {
                PointTable probeTable;
                probe->prepare(probeTable);
                if (probe->getSpatialReference().empty()) {
                    needsTransformOnly = true;
                }
            } catch (...) {
                // Probe failed — assume no SRS, skip reprojection.
                needsTransformOnly = true;
            }
        }
    }

    if (!needsTransformOnly) {
        *outFilter = factory.createStage("filters.reprojection");
        if (*outFilter) {
            Options filterOptions;
            filterOptions.add("out_srs", "EPSG:3857");
            (*outFilter)->setOptions(filterOptions);
            (*outFilter)->setInput(*finalStage);
            finalStage = *outFilter;
        }
    }

    // 4. Transformation (The Matrix Flip)
    *outFlipFilter = factory.createStage("filters.transformation");
    if (!*outFlipFilter) return nullptr;

    Options flipOptions;
    if (*outFilter) {
        flipOptions.add("matrix", "1  0  0  0  "
                                 "0  1  0  0  "
                                 "0  0  -1  0  "
                                 "0  0  0  1");
    } else {
        flipOptions.add("matrix", "1  0  0  0  "
                                 "0  0  1  0  "
                                 "0 -1  0  0  "
                                 "0  0  0  1");
    }
    (*outFlipFilter)->setOptions(flipOptions);
    (*outFlipFilter)->setInput(*finalStage);
    finalStage = *outFlipFilter;

    return finalStage;
}

/**
 * @brief Helper function to calculate the next aligned offset (C-style)
 */
static inline size_t alignUp(size_t offset, size_t alignment)
{
    // A common and fast way to calculate (offset + alignment - 1) / alignment * alignment
    return (offset + alignment - 1) & ~(alignment - 1);
}

static size_t createDimensionSpecs(
    pdal::PointLayoutPtr layout,
    PDALDimensionInfo** outSpecs,
    size_t* outDimCount)
{
    auto dims = layout->dims();
    PDALDimensionInfo* specs = new PDALDimensionInfo[dims.size()];

    size_t currentOffset = 0;
    size_t maxAlignment = 1; // Keep track of largest alignment for final stride

    for (size_t i = 0; i < dims.size(); i++) {
        auto dim = dims[i];
        specs[i].sourceType = layout->dimType(dim);
        specs[i].outputType = specs[i].sourceType;
        specs[i].name = strdup(layout->dimName(dim).c_str());  // Allocate C string

        if (specs[i].sourceType == Dimension::Type::Double) {
            specs[i].outputType = Dimension::Type::Float;
        }

        size_t outputSize = Dimension::size(specs[i].outputType);
        
        // Determine alignment: this is just the size of the type
        // e.g., float (size 4) -> align 4
        //       ushort (size 2) -> align 2
        //       uchar (size 1) -> align 1
        size_t alignment = outputSize;

        // Keep track of the largest alignment needed
        if (alignment > maxAlignment) {
            maxAlignment = alignment;
        }

        // --- BUG 1 FIX ---
        // Align the current offset *before* placing the field
        currentOffset = alignUp(currentOffset, alignment);

        specs[i].offset = currentOffset; // Store the correct, aligned offset
        specs[i].outputSize = outputSize;
        
        currentOffset += specs[i].outputSize; // Move to the end of this field
    }

    *outSpecs = specs;
    *outDimCount = dims.size();

    // --- BUG 2 FIX ---
    // The final stride of the struct must be a multiple of its
    // largest member's alignment (which is 4 bytes for float).
    // This will correctly calculate 44.
    size_t structStride = alignUp(currentOffset, maxAlignment);
    
    // DO NOT 16-BYTE ALIGN. This was the bug.
    // size_t stride = ((currentOffset + 15) / 16) * 16;
    
    return structStride; // This will now return 44
}

// Helper function to extract bounds from view
static void extractBounds(pdal::PointViewPtr view, PDALBounds& bbox) {
    BOX3D _bbox;
    view->calculateBounds(_bbox);

    bbox.min_x = _bbox.minx;
    bbox.min_y = _bbox.miny;
    bbox.min_z = _bbox.minz;
    bbox.max_x = _bbox.maxx;
    bbox.max_y = _bbox.maxy;
    bbox.max_z = _bbox.maxz;
}

int pdal_read_binary(const char* reader_name_backup, const char* filename, const char** outData, size_t* outSize, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox){

    try {
        StageFactory factory;
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;

        Stage* finalStage = createConfiguredStage(reader_name_backup, filename, factory, &filter, &flipFilter);
        if (!finalStage) return PDAL_ERR_CREATE_STAGE;
        
        PointTable table;
        finalStage->prepare(table);
        PointViewSet viewSet = finalStage->execute(table);
        
        if (viewSet.empty()) return PDAL_ERR_NO_POINTS;
        PointViewPtr view = *viewSet.begin();
        pdal::PointLayoutPtr layout = view->layout();

        PDALDimensionInfo* specs;
        size_t stride = createDimensionSpecs(layout, &specs, dimCount);

        size_t pointCount = view->size();
        size_t totalSize = pointCount * stride;

        void* alignedPtr = nullptr;
        int alignResult = posix_memalign(&alignedPtr, sysconf(_SC_PAGESIZE), totalSize);
        if (alignResult != 0 || !alignedPtr) {
            return PDAL_ERR_ALLOC_FAILED;
        }
        char* storage = static_cast<char*>(alignedPtr);
        std::memset(storage, 0, totalSize);  // Zero out padding bytes

        extractBounds(view, bbox);

        auto dims = layout->dims();

        for (size_t pointIdx = 0; pointIdx < pointCount; ++pointIdx) {
            char* pointBase = storage + (pointIdx * stride);
            for (size_t dimIdx = 0; dimIdx < dims.size(); ++dimIdx) {
                auto dimId = dims[dimIdx];
                auto name = specs[dimIdx].name;
                auto outputType = specs[dimIdx].outputType;
                char* destPtr = pointBase + specs[dimIdx].offset;
                view->getField(destPtr, dimId, outputType, pointIdx);
            }
        }
        *outData = storage;
        *outSize = totalSize;
        *outCount = pointCount;
        *outStride = stride;
        *dimList = specs;
        return 0;
    } catch (const pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}

// ============================================================================
// STREAMING IMPLEMENTATION
// ============================================================================

#ifndef PDAL_IOS

#include <pdal/Streamable.hpp>
#include <pdal/filters/StreamCallbackFilter.hpp>

int pdal_load_info(const char* reader_name_backup, const char* filename, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox, PointViewContextPtr& outView){
    try {
        StageFactory factory;
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;

        Stage* finalStage = createConfiguredStage(reader_name_backup, filename, factory, &filter, &flipFilter);
        if (!finalStage) return PDAL_ERR_CREATE_STAGE;

        auto table = std::make_shared<PointTable>();
        finalStage->prepare(*table);
        PointViewSet viewSet = finalStage->execute(*table);

        if (viewSet.empty()) return PDAL_ERR_NO_POINTS;
        PointViewPtr view = *viewSet.begin();
        pdal::PointLayoutPtr layout = view->layout();

        PDALDimensionInfo* specs;
        size_t stride = createDimensionSpecs(layout, &specs, dimCount);

        size_t pointCount = view->size();
        // extractBounds(view, bbox);

        *outCount = pointCount;
        *outStride = stride;
        *dimList = specs;

        // Return the PointViewContext via shared_ptr for automatic lifetime management
        outView = std::make_shared<PointViewContext>(view, table);

        return 0;
    } catch (const pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        std::cerr << "Error in pdal_load_info: " << e.what() << std::endl;
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}



class ProgressivePointLoader {
private:
    std::vector<char> chunkBuffer;
    size_t chunkSize;  // Points per chunk
    size_t currentPointIndex;
    size_t totalPointsProcessed;
    size_t stride;
    PDALDimensionInfo* dimSpecs;
    size_t dimCount;
    std::vector<pdal::Dimension::Id> dimIds;  // Store dimension IDs
    ProgressCallback callback;
    void* callbackContext;
    bool initialized;
    bool isFirstChunk;  // NEW: Track first chunk
    DimensionMap dimMap;  // NEW: Dimension name mapping

    // Bounds tracking
    pdal::Dimension::Id xDimId, yDimId, zDimId;
    bool hasBounds;
    float minX, minY, minZ;
    float maxX, maxY, maxZ;
    
    // Cache for current point coordinates (avoid duplicate reads)
    float currentX = 0.0f, currentY = 0.0f, currentZ = 0.0f;

public:
    ProgressivePointLoader(size_t pointsPerChunk, ProgressCallback cb, void* ctx, const DimensionMap& dimensionMap = {})
        : chunkSize(pointsPerChunk)
        , currentPointIndex(0)
        , totalPointsProcessed(0)
        , stride(0)
        , dimSpecs(nullptr)
        , dimCount(0)
        , callback(cb)
        , callbackContext(ctx)
        , initialized(false)
        , isFirstChunk(true)  // NEW
        , dimMap(dimensionMap)  // NEW: Store dimension map
        , hasBounds(false)
        , minX(std::numeric_limits<double>::max())
        , minY(std::numeric_limits<double>::max())
        , minZ(std::numeric_limits<double>::max())
        , maxX(std::numeric_limits<double>::lowest())
        , maxY(std::numeric_limits<double>::lowest())
        , maxZ(std::numeric_limits<double>::lowest())
    {}

    // Must be called after prepare() to initialize dimensions from layout
    void initialize(pdal::PointLayoutPtr layout) {
        using namespace pdal;

        if (initialized) return;

        auto dims = layout->dims();
        dimIds = dims;
        dimCount = dims.size();
        
        // Allocate C-compatible array
        dimSpecs = new PDALDimensionInfo[dimCount];

        // Find X, Y, Z dimension IDs for bounds tracking
        std::string xName = dimMap.empty() ? "X" : resolveDimension(dimMap, "X");
        std::string yName = dimMap.empty() ? "Y" : resolveDimension(dimMap, "Y");
        std::string zName = dimMap.empty() ? "Z" : resolveDimension(dimMap, "Z");

        xDimId = layout->findDim(xName);
        yDimId = layout->findDim(yName);
        zDimId = layout->findDim(zName);
        hasBounds = (xDimId != Dimension::Id::Unknown &&
                     yDimId != Dimension::Id::Unknown &&
                     zDimId != Dimension::Id::Unknown);

        size_t currentOffset = 0;
        size_t maxAlignment = 1;

        for (size_t i = 0; i < dimCount; i++) {
            auto dim = dims[i];
            dimSpecs[i].sourceType = layout->dimType(dim);
            dimSpecs[i].outputType = dimSpecs[i].sourceType;
            dimSpecs[i].name = strdup(layout->dimName(dim).c_str());
            dimSpecs[i].offset = currentOffset;
            if (dimSpecs[i].sourceType == Dimension::Type::Double) {
                dimSpecs[i].outputType = Dimension::Type::Float;
            }
            dimSpecs[i].outputSize = Dimension::size(dimSpecs[i].outputType);
            // Proper alignment
            size_t alignment = dimSpecs[i].outputSize;
            if (alignment > maxAlignment) {
                maxAlignment = alignment;
            }
            currentOffset = (currentOffset + alignment - 1) & ~(alignment - 1);
            dimSpecs[i].offset = currentOffset;
            currentOffset += dimSpecs[i].outputSize;
        }

        // Calculate stride with 16-byte alignment (matching pdal_read_binary)
//        stride = ((currentOffset + 15) / 16) * 16;
        stride = (currentOffset + maxAlignment - 1) & ~(maxAlignment - 1);

        // Allocate chunk buffer
        chunkBuffer.resize(chunkSize * stride);
        std::memset(chunkBuffer.data(), 0, chunkBuffer.size());

        initialized = true;
    }

    bool streamCallback(pdal::PointRef& point) {
        using namespace pdal;

        if (!initialized) {
            std::cerr << "Error: ProgressivePointLoader not initialized!\n";
            return false;
        }

        // Read coordinates once for both bounds tracking and dimension extraction
        float x, y, z;
        if (hasBounds) {
            x = point.getFieldAs<float>(xDimId);
            y = point.getFieldAs<float>(yDimId);
            z = point.getFieldAs<float>(zDimId);
            
            // Update bounds with cached values
            minX = fmin(minX, x);
            minY = fmin(minY, y);
            minZ = fmin(minZ, z);
            maxX = fmax(maxX, x);
            maxY = fmax(maxY, y);
            maxZ = fmax(maxZ, z);
            
            // Cache for potential future use
            currentX = x;
            currentY = y;
            currentZ = z;
        }
        
        // Write point data to current position in chunk
        char* pointBase = chunkBuffer.data() + (currentPointIndex * stride);

        for (size_t dimIdx = 0; dimIdx < dimCount; ++dimIdx) {
            auto& spec = dimSpecs[dimIdx];
            char* destPtr = pointBase + spec.offset;
            auto dimId = dimIds[dimIdx];
            point.getField(destPtr, dimId, spec.outputType);
        }

        currentPointIndex++;
        totalPointsProcessed++;

        // Chunk is full - deliver it
        if (currentPointIndex >= chunkSize) {
            ChunkData chunk;
            chunk.data = chunkBuffer.data();
            chunk.pointCount = currentPointIndex;
            chunk.stride = stride;
            chunk.isComplete = false;
            chunk.totalPointsSoFar = totalPointsProcessed;
            chunk.estimatedTotalPoints = 0; // Unknown during streaming
            getBounds(chunk.currentBounds);
            
            chunk.dimensions = dimSpecs;
            chunk.dimensionCount = dimCount;
            chunk.isFirstChunk = isFirstChunk;
            
            bool shouldContinue = callback(&chunk, callbackContext);

            // Reset for next chunk
            isFirstChunk = false;  // No longer first chunk

            currentPointIndex = 0;
            std::memset(chunkBuffer.data(), 0, chunkBuffer.size());

            return shouldContinue;
        }

        return true;
    }

    void flushFinalChunk() {
        if (currentPointIndex > 0) {
            ChunkData chunk;
            chunk.data = chunkBuffer.data();
            chunk.pointCount = currentPointIndex;
            chunk.stride = stride;
            chunk.isComplete = true;
            chunk.totalPointsSoFar = totalPointsProcessed;
            chunk.estimatedTotalPoints = totalPointsProcessed;
            getBounds(chunk.currentBounds);
            
            chunk.dimensions = dimSpecs;
            chunk.dimensionCount = dimCount;
            chunk.isFirstChunk = isFirstChunk;
            
            callback(&chunk, callbackContext);
            isFirstChunk = false;

        }
    }

    const PDALDimensionInfo* getDimensionSpecs() const {
        return dimSpecs;
    }
    
    size_t getDimensionCount() const {
        return dimCount;
    }

    size_t getStride() const { return stride; }
    size_t getTotalPoints() const { return totalPointsProcessed; }

    // Get computed bounds
    void getBounds(PDALBounds& bbox) const {
        if (hasBounds) {
            bbox.min_x = minX;
            bbox.min_y = minY;
            bbox.min_z = minZ;
            bbox.max_x = maxX;
            bbox.max_y = maxY;
            bbox.max_z = maxZ;
        } else {
            bbox.min_x = bbox.min_y = bbox.min_z = 0.0f;
            bbox.max_x = bbox.max_y = bbox.max_z = 0.0f;
        }
    }
    
    ~ProgressivePointLoader() {
        if (dimSpecs) {
            for (size_t i = 0; i < dimCount; i++) {
                if (dimSpecs[i].name) {
                    free((void*)dimSpecs[i].name);
                }
            }
            delete[] dimSpecs;
        }
    }
};




int pdal_read_binary_stream_progressive(
    const char* reader_name_backup,
    const char* filename,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    PDALBounds& bbox,
    const DimensionMap& dimensionMap)
{
    try {
        using namespace pdal;

        if (!onChunk) return PDAL_ERR_INVALID_CALLBACK; // Invalid callback
        if (chunkSize == 0) return PDAL_ERR_INVALID_CHUNK_SIZE; // Invalid chunk size

        StageFactory factory;
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;

        Stage* finalStage = createConfiguredStage(reader_name_backup, filename, factory, &filter, &flipFilter, dimensionMap);
        if (!finalStage) return PDAL_ERR_CREATE_STAGE;

        bool isStreamable = finalStage->pipelineStreamable();

        auto nonStreamables = finalStage->findNonstreamable();



        // Create progressive loader with dimension mapping
        ProgressivePointLoader loader(chunkSize, onChunk, context, dimensionMap);

        // Setup streaming callback filter
        StreamCallbackFilter streamFilter;
        streamFilter.setCallback([&loader](PointRef& p) {
            return loader.streamCallback(p);
        });
        streamFilter.setInput(*finalStage);

        // Execute with streaming
        // For streaming mode, we use a regular PointTable and rely on the
        // StreamCallbackFilter's processOne() method to be called for each point
        PointTable table;
        streamFilter.prepare(table);
        loader.initialize(table.layout());

        // Execute the streaming pipeline
        streamFilter.execute(table);

        // Flush any remaining points
        loader.flushFinalChunk();

        // Get bounds computed during streaming (avoids second pass)
        loader.getBounds(bbox);

        return 0;

    } catch (const pdal::pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}

// New function: Stream from an existing PointViewContext (avoids re-reading the file)
int pdal_read_binary_stream_from_view(
    const PointViewContextPtr& viewCtx,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    const DimensionMap& dimensionMap)
{
    try {
        using namespace pdal;

        if (!viewCtx) {
            return PDAL_ERR_INVALID_VIEW_POINTER;
        }
        if (!onChunk) {
            return PDAL_ERR_INVALID_CALLBACK;
        }
        if (chunkSize == 0) {
            return PDAL_ERR_INVALID_CHUNK_SIZE;
        }

        PointViewPtr view = viewCtx->view;
        pdal::PointLayoutPtr layout = viewCtx->layout;

        if (!view) {
            return PDAL_ERR_INVALID_VIEW_POINTER;
        }

        // Build dimension specs
        PDALDimensionInfo* specs;
        size_t dimCount;
        size_t stride = createDimensionSpecs(layout, &specs, &dimCount);
        auto dims = layout->dims();

        size_t totalPoints = view->size();
        size_t currentPoint = 0;
        bool isFirstChunk = true;  // Track first chunk

        // Initialize bounds tracking with dimension mapping
        std::string xName = dimensionMap.empty() ? "X" : resolveDimension(dimensionMap, "X");
        std::string yName = dimensionMap.empty() ? "Y" : resolveDimension(dimensionMap, "Y");
        std::string zName = dimensionMap.empty() ? "Z" : resolveDimension(dimensionMap, "Z");

        Dimension::Id xDimId = layout->findDim(xName);
        Dimension::Id yDimId = layout->findDim(yName);
        Dimension::Id zDimId = layout->findDim(zName);
        bool hasBounds = (xDimId != Dimension::Id::Unknown &&
                         yDimId != Dimension::Id::Unknown &&
                         zDimId != Dimension::Id::Unknown);

        PDALBounds currentBounds;
        if (hasBounds) {
            currentBounds.min_x = currentBounds.min_y = currentBounds.min_z = std::numeric_limits<float>::max();
            currentBounds.max_x = currentBounds.max_y = currentBounds.max_z = std::numeric_limits<float>::lowest();
        } else {
            currentBounds.min_x = currentBounds.min_y = currentBounds.min_z = 0.0f;
            currentBounds.max_x = currentBounds.max_y = currentBounds.max_z = 0.0f;
        }

        // Allocate chunk buffer
        size_t bufferSize = chunkSize * stride;
        std::vector<char> chunkBuffer(bufferSize);

        while (currentPoint < totalPoints) {
            size_t pointsInChunk = std::min(chunkSize, totalPoints - currentPoint);
            std::memset(chunkBuffer.data(), 0, chunkBuffer.size());

            // Copy points into chunk buffer and update bounds
            for (size_t i = 0; i < pointsInChunk; ++i) {
                size_t pointIdx = currentPoint + i;
                char* pointBase = chunkBuffer.data() + (i * stride);

                // Update bounds
                if (hasBounds) {
                    float x = view->getFieldAs<float>(xDimId, pointIdx);
                    float y = view->getFieldAs<float>(yDimId, pointIdx);
                    float z = view->getFieldAs<float>(zDimId, pointIdx);

                    currentBounds.min_x = fmin(currentBounds.min_x, x);
                    currentBounds.min_y = fmin(currentBounds.min_y, y);
                    currentBounds.min_z = fmin(currentBounds.min_z, z);
                    currentBounds.max_x = fmax(currentBounds.max_x, x);
                    currentBounds.max_y = fmax(currentBounds.max_y, y);
                    currentBounds.max_z = fmax(currentBounds.max_z, z);
                }

                for (size_t dimIdx = 0; dimIdx < dims.size(); ++dimIdx) {
                    auto dimId = dims[dimIdx];
                    auto outputType = specs[dimIdx].outputType;
                    char* destPtr = pointBase + specs[dimIdx].offset;
                    view->getField(destPtr, dimId, outputType, pointIdx);
                }
            }

            // Call the callback
            ChunkData chunk;
            chunk.data = chunkBuffer.data();
            chunk.pointCount = pointsInChunk;
            chunk.stride = stride;
            chunk.isComplete = (currentPoint + pointsInChunk >= totalPoints);
            chunk.totalPointsSoFar = currentPoint + pointsInChunk;
            chunk.estimatedTotalPoints = totalPoints;
            chunk.currentBounds = currentBounds;
            chunk.dimensions = specs;
            chunk.dimensionCount = dimCount;
            chunk.isFirstChunk = isFirstChunk;

            bool shouldContinue = onChunk(&chunk, context);

            isFirstChunk = false;
            currentPoint += pointsInChunk;

            if (!shouldContinue) {
                // Free dimension specs before returning
                for (size_t i = 0; i < dimCount; i++) {
                    if (specs[i].name) free((void*)specs[i].name);
                }
                delete[] specs;
                return 0;
            }
        }

        // Free dimension specs
        for (size_t i = 0; i < dimCount; i++) {
            if (specs[i].name) free((void*)specs[i].name);
        }
        delete[] specs;
        return 0;

    } catch (const pdal::pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return PDAL_ERR_PDAL;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return PDAL_ERR_STD_EXCEPTION;
    } catch (...) {
        return PDAL_ERR_UNKNOWN;
    }
}

#else
// iOS stub implementation
int pdal_read_binary_stream_progressive(
    const char* reader_name_backup,
    const char* filename,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    PDALBounds& bbox,
    const DimensionMap& dimensionMap)
{
    return PDAL_ERR_NOT_IMPLEMENTED; // Not implemented on iOS
}

int pdal_read_binary_stream_from_view(
    const PointViewContextPtr& view,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    const DimensionMap& dimensionMap)
{
    return PDAL_ERR_NOT_IMPLEMENTED; // Not implemented on iOS
}

const char* pdal_error_message(int error_code) {
    switch (error_code) {
        case PDAL_OK: return "OK";
        case PDAL_ERR_NOT_IMPLEMENTED: return "Not implemented on this platform";
        case PDAL_ERR_PDAL: return "PDAL error occurred";
        case PDAL_ERR_STD_EXCEPTION: return "Standard exception occurred";
        case PDAL_ERR_CREATE_STAGE: return "Failed to create stage";
        case PDAL_ERR_NO_POINTS: return "No points in view";
        case PDAL_ERR_UNKNOWN: return "Unknown error";
        case PDAL_ERR_INVALID_CALLBACK: return "Invalid callback";
        case PDAL_ERR_INVALID_CHUNK_SIZE: return "Invalid chunk size";
        case PDAL_ERR_INVALID_VIEW_POINTER: return "Invalid view pointer";
        case PDAL_ERR_ALLOC_FAILED: return "Memory allocation failed";
        default: return "Unknown error code";
    }
}
#endif
