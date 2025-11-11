//
//  pdal_common.h
//  PointCloudKit
//
//  Created by HIROAKI YAMANE on 13/07/2025.
//

#ifndef PDAL_COMMON_H
#define PDAL_COMMON_H

#include <stddef.h>

// Bounds structure (same as before)
typedef struct {
    float min_x, min_y, min_z;
    float max_x, max_y, max_z;
} PDALBounds;
#endif // PDAL_COMMON_H
