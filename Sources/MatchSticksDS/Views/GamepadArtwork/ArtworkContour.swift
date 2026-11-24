import AppKit

enum ArtworkContour {
    private struct Point: Hashable {
        let x: Int, y: Int
    }
    private struct Edge: Hashable {
        let from: Point, to: Point
    }

    static func paths(image: CGImage) -> [NSBezierPath] {
        let width = image.width, height = image.height
        guard let context = bitmapContext(image), width > 0, height > 0 else { return [] }
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func opaque(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return pixels[(y * width + x) * 4 + 3] >= 128
        }
        var edges = [Point: [Point]]()
        func add(_ from: Point, _ to: Point) { edges[from, default: []].append(to) }
        for y in 0..<height {
            for x in 0..<width where opaque(x, y) {
                if !opaque(x, y - 1) { add(Point(x: x, y: y), Point(x: x + 1, y: y)) }
                if !opaque(x + 1, y) { add(Point(x: x + 1, y: y), Point(x: x + 1, y: y + 1)) }
                if !opaque(x, y + 1) { add(Point(x: x + 1, y: y + 1), Point(x: x, y: y + 1)) }
                if !opaque(x - 1, y) { add(Point(x: x, y: y + 1), Point(x: x, y: y)) }
            }
        }
        let starts = edges.keys.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        var used = Set<Edge>()
        var result = [(path: NSBezierPath, area: Double)]()
        for start in starts {
            var current = start
            var points = [start]
            for _ in 0..<(width * height * 4) {
                guard let next = edges[current]?.first(where: { !used.contains(Edge(from: current, to: $0)) }) else { break }
                used.insert(Edge(from: current, to: next))
                points.append(next)
                if next == start { break }
                current = next
            }
            guard points.count > 4, points.last == start else { continue }
            let path = NSBezierPath()
            path.windingRule = .nonZero
            var previous = points[0]
            path.move(to: CGPoint(x: previous.x, y: previous.y))
            for index in 1..<(points.count - 1) {
                let point = points[index], next = points[index + 1]
                let first = (point.x - previous.x, point.y - previous.y)
                let second = (next.x - point.x, next.y - point.y)
                if first.0 == second.0 && first.1 == second.1 { continue }
                path.line(to: CGPoint(x: point.x, y: point.y))
                previous = point
            }
            path.close()
            if path.elementCount > 3 {
                let area = points.enumerated().reduce(0.0) { partial, item in
                    let next = points[(item.offset + 1) % points.count]
                    return partial + Double(item.element.x * next.y - next.x * item.element.y)
                } / 2
                result.append((path, area))
            }
        }
        guard let outer = result.max(by: { abs($0.area) < abs($1.area) }) else { return [] }
        return result.map { path, area in
            area * outer.area > 0 && path !== outer.path ? path.reversed : path
        }
    }

    static func cleanedBase(image: CGImage, handle: CGImage, pivot: CGPoint) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = bitmapContext(image), let handleContext = bitmapContext(handle),
              handle.width == width, handle.height == height,
              let silver = baseSilver(image: image, pivot: pivot) else { return nil }
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let handlePixels = handleContext.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where handlePixels[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let margin = 105
        minX = max(0, minX - margin); minY = max(0, minY - margin)
        maxX = min(width - 1, maxX + margin); maxY = min(height - 1, maxY + margin)
        func index(_ x: Int, _ y: Int) -> Int { y * width + x }
        func dark(_ x: Int, _ y: Int) -> Bool {
            let offset = index(x, y) * 4
            guard pixels[offset + 3] > 0 else { return false }
            let luminance = (Double(pixels[offset]) * 0.2126 + Double(pixels[offset + 1]) * 0.7152 + Double(pixels[offset + 2]) * 0.0722) / 255
            return luminance < 0.35
        }
        var queue = [Int]()
        for y in minY...maxY {
            for x in minX...maxX where handlePixels[index(x, y) * 4 + 3] > 16 {
                queue.append(index(x, y))
            }
        }
        var mask = Set(queue)
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let x = current % width, y = current / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= minX, nx <= maxX, ny >= minY, ny <= maxY, dark(nx, ny) else { continue }
                let next = index(nx, ny)
                if mask.insert(next).inserted { queue.append(next) }
            }
        }
        for position in mask {
            let offset = position * 4
            pixels[offset] = silver.0
            pixels[offset + 1] = silver.1
            pixels[offset + 2] = silver.2
            pixels[offset + 3] = 255
        }
        return context.makeImage()
    }

    private static func baseSilver(image: CGImage, pivot: CGPoint) -> (UInt8, UInt8, UInt8)? {
        let width = image.width, height = image.height
        guard let context = bitmapContext(image) else { return nil }
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var red = 0, green = 0, blue = 0, count = 0
        let center = Int(pivot.x)
        for y in Int(Double(height) * 0.82)..<Int(Double(height) * 0.9) {
            for x in max(0, center - 120)..<min(width, center + 120) {
                let offset = (y * width + x) * 4
                let luminance = (Double(pixels[offset]) * 0.2126 + Double(pixels[offset + 1]) * 0.7152 + Double(pixels[offset + 2]) * 0.0722) / 255
                guard pixels[offset + 3] > 128, luminance > 0.45 else { continue }
                red += Int(pixels[offset]); green += Int(pixels[offset + 1]); blue += Int(pixels[offset + 2]); count += 1
            }
        }
        guard count > 0 else { return nil }
        return (UInt8(red / count), UInt8(green / count), UInt8(blue / count))
    }

    private static func bitmapContext(_ image: CGImage) -> CGContext? {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }
}
