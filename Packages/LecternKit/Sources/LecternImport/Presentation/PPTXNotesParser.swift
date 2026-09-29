import Foundation

/// Structure and presenter notes read straight from a PPTX package (no PowerPoint needed).
public struct PPTXContents: Sendable, Equatable {
    /// Presenter notes by 1-based slide position in presentation order (slides without notes are absent).
    public var notes: [Int: String]
    public var slideCount: Int
    /// 1-based positions of slides marked hidden (`show="0"`).
    public var hiddenSlides: Set<Int>
}

/// Parses `ppt/presentation.xml`, its relationships, and each slide's notes slide.
///
/// The notes part for a slide is found through the slide's own relationships, never by assuming
/// `notesSlideN.xml` belongs to slide N (PowerPoint numbers notes parts in creation order).
public enum PPTXNotesParser {
    public static func parse(_ file: URL) throws -> PPTXContents {
        let zip = ZipEntryReader(archive: file)
        guard let presentation = try zip.data(for: "ppt/presentation.xml") else {
            throw ImportError.invalidPresentation("not a PowerPoint (.pptx) package")
        }
        let relationships = try relationshipTargets(in: zip, part: "ppt/presentation.xml")
        let slideParts = OrderedRelationshipIDs.parse(presentation).compactMap { relationships[$0]?.target }

        var notes: [Int: String] = [:]
        var hidden: Set<Int> = []
        for (offset, slidePart) in slideParts.enumerated() {
            let number = offset + 1
            if let slideXML = try zip.data(for: slidePart), SlideAttributes.isHidden(slideXML) { hidden.insert(number) }
            let slideRelationships = try relationshipTargets(in: zip, part: slidePart)
            guard let notesPart = slideRelationships.values.first(where: { $0.type.hasSuffix("/notesSlide") })?.target,
                  let notesXML = try zip.data(for: notesPart) else { continue }
            let text = NotesText.parse(notesXML).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { notes[number] = text }
        }
        return PPTXContents(notes: notes, slideCount: slideParts.count, hiddenSlides: hidden)
    }

    // MARK: - Relationships

    struct Relationship { var type: String; var target: String }

    /// Relationships of `part` (`ppt/slides/slide1.xml` → `ppt/slides/_rels/slide1.xml.rels`), with
    /// targets resolved to package paths.
    static func relationshipTargets(in zip: ZipEntryReader, part: String) throws -> [String: Relationship] {
        let directory = (part as NSString).deletingLastPathComponent
        let relsPath = "\(directory)/_rels/\((part as NSString).lastPathComponent).rels"
        guard let data = try zip.data(for: relsPath) else { return [:] }
        return RelationshipsParser.parse(data, relativeTo: directory)
    }

    /// Resolves `target` against the part's directory the way OPC does (absolute targets start with "/").
    static func resolve(_ target: String, relativeTo directory: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = directory.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }
}

// MARK: - XML helpers

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    private var result: [String: PPTXNotesParser.Relationship] = [:]
    private let directory: String

    private init(directory: String) { self.directory = directory }

    static func parse(_ data: Data, relativeTo directory: String) -> [String: PPTXNotesParser.Relationship] {
        let handler = RelationshipsParser(directory: directory)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"],
              attributeDict["TargetMode"] != "External" else { return }
        result[id] = PPTXNotesParser.Relationship(type: attributeDict["Type"] ?? "", target: PPTXNotesParser.resolve(target, relativeTo: directory))
    }
}

/// `r:id` values of `<p:sldId>` elements, in presentation order.
private final class OrderedRelationshipIDs: NSObject, XMLParserDelegate {
    private var ids: [String] = []

    static func parse(_ data: Data) -> [String] {
        let handler = OrderedRelationshipIDs()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.ids
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName.split(separator: ":").last == "sldId" else { return }
        // The relationship attribute is namespaced (`r:id`); the bare `id` is the numeric slide ID.
        if let key = attributeDict.keys.first(where: { $0.hasSuffix(":id") }), let value = attributeDict[key] { ids.append(value) }
    }
}

private enum SlideAttributes {
    /// True when the root `<p:sld>` element has `show="0"`.
    static func isHidden(_ data: Data) -> Bool {
        final class Root: NSObject, XMLParserDelegate {
            var hidden = false
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
                hidden = attributeDict["show"] == "0"
                parser.abortParsing()   // only the root element matters
            }
        }
        let handler = Root()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.hidden
    }
}

/// Text of the body placeholder(s) of a notes slide, one line per paragraph.
private final class NotesText: NSObject, XMLParserDelegate {
    private var notes: [String] = []
    private var shapeDepth = 0
    private var placeholderType: String?
    private var paragraphs: [String] = []
    private var current = ""
    private var insideText = false

    static func parse(_ data: Data) -> String {
        let handler = NotesText()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.notes.joined(separator: "\n")
    }

    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch local(elementName) {
        case "sp":
            shapeDepth += 1
            if shapeDepth == 1 { placeholderType = nil; paragraphs = []; current = "" }
        case "ph" where shapeDepth == 1:
            placeholderType = attributeDict["type"] ?? "body"
        case "br" where shapeDepth == 1:
            current += "\n"
        case "t" where shapeDepth == 1:
            insideText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch local(elementName) {
        case "t": insideText = false
        case "p" where shapeDepth == 1:
            paragraphs.append(current)
            current = ""
        case "sp":
            if shapeDepth == 1, placeholderType == "body" { notes.append(paragraphs.joined(separator: "\n")) }
            shapeDepth = max(0, shapeDepth - 1)
        default:
            break
        }
    }
}
