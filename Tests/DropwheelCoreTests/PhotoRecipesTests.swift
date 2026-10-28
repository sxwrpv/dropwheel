import Foundation
import Testing
@testable import DropwheelCore

@Suite("PhotoAdjustments")
struct PhotoAdjustmentsTests {
    @Test("Neutral adjustments change nothing")
    func neutral() {
        #expect(PhotoAdjustments.neutral.isNeutral)
        var brighter = PhotoAdjustments.neutral
        brighter.exposure = 0.5
        #expect(!brighter.isNeutral)
    }

    @Test("Values are clamped into their ranges")
    func clamped() {
        var wild = PhotoAdjustments.neutral
        wild.exposure = 9
        wild.saturation = -5
        wild.grain = .nan
        let safe = wild.clamped()
        #expect(safe.exposure == PhotoAdjustments.exposureRange.upperBound)
        #expect(safe.saturation == -1)
        #expect(safe.grain == 0)
    }
}

@Suite("BackgroundRecipe")
struct BackgroundRecipeTests {
    @Test("Padding surrounds the photo evenly, measured on its long edge")
    func padding() {
        let recipe = BackgroundRecipe(aspect: .free, padding: 0.1, cornerRadius: 0, shadow: 0, fill: .color(.white))
        let layout = recipe.layout(imageWidth: 1000, imageHeight: 500)
        #expect(layout.canvasWidth == 1200 && layout.canvasHeight == 700)
        #expect(layout.imageRect == PixelRect(x: 100, y: 100, width: 1000, height: 500))
    }

    @Test("An aspect ratio widens the canvas without cropping the photo")
    func aspect() {
        let recipe = BackgroundRecipe(aspect: .square, padding: 0, cornerRadius: 0, shadow: 0, fill: .color(.white))
        let layout = recipe.layout(imageWidth: 1000, imageHeight: 500)
        #expect(layout.canvasWidth == 1000 && layout.canvasHeight == 1000)
        #expect(layout.imageRect == PixelRect(x: 0, y: 250, width: 1000, height: 500))
    }

    @Test("Corner radius is a share of the photo's short edge")
    func corners() {
        let recipe = BackgroundRecipe(aspect: .free, padding: 0, cornerRadius: 0.1, shadow: 0, fill: .color(.white))
        #expect(recipe.cornerRadiusPixels(imageWidth: 1000, imageHeight: 500) == 50)
    }
}

@Suite("Annotations")
struct AnnotationTests {
    @Test("A box drawn in any direction normalises to the same rectangle")
    func rectangleFromAnyDrag() {
        let a = NormalizedPoint(x: 0.8, y: 0.6)
        let b = NormalizedPoint(x: 0.2, y: 0.1)
        let rect = AnnotationGeometry.rect(from: a, to: b)
        #expect(abs(rect.x - 0.2) < 1e-9 && abs(rect.y - 0.1) < 1e-9)
        #expect(abs(rect.width - 0.6) < 1e-9 && abs(rect.height - 0.5) < 1e-9)
    }

    @Test("An arrowhead's barbs sit behind the tip, either side of the line")
    func arrowhead() {
        let barbs = AnnotationGeometry.arrowheadBarbs(from: (0, 0), to: (100, 0), length: 10)
        #expect(barbs.left.x < 100 && barbs.right.x < 100)
        #expect(barbs.left.y > 0 && barbs.right.y < 0)
    }
}

@Suite("Redaction")
struct RedactionTests {
    @Test("Vision boxes (origin bottom left) become editor boxes (origin top left), with a margin")
    func visionToEditor() {
        let region = RedactionRegion.fromVision(x: 0.1, y: 0.2, width: 0.3, height: 0.1, margin: 0)
        #expect(abs(region.rect.x - 0.1) < 1e-9)
        #expect(abs(region.rect.y - 0.7) < 1e-9)
        let padded = RedactionRegion.fromVision(x: 0.1, y: 0.2, width: 0.3, height: 0.1, margin: 0.05)
        #expect(padded.rect.width > region.rect.width && padded.rect.x < region.rect.x)
    }
}

@Suite("Photo editor tools")
struct PhotoEditorToolTests {
    @Test("Photos offer the four photo editors, which open editing windows")
    func catalog() {
        let tools = ToolCatalog.tools(for: [.input(.jpg)])
        #expect(tools.contains(.editPhoto) && tools.contains(.annotate) && tools.contains(.addBackground) && tools.contains(.redactPhoto))
        #expect(ToolKind.editPhoto.opensEditor && ToolKind.redactPhoto.opensEditor)
        #expect(!ToolCatalog.tools(for: [.input(.mp4)]).contains(.annotate))
    }
}
