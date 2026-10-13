import Foundation
import Testing
@testable import PiWidgetLayout

private func content(_ json: String) throws -> WidgetContent {
    try #require(WidgetContent(data: Data(json.utf8)))
}

@Test func storedContentAndSizes() throws {
    let widget = try content("""
    { "version": 1, "updatedAt": 1700000000000, "entries": [{ "date": null, "margins": false, "background": "#112233",
      "layouts": { "default": { "type": "text", "text": "hi" }, "circular": { "type": "symbol", "name": "airplane" } } }] }
    """)
    let entry = try #require(widget.entry(at: .now))
    #expect(entry.margins == false)
    #expect(entry.background == .string("#112233"))
    #expect(entry.layout(for: "large")?.string("text") == "hi")
    #expect(entry.layout(for: "circular")?.type == "symbol")
    // Lock Screen sizes without their own show the app's icon and name, not a Home Screen layout.
    #expect(entry.layout(for: "rectangular") == nil)
}

@Test func homeScreenSizesFallBackToEachOther() throws {
    let widget = try content("""
    { "entries": [{ "layouts": { "small": { "type": "text", "text": "small" } } }] }
    """)
    #expect(widget.entries[0].layout(for: "large")?.string("text") == "small")
    #expect(widget.entries[0].margins)
}

@Test func timelineEntries() throws {
    let widget = try content("""
    { "entries": [
      { "date": null, "layouts": { "default": { "type": "text", "text": "now" } } },
      { "date": 2000000000000, "layouts": { "default": { "type": "text", "text": "later" } } }] }
    """)
    #expect(widget.entry(at: Date(timeIntervalSince1970: 1_900_000_000))?.layouts["default"]?.string("text") == "now")
    #expect(widget.entry(at: Date(timeIntervalSince1970: 2_100_000_000))?.layouts["default"]?.string("text") == "later")
}

@Test func nodesAndLimits() throws {
    let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
    { "type": "vstack", "spacing": 4, "children": [{ "type": "text", "text": "a" }, { "nope": 1 }, { "type": "spacer" }] }
    """.utf8))
    let node = try #require(WidgetNode(json: json))
    #expect(node.type == "vstack")
    #expect(node.number("spacing") == 4)
    #expect(node.children.map(\.type) == ["text", "spacer"])
    #expect(node.props["children"] == nil)

    var deep: JSONValue = .object(["type": .string("text"), "text": .string("leaf")])
    for _ in 0..<40 { deep = .object(["type": .string("vstack"), "children": .array([deep])]) }
    var depth = 0
    var current = WidgetNode(json: deep)
    while let next = current?.children.first { depth += 1; current = next }
    #expect(depth == WidgetNode.maxDepth - 1)
}

@Test func appIDsAndURLs() {
    let app = WidgetApp(extensionName: "flights", name: "board", title: "Flights", icon: "airplane", description: nil, scope: "session:12")
    #expect(app.id == "flights/board@12")
    #expect(app.key == "flights/board")
    #expect(app.sessionId == 12)
    #expect(WidgetApp.parse(id: app.id).key == "flights/board")
    #expect(WidgetApp.parse(id: app.id).sessionId == 12)
    #expect(WidgetApp.parse(id: "mail/inbox").sessionId == nil)

    let url = WidgetLayout.openURL(app: app.id, target: "flight LY 315 & more")
    let parsed = WidgetLayout.parse(url)
    #expect(parsed?.app == app.id)
    #expect(parsed?.target == "flight LY 315 & more")
    #expect(WidgetLayout.parse(URL(string: "https://example.com")!) == nil)
}

@Test func colors() {
    #expect(Style.hex("fff") != nil)
    #expect(Style.hex("00000080") != nil)
    #expect(Style.hex("zzz") == nil)
    #expect(Style.color(.string("accent")) != nil)
    #expect(Style.shapeStyle(.object(["gradient": .string("linear"), "colors": .array([.string("red"), .string("#00f")])])) != nil)
    #expect(Style.insets(.object(["horizontal": .number(8)]))?.leading == 8)
}

@Test func viewsAndButtons() throws {
    let widget = try content("""
    { "entries": [{ "layouts": { "default": { "type": "button", "action": "refresh", "value": { "n": 1 },
        "children": [{ "type": "text", "text": "Refresh" }] } } }],
      "views": { "details": { "layouts": { "default": { "type": "text", "text": "Gate B7" } } } } }
    """)
    #expect(widget.views["details"]?.layout(for: "small")?.string("text") == "Gate B7")
    let button = try #require(widget.entries[0].layout(for: "medium"))
    #expect(button.type == "button")
    #expect(button.children.first?.string("text") == "Refresh")
    #expect(button.props["value"]?["n"] == .number(1))
}
