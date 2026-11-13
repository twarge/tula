import ERPNextKit
import SwiftUI

/// A child table (invoice items etc.). Mirrors Desk's grid: a row number
/// column, user-choosable columns (gear menu, persisted per child DocType;
/// widths are content-sized, the native equivalent of Desk's width
/// settings), and a per-row button that opens the full row in a sheet — the
/// native take on Desk's pencil.
///
/// In an edit session the grid edits in place, as Desk's does: tapping a
/// line turns its columns into inputs, Add Row appends a line that is
/// editable at once, and Return or Tab walks the cells — past the last one
/// onto the next line, or onto a new line after the last. On a transaction,
/// leaving the item cell with a new item fills the line from the server —
/// name, UOM, rate (`ItemDetails`). The row sheet stays behind the pencil
/// for the fields the grid doesn't show.
struct ChildTableView: View {
    let title: String?
    let meta: DocTypeMeta
    let rows: [Document]
    let parentValues: [String: FrappeValue]
    /// Desk's per-user grid configuration for this child DocType, if any.
    let serverColumns: [GridColumn]?
    /// The parent document's fieldname for this table; non-nil while the
    /// enclosing screen is editing, which turns on row editing.
    let editFieldname: String?
    /// Whether lines may be added or deleted (`EditSession.allowsRowChanges`).
    let allowsRowChanges: Bool
    /// The DocType of the document these lines belong to. Decides whether
    /// picking an item fills the line from the server (`ItemDetails`).
    let parentDoctype: String?

    @Environment(AppModel.self) private var model
    @Environment(\.editSession) private var editSession
    @Environment(\.formScroll) private var formScroll
    @State private var visibleFieldnames: [String]
    @State private var detailRow: Document?
    @State private var editingRow: EditingRowSelection?
    @State private var active: ActiveRow?
    @State private var activations = 0
    /// The column to focus once the newly active line's editors exist.
    @State private var pendingFocus: String?
    /// The focused cell of the active line, by fieldname.
    @FocusState private var focusedColumn: String?
    /// How far down the table the cell being typed in reaches, suggestions
    /// included; nil when no cell has focus.
    @State private var revealBottom: CGFloat?
    @State private var suggestionsOpen = false
    @Namespace private var revealMarker
    /// The item the active line last came to rest on: what it held when the
    /// line became active, or what its details were last asked for.
    @State private var restingItem: String?
    /// Why the last item lookup brought nothing back, for the line under the
    /// table; nil once one succeeds.
    @State private var itemLookupError: String?

    struct EditingRowSelection: Identifiable {
        let index: Int
        /// The line's item was changed in the grid and the sheet opens
        /// before its details are back, so the sheet asks for them too.
        var fetchesItemDetails = false
        var id: Int { index }
    }

    /// The line being edited in place — one at a time, as in Desk.
    private struct ActiveRow {
        let index: Int
        /// The row's editability rules and current values. Cells write
        /// through it into the parent draft on every change.
        let session: EditSession
        /// New for every activation, so a line's editors never inherit the
        /// typing state of whichever line held that position before.
        let token: Int
        /// The edit session this belongs to; a leftover from an earlier
        /// session must not come back to life in the next.
        let parent: ObjectIdentifier
    }

    private enum FocusRequest {
        case column(String)
        case first
        case last
    }

    init(
        title: String?, meta: DocTypeMeta, rows: [Document],
        parentValues: [String: FrappeValue], serverColumns: [GridColumn]? = nil,
        editFieldname: String? = nil, allowsRowChanges: Bool = false,
        parentDoctype: String? = nil
    ) {
        self.title = title
        self.meta = meta
        self.rows = rows
        self.parentValues = parentValues
        self.serverColumns = serverColumns
        self.editFieldname = editFieldname
        self.allowsRowChanges = allowsRowChanges
        self.parentDoctype = parentDoctype
        // Precedence: this device's explicit choice → Desk grid settings →
        // the DocType's in_list_view defaults.
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey(meta.name))
        _visibleFieldnames = State(
            initialValue: stored ?? serverColumns?.map(\.fieldname)
                ?? meta.listFields.map(\.fieldname))
    }

    private static func storageKey(_ doctype: String) -> String {
        "childTableColumns.\(doctype)"
    }

    private var availableFields: [DocField] {
        meta.fields.filter { $0.fieldtype.isPresentable && !$0.hidden }
    }

    /// Visible columns in metadata order; falls back to the DocType's list
    /// fields if the user deselects everything.
    private var visibleFields: [DocField] {
        let chosen = availableFields.filter { visibleFieldnames.contains($0.fieldname) }
        return chosen.isEmpty ? meta.listFields : chosen
    }

    private var isEditing: Bool {
        editFieldname != nil && editSession != nil
    }

    /// The active line, if it still belongs to this edit session and still
    /// is the line at its index. Every cell edit lands in the row's session
    /// and the parent draft together, so the two differ only when something
    /// else changed the table (the row sheet, blank lines dropped at save) —
    /// and then the index may no longer mean the same line.
    private var current: ActiveRow? {
        guard let active, let editSession, editFieldname != nil,
            active.parent == ObjectIdentifier(editSession),
            rows.indices.contains(active.index),
            rows[active.index].raw == active.session.draft
        else { return nil }
        return active
    }

    /// Every line is as tall as an editor while editing, so a line doesn't
    /// change height when it becomes the active one.
    private var rowMinHeight: CGFloat? {
        isEditing ? InlineCellMetrics.controlHeight : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                columnsMenu
            }
            VStack(alignment: .leading, spacing: 0) {
                grid
                if isEditing, allowsRowChanges {
                    Divider()
                    // Below the lines, where Desk has it and where the new
                    // line appears.
                    Button {
                        addRow()
                    } label: {
                        Label("Add Row", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                if isEditing, let itemLookupError {
                    Label(itemLookupError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .coordinateSpace(.named(InlineCellMetrics.tableSpace))
            .overlay(alignment: revealsFooter ? .bottom : .top) { revealTarget }
            .onPreferenceChange(InlineCellRevealKey.self) { bottom in
                revealBottom = bottom
                revealFocusedCell()
            }
            .onPreferenceChange(InlineCellListOpenKey.self) { open in
                // The mark moves between the list and the table's foot.
                suggestionsOpen = open
                revealFocusedCell()
            }
            #if os(iOS)
                // The first cell of a line takes focus before the keyboard
                // is up, when there is nothing yet to scroll clear of.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardDidShowNotification)
                ) { _ in
                    revealFocusedCell()
                }
            #endif
        }
        .sheet(item: $detailRow) { row in
            ChildRowDetailSheet(meta: meta, row: row)
        }
        .sheet(item: $editingRow) { selection in
            if let editFieldname, let session = editSession {
                ChildRowEditor(
                    meta: meta, parentSession: session,
                    tableFieldname: editFieldname, index: selection.index,
                    allowsDelete: allowsRowChanges, parentDoctype: parentDoctype,
                    fetchesItemDetails: selection.fetchesItemDetails)
            }
        }
        .onChange(of: focusedColumn) { previous, _ in
            // Every way of picking an item ends with focus moving on.
            if previous == ItemDetails.itemField { settleItem() }
        }
        .onChange(of: active?.token) { _, _ in
            guard let pending = pendingFocus else { return }
            pendingFocus = nil
            // The line's editors are created by the same update that made it
            // active; focus can only land on one once it exists.
            Task { @MainActor in focusedColumn = pending }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                active = nil
                itemLookupError = nil
            }
        }
        #if os(iOS)
            .toolbar { keyboardBar }
        #endif
    }

    /// Scrolls the form the least it takes to show the cell being typed in
    /// (and its suggestions); not at all if they are already on screen.
    private func revealFocusedCell() {
        guard revealBottom != nil, let formScroll else { return }
        // A turn later, once the marker has been laid out where they end.
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                formScroll.scrollTo(revealMarker)
            }
        }
    }

    /// Clear space kept under the cell or its list. On iOS the keyboard's own
    /// bar floats over the bottom of the visible form, and has to be cleared
    /// too.
    #if os(iOS)
        private static let revealMargin: CGFloat = 84
    #else
        private static let revealMargin: CGFloat = 8
    #endif

    /// On the last line the form shows the whole table, Add Row included,
    /// instead of stopping at the cell: scrolled only as far as the cell,
    /// the button under it can end up behind the keyboard's bar. Not while
    /// suggestions are open, though — on a phone there isn't room for both,
    /// and the list is what is being used.
    private var revealsFooter: Bool {
        guard allowsRowChanges, !suggestionsOpen, let current else { return false }
        return current.index == rows.count - 1
    }

    /// An invisible mark at the bottom edge of the cell being typed in (or
    /// just under the table, see `revealsFooter`) — the thing the form
    /// scrolls to. It lives out here because the cell itself is inside the
    /// table's own sideways scroll view, which is as far as a scroll request
    /// for it would get.
    @ViewBuilder
    private var revealTarget: some View {
        if let revealBottom {
            Group {
                if revealsFooter {
                    Color.clear.frame(width: 1, height: Self.revealMargin)
                        .id(revealMarker)
                        // Hangs below the table instead of sitting in it.
                        .alignmentGuide(.bottom) { $0[.top] }
                } else {
                    VStack(spacing: 0) {
                        Color.clear.frame(width: 1, height: max(revealBottom, 0))
                        Color.clear.frame(width: 1, height: Self.revealMargin)
                            .id(revealMarker)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Columns

    private var columnsMenu: some View {
        Menu {
            ForEach(availableFields) { field in
                Toggle(isOn: columnBinding(for: field)) {
                    Text(field.label)
                }
            }
            Divider()
            Button("Reset Columns") {
                visibleFieldnames =
                    serverColumns?.map(\.fieldname) ?? meta.listFields.map(\.fieldname)
                UserDefaults.standard.removeObject(forKey: Self.storageKey(meta.name))
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose columns")
    }

    private func columnBinding(for field: DocField) -> Binding<Bool> {
        Binding {
            visibleFieldnames.contains(field.fieldname)
        } set: { isOn in
            if isOn {
                visibleFieldnames.append(field.fieldname)
            } else {
                visibleFieldnames.removeAll { $0 == field.fieldname }
            }
            persistColumns()
        }
    }

    private func persistColumns() {
        UserDefaults.standard.set(visibleFieldnames, forKey: Self.storageKey(meta.name))
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // No spacing between cells: each pads itself, so a line is one
            // unbroken tap target and the active line one unbroken band.
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("#")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .modifier(GridCell())
                    ForEach(visibleFields) { field in
                        header(field)
                    }
                    Text("")
                        .modifier(GridCell())
                }
                Divider()
                    .padding(.vertical, 3)
                // Index identity: new rows have no server name yet, so the
                // document id would collide.
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow(alignment: .top) {
                        rowCells(index: index, row: row)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 7)
        }
    }

    private func header(_ field: DocField) -> some View {
        HStack(spacing: 2) {
            Text(field.label)
            // Desk stars the columns a line can't be saved without.
            if isEditing, field.reqd {
                Text("*")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // A column whose cells can become editors keeps an editor's width,
        // so nothing shifts sideways when a line turns editable.
        .frame(
            minWidth: isEditing && InlineCellEditor.supports(field.fieldtype)
                && !field.readOnly
                ? InlineCellMetrics.minWidth(for: field.fieldtype) : nil,
            alignment: field.fieldtype.isNumeric ? .trailing : .leading
        )
        .modifier(GridCell(trailing: field.fieldtype.isNumeric))
    }

    @ViewBuilder
    private func rowCells(index: Int, row: Document) -> some View {
        let activeRow = current.flatMap { $0.index == index ? $0 : nil }
        let isActive = activeRow != nil

        Text("\(index + 1)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .modifier(GridCell(highlighted: isActive, minHeight: rowMinHeight))
            .modifier(
                TapToEdit(enabled: isEditing && !isActive) {
                    activate(index, focus: .first)
                })

        ForEach(visibleFields) { field in
            if let activeRow, isInlineEditable(field, in: activeRow.session) {
                InlineCellEditor(
                    field: field,
                    value: binding(for: field, in: activeRow),
                    row: activeRow.session,
                    focus: $focusedColumn,
                    navigation: navigation(from: field.fieldname, in: activeRow)
                )
                .id("\(activeRow.token).\(field.fieldname)")
                .modifier(GridCell(highlighted: true))
            } else {
                FieldValueView(
                    fieldname: field.fieldname,
                    fieldtype: field.fieldtype,
                    options: field.options,
                    value: row[field.fieldname],
                    currencyCode: ValueFormatting.currencyCode(
                        options: field.fieldtype == .currency ? field.options : nil,
                        rowValues: row.raw,
                        parentValues: parentValues,
                        fallback: model.fallbackCurrencyCode),
                    linkEnabled: false,
                    // Selectable text would swallow the click that makes
                    // the line editable.
                    selectable: !isEditing
                )
                .lineLimit(1)
                .modifier(
                    GridCell(
                        trailing: field.fieldtype.isNumeric, highlighted: isActive,
                        minHeight: rowMinHeight)
                )
                .modifier(
                    TapToEdit(enabled: isEditing && !isActive) {
                        activate(index, focus: .column(field.fieldname))
                    })
            }
        }

        HStack(spacing: 12) {
            if isEditing, allowsRowChanges {
                // Present on every line so the column keeps its width; live
                // only on the active one.
                Button(role: .destructive) {
                    deleteRow(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete row")
                .accessibilityLabel("Delete row \(index + 1)")
                .opacity(isActive ? 1 : 0)
                .disabled(!isActive)
                .accessibilityHidden(!isActive)
            }
            Button {
                if isEditing {
                    openFullRow(index)
                } else {
                    detailRow = row
                }
            } label: {
                Image(systemName: isEditing ? "pencil" : "info.circle")
            }
            .help(isEditing ? "Edit the full row" : "Row details")
            .accessibilityLabel(
                isEditing ? "Edit the full row \(index + 1)" : "Row \(index + 1) details")
        }
        .buttonStyle(.borderless)
        .modifier(GridCell(highlighted: isActive, minHeight: rowMinHeight))
    }

    // MARK: Editing in place

    /// A cell edits in the grid when its fieldtype has a grid editor and
    /// the row's own rules (read-only, docstatus, depends_on) allow it.
    private func isInlineEditable(_ field: DocField, in session: EditSession) -> Bool {
        InlineCellEditor.supports(field.fieldtype) && session.isEditable(field)
    }

    /// The columns the keyboard walks, in display order.
    private func focusTargets(in session: EditSession) -> [String] {
        visibleFields
            .filter {
                InlineCellEditor.takesKeyboardFocus($0.fieldtype) && session.isEditable($0)
            }
            .map(\.fieldname)
    }

    private func activate(_ index: Int, focus request: FocusRequest) {
        guard let editFieldname, let parent = editSession else { return }
        let tableRows = parent.rows(of: editFieldname)
        guard tableRows.indices.contains(index) else { return }
        // The line being left may have a newly picked item to look up.
        settleItem()
        let session = parent.rowSession(for: tableRows[index])
        activations += 1
        active = ActiveRow(
            index: index, session: session, token: activations,
            parent: ObjectIdentifier(parent))
        restingItem = tableRows[index][ItemDetails.itemField]?.nonEmptyString

        let targets = focusTargets(in: session)
        switch request {
        case .column(let fieldname):
            if targets.contains(fieldname) {
                pendingFocus = fieldname
            } else if let field = meta.field(named: fieldname),
                isInlineEditable(field, in: session) {
                // A menu, checkbox or date: the tap was for that control,
                // not for a keyboard.
                pendingFocus = nil
            } else {
                pendingFocus = targets.first
            }
        case .first:
            pendingFocus = targets.first
        case .last:
            pendingFocus = targets.last
        }
    }

    /// `settling: false` for a line that is going away, whose item needs no
    /// looking up.
    private func deactivate(settling: Bool = true) {
        if settling { settleItem() }
        active = nil
        pendingFocus = nil
        focusedColumn = nil
    }

    /// The pencil: the full row in a sheet.
    private func openFullRow(_ index: Int) {
        let unsettled = activeRowInDraft().map { $0.row.index == index && isItemUnsettled($0.row) }
        deactivate()
        editingRow = EditingRowSelection(index: index, fetchesItemDetails: unsettled ?? false)
    }

    private func addRow() {
        guard let editFieldname, let parent = editSession else { return }
        let index = parent.appendRow(to: editFieldname, doctype: meta.name)
        activate(index, focus: .first)
    }

    private func deleteRow(at index: Int) {
        guard let editFieldname, let parent = editSession else { return }
        deactivate(settling: false)
        itemLookupError = nil
        parent.removeRow(at: index, from: editFieldname)
    }

    private func binding(for field: DocField, in row: ActiveRow) -> Binding<FrappeValue?> {
        Binding(
            get: { row.session.draft[field.fieldname] },
            set: { write($0, to: field.fieldname, in: row) })
    }

    /// One cell edit: into the row's session, so its rules follow, and into
    /// the parent draft, which is what gets saved.
    private func write(_ value: FrappeValue?, to fieldname: String, in row: ActiveRow) {
        guard let editFieldname, let parent = editSession else { return }
        var draft = row.session.draft
        guard draft[fieldname] != value else { return }
        draft[fieldname] = value
        if fieldname == "qty" || fieldname == "rate" {
            draft = meta.settingRowAmount(in: draft)
        }
        row.session.draft = draft
        parent.setRow(draft, at: row.index, in: editFieldname)
    }

    // MARK: Item details

    /// Whether picking an item on these lines fills the line from the
    /// server, as Desk's transactions do.
    private var fillsItemDetails: Bool {
        ItemDetails.applies(parentDoctype: parentDoctype, childMeta: meta)
    }

    /// The active line, checked against the draft itself rather than against
    /// the rows this view was last drawn with: the callbacks that get here
    /// can run one draw behind the edit that caused them.
    private func activeRowInDraft() -> (row: ActiveRow, parent: EditSession, table: String)? {
        guard let active, let editFieldname, let parent = editSession,
            active.parent == ObjectIdentifier(parent)
        else { return nil }
        let tableRows = parent.rows(of: editFieldname)
        guard tableRows.indices.contains(active.index),
            tableRows[active.index] == active.session.draft
        else { return nil }
        return (active, parent, editFieldname)
    }

    private func isItemUnsettled(_ row: ActiveRow) -> Bool {
        fillsItemDetails
            && row.session.draft[ItemDetails.itemField]?.nonEmptyString != restingItem
    }

    /// The item cell has been left — focus moved on, or the line stopped
    /// being the active one. If the line's item changed since it last came
    /// to rest, this is the moment Desk asks the server what the item brings:
    /// its name, UOM, list price and defaults (`ItemDetails`). Not on every
    /// keystroke: until then the cell may hold half a code.
    private func settleItem() {
        guard let parentDoctype, let (row, parent, table) = activeRowInDraft(),
            isItemUnsettled(row)
        else { return }
        let asked = row.session.draft
        let item = asked[ItemDetails.itemField]?.nonEmptyString
        restingItem = item
        // Whatever the last lookup complained of, the line has moved on.
        itemLookupError = nil
        guard
            let item,
            let context = ItemDetails.arguments(
                parentDoctype: parentDoctype, parent: parent.draft, row: asked,
                childDoctype: meta.name)
        else { return }
        let index = row.index
        let source = model.dataSource
        Task { @MainActor in
            do {
                guard let details = try await source.itemDetails(context: context)
                else { return }
                applyItemDetails(details, asked: asked, at: index, in: table, of: parent)
            } catch {
                itemLookupError =
                    "Couldn't fetch details for \(item): \(error.localizedDescription)"
            }
        }
    }

    /// Lays the server's answer over the line it was asked for — in the
    /// draft, and in the line's own session if it is still the active one.
    private func applyItemDetails(
        _ details: [String: FrappeValue], asked: [String: FrappeValue], at index: Int,
        in table: String, of parent: EditSession
    ) {
        let tableRows = parent.rows(of: table)
        // A line deleted since, or given another item, isn't the line the
        // answer is about.
        guard tableRows.indices.contains(index),
            tableRows[index][ItemDetails.itemField] == asked[ItemDetails.itemField]
        else { return }
        let before = tableRows[index]
        let filled = ItemDetails.applying(details, to: before, asked: asked, meta: meta)
        guard filled != before else { return }
        parent.setRow(filled, at: index, in: table)
        if let active, active.index == index, active.parent == ObjectIdentifier(parent),
            active.session.draft == before {
            active.session.draft = filled
            // The server answers with the item's own spelling of its code.
            restingItem = filled[ItemDetails.itemField]?.nonEmptyString
        }
    }

    private func navigation(from fieldname: String, in row: ActiveRow) -> InlineCellNavigation {
        InlineCellNavigation(
            submit: {
                // Return on a last line nobody has typed into ends the
                // entry, rather than walking an empty line cell by cell.
                if row.index == rows.count - 1, isBlank(row.session.draft) {
                    deactivate()
                    return true
                }
                return move(from: fieldname, by: 1, in: row)
            },
            next: { move(from: fieldname, by: 1, in: row) },
            previous: { move(from: fieldname, by: -1, in: row) },
            vertical: { delta in
                let neighbour = row.index + delta
                guard rows.indices.contains(neighbour) else { return false }
                activate(neighbour, focus: .column(fieldname))
                return true
            },
            exit: { deactivate() })
    }

    /// Steps to the neighbouring cell: along the line, then onto the
    /// neighbouring line, then — forward off the last line — onto a new
    /// one, as Desk's Tab does. A last line that is still blank doesn't
    /// spawn another; the step reports false and focus is free to leave.
    @discardableResult
    private func move(from fieldname: String, by step: Int, in row: ActiveRow) -> Bool {
        let targets = focusTargets(in: row.session)
        if let position = targets.firstIndex(of: fieldname),
            targets.indices.contains(position + step) {
            focusedColumn = targets[position + step]
            return true
        }
        let neighbour = row.index + step
        if rows.indices.contains(neighbour) {
            activate(neighbour, focus: step > 0 ? .first : .last)
            return true
        }
        if step > 0, allowsRowChanges, !isBlank(row.session.draft) {
            addRow()
            return true
        }
        return false
    }

    /// A line with nothing in it yet: empty by Desk's rule (which is what
    /// save drops), or showing nothing in any column on screen.
    private func isBlank(_ row: [String: FrappeValue]) -> Bool {
        meta.isEmptyRow(row)
            || visibleFields.allSatisfy { row[$0.fieldname]?.isTruthy != true }
    }

    #if os(iOS)
        /// The number pads have no Return key, so the keyboard gets the
        /// cell-to-cell steps and a way to put itself away.
        @ToolbarContentBuilder
        private var keyboardBar: some ToolbarContent {
            if let row = current, let column = focusedColumn {
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        move(from: column, by: -1, in: row)
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Previous cell")
                    Button {
                        move(from: column, by: 1, in: row)
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .accessibilityLabel("Next cell")
                    Spacer()
                    // The line's own pencil is at its far end, which on a
                    // phone is usually scrolled out of sight.
                    Button {
                        openFullRow(row.index)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit the full row")
                    Button("Done") {
                        focusedColumn = nil
                    }
                }
            }
        }
    #endif
}

/// One grid cell's box. Cells fill their column and row so that backgrounds
/// and tap targets meet edge to edge.
private struct GridCell: ViewModifier {
    var trailing = false
    /// Part of the line being edited in place.
    var highlighted = false
    var minHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(minHeight: minHeight)
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: trailing ? .topTrailing : .topLeading
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(highlighted ? Color.accentColor.opacity(0.08) : .clear)
            // Filling the row must not make the row flexible: a grid shares
            // height out among flexible rows, so one line growing (a link
            // cell's suggestions) would stretch every other line with it.
            .gridCellUnsizedAxes(.vertical)
    }
}

/// Makes a display cell the way into editing its line. Absent rather than
/// inert outside an edit session, so reading keeps its own gestures.
private struct TapToEdit: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// The full child row rendered through the generic form renderer — every
/// field, laid out by the child DocType's own section/column breaks.
private struct ChildRowDetailSheet: View {
    let meta: DocTypeMeta
    let row: Document

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DocumentFormView(meta: meta, childMetas: [:], document: row)
                    .padding()
            }
            .navigationTitle(rowTitle)
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    private var rowTitle: String {
        if let titleField = meta.titleField, let title = row[titleField]?.nonEmptyString {
            return title
        }
        // Child rows have opaque autonames; prefer the first identifying value.
        let candidate = meta.listFields.first {
            ($0.fieldtype == .link || $0.fieldtype == .data)
                && row[$0.fieldname]?.nonEmptyString != nil
        }
        if let candidate, let value = row[candidate.fieldname]?.nonEmptyString {
            return value
        }
        return "Row Details"
    }
}

/// The full row as an editable form (W3), for the fields the grid doesn't
/// show: the row is copied into a local edit session rendered through the
/// same generic form; Done writes it back into the parent draft (with the
/// one convention-safe computation, amount = qty × rate), Cancel discards,
/// Delete removes the row. Picking an item here fills the row from the
/// server as it does in the grid.
private struct ChildRowEditor: View {
    let meta: DocTypeMeta
    let parentSession: EditSession
    let tableFieldname: String
    let index: Int
    let allowsDelete: Bool
    let parentDoctype: String?

    @State private var localSession: EditSession
    @State private var initialRow: Document
    /// The item the row last came to rest on; see `ChildTableView`.
    @State private var restingItem: String?
    @State private var itemLookupError: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(
        meta: DocTypeMeta, parentSession: EditSession, tableFieldname: String, index: Int,
        allowsDelete: Bool, parentDoctype: String? = nil, fetchesItemDetails: Bool = false
    ) {
        self.meta = meta
        self.parentSession = parentSession
        self.tableFieldname = tableFieldname
        self.index = index
        self.allowsDelete = allowsDelete
        self.parentDoctype = parentDoctype
        let rows = parentSession.rows(of: tableFieldname)
        let raw = rows.indices.contains(index) ? rows[index] : [:]
        _initialRow = State(initialValue: Document(raw: raw))
        _localSession = State(initialValue: parentSession.rowSession(for: raw))
        // Opened with an item whose details are still owed: nothing counts
        // as settled yet, so the first check asks for them.
        _restingItem = State(
            initialValue: fetchesItemDetails
                ? nil : raw[ItemDetails.itemField]?.nonEmptyString)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let itemLookupError {
                        Label(itemLookupError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DocumentFormView(meta: meta, childMetas: [:], document: initialRow)
                        .environment(\.editSession, localSession)
                }
                .padding()
            }
            .navigationTitle("Edit Row \(index + 1)")
            .onAppear {
                guard ItemDetails.applies(parentDoctype: parentDoctype, childMeta: meta)
                else { return }
                localSession.linkSettled = { fieldname in
                    if fieldname == ItemDetails.itemField { settleItem() }
                }
                settleItem()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if allowsDelete {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            parentSession.removeRow(at: index, from: tableFieldname)
                            dismiss()
                        } label: {
                            Label("Delete Row", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // amount = qty × rate (ARCHITECTURE §12); taxes
                        // and totals come back from the server on save.
                        parentSession.setRow(
                            meta.settingRowAmount(in: localSession.draft),
                            at: index, in: tableFieldname)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    /// The form's counterpart of the grid's lookup: once the item field's
    /// entry settles on a different item, fill the row from the server.
    private func settleItem() {
        guard let parentDoctype else { return }
        let session = localSession
        let asked = session.draft
        let item = asked[ItemDetails.itemField]?.nonEmptyString
        guard item != restingItem else { return }
        restingItem = item
        itemLookupError = nil
        guard
            let item,
            let context = ItemDetails.arguments(
                parentDoctype: parentDoctype, parent: parentSession.draft, row: asked,
                childDoctype: meta.name)
        else { return }
        let source = model.dataSource
        Task { @MainActor in
            do {
                guard let details = try await source.itemDetails(context: context),
                    session.draft[ItemDetails.itemField] == asked[ItemDetails.itemField]
                else { return }
                session.draft = ItemDetails.applying(
                    details, to: session.draft, asked: asked, meta: meta)
                restingItem = session.draft[ItemDetails.itemField]?.nonEmptyString
            } catch {
                itemLookupError =
                    "Couldn't fetch details for \(item): \(error.localizedDescription)"
            }
        }
    }
}
