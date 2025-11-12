//
//  pdal_wrapper.cpp
//  PDAL-Swift
//
//  Created by HIROAKI YAMANE on 08/04/2025.
//

// pdal_wrapper.cpp
#include "include/pdal_wrapper.h"

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

using namespace pdal;
#endif

PDALPipeline pdal_pipeline_create() {
    return static_cast<PDALPipeline>(new pdal::PipelineManager());
}

int pdal_pipeline_parse_json(PDALPipeline pipeline_ptr, const char* json_string) {
    if (!pipeline_ptr || !json_string) return -1; // Error code

    pdal::PipelineManager* pipeline = static_cast<pdal::PipelineManager*>(pipeline_ptr);
    std::stringstream ss(json_string);
    try {
        pipeline->readPipeline(ss);
        return 0; // Success
    } catch (const pdal_error& e) {
        // Log error if needed
        return -2; // PDAL Error Code
    }
}

int pdal_pipeline_execute(PDALPipeline pipeline_ptr) {
    if (!pipeline_ptr) return -1;

    pdal::PipelineManager* pipeline = static_cast<pdal::PipelineManager*>(pipeline_ptr);
    try {
        pipeline->execute();
        return 0; // Success
    } catch (const pdal_error& e) {
        // Log error if needed
        return -2; // PDAL Error Code
    }
}

int pdal_pipeline_get_metadata_json(PDALPipeline pipeline_ptr, char* buffer, size_t buffer_size) {
    if (!pipeline_ptr || !buffer || buffer_size == 0) return -1;

    pdal::PipelineManager* pipeline = static_cast<pdal::PipelineManager*>(pipeline_ptr);
    std::stringstream ss;
    try {
        MetadataNode root = pipeline->getMetadata().clone("metadata");
        Utils::toJSON(root, ss);
        std::string metadata_json = ss.str();

        if (metadata_json.length() + 1 > buffer_size) {
            return -3; // Buffer too small
        }
        strcpy(buffer, metadata_json.c_str()); // Use strcpy carefully!
        return 0; // Success
    } catch (const pdal_error& e) {
        return -2; // PDAL Error Code
    }
}

void pdal_free_data(const char* data, PDALDimensionInfo* dimList) { delete[] data; delete[] dimList; }

// Helper function to create and configure the PDAL stage pipeline
static Stage* createConfiguredStage(
    const std::string& reader_name_backup,
    const std::string& filename,
    StageFactory& factory,
    Stage** outFilter,
    Stage** outFlipFilter)
{
    std::string inferredReaderName = factory.inferReaderDriver(filename);
    std::string reader_name = reader_name_backup;
    if (!inferredReaderName.empty()) {
        reader_name = inferredReaderName;
    }

    Stage* reader = factory.createStage(reader_name);
    if (!reader) return nullptr;

    Options options;
    options.add("filename", filename);
    if (filename.ends_with(".xyz")) {
        options.add("skip", 0);
        options.add("separator", " ");
        options.add("header", "X Y Z Red Green Blue");
    }

    bool needsTransform = filename.ends_with(".xyz") || reader_name == "readers.ply";
    reader->setOptions(options);

    Stage* finalStage = reader;

    if (needsTransform) {
        *outFlipFilter = factory.createStage("filters.transformation");
        if (!*outFlipFilter) return nullptr;
        Options flipOptions;
        flipOptions.add("matrix", "1  0  0  0  "    // X unchanged
                        "0 0  1  0  "    // Y flipped (multiply by -1)
                        "0  -1  0  0  "    // Z unchanged
                        "0  0  0  1");    // Homogeneous coordinate
        (*outFlipFilter)->setOptions(flipOptions);
        (*outFlipFilter)->setInput(*reader);
        finalStage = *outFlipFilter;
    } else if (reader_name == "readers.las") {
        *outFilter = factory.createStage("filters.reprojection");
        *outFlipFilter = factory.createStage("filters.transformation");
        if (!*outFilter || !*outFlipFilter) return nullptr;

        Options filterOptions;
        filterOptions.add("out_srs", "EPSG:3857");
        (*outFilter)->setOptions(filterOptions);
        (*outFilter)->setInput(*reader);

        Options flipOptions;
        flipOptions.add("matrix", "1  0  0  0  "    // X unchanged
                        "0 0  1  0  "    // Y flipped (multiply by -1)
                        "0  -1  0  0  "    // Z unchanged
                        "0  0  0  1");    // Homogeneous coordinate
        (*outFlipFilter)->setOptions(flipOptions);
        (*outFlipFilter)->setInput(**outFilter);
        finalStage = *outFlipFilter;
    }

    return finalStage;
}

// Helper function to create dimension specs and calculate stride
static size_t createDimensionSpecs(
    pdal::PointLayoutPtr layout,
    PDALDimensionInfo** outSpecs,
    size_t* outDimCount)
{
    auto dims = layout->dims();
    PDALDimensionInfo* specs = new PDALDimensionInfo[dims.size()];

    size_t currentOffset = 0;
    for (size_t i = 0; i < dims.size(); i++) {
        auto dim = dims[i];
        specs[i].sourceType = layout->dimType(dim);
        specs[i].outputType = specs[i].sourceType;
        specs[i].name = layout->dimName(dim);
        specs[i].offset = currentOffset;
        if (specs[i].sourceType == Dimension::Type::Double) {
            specs[i].outputType = Dimension::Type::Float;
        }
        specs[i].outputSize = Dimension::size(specs[i].outputType);
        currentOffset += specs[i].outputSize;
    }

    // Calculate stride with 16-byte alignment
    size_t stride = ((currentOffset + 15) / 16) * 16;

    *outSpecs = specs;
    *outDimCount = dims.size();
    return stride;
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

int pdal_read_binary(const std::string& reader_name_backup, const std::string& filename, const char** outData, size_t* outSize, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox){

    try {
        StageFactory factory;
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;

        Stage* finalStage = createConfiguredStage(reader_name_backup, filename, factory, &filter, &flipFilter);
        if (!finalStage) return -4;
        
        PointTable table;
        finalStage->prepare(table);
        PointViewSet viewSet = finalStage->execute(table);
        
        if (viewSet.empty()) return -5;
        PointViewPtr view = *viewSet.begin();
        pdal::PointLayoutPtr layout = view->layout();

        PDALDimensionInfo* specs;
        size_t stride = createDimensionSpecs(layout, &specs, dimCount);

        size_t pointCount = view->size();
        size_t totalSize = pointCount * stride;

        char* storage = new char[totalSize];
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
        return -2;
    } catch (const std::exception& e) {
        return -3;
    } catch (...) {
        return -6;
    }
}

// ============================================================================
// STREAMING IMPLEMENTATION
// ============================================================================

#ifndef PDAL_IOS

#include <pdal/Streamable.hpp>
#include <pdal/filters/StreamCallbackFilter.hpp>

// Structure to hold PointView and PointTable together
// CRITICAL: PointTable MUST remain alive for PointView to be valid
// The PointView references memory owned by the PointTable
struct PointViewContext {
    pdal::PointViewPtr view;
    std::shared_ptr<pdal::PointTable> table;  // Keep the table alive!
    pdal::PointLayoutPtr layout;

    PointViewContext(pdal::PointViewPtr v, std::shared_ptr<pdal::PointTable> t)
        : view(v), table(t), layout(v->layout()) {
        std::cerr << "DEBUG: PointViewContext created with " << layout->dims().size() << " dimensions" << std::endl;
    }
};

int pdal_load_info(const std::string& reader_name_backup, const std::string& filename, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox, PDALPointViewPtr* outView){
    try {
        StageFactory factory;
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;

        Stage* finalStage = createConfiguredStage(reader_name_backup, filename, factory, &filter, &flipFilter);
        if (!finalStage) return -4;

        // CRITICAL: Use shared_ptr to keep the table alive
        auto table = std::make_shared<PointTable>();
        finalStage->prepare(*table);
        PointViewSet viewSet = finalStage->execute(*table);

        if (viewSet.empty()) return -5;
        PointViewPtr view = *viewSet.begin();
        pdal::PointLayoutPtr layout = view->layout();

        std::cerr << "DEBUG: pdal_load_info - layout has " << layout->dims().size() << " dimensions" << std::endl;

        PDALDimensionInfo* specs;
        size_t stride = createDimensionSpecs(layout, &specs, dimCount);

        size_t pointCount = view->size();
        extractBounds(view, bbox);

        *outCount = pointCount;
        *outStride = stride;
        *dimList = specs;

        // Return the PointView if requested (for later streaming)
        if (outView) {
            // CRITICAL: Keep both view AND table alive
            PointViewContext* ctx = new PointViewContext(view, table);
            *outView = static_cast<PDALPointViewPtr>(ctx);
            std::cerr << "DEBUG: Created context and returning view pointer" << std::endl;
        }

        return 0;
    } catch (const pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return -2;
    } catch (const std::exception& e) {
        std::cerr << "Error in pdal_load_info: " << e.what() << std::endl;
        return -3;
    } catch (...) {
        return -6;
    }
}



class ProgressivePointLoader {
private:
    std::vector<char> chunkBuffer;
    size_t chunkSize;  // Points per chunk
    size_t currentPointIndex;
    size_t totalPointsProcessed;
    size_t stride;
    std::vector<PDALDimensionInfo> dimSpecs;
    std::vector<pdal::Dimension::Id> dimIds;  // Store dimension IDs
    ProgressCallback callback;
    void* callbackContext;
    bool initialized;

public:
    ProgressivePointLoader(size_t pointsPerChunk, ProgressCallback cb, void* ctx)
        : chunkSize(pointsPerChunk)
        , currentPointIndex(0)
        , totalPointsProcessed(0)
        , stride(0)
        , callback(cb)
        , callbackContext(ctx)
        , initialized(false)
    {}

    // Must be called after prepare() to initialize dimensions from layout
    void initialize(pdal::PointLayoutPtr layout) {
        using namespace pdal;

        if (initialized) return;

        auto dims = layout->dims();
        dimIds = dims;

        size_t currentOffset = 0;
        for (auto dim : dims) {
            PDALDimensionInfo info;
            info.sourceType = layout->dimType(dim);
            info.outputType = info.sourceType;
            info.name = layout->dimName(dim);
            info.offset = currentOffset;
            if (info.sourceType == Dimension::Type::Double) {
                info.outputType = Dimension::Type::Float;
            }
            info.outputSize = Dimension::size(info.outputType);
            currentOffset += info.outputSize;
            dimSpecs.push_back(info);
        }

        // Calculate stride with 16-byte alignment (matching pdal_read_binary)
        stride = ((currentOffset + 15) / 16) * 16;

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

        // Write point data to current position in chunk
        char* pointBase = chunkBuffer.data() + (currentPointIndex * stride);

        for (size_t dimIdx = 0; dimIdx < dimSpecs.size(); ++dimIdx) {
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

            bool shouldContinue = callback(
                chunk.data,
                chunk.pointCount,
                chunk.stride,
                chunk.isComplete,
                chunk.totalPointsSoFar,
                chunk.estimatedTotalPoints,
                callbackContext
            );

            // Reset for next chunk
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

            callback(
                chunk.data,
                chunk.pointCount,
                chunk.stride,
                chunk.isComplete,
                chunk.totalPointsSoFar,
                chunk.estimatedTotalPoints,
                callbackContext
            );
        }
    }

    const std::vector<PDALDimensionInfo>& getDimensionSpecs() const {
        return dimSpecs;
    }

    size_t getStride() const { return stride; }
    size_t getTotalPoints() const { return totalPointsProcessed; }
};




int pdal_read_binary_stream_progressive(
    const std::string& reader_name_backup,
    const std::string& filename,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    PDALBounds& bbox)
{
    try {
        using namespace pdal;

        if (!onChunk) return -7; // Invalid callback
        if (chunkSize == 0) return -8; // Invalid chunk size

        StageFactory factory;
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;

        Stage* finalStage = createConfiguredStage(reader_name_backup, filename, factory, &filter, &flipFilter);
        if (!finalStage) return -4;

        // Create progressive loader
        ProgressivePointLoader loader(chunkSize, onChunk, context);

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

        // Calculate bounds - we need to do a second pass for accurate bounds
        // Alternative: track bounds during streaming (adds overhead per point)
        PointTable boundTable;
        finalStage->prepare(boundTable);
        PointViewSet boundViewSet = finalStage->execute(boundTable);

        if (!boundViewSet.empty()) {
            PointViewPtr view = *boundViewSet.begin();
            BOX3D _bbox;
            view->calculateBounds(_bbox);

            bbox.min_x = _bbox.minx;
            bbox.min_y = _bbox.miny;
            bbox.min_z = _bbox.minz;
            bbox.max_x = _bbox.maxx;
            bbox.max_y = _bbox.maxy;
            bbox.max_z = _bbox.maxz;
        } else {
            // If bound calculation fails, set to invalid bounds
            bbox.min_x = bbox.min_y = bbox.min_z = 0.0;
            bbox.max_x = bbox.max_y = bbox.max_z = 0.0;
        }

        return 0;

    } catch (const pdal::pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return -2;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return -3;
    } catch (...) {
        return -6;
    }
}

// New function: Stream from an existing PointViewPtr (avoids re-reading the file)
int pdal_read_binary_stream_from_view(
    PDALPointViewPtr viewPtr,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context)
{
    try {
        using namespace pdal;

        if (!viewPtr) {
            return -9; // Invalid view pointer
        }
        if (!onChunk) {
            return -7; // Invalid callback
        }
        if (chunkSize == 0) {
            return -8; // Invalid chunk size
        }

        // Cast back to PointViewContext
        PointViewContext* ctx = static_cast<PointViewContext*>(viewPtr);
        PointViewPtr view = ctx->view;
        pdal::PointLayoutPtr layout = ctx->layout;

        if (!view) {
            return -9; // Invalid view
        }

        // Build dimension specs
        PDALDimensionInfo* specs;
        size_t dimCount;
        size_t stride = createDimensionSpecs(layout, &specs, &dimCount);
        auto dims = layout->dims();

        size_t totalPoints = view->size();
        size_t currentPoint = 0;

        // Allocate chunk buffer
        size_t bufferSize = chunkSize * stride;
        std::vector<char> chunkBuffer(bufferSize);

        while (currentPoint < totalPoints) {
            size_t pointsInChunk = std::min(chunkSize, totalPoints - currentPoint);
            std::memset(chunkBuffer.data(), 0, chunkBuffer.size());

            // Copy points into chunk buffer
            for (size_t i = 0; i < pointsInChunk; ++i) {
                size_t pointIdx = currentPoint + i;
                char* pointBase = chunkBuffer.data() + (i * stride);

                for (size_t dimIdx = 0; dimIdx < dims.size(); ++dimIdx) {
                    auto dimId = dims[dimIdx];
                    auto outputType = specs[dimIdx].outputType;
                    char* destPtr = pointBase + specs[dimIdx].offset;
                    view->getField(destPtr, dimId, outputType, pointIdx);
                }
            }

            // Call the callback
            bool isComplete = (currentPoint + pointsInChunk >= totalPoints);
            bool shouldContinue = onChunk(
                chunkBuffer.data(),
                pointsInChunk,
                stride,
                isComplete,
                currentPoint + pointsInChunk,
                totalPoints,
                context
            );

            currentPoint += pointsInChunk;

            if (!shouldContinue) {
                delete[] specs;
                return 0; // User cancelled
            }
        }

        delete[] specs;
        return 0;

    } catch (const pdal::pdal_error& e) {
        std::cerr << "PDAL Error: " << e.what() << std::endl;
        return -2;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return -3;
    } catch (...) {
        return -6;
    }
}

// Free the PointViewPtr
void pdal_free_point_view(PDALPointViewPtr viewPtr) {
    if (viewPtr) {
        PointViewContext* ctx = static_cast<PointViewContext*>(viewPtr);
        delete ctx;
    }
}

#else
// iOS stub implementation
int pdal_read_binary_stream_progressive(
    const std::string& reader_name_backup,
    const std::string& filename,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context,
    PDALBounds& bbox)
{
    return -1; // Not implemented on iOS
}

int pdal_read_binary_stream_from_view(
    PDALPointViewPtr viewPtr,
    size_t chunkSize,
    ProgressCallback onChunk,
    void* context)
{
    return -1; // Not implemented on iOS
}

void pdal_free_point_view(PDALPointViewPtr viewPtr) {
    // No-op on iOS
}
#endif
