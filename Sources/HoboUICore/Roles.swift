/// The accessibility API a role name comes from.
public enum UIPlatform: String, Codable, Sendable {
    /// macOS accessibility (`AXButton`, with subroles such as `AXSwitch`).
    case macOS
    /// AT-SPI, by `Atspi.Accessible.get_role_name` (`push button`).
    case linux
    /// UI Automation, by control type programmatic name without `ControlType.` (`Button`).
    case windows
}

/// The role every guest's snapshots show: an ARIA role name, plus `window`, `text` and
/// `scrollarea` for what ARIA has no role for. Each platform's native roles map onto them as the
/// W3C Core Accessibility API Mappings (Core-AAM) map ARIA roles to AX, AT-SPI and UIA, read in
/// reverse, so `click --text Save --role button` means the same in every guest. A native role with
/// no mapping shows as itself, lowercased with spaces and an `AX` prefix dropped.
public enum UIRole {
    public static func aria(_ platform: UIPlatform, role native: String, subrole: String? = nil) -> String {
        switch platform {
        case .macOS:
            if let subrole, let role = macSubroles[subrole] { return role }
            return macRoles[native] ?? fallback(native)
        case .linux: return atspiRoles[native] ?? fallback(native)
        case .windows: return uiaRoles[native] ?? fallback(native)
        }
    }

    /// `AXDateField` → `datefield`, `page tab` → `pagetab`.
    public static func fallback(_ native: String) -> String {
        let name = native.hasPrefix("AX") ? String(native.dropFirst(2)) : native
        return name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Containers a person reads as unstructured: folded out of a snapshot when they have no name.
    public static let layout: Set<String> = ["group", "generic"]
    /// Roles whose element is on or off (`checked`).
    public static let checkable: Set<String> = ["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"]
    /// What a covering element is named by in a click's failure: the window, sheet, popover or
    /// menu it belongs to.
    public static let containers: Set<String> = ["window", "dialog", "alertdialog", "menu"]

    static let macSubroles: [String: String] = [
        "AXSwitch": "switch", "AXToggle": "switch", "AXSearchField": "searchbox", "AXTabButton": "tab",
        "AXOutlineRow": "treeitem", "AXDialog": "dialog", "AXSystemDialog": "dialog",
    ]

    static let macRoles: [String: String] = [
        "AXApplication": "application", "AXWindow": "window", "AXSheet": "dialog", "AXPopover": "dialog",
        "AXDrawer": "group", "AXButton": "button", "AXMenuButton": "button", "AXDisclosureTriangle": "button",
        "AXColorWell": "button", "AXPopUpButton": "combobox", "AXComboBox": "combobox", "AXCheckBox": "checkbox",
        "AXRadioButton": "radio", "AXToggle": "switch", "AXTextField": "textbox", "AXTextArea": "textbox",
        "AXStaticText": "text", "AXHeading": "heading", "AXLink": "link", "AXImage": "img", "AXGroup": "group",
        "AXSplitGroup": "group", "AXLayoutArea": "group", "AXLayoutItem": "group", "AXRadioGroup": "radiogroup",
        "AXUnknown": "generic", "AXList": "list", "AXOutline": "tree", "AXTable": "table", "AXGrid": "grid",
        "AXRow": "row", "AXColumn": "column", "AXCell": "cell", "AXMenuBar": "menubar", "AXMenuBarItem": "menuitem",
        "AXMenu": "menu", "AXMenuItem": "menuitem", "AXToolbar": "toolbar", "AXTabGroup": "tablist",
        "AXScrollArea": "scrollarea", "AXScrollBar": "scrollbar", "AXSlider": "slider", "AXIncrementor": "spinbutton",
        "AXProgressIndicator": "progressbar", "AXBusyIndicator": "progressbar", "AXLevelIndicator": "meter",
        "AXRelevanceIndicator": "meter", "AXSplitter": "separator", "AXHelpTag": "tooltip", "AXWebArea": "document",
    ]

    static let atspiRoles: [String: String] = [
        "application": "application", "frame": "window", "window": "window", "dialog": "dialog",
        "file chooser": "dialog", "alert": "alertdialog", "push button": "button", "push button menu": "button",
        "toggle button": "button", "check box": "checkbox", "radio button": "radio", "switch": "switch",
        "menu item": "menuitem", "tearoff menu item": "menuitem", "check menu item": "menuitemcheckbox",
        "radio menu item": "menuitemradio", "menu": "menu", "popup menu": "menu", "menu bar": "menubar",
        "text": "textbox", "entry": "textbox", "password text": "textbox", "editbar": "textbox", "label": "text",
        "static": "text", "caption": "text", "heading": "heading", "paragraph": "paragraph", "link": "link",
        "image": "img", "icon": "img", "panel": "group", "filler": "group", "grouping": "group",
        "layered pane": "group", "split pane": "group", "viewport": "group", "section": "generic",
        "glass pane": "generic", "root pane": "generic", "unknown": "generic", "redundant object": "generic",
        "list": "list", "list box": "listbox", "list item": "listitem", "tree": "tree", "tree table": "treegrid",
        "tree item": "treeitem", "table": "table", "table cell": "cell", "table row": "row",
        "table column header": "columnheader", "column header": "columnheader", "table row header": "rowheader",
        "row header": "rowheader", "page tab": "tab", "page tab list": "tablist", "scroll pane": "scrollarea",
        "scroll bar": "scrollbar", "slider": "slider", "dial": "slider", "spin button": "spinbutton",
        "progress bar": "progressbar", "level bar": "meter", "separator": "separator", "tool bar": "toolbar",
        "status bar": "status", "tool tip": "tooltip", "combo box": "combobox", "document frame": "document",
        "document web": "document", "document text": "document", "form": "form", "notification": "alert",
        "landmark": "region", "article": "article", "block quote": "blockquote", "calendar": "grid",
    ]

    static let uiaRoles: [String: String] = [
        "AppBar": "toolbar", "Button": "button", "Calendar": "grid", "CheckBox": "checkbox", "ComboBox": "combobox",
        "Custom": "generic", "DataGrid": "grid", "DataItem": "row", "Document": "document", "Edit": "textbox",
        "Group": "group", "Header": "row", "HeaderItem": "columnheader", "Hyperlink": "link", "Image": "img",
        "List": "list", "ListItem": "listitem", "Menu": "menu", "MenuBar": "menubar", "MenuItem": "menuitem",
        "Pane": "group", "ProgressBar": "progressbar", "RadioButton": "radio", "ScrollBar": "scrollbar",
        "SemanticZoom": "group", "Separator": "separator", "Slider": "slider", "Spinner": "spinbutton",
        "SplitButton": "button", "StatusBar": "status", "Tab": "tablist", "TabItem": "tab", "Table": "table",
        "Text": "text", "Thumb": "generic", "TitleBar": "generic", "ToolBar": "toolbar", "ToolTip": "tooltip",
        "Tree": "tree", "TreeItem": "treeitem", "Window": "window",
    ]
}
