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

int pdal_read_binary(const std::string& reader_name_backup, const std::string& filename, const char** outData, size_t* outSize, size_t* outCount, size_t* outStride, PDALDimensionInfo** dimList, size_t* dimCount, PDALBounds& bbox){
    
    try {
        
        StageFactory factory;
        std::string inferredReaderName = factory.inferReaderDriver(filename);
        std::string reader_name = reader_name_backup;
        if (!inferredReaderName.empty()) {
            reader_name = inferredReaderName;
        }
        Stage* reader = factory.createStage(reader_name);
        Stage* filter = nullptr;
        Stage* flipFilter = nullptr;
        bool needsTransform = false;

        if (!reader) return -4;

        Options options;
        options.add("filename", filename);
        if (filename.ends_with(".xyz")) {
            options.add("skip", 0);
            options.add("separator", " ");
            options.add("header", "X Y Z Red Green Blue");
        }
        
        if (filename.ends_with(".xyz") || reader_name == "readers.ply") {
            needsTransform = true;
        }
        
//        needsTransform = true;
        
        reader->setOptions(options);
        
        Stage* finalStage;
        
        if (needsTransform) {
            flipFilter = factory.createStage("filters.transformation");
            if (!flipFilter) return -4;
            Options flipOptions;
            flipOptions.add("matrix", "1  0  0  0  "    // X unchanged
                            "0 0  1  0  "    // Y flipped (multiply by -1)
                            "0  -1  0  0  "    // Z unchanged
                            "0  0  0  1");    // Homogeneous coordinate
            flipFilter->setOptions(flipOptions);
            flipFilter->setInput(*reader);  // Connect flip filter after reprojection
            finalStage = flipFilter;
        } else if (reader_name == "readers.las") {
            filter = factory.createStage("filters.reprojection");
            flipFilter = factory.createStage("filters.transformation");
            if (!filter || !flipFilter) return -4;
            
            Options filterOptions;
            filterOptions.add("out_srs", "EPSG:3857");
            filter->setOptions(filterOptions);
            filter->setInput(*reader);
            
            Options flipOptions;
            flipOptions.add("matrix", "1  0  0  0  "    // X unchanged
                            "0 0  1  0  "    // Y flipped (multiply by -1)
                            "0  -1  0  0  "    // Z unchanged
                            "0  0  0  1");    // Homogeneous coordinate
            flipFilter->setOptions(flipOptions);
            flipFilter->setInput(*filter);  // Connect flip filter after reprojection
            finalStage = flipFilter;
        } else {
            finalStage = reader;
        }
        
        PointTable table;
        finalStage->prepare(table);
        PointViewSet viewSet = finalStage->execute(table);
        
        if (viewSet.empty()) return -5;
        PointViewPtr view = *viewSet.begin();
        pdal::PointLayoutPtr layout = view->layout();
        
        auto dims = layout->dims();

        PDALDimensionInfo* specs = new PDALDimensionInfo[dims.size()];

        size_t pointCount = view->size();
        size_t currentOffset = 0;

        for (size_t i = 0; i < dims.size(); i++) {
            auto dim = dims[i];
            PDALDimensionInfo info;
            specs[i].sourceType = view->dimType(dim);
            specs[i].name = view->dimName(dim);
            specs[i].offset = currentOffset;
            if (specs[i].sourceType == Dimension::Type::Double) {
                specs[i].outputSize = Dimension::size(Dimension::Type::Float);
            } else {
                specs[i].outputSize = view->dimSize(dim);
            }
            currentOffset += specs[i].outputSize;
        }
        
        size_t stride = ((currentOffset + 15) / 16) * 16;
        size_t totalSize = pointCount * stride;
        
        char* storage = new char[totalSize];
        std::memset(storage, 0, totalSize);  // Zero out padding bytes
        
        BOX3D _bbox;
        view->calculateBounds(_bbox);
        
        bbox.min_x = _bbox.minx;
        bbox.min_y = _bbox.miny;
        bbox.min_z = _bbox.minz;
        
        bbox.max_x = _bbox.maxx;
        bbox.max_y = _bbox.maxy;
        bbox.max_z = _bbox.maxz;

        for (size_t pointIdx = 0; pointIdx < pointCount; ++pointIdx) {
            char* pointBase = storage + (pointIdx * stride);
            for (size_t dimIdx = 0; dimIdx < dims.size(); ++dimIdx) {
                auto dimId = dims[dimIdx];
                auto name = specs[dimIdx].name;
                auto sourceType = specs[dimIdx].sourceType;
                char* destPtr = pointBase + specs[dimIdx].offset;
                if (sourceType == Dimension::Type::Double) {
                    view->getField(destPtr, dimId, Dimension::Type::Float, pointIdx);
                } else {
                    view->getField(destPtr, dimId, sourceType, pointIdx);
                }
            }
        }
        *outData = storage;
        *outSize = totalSize;
        *outCount = pointCount;
        *outStride = stride;
        *dimList = specs;
        *dimCount = dims.size();
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