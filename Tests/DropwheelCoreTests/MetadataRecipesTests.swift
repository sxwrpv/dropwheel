import Foundation
import Testing
@testable import DropwheelCore

private let probeJSON = """
{"streams":[
 {"index":0,"codec_type":"video","codec_name":"h264","disposition":{"attached_pic":0},
  "tags":{"language":"und","handler_name":"VideoHandler","vendor_id":"FFMP","encoder":"Lavc libx264"}},
 {"index":1,"codec_type":"data","codec_name":"bin_data","tags":{"handler_name":"Telemetry"}},
 {"index":2,"codec_type":"audio","codec_name":"aac","disposition":{"attached_pic":0},
  "tags":{"language":"eng","vendor_id":"[0][0][0][0]"}},
 {"index":3,"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}
],
"chapters":[{"id":0,"start_time":"0.000000","end_time":"10.500000","tags":{"title":"Intro"}},
            {"id":1,"start_time":"10.500000","end_time":"20.000000"}],
"format":{"tags":{"title":"Holiday","comment":"Old","major_brand":"isom","creation_time":"2024-01-02T03:04:05.000000Z",
                  "com.apple.quicktime.make":"Apple","com.apple.quicktime.title":"Clip"}}}
"""

private func sampleReport() throws -> MetadataReport {
    try #require(MetadataReport.parse(ffprobeJSON: Data(probeJSON.utf8)))
}

private func field(_ report: MetadataReport, _ key: String, in scope: MetadataScope = .file) throws -> MetadataField {
    try #require(report.fields.first { $0.key == key && $0.scope == scope })
}

@Suite("MetadataReport")
struct MetadataReportTests {
    @Test("Tags are grouped by file, track and chapter")
    func groups() throws {
        let titles = try sampleReport().groups.map(\.title)
        #expect(titles == ["File", "Track 1 · Video · H264", "Track 2 · Data · BIN_DATA · not kept in a copy", "Track 3 · Audio · AAC",
                           "Track 4 · Cover Art · MJPEG", "Chapter 1 · 0:00.000–0:10.500", "Chapter 2 · 0:10.500–0:20.000"])
    }

    @Test("A file with no tags at all still has a File group to add fields to")
    func emptyFile() throws {
        let report = try #require(MetadataReport.parse(ffprobeJSON: Data(#"{"streams":[],"format":{}}"#.utf8)))
        #expect(report.groups.map(\.title) == ["File"])
        #expect(report.fields.isEmpty)
    }

    @Test("A data track with no tags is still listed, as it won't reach the copy")
    func emptyDataTrack() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"data","codec_tag_string":"gpmd"}],"format":{}}"#
        let report = try #require(MetadataReport.parse(ffprobeJSON: Data(json.utf8)))
        #expect(report.groups.map(\.title) == ["File", "Track 1 · Data · GPMD · not kept in a copy"])
        #expect(report.keptTracks.isEmpty)
    }

    @Test("Chapter and timecode tracks aren't listed, as they are built again in the copy")
    func rebuiltTracks() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"audio","codec_name":"aac"},
                    {"index":1,"codec_type":"data","codec_name":"bin_data","codec_tag_string":"text","tags":{"handler_name":"Chapter"}},
                    {"index":2,"codec_type":"data","codec_tag_string":"tmcd","tags":{"timecode":"01:00:00:00"}}],"format":{}}
        """
        let report = try #require(MetadataReport.parse(ffprobeJSON: Data(json.utf8)))
        #expect(report.groups.map(\.title) == ["File", "Track 1 · Audio · AAC"])
        #expect(report.keptTracks == [0])
    }

    @Test("Text that isn't a probe result is refused")
    func notJSON() {
        #expect(MetadataReport.parse(ffprobeJSON: Data("nope".utf8)) == nil)
    }

    @Test("Fields written by the format itself are locked")
    func locked() throws {
        let report = try sampleReport()
        #expect(try field(report, "major_brand").access == .locked)
        #expect(try field(report, "vendor_id", in: .track(0)).access == .locked)
        #expect(try field(report, "title").access == .editable)
    }

    @Test("Blank vendor ids are left out")
    func blankVendor() throws {
        #expect(try sampleReport().fields.first { $0.key == "vendor_id" && $0.scope == .track(2) } == nil)
    }

    @Test("Data tracks can't be carried into a copy")
    func dataTracks() throws {
        let report = try sampleReport()
        #expect(report.keptTracks == [0, 2, 3])
        #expect(try !field(report, "handler_name", in: .track(1)).isKept)
        #expect(try field(report, "handler_name", in: .track(0)).isKept)
    }

    @Test("Editable fields come before locked ones, and each kind is in label order")
    func order() throws {
        let keys = try sampleReport().groups[0].fields.map(\.key)
        #expect(keys == ["com.apple.quicktime.make", "comment", "creation_time", "com.apple.quicktime.title", "title", "major_brand"])
    }

    @Test("Fields missing from a trial copy are marked as not kept; chapters and QuickTime keys aren't compared")
    func marksLost() throws {
        let report = try sampleReport()
        let copy = MetadataReport(groups: [
            MetadataGroup(scope: .file, title: "File", fields: [
                MetadataField(scope: .file, key: "TITLE", value: "Holiday"),
                MetadataField(scope: .file, key: "creation_time", value: "2024-01-02T03:04:05.000000Z"),
                MetadataField(scope: .file, key: "major_brand", value: "isom"),
            ]),
            MetadataGroup(scope: .track(1), title: "Audio", fields: [MetadataField(scope: .track(1), key: "language", value: "eng")]),
        ])
        let marked = report.markingLostFields(comparedTo: copy)
        #expect(try !field(marked, "comment").isKept)
        #expect(try field(marked, "title").isKept)
        #expect(try field(marked, "com.apple.quicktime.make").isKept)
        #expect(try field(marked, "language", in: .track(2)).isKept)
        #expect(try !field(marked, "encoder", in: .track(0)).isKept)
        #expect(try field(marked, "title", in: .chapter(0)).isKept)
    }

    @Test("A default the copy leaves unsaid isn't a loss")
    func defaultsStay() throws {
        let marked = try sampleReport().markingLostFields(comparedTo: MetadataReport(groups: []))
        #expect(try field(marked, "language", in: .track(0)).isKept)
        #expect(try field(marked, "handler_name", in: .track(0)).isKept)
    }
}

@Suite("MetadataDraft")
struct MetadataDraftTests {
    @Test("An untouched draft has nothing to save")
    func untouched() throws {
        let draft = MetadataDraft(report: try sampleReport())
        #expect(!draft.hasChanges)
        #expect(draft.recipe.changes.isEmpty)
    }

    @Test("Typing changes a field, and typing the original back undoes it")
    func typing() throws {
        let report = try sampleReport()
        let title = try field(report, "title")
        let draft = MetadataDraft(report: report).setting("Trip", for: title)
        #expect(draft.value(of: title) == "Trip")
        #expect(draft.recipe.changes == [MetadataChange(scope: .file, key: "title", value: "Trip", original: "Holiday")])
        #expect(draft.changedCount == 1)
        #expect(!draft.setting("Holiday", for: title).hasChanges)
    }

    @Test("Clearing a field removes it")
    func clearing() throws {
        let report = try sampleReport()
        let title = try field(report, "title")
        let draft = MetadataDraft(report: report).setting("  ", for: title)
        #expect(draft.recipe.changes == [MetadataChange(scope: .file, key: "title", value: nil, original: "Holiday")])
        #expect(draft.removedCount == 1)
    }

    @Test("A removed field can be restored, along with what was typed before")
    func restoring() throws {
        let report = try sampleReport()
        let title = try field(report, "title")
        let draft = MetadataDraft(report: report).setting("Trip", for: title).removing(title)
        #expect(draft.isRemoved(title))
        #expect(draft.recipe.changes.first?.value == nil)
        let restored = draft.restoring(title)
        #expect(!restored.isRemoved(title))
        #expect(restored.value(of: title) == "Trip")
    }

    @Test("Locked fields and fields a copy can't keep stay as they are")
    func protectedFields() throws {
        let report = try sampleReport()
        let brand = try field(report, "major_brand")
        let telemetry = try field(report, "handler_name", in: .track(1))
        let draft = MetadataDraft(report: report).setting("x", for: brand).removing(brand).removing(telemetry)
        #expect(!draft.hasChanges)
    }

    @Test("A report that can only be read offers nothing to add")
    func readOnly() {
        let title = MetadataField(scope: .file, key: "Title", value: "Report", access: .locked)
        let report = MetadataReport(groups: [MetadataGroup(scope: .file, title: "File", fields: [title])], isReadOnly: true)
        let draft = MetadataDraft(report: report)
        #expect(draft.addableKeys(to: .file, format: .pdf).isEmpty)
        #expect(!draft.adding(key: "Author", to: .file).hasChanges)
        #expect(draft.adding(key: "Author", to: .file).groups(matching: "")[0].fields == [title])
    }

    @Test("A removable field can't be retyped")
    func removableOnly() {
        let date = MetadataField(scope: .file, key: "CreationDate", value: "2024", access: .removable)
        let report = MetadataReport(groups: [MetadataGroup(scope: .file, title: "File", fields: [date])])
        let draft = MetadataDraft(report: report)
        #expect(!draft.setting("2025", for: date).hasChanges)
        #expect(draft.removing(date).hasChanges)
    }

    @Test("A new field joins its group; left blank it saves nothing")
    func adding() throws {
        let report = try sampleReport()
        let draft = MetadataDraft(report: report).adding(key: "artist", to: .file)
        let added = try #require(draft.groups(matching: "")[0].fields.first { $0.key == "artist" })
        #expect(!draft.hasChanges)
        let filled = draft.setting("Jo", for: added)
        #expect(filled.recipe.changes == [MetadataChange(scope: .file, key: "artist", value: "Jo", original: nil)])
        #expect(filled.changedCount == 1)
    }

    @Test("Adding a field that exists does nothing")
    func addingTwice() throws {
        let report = try sampleReport()
        let draft = MetadataDraft(report: report).adding(key: "title", to: .file).adding(key: "artist", to: .file).adding(key: "artist", to: .file)
        #expect(draft.groups(matching: "")[0].fields.filter { $0.key == "artist" }.count == 1)
        #expect(draft.groups(matching: "")[0].fields.filter { $0.key == "title" }.count == 1)
    }

    @Test("Removing an added field forgets it")
    func removingAdded() throws {
        let report = try sampleReport()
        let draft = MetadataDraft(report: report).adding(key: "artist", to: .file)
        let added = try #require(draft.groups(matching: "")[0].fields.first { $0.key == "artist" })
        let removed = draft.setting("Jo", for: added).removing(added)
        #expect(!removed.hasChanges)
        #expect(removed.groups(matching: "")[0].fields.first { $0.key == "artist" } == nil)
    }

    @Test("Camera and processing data goes; what the user wrote stays")
    func cameraData() throws {
        let report = try sampleReport()
        let draft = MetadataDraft(report: report).removingCameraData()
        let removed = Set(draft.recipe.changes.filter { $0.value == nil }.map(\.key))
        #expect(removed == ["com.apple.quicktime.make", "creation_time", "encoder", "handler_name"])
        #expect(draft.recipe.changes.allSatisfy { $0.scope != .track(1) })
        #expect(draft.hasCameraData == false)
        #expect(MetadataDraft(report: report).hasCameraData)
    }

    @Test("Search looks through labels, names, values and group titles", arguments: [
        ("HOLIDAY", ["title"]),
        ("camera make", ["com.apple.quicktime.make"]),
        ("major", ["major_brand"]),
        ("Intro", ["title"]),
    ])
    func search(query: String, keys: [String]) throws {
        let draft = MetadataDraft(report: try sampleReport())
        #expect(draft.groups(matching: query).flatMap(\.fields).map(\.key) == keys)
    }

    @Test("A search matching a group's title shows the whole group")
    func searchGroupTitle() throws {
        let groups = MetadataDraft(report: try sampleReport()).groups(matching: "track 3")
        #expect(groups.map(\.title) == ["Track 3 · Audio · AAC"])
        #expect(groups[0].fields.map(\.key) == ["language"])
    }

    @Test("A track with nothing in it and nothing to add is left out, unless it won't reach a copy")
    func shownGroups() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"audio","codec_name":"mp3"},{"index":1,"codec_type":"data","codec_tag_string":"gpmd"}],"format":{}}"#
        let draft = MetadataDraft(report: try #require(MetadataReport.parse(ffprobeJSON: Data(json.utf8))))
        #expect(draft.shownGroups(matching: "", format: .mp3).map(\.title) == ["File", "Track 2 · Data · GPMD · not kept in a copy"])
        #expect(draft.shownGroups(matching: "", format: .mkv).map(\.title) == ["File", "Track 1 · Audio · MP3", "Track 2 · Data · GPMD · not kept in a copy"])
    }

    @Test("Groups with nothing matching are left out")
    func searchNothing() throws {
        #expect(MetadataDraft(report: try sampleReport()).groups(matching: "zzz").isEmpty)
    }

    @Test("Search matches what has been typed, and what was there, so a row stays while it is edited")
    func searchTyped() throws {
        let report = try sampleReport()
        let draft = MetadataDraft(report: report).setting("Barcelona", for: try field(report, "title"))
        #expect(draft.groups(matching: "barcelona").flatMap(\.fields).map(\.key) == ["title"])
        #expect(draft.groups(matching: "holiday").flatMap(\.fields).map(\.key) == ["title"])
    }
}

@Suite("MetadataPlans")
struct MetadataPlansTests {
    private func change(_ scope: MetadataScope, _ key: String, _ value: String?, original: String? = "old") -> MetadataChange {
        MetadataChange(scope: scope, key: key, value: value, original: original)
    }

    @Test("Everything but data tracks is copied untouched, and no encoder name is added")
    func baseOptions() throws {
        let options = MetadataPlans.options(MetadataRecipe(changes: []), report: try sampleReport(), format: .mp4)
        #expect(options == ["-map", "0", "-map", "-0:d", "-c", "copy", "-fflags", "+bitexact"])
    }

    @Test("Changes and removals are written where each field lives")
    func changes() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "title", "New"), change(.file, "comment", nil),
                                              change(.chapter(0), "title", "Start")])
        let options = MetadataPlans.options(recipe, report: try sampleReport(), format: .mp4)
        #expect(options.suffix(6) == ["-metadata", "title=New", "-metadata", "comment=", "-metadata:c:0", "title=Start"])
    }

    @Test("Track numbers follow the copy, which has no data tracks")
    func trackNumbers() throws {
        let recipe = MetadataRecipe(changes: [change(.track(2), "language", "fra")])
        let options = MetadataPlans.options(recipe, report: try sampleReport(), format: .mp4)
        #expect(options.suffix(2) == ["-metadata:s:1", "language=fra"])
    }

    @Test("QuickTime track names are written back, as a copy would lose them otherwise")
    func keptTrackNames() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"audio","codec_name":"aac","tags":{"name":"Commentary"}}],"format":{}}"#
        let report = try #require(MetadataReport.parse(ffprobeJSON: Data(json.utf8)))
        let options = MetadataPlans.options(MetadataRecipe(changes: []), report: report, format: .m4a)
        #expect(options.suffix(2) == ["-metadata:s:0", "title=Commentary"])
        #expect(!MetadataPlans.options(MetadataRecipe(changes: []), report: report, format: .mkv).contains { $0.hasPrefix("title=") })
    }

    @Test("A changed track name is written once, with the new value")
    func changedTrackName() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"audio","codec_name":"aac","tags":{"name":"Commentary"}}],"format":{}}"#
        let report = try #require(MetadataReport.parse(ffprobeJSON: Data(json.utf8)))
        let recipe = MetadataRecipe(changes: [change(.track(0), "name", "Director")])
        let options = MetadataPlans.options(recipe, report: report, format: .mp4)
        #expect(options.filter { $0.hasPrefix("title=") } == ["title=Director"])
    }

    @Test("QuickTime keys are left to the atom written afterwards")
    func quickTimeKeysSkipped() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "com.apple.quicktime.title", "New")])
        let options = MetadataPlans.options(recipe, report: try sampleReport(), format: .mov)
        #expect(!options.contains { $0.contains("quicktime") })
    }

    @Test("The atom carries untouched and changed QuickTime keys, not removed ones")
    func quickTimeItems() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "com.apple.quicktime.make", nil),
                                              change(.file, "com.apple.quicktime.title", "New", original: "Clip")])
        #expect(MetadataPlans.quickTimeItems(recipe, report: try sampleReport(), format: .mov)
            == [QuickTimeItem(key: "com.apple.quicktime.title", value: "New")])
    }

    @Test("A new QuickTime key reaches the atom too")
    func newQuickTimeItem() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "com.apple.quicktime.comment", "Hi", original: nil)])
        #expect(MetadataPlans.quickTimeItems(recipe, report: try sampleReport(), format: .mov).map(\.key).contains("com.apple.quicktime.comment"))
    }

    @Test("Untouched values keep their stored form and order; changed ones become text")
    func storedQuickTimeItems() throws {
        let score = QuickTimeItem(key: "com.apple.quicktime.score", data: Data([0x3F, 0x60, 0, 0]), type: 23)
        let title = QuickTimeItem(key: "com.apple.quicktime.title", value: "Clip")
        let make = QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")
        let recipe = MetadataRecipe(changes: [change(.file, "com.apple.quicktime.title", "New", original: "Clip")])
        #expect(MetadataPlans.quickTimeItems(recipe, report: try sampleReport(), stored: [score, title, make], format: .mov)
            == [score, QuickTimeItem(key: "com.apple.quicktime.title", value: "New"), make])
    }

    @Test("Keys from other makers in the same atom aren't written back, as the editor says")
    func foreignAtomKeys() throws {
        let android = QuickTimeItem(key: "com.android.manufacturer", value: "Google")
        let make = QuickTimeItem(key: "com.apple.quicktime.make", value: "Apple")
        let recipe = MetadataRecipe(changes: [])
        #expect(MetadataPlans.quickTimeItems(recipe, report: try sampleReport(), stored: [android, make], format: .mov) == [make])
    }

    @Test("Outside QuickTime files those keys are ordinary tags")
    func quickTimeKeysElsewhere() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "com.apple.quicktime.title", "New", original: "Clip")])
        #expect(MetadataPlans.quickTimeItems(recipe, report: try sampleReport(), format: .mkv).isEmpty)
        #expect(MetadataPlans.options(recipe, report: try sampleReport(), format: .mkv).suffix(2)
            == ["-metadata", "com.apple.quicktime.title=New"])
    }

    @Test("Formats that need a nudge to store everything get it", arguments: [
        (FileFormat.aiff, ["-write_id3v2", "1"]),
        (FileFormat.wav, ["-rf64", "auto"]),
    ])
    func formatOptions(format: FileFormat, expected: [String]) throws {
        let options = MetadataPlans.options(MetadataRecipe(changes: []), report: try sampleReport(), format: format)
        #expect(options.suffix(2) == expected[...])
    }

    @Test("A QuickTime track name is written as the track title, the muxer's name for it")
    func trackName() throws {
        let recipe = MetadataRecipe(changes: [change(.track(0), "name", "Main")])
        for format in [FileFormat.mp4, .mov, .m4a] {
            #expect(MetadataPlans.options(recipe, report: try sampleReport(), format: format).suffix(2) == ["-metadata:s:0", "title=Main"])
        }
        #expect(MetadataPlans.options(recipe, report: try sampleReport(), format: .mkv).suffix(2) == ["-metadata:s:0", "name=Main"])
    }

    private func saved(_ fields: [MetadataField]) -> MetadataReport {
        MetadataReport(groups: [MetadataGroup(scope: .file, title: "File", fields: fields)])
    }

    @Test("A change that reached the file passes, however the key is cased")
    func verified() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "artist", "Jo")])
        let copy = saved([MetadataField(scope: .file, key: "ARTIST", value: "Jo")])
        #expect(MetadataPlans.missedChange(in: recipe, saved: copy, report: try sampleReport()) == nil)
    }

    @Test("A value the format reworded still counts")
    func reworded() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "creation_time", "2024-01-01T00:00:00Z", original: "2020-01-01T00:00:00.000000Z")])
        let copy = saved([MetadataField(scope: .file, key: "creation_time", value: "2024-01-01T00:00:00.000000Z")])
        #expect(MetadataPlans.missedChange(in: recipe, saved: copy, report: try sampleReport()) == nil)
    }

    @Test("A value that stayed as it was is reported")
    func stayed() throws {
        let wanted = change(.file, "date", "2024", original: "2020")
        let copy = saved([MetadataField(scope: .file, key: "date", value: "2020")])
        #expect(MetadataPlans.missedChange(in: MetadataRecipe(changes: [wanted]), saved: copy, report: try sampleReport()) == wanted)
    }

    @Test("A new field the format can't store is reported")
    func notStored() throws {
        let wanted = change(.file, "custom", "x", original: nil)
        #expect(MetadataPlans.missedChange(in: MetadataRecipe(changes: [wanted]), saved: saved([]), report: try sampleReport()) == wanted)
    }

    @Test("A removal passes once the value is gone, even if the format wrote its own")
    func removedAndReplaced() throws {
        let recipe = MetadataRecipe(changes: [change(.file, "encoder", nil, original: "Handbrake")])
        let copy = saved([MetadataField(scope: .file, key: "encoder", value: "Lavf")])
        #expect(MetadataPlans.missedChange(in: recipe, saved: copy, report: try sampleReport()) == nil)
    }

    @Test("A removal that left the value in place is reported")
    func notRemoved() throws {
        let wanted = change(.file, "title", nil, original: "Secret")
        let copy = saved([MetadataField(scope: .file, key: "title", value: "Secret")])
        #expect(MetadataPlans.missedChange(in: MetadataRecipe(changes: [wanted]), saved: copy, report: try sampleReport()) == wanted)
    }

    @Test("A default the format always writes doesn't count as staying behind")
    func regenerated() throws {
        let recipe = MetadataRecipe(changes: [change(.track(0), "handler_name", nil, original: "VideoHandler")])
        let copy = MetadataReport(groups: [MetadataGroup(scope: .track(0), title: "Track", fields: [
            MetadataField(scope: .track(0), key: "handler_name", value: "VideoHandler"),
        ])])
        #expect(MetadataPlans.missedChange(in: recipe, saved: copy, report: try sampleReport()) == nil)
    }

    @Test("Saved tracks are matched through the copy's own numbering")
    func trackMapping() throws {
        let recipe = MetadataRecipe(changes: [change(.track(2), "language", "fra", original: "eng")])
        let copy = MetadataReport(groups: [MetadataGroup(scope: .track(1), title: "Track", fields: [
            MetadataField(scope: .track(1), key: "language", value: "fra"),
        ])])
        #expect(MetadataPlans.missedChange(in: recipe, saved: copy, report: try sampleReport()) == nil)
    }
}

@Suite("MetadataRules")
struct MetadataRulesTests {
    @Test("Common names read as words", arguments: [
        ("title", "Title"),
        ("album_artist", "Album Artist"),
        ("ARTIST", "Artist"),
        ("com.apple.quicktime.location.ISO6709", "Location"),
        ("com.apple.quicktime.make", "Camera Make"),
        ("dc:creator", "Author"),
        ("tiff:Model", "Camera Model"),
        ("exif:FocalLength", "Focal Length"),
        ("exifEX:LensModel", "Lens"),
        ("some.vendor.fooBar", "Foo Bar"),
        ("handler_name", "Handler Name"),
        ("CreationDate", "Created"),
        ("png:tIME", "Last Modified"),
    ])
    func labels(key: String, label: String) {
        #expect(MetadataRules.label(for: key) == label)
    }

    @Test("Camera and processing fields", arguments: [
        "exif:GPSLatitude", "exif:DateTimeOriginal", "exifEX:LensModel", "tiff:Make", "xmp:CreatorTool", "xmpMM:DocumentID",
        "photoshop:History", "com.apple.quicktime.location.ISO6709", "com.android.version", "location", "encoder", "Producer", "ModDate",
        "png:parameters", "AnnotationAuthors",
    ])
    func camera(key: String) {
        #expect(MetadataRules.isCameraOrProcessing(key))
    }

    @Test("Fields people write themselves", arguments: [
        "title", "artist", "comment", "dc:title", "dc:rights", "exif:UserComment", "com.apple.quicktime.title",
        "com.apple.quicktime.description", "Title", "Author",
    ])
    func personal(key: String) {
        #expect(!MetadataRules.isCameraOrProcessing(key))
    }

    @Test("Each format offers only fields it can store")
    func addableFiles() {
        #expect(MetadataRules.addableKeys(for: .mp4, scope: .file).contains("album_artist"))
        #expect(!MetadataRules.addableKeys(for: .mov, scope: .file).contains("album_artist"))
        #expect(MetadataRules.addableKeys(for: .mov, scope: .file).contains("title"))
        #expect(MetadataRules.addableKeys(for: .wav, scope: .file) == ["title", "artist", "album", "genre", "date", "comment", "copyright", "track"])
        #expect(MetadataRules.addableKeys(for: .png, scope: .file) == ["dc:title", "dc:description", "dc:creator", "dc:rights", "dc:subject"])
        #expect(MetadataRules.addableKeys(for: .pdf, scope: .file) == ["Title", "Author", "Subject", "Keywords"])
    }

    @Test("Ogg keeps its tags on the audio track")
    func addableOgg() {
        #expect(MetadataRules.addableKeys(for: .ogg, scope: .file).isEmpty)
        #expect(MetadataRules.addableKeys(for: .opus, scope: .track(0)).contains("artist"))
    }

    @Test("Tracks and chapters offer their own fields")
    func addableParts() {
        #expect(MetadataRules.addableKeys(for: .mp4, scope: .track(0)) == ["language"])
        #expect(MetadataRules.addableKeys(for: .mkv, scope: .track(0)) == ["title", "language"])
        #expect(MetadataRules.addableKeys(for: .mp4, scope: .chapter(0)) == ["title"])
    }

    @Test("Formats with no tags on their tracks offer none", arguments: [FileFormat.mp3, .flac, .wav, .aiff, .avi, .wma])
    func noTrackTags(format: FileFormat) {
        #expect(MetadataRules.addableKeys(for: format, scope: .track(0)).isEmpty)
    }

    @Test("New fields are stored the way the XMP standard defines them")
    func valueKinds() {
        #expect(MetadataRules.valueKind(of: "dc:title") == .languageTagged)
        #expect(MetadataRules.valueKind(of: "dc:rights") == .languageTagged)
        #expect(MetadataRules.valueKind(of: "dc:creator") == .orderedList)
        #expect(MetadataRules.valueKind(of: "dc:subject") == .unorderedList)
        #expect(MetadataRules.valueKind(of: "tiff:Model") == .text)
    }

    @Test("Names can hold commas, so authors are separated otherwise")
    func listSeparators() {
        #expect(MetadataRules.listSeparator(for: "dc:creator") == ";")
        #expect(MetadataRules.listSeparator(for: "dc:subject") == ",")
    }

    @Test("A muxer's name and date can go, though the statistics beside them are locked")
    func statistics() {
        #expect(MetadataRules.access(forKey: "_STATISTICS_WRITING_APP", scope: .track(0)) == .editable)
        #expect(MetadataRules.isCameraOrProcessing("_STATISTICS_WRITING_DATE_UTC"))
        #expect(MetadataRules.access(forKey: "_STATISTICS_TAGS", scope: .track(0)) == .locked)
    }

    @Test("A name ffmpeg can't take as an argument is locked")
    func keyWithEquals() {
        #expect(MetadataRules.access(forKey: "odd=key", scope: .file) == .locked)
    }

    @Test("Edit Metadata covers images, PDFs, audio and video, one file at a time")
    func catalog() {
        for format in [FileFormat.jpg, .pdf, .mp3, .mov] {
            #expect(ToolCatalog.tools(for: [.input(format)]).contains(.editMetadata))
        }
        #expect(!ToolCatalog.tools(for: [.input(.gif)]).contains(.editMetadata))
        #expect(!ToolCatalog.tools(for: [.input(.bmp)]).contains(.editMetadata))
        #expect(!ToolCatalog.tools(for: [.input(.docx)]).contains(.editMetadata))
        #expect(ToolKind.editMetadata.opensEditor)
        #expect(!ToolKind.editMetadata.usesWholeSelection)
    }
}

@Suite("QuickTimeAtoms")
struct QuickTimeAtomsTests {
    private func uint32(_ data: Data, at offset: Int) -> Int {
        data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
    }

    private func text(_ data: Data, at offset: Int, length: Int) -> String {
        String(decoding: data[data.startIndex + offset..<data.startIndex + offset + length], as: UTF8.self)
    }

    @Test("A meta atom holds a handler, the key names, and the values by number")
    func layout() {
        let atom = QuickTimeAtoms.metadata([QuickTimeItem(key: "k.a", value: "hi")])
        #expect(text(atom, at: 4, length: 4) == "meta")
        #expect(uint32(atom, at: 0) == atom.count)

        let handlerStart = 8
        let handlerSize = uint32(atom, at: handlerStart)
        #expect(text(atom, at: handlerStart + 4, length: 4) == "hdlr")
        #expect(text(atom, at: handlerStart + 16, length: 4) == "mdta")

        let keysStart = handlerStart + handlerSize
        let keysSize = uint32(atom, at: keysStart)
        #expect(text(atom, at: keysStart + 4, length: 4) == "keys")
        #expect(uint32(atom, at: keysStart + 12) == 1)
        #expect(uint32(atom, at: keysStart + 16) == 8 + 3)
        #expect(text(atom, at: keysStart + 20, length: 4) == "mdta")
        #expect(text(atom, at: keysStart + 24, length: 3) == "k.a")

        let listStart = keysStart + keysSize
        #expect(text(atom, at: listStart + 4, length: 4) == "ilst")
        #expect(uint32(atom, at: listStart + 8) == 8 + 16 + 2)
        #expect(uint32(atom, at: listStart + 12) == 1)
        #expect(uint32(atom, at: listStart + 16) == 16 + 2)
        #expect(text(atom, at: listStart + 20, length: 4) == "data")
        #expect(uint32(atom, at: listStart + 24) == 1)
        #expect(text(atom, at: listStart + 32, length: 2) == "hi")
        #expect(listStart + uint32(atom, at: listStart) == atom.count)
    }

    @Test("Key numbers count from one")
    func numbering() {
        let atom = QuickTimeAtoms.metadata([QuickTimeItem(key: "a", value: "1"), QuickTimeItem(key: "b", value: "2")])
        let handlerSize = uint32(atom, at: 8)
        let keysSize = uint32(atom, at: 8 + handlerSize)
        let listStart = 8 + handlerSize + keysSize
        #expect(uint32(atom, at: listStart + 12) == 1)
        let firstItemSize = uint32(atom, at: listStart + 8)
        #expect(uint32(atom, at: listStart + 8 + firstItemSize + 4) == 2)
    }
}
