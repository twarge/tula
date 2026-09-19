import Foundation

/// Frappe encodes form layout inline in the field sequence: `Tab Break`,
/// `Section Break`, and `Column Break` pseudo-fields partition the flat list.
/// This parser converts that into the tree the Desk UI renders — tabs
/// containing sections containing columns of fields — so any DocType,
/// including ones with server-side custom fields, lays out correctly with no
/// per-DocType code.
public struct FormLayout: Sendable {
    public struct Tab: Sendable, Identifiable {
        public let id: Int
        public var label: String
        public var sections: [Section]
        /// The Tab Break field that opened this tab (nil for the implicit
        /// first tab); carries `depends_on` for whole-tab visibility.
        public var breakField: DocField?
    }

    public struct Section: Sendable, Identifiable {
        public let id: Int
        public var label: String?
        public var collapsible: Bool
        /// Regular fields, split into side-by-side columns. Table MultiSelect
        /// fields flow here too: Desk renders them as a pill input, not a grid.
        public var columns: [[DocField]]
        /// Child-table fields render full-width below the columns.
        public var tables: [DocField]
        /// The Section Break field that opened this section (nil for the
        /// implicit first section); carries `depends_on`.
        public var breakField: DocField?

        public var isEmpty: Bool {
            columns.allSatisfy(\.isEmpty) && tables.isEmpty
        }
    }

    public var tabs: [Tab]

    public static func parse(_ meta: DocTypeMeta) -> FormLayout {
        var tabs: [Tab] = []
        var sections: [Section] = []
        var currentSection = Section(
            id: 0, label: nil, collapsible: false, columns: [[]], tables: [], breakField: nil)
        var currentTabLabel = "Details"
        var currentTabBreak: DocField?
        var nextSectionID = 1
        var nextTabID = 0

        func closeSection() {
            if !currentSection.isEmpty {
                sections.append(currentSection)
            }
            currentSection = Section(
                id: nextSectionID, label: nil, collapsible: false, columns: [[]], tables: [],
                breakField: nil)
            nextSectionID += 1
        }

        func closeTab() {
            closeSection()
            if !sections.isEmpty {
                tabs.append(
                    Tab(
                        id: nextTabID, label: currentTabLabel, sections: sections,
                        breakField: currentTabBreak))
                nextTabID += 1
            }
            sections = []
        }

        for field in meta.fields where !field.hidden {
            switch field.fieldtype {
            case .tabBreak:
                closeTab()
                currentTabLabel = field.label
                currentTabBreak = field
            case .sectionBreak, .fold:
                closeSection()
                currentSection.label = field.raw["label"]?.nonEmptyString
                currentSection.collapsible = field.collapsible
                currentSection.breakField = field
            case .columnBreak:
                currentSection.columns.append([])
            case .table:
                currentSection.tables.append(field)
            default:
                guard field.fieldtype.isPresentable else { continue }
                currentSection.columns[currentSection.columns.count - 1].append(field)
            }
        }
        closeTab()

        return FormLayout(tabs: tabs)
    }
}
