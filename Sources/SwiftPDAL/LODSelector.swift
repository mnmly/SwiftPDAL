import simd

/// Level of Detail (LOD) selector for adaptive point cloud rendering
public struct LODSelector {

    /// Configuration for LOD selection
    public struct Config: Sendable {
        /// Distance thresholds for each LOD level (in world units)
        public let distanceThresholds: [(distance: Float, level: UInt8)]

        /// Maximum level to render (highest detail)
        public let maxLevel: UInt8

        /// Minimum level to render (lowest detail)
        public let minLevel: UInt8

        public init(
            distanceThresholds: [(distance: Float, level: UInt8)] = [
                (10, 10),   // High detail within 10 units
                (50, 7),    // Medium-high detail within 50 units
                (100, 5),   // Medium detail within 100 units
                (500, 3),   // Low detail within 500 units
                (1000, 1)   // Very low detail beyond
            ],
            maxLevel: UInt8 = 10,
            minLevel: UInt8 = 0
        ) {
            // Sort thresholds by distance
            self.distanceThresholds = distanceThresholds.sorted { $0.distance < $1.distance }
            self.maxLevel = maxLevel
            self.minLevel = minLevel
        }

        /// Default configuration with standard distance-based LOD
        public static let `default` = Config()

        /// Aggressive LOD for performance (lower detail at all distances)
        public static let performance = Config(
            distanceThresholds: [
                (10, 7),
                (50, 5),
                (100, 3),
                (500, 1)
            ],
            maxLevel: 7,
            minLevel: 0
        )

        /// Quality-focused LOD (higher detail at all distances)
        public static let quality = Config(
            distanceThresholds: [
                (20, 10),
                (100, 8),
                (200, 6),
                (500, 4),
                (1000, 2)
            ],
            maxLevel: 10,
            minLevel: 0
        )

        /// Create LOD configuration based on bounding box dimensions
        /// - Parameters:
        ///   - min: Minimum bounds of the point cloud
        ///   - max: Maximum bounds of the point cloud
        ///   - profile: LOD profile (adaptive, balanced, or aggressive)
        /// - Returns: Configuration with appropriate distance thresholds
        public static func fromBounds(
            min: simd_float3,
            max: simd_float3,
            profile: LODProfile = .balanced
        ) -> Config {
            let diagonal = simd_length(max - min)

            switch profile {
            case .adaptive:
                // High quality, more LOD levels
                return Config(
                    distanceThresholds: [
                        (diagonal * 0.1, 10),
                        (diagonal * 0.25, 8),
                        (diagonal * 0.5, 6),
                        (diagonal * 1.0, 4),
                        (diagonal * 2.0, 2)
                    ],
                    maxLevel: 10,
                    minLevel: 0
                )
            case .balanced:
                // Balanced quality and performance
                return Config(
                    distanceThresholds: [
                        (diagonal * 0.15, 10),
                        (diagonal * 0.3, 7),
                        (diagonal * 0.6, 5),
                        (diagonal * 1.5, 3)
                    ],
                    maxLevel: 10,
                    minLevel: 0
                )
            case .aggressive:
                // Performance-focused, fewer LOD levels
                return Config(
                    distanceThresholds: [
                        (diagonal * 0.2, 7),
                        (diagonal * 0.5, 5),
                        (diagonal * 1.0, 3)
                    ],
                    maxLevel: 7,
                    minLevel: 0
                )
            }
        }
    }

    /// LOD profile for automatic threshold calculation
    public enum LODProfile {
        /// High quality with more LOD transitions
        case adaptive
        /// Balanced quality and performance
        case balanced
        /// Performance-focused with fewer LOD levels
        case aggressive
    }

    public let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    /// Select appropriate LOD level based on distance from camera
    public func selectLevel(distance: Float) -> UInt8 {
        // Find the appropriate level based on distance
        for threshold in config.distanceThresholds {
            if distance < threshold.distance {
                return min(max(threshold.level, config.minLevel), config.maxLevel)
            }
        }

        // If beyond all thresholds, use minimum level
        return config.minLevel
    }

    /// Filter cells to render based on LOD criteria
    public func selectCells(
        _ cells: [OctreeCell],
        cameraPosition: simd_float3
    ) -> [OctreeCell] {
        var selectedCells: [OctreeCell] = []
        var cellsByLevel: [UInt8: [OctreeCell]] = [:]

        // Group cells by level
        for cell in cells {
            cellsByLevel[cell.level, default: []].append(cell)
        }

        // For each cell, determine if it should be rendered at its level
        for cell in cells {
            let distance = cell.distance(to: cameraPosition)
            let targetLevel = selectLevel(distance: distance)

            // Render this cell if it matches the target level
            if cell.level == targetLevel {
                selectedCells.append(cell)
            }
        }

        return selectedCells
    }

    /// Select cells with hierarchical culling - prevents rendering parent and child simultaneously
    public func selectCellsHierarchical(
        _ cells: [OctreeCell],
        cameraPosition: simd_float3
    ) -> [OctreeCell] {
        var selectedCells: [OctreeCell] = []
        var processedRegions = Set<OctreeCellCode>()

        // Group cells by their code for easy parent-child lookup
        var cellsByCode: [OctreeCellCode: OctreeCell] = [:]
        for cell in cells {
            cellsByCode[cell.cellCode] = cell
        }

        // Start with root level cells
        let sortedCells = cells.sorted { $0.level < $1.level }

        for cell in sortedCells {
            // Skip if this region is already covered
            if isRegionCovered(cell.cellCode, in: processedRegions) {
                continue
            }

            let distance = cell.distance(to: cameraPosition)
            let targetLevel = selectLevel(distance: distance)

            // If this cell provides sufficient detail, use it
            if cell.level >= targetLevel {
                selectedCells.append(cell)
                processedRegions.insert(cell.cellCode)
            }
            // Otherwise, this cell is too coarse, but we'll still render it if no children available
            else {
                // Check if children exist that could provide better detail
                let hasChildrenInCells = hasChildren(of: cell.cellCode, in: cellsByCode)

                if !hasChildrenInCells {
                    // No better option available, render this cell
                    selectedCells.append(cell)
                    processedRegions.insert(cell.cellCode)
                }
            }
        }

        return selectedCells
    }

    private func isRegionCovered(_ cellCode: OctreeCellCode, in processedRegions: Set<OctreeCellCode>) -> Bool {
        // Check if any ancestor of this cell is already processed
        var currentLevel = cellCode.level
        var currentCode = cellCode.morton.code

        while currentLevel > 0 {
            currentLevel -= 1
            currentCode >>= 3

            if processedRegions.contains(OctreeCellCode(morton: MortonCode(code: currentCode), level: currentLevel)) {
                return true
            }
        }

        return false
    }

    private func hasChildren(of cellCode: OctreeCellCode, in cellsByCode: [OctreeCellCode: OctreeCell]) -> Bool {
        let childLevel = cellCode.level + 1

        // Check all 8 possible children
        for i in 0..<8 {
            let childCode = (cellCode.morton.code << 3) | UInt64(i)
            if cellsByCode[OctreeCellCode(morton: MortonCode(code: childCode), level: childLevel)] != nil {
                return true
            }
        }

        return false
    }
}
