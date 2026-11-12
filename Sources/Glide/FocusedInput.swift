import AppKit
import ApplicationServices

/// The element that has keyboard focus, read through Accessibility.
struct FocusedInput {
    /// true: a text input. false: something else. nil: the app does not say (some web and Electron apps).
    var isText: Bool?
    /// Text before the cursor, at most 1500 characters.
    var textBeforeCursor: String

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func current() -> FocusedInput {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return FocusedInput(isText: nil, textBeforeCursor: "")
        }
        let e = element as! AXUIElement

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
        var rangeValue: AnyObject?
        let hasRange = AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success

        let isText = textRoles.contains(role) || (settable.boolValue && hasRange)

        var before = ""
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &value) == .success, let text = value as? String {
            var range = CFRange(location: text.utf16.count, length: 0)
            if let r = rangeValue, CFGetTypeID(r) == AXValueGetTypeID() {
                AXValueGetValue(r as! AXValue, .cfRange, &range)
            }
            let end = min(max(0, range.location), text.utf16.count)
            let utf16 = Array(text.utf16.prefix(end))
            before = String(String(decoding: utf16, as: UTF16.self).suffix(1500))
        }
        return FocusedInput(isText: isText, textBeforeCursor: before)
    }
}
