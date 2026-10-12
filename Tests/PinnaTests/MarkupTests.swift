import AppKit
import Testing
@testable import Pinna

@MainActor
struct MarkupTests {
    @Test func cropKeepsThePixelsOfTheCroppedPart() {
        let base = Screenshot(image: makeImage(width: 400, height: 200), scale: 2) // 200 × 100 points
        var state = MarkupState()
        state.crop = CGRect(x: 50, y: 25, width: 100, height: 50)
        let result = MarkupRenderer.render(state, on: base)
        #expect(result.image.width == 200)
        #expect(result.image.height == 100)
        #expect(result.scale == 2)
        #expect(result.size == NSSize(width: 100, height: 50))
    }

    @Test func annotationsAreDrawnIn() throws {
        let base = Screenshot(image: makeImage(width: 100, height: 100, color: .white), scale: 1)
        var state = MarkupState()
        state.annotations = [Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 80, height: 80)), color: .black, size: .large)]
        let result = MarkupRenderer.render(state, on: base)
        #expect(result.image.width == 100)
        #expect(try darkness(of: result.image, atX: 10, yFromTop: 50) > 0.5) // on the left edge
        #expect(try darkness(of: result.image, atX: 50, yFromTop: 50) < 0.1) // in the middle
    }

    @Test func pixelatingMakesBlocksOfOneColor() throws {
        // Left half black, right half white: a block across the middle becomes gray.
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(.black)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        let base = Screenshot(image: context.makeImage()!, scale: 1)
        let annotation = Annotation(kind: .pixelate(CGRect(x: 0, y: 0, width: 40, height: 40)), color: .black, size: .large)
        let patch = try #require(MarkupRenderer.pixelatedPatch(for: annotation, in: base))
        #expect(patch.width == 40)
        #expect(patch.height == 40)
        // Three blocks across: the middle one straddles the edge.
        let middle = try darkness(of: patch, atX: 22, yFromTop: 5)
        #expect(middle > 0.2 && middle < 0.8)
    }

    @Test func arrowHeadPointsAtTheEnd() throws {
        let (_, head) = try #require(MarkupRenderer.arrowPaths(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4))
        let box = head.boundingBox
        #expect(box.maxX == 100)
        #expect(box.minX < 100)
        #expect(MarkupRenderer.arrowPaths(from: .zero, to: .zero, lineWidth: 4) == nil)
    }

    @Test func shiftMakesSquaresAndStraightLines() {
        let square = MarkupRenderer.rect(from: .zero, to: CGPoint(x: -30, y: 10), square: true)
        #expect(square == CGRect(x: -30, y: 0, width: 30, height: 30))
        let snapped = MarkupRenderer.snapped(CGPoint(x: 100, y: 10), from: .zero)
        #expect(abs(snapped.y) < 0.001)
        #expect(abs(snapped.x - hypot(100, 10)) < 0.001)
    }

    @Test func emptyStateChangesNothing() {
        #expect(MarkupState().isEmpty)
        var state = MarkupState()
        state.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(!state.isEmpty)
    }

    /// 0 for white, 1 for black.
    private func darkness(of image: CGImage, atX x: Int, yFromTop y: Int) throws -> CGFloat {
        let single = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return 1 - (CGFloat(bytes[0]) + CGFloat(bytes[1]) + CGFloat(bytes[2])) / (3 * 255)
    }
}
