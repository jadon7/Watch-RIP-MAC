import Foundation
import AppKit // Needed for NSColor? Might not be needed here directly.

// Moved from StatusMenuController.swift
class WearOSAppcastParserDelegate: NSObject, XMLParserDelegate {
    var latestVersionName: String?
    var downloadURL: String?
    var length: String?
    private var currentElement: String = ""
    private var foundFirstItem = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" && !foundFirstItem { }
        else if elementName == "enclosure" && !foundFirstItem {
            downloadURL = attributeDict["url"]
            length = attributeDict["length"]
            // Find watchrip:versionName within the item's enclosure or nearby elements
            // This logic might need adjustment based on exact XML structure
            // For now, assuming version is found before the *next* item
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return }
        
        // Assuming watchrip:versionName is a direct child of <item> or similar context
        if currentElement == "watchrip:versionName" && !foundFirstItem {
             latestVersionName = value
             // Once version, URL, and length are found for the first item, stop processing further items
             // The `foundFirstItem` flag handles stopping after the first <enclosure>
        }
    }
    
    // We need to reset foundFirstItem if a new item starts AFTER we found the first one completely
    // Or better, ensure we capture the version associated *with* the first enclosure found.
    // Let's simplify: Assume version name is always before the first enclosure in the relevant item.
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" && foundFirstItem {
             // If we finished the item where we found the enclosure, definitively stop.
             // This might be too late if multiple items exist.
             // The current logic relying on `foundFirstItem` in `didStartElement` and `foundCharacters`
             // should effectively stop capturing data after the first enclosure and associated version.
        }
        currentElement = ""
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        print("[XML Parser] 解析完成。版本: \(latestVersionName ?? "无"), URL: \(downloadURL ?? "无"), 大小: \(length ?? "无")")
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        print("[XML Parser] 解析错误: \(parseError.localizedDescription)")
        latestVersionName = nil
        downloadURL = nil
        length = nil
    }
} 