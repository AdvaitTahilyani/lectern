import Foundation
@testable import LecternImport

/// Builds a minimal but structurally faithful PPTX with `/usr/bin/zip`.
///
/// Presentation order is slide2.xml, slide1.xml, slide3.xml (hidden). Notes parts are numbered so
/// that "notesSlideN belongs to slide N" is false everywhere:
///   position 1 = slide2.xml → notesSlide1.xml, position 2 = slide1.xml → notesSlide2.xml, slide3 has none.
enum PPTXFixture {
    static let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
    static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func notesSlide(body: String, number: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes \(ns)><p:cSld><p:spTree>
          <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image"/><p:cNvSpPr/><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>
          <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/>
            <p:txBody><a:bodyPr/>\(body)</p:txBody></p:sp>
          <p:sp><p:nvSpPr><p:cNvPr id="4" name="Slide Number"/><p:cNvSpPr/><p:nvPr><p:ph type="sldNum" idx="10"/></p:nvPr></p:nvSpPr><p:spPr/>
            <p:txBody><a:p><a:fld type="slidenum"><a:t>\(number)</a:t></a:fld></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:notes>
        """
    }

    static func make(in directory: URL, name: String = "sample.pptx") throws -> URL {
        let root = directory.appendingPathComponent("pptx-src")
        func write(_ path: String, _ content: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func rels(_ entries: [(id: String, type: String, target: String)]) -> String {
            "<Relationships xmlns=\"\(relNS)\">" + entries.map { "<Relationship Id=\"\($0.id)\" Type=\"\(officeRel)/\($0.type)\" Target=\"\($0.target)\"/>" }.joined() + "</Relationships>"
        }
        try write("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        try write("ppt/presentation.xml", """
        <p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst><p:sldId id="257" r:id="rId12"/><p:sldId id="256" r:id="rId10"/><p:sldId id="258" r:id="rId11"/></p:sldIdLst></p:presentation>
        """)
        try write("ppt/_rels/presentation.xml.rels", rels([
            ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId10", "slide", "slides/slide1.xml"),
            ("rId11", "slide", "/ppt/slides/slide3.xml"),
            ("rId12", "slide", "slides/slide2.xml"),
        ]))
        try write("ppt/slides/slide1.xml", "<p:sld \(ns)><p:cSld/></p:sld>")
        try write("ppt/slides/slide2.xml", "<p:sld \(ns)><p:cSld/></p:sld>")
        try write("ppt/slides/slide3.xml", "<p:sld \(ns) show=\"0\"><p:cSld/></p:sld>")
        try write("ppt/slides/_rels/slide1.xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "notesSlide", "../notesSlides/notesSlide2.xml")]))
        try write("ppt/slides/_rels/slide2.xml.rels", rels([("rId1", "notesSlide", "../notesSlides/notesSlide1.xml"), ("rId2", "slideLayout", "../slideLayouts/slideLayout1.xml")]))
        try write("ppt/slides/_rels/slide3.xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]))
        try write("ppt/notesSlides/notesSlide1.xml", notesSlide(
            body: "<a:p><a:r><a:t>Notes for the </a:t></a:r><a:r><a:t>first position.</a:t></a:r></a:p><a:p><a:r><a:t>Second line &amp; more</a:t></a:r></a:p>",
            number: "1"))
        try write("ppt/notesSlides/notesSlide2.xml", notesSlide(
            body: "<a:p><a:r><a:t>Position two</a:t></a:r><a:br/><a:r><a:t>after a break</a:t></a:r></a:p><a:p><a:endParaRPr/></a:p>",
            number: "2"))

        let output = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: output)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-X", "-r", output.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return output
    }
}
