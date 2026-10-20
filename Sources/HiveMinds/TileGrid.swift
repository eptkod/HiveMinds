import SwiftUI
import AppKit

/// A tile you've sized by hand: where it sits and how big it is, in cells of a 6 × 6 snap grid that
/// covers the visible area. Fractions of the window rather than points, so it holds up when the window changes size.
struct TilePin: Codable, Hashable {
    var col: Int
    var row: Int
    var width: Int
    var height: Int

    static let columns = 6
    static let rows = 6

    var cells: Int { width * height }

    func overlaps(_ o: TilePin) -> Bool {
        col < o.col + o.width && o.col < col + width && row < o.row + o.height && o.row < row + height
    }

    /// Moved and shrunk as needed to sit inside the grid.
    var clamped: TilePin {
        let w = min(max(width, 1), Self.columns), h = min(max(height, 1), Self.rows)
        return TilePin(col: min(max(col, 0), Self.columns - w), row: min(max(row, 0), Self.rows - h), width: w, height: h)
    }

    /// The two put together, when that makes a rectangle.
    func union(_ o: TilePin) -> TilePin? {
        if col == o.col && width == o.width && (row + height == o.row || o.row + o.height == row) {
            return TilePin(col: col, row: min(row, o.row), width: width, height: height + o.height)
        }
        if row == o.row && height == o.height && (col + width == o.col || o.col + o.width == col) {
            return TilePin(col: min(col, o.col), row: row, width: width + o.width, height: height)
        }
        return nil
    }
}

/// Tiles laid out in a grid that fits the window, used by the Canvas and the meeting room.
/// Drag a tile by its title bar to move it: the others make room, and it snaps into the nearest slot.
/// Drag its bottom-right corner to size it: it snaps to the grid and keeps that size, and the tiles
/// you haven't sized share whatever space is left.
struct TileGrid<Tile: View>: View {
    let items: [UUID]
    /// Tiles you've sized by hand.
    let pins: [UUID: TilePin]
    /// Called with the new order when a dragged tile is dropped.
    let onReorder: ([UUID]) -> Void
    /// Called with every hand-sized tile once a move or resize ends.
    let onPin: ([UUID: TilePin]) -> Void
    /// A tile, given whether it's being dragged and the gesture its title bar should use.
    @ViewBuilder let tile: (UUID, Bool, AnyGesture<DragGesture.Value>) -> Tile

    /// The order on screen while a tile is being dragged. Saved when it's dropped.
    @State private var order: [UUID] = []
    @State private var dragging: UUID?
    @State private var dragStart: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    /// The hand-sized tiles while one is being moved or resized. Saved when it's let go.
    @State private var livePins: [UUID: TilePin]?
    @State private var resizing: UUID?
    /// Where the tile being resized started, in points and in cells.
    @State private var resizeFrame: CGRect = .zero
    @State private var resizeOrigin = TilePin(col: 0, row: 0, width: 1, height: 1)
    /// The page showing, when there are more tiles than fit and they carry on to the right.
    @State private var page = 0

    private let spacing: CGFloat = 10
    private let padding: CGFloat = 14
    private let minTileHeight: CGFloat = 260

    var body: some View {
        GeometryReader { geo in
            let ids = displayOrder(items)
            let layout = TileLayout(ids: ids, pins: livePins ?? pins, size: geo.size,
                                    spacing: spacing, padding: padding, minTileHeight: minTileHeight)
            let shown = min(page, layout.pages - 1)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if livePins != nil {
                        SnapGridLines(layout: layout)
                    }
                    ForEach(ids, id: \.self) { id in
                        if let slot = layout.frames[id] {
                            let isDragged = dragging == id
                            tile(id, isDragged, dragGesture(id: id, ids: ids, layout: layout))
                                .frame(width: slot.width, height: slot.height)
                                .overlay {
                                    if !isDragged {
                                        ResizeHandles { edges in
                                            resizeGesture(id: id, edges: edges, ids: ids, layout: layout)
                                        } onReset: {
                                            unpin(id)
                                        }
                                        .contextMenu {
                                            Button("Fit Automatically") { unpin(id) }
                                                .disabled(layout.placed[id] == nil)
                                            Button("Fit All Automatically") { withAnimation(Motion.bouncy) { onPin([:]) } }
                                                .disabled(layout.placed.isEmpty)
                                        }
                                    }
                                }
                                .position(isDragged
                                          ? CGPoint(x: dragStart.x + dragTranslation.width, y: dragStart.y + dragTranslation.height)
                                          : CGPoint(x: slot.midX, y: slot.midY))
                                .zIndex(isDragged ? 1 : 0)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                }
                // Tiles added, closed, reordered or resized from elsewhere spring into place. Not during a
                // drag, where the dragged tile has to stay under the pointer.
                .animation(dragging == nil && resizing == nil ? Motion.bouncy : nil, value: items)
                .animation(dragging == nil && resizing == nil ? Motion.bouncy : nil, value: pins)
                .frame(width: layout.contentWidth, height: geo.size.height, alignment: .topLeading)
                .offset(x: -CGFloat(shown) * geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .background(PagerAnchor(pages: layout.pages) { step in turn(by: step, of: layout.pages) })
            .overlay(alignment: .bottom) {
                if layout.pages > 1 {
                    PageDots(pages: layout.pages, current: shown) { target in turn(by: target - shown, of: layout.pages) }
                }
            }
        }
        .coordinateSpace(.named("grid"))
    }

    private func turn(by step: Int, of pages: Int) {
        let next = min(max(min(page, pages - 1) + step, 0), pages - 1)
        guard next != page else { return }
        withAnimation(Motion.pageTurn) { page = next }
    }

    /// The saved order, with anything the drag doesn't know about yet added at the end.
    private func displayOrder(_ current: [UUID]) -> [UUID] {
        guard dragging != nil else { return current }
        return order.filter(current.contains) + current.filter { !order.contains($0) }
    }

    private func unpin(_ id: UUID) {
        guard pins[id] != nil else { return }
        var next = pins
        next[id] = nil
        withAnimation(Motion.bouncy) { onPin(next) }
    }

    /// `pins` with one tile put at `target`. Hand-sized tiles it lands on go back to filling the space.
    /// Nil when that wouldn't leave every other tile at least one cell.
    private func placing(_ target: TilePin, for id: UUID, in pins: [UUID: TilePin], ids: [UUID]) -> [UUID: TilePin]? {
        var next = pins.filter { $0.key != id && !$0.value.overlaps(target) }
        next[id] = target
        let used = next.values.reduce(0) { $0 + $1.cells }
        let others = ids.count - next.count
        return TilePin.columns * TilePin.rows - used >= others ? next : nil
    }

    private func dragGesture(id: UUID, ids: [UUID], layout: TileLayout) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("grid"))
            .onChanged { value in
                if dragging != id {
                    order = ids
                    let start = layout.frames[id] ?? .zero
                    dragStart = CGPoint(x: start.midX, y: start.midY)
                    if layout.placed[id] != nil { livePins = layout.placed }
                    withAnimation(Motion.press) { dragging = id }
                    NSCursor.closedHand.push()
                }
                dragTranslation = value.translation
                let center = CGPoint(x: dragStart.x + value.translation.width, y: dragStart.y + value.translation.height)
                if let live = livePins, let pin = live[id] {
                    // A hand-sized tile keeps its size and snaps to the cells under it.
                    let target = layout.snap(center: center, width: pin.width, height: pin.height)
                    if target != pin, let next = placing(target, for: id, in: live, ids: ids) {
                        withAnimation(Motion.reflow) { livePins = next }
                    }
                } else {
                    // The others swap places with whichever filling tile is nearest.
                    let filling = ids.filter { layout.placed[$0] == nil }
                    let nearest = filling.min { a, b in
                        layout.distance(of: a, to: center) < layout.distance(of: b, to: center)
                    }
                    if let nearest, nearest != id,
                       let from = order.firstIndex(of: id), let to = order.firstIndex(of: nearest) {
                        withAnimation(Motion.reflow) {
                            order.remove(at: from)
                            order.insert(id, at: to)
                        }
                    }
                }
            }
            .onEnded { _ in
                NSCursor.pop()
                onReorder(order)
                if let live = livePins { onPin(live) }
                withAnimation(Motion.drop) {
                    dragging = nil
                    dragTranslation = .zero
                    livePins = nil
                }
            })
    }

    /// Dragging one of a tile's edges or corners: those edges follow the pointer, snapped to grid lines.
    private func resizeGesture(id: UUID, edges: Edge.Set, ids: [UUID], layout: TileLayout) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("grid"))
            .onChanged { value in
                if resizing != id {
                    resizeFrame = layout.frames[id] ?? .zero
                    resizeOrigin = layout.cells[id] ?? layout.pin(covering: resizeFrame)
                    livePins = layout.placed
                    resizing = id
                    NSCursor.frameResize(position: ResizeHandles.position(edges), directions: .all).push()
                }
                guard let live = livePins else { return }
                let target = layout.pin(resizing: resizeOrigin, from: resizeFrame, edges: edges, by: value.translation)
                if target != live[id], let next = placing(target, for: id, in: live, ids: ids) {
                    withAnimation(Motion.reflow) { livePins = next }
                }
            }
            .onEnded { _ in
                NSCursor.pop()
                if let live = livePins { onPin(live) }
                withAnimation(Motion.drop) {
                    resizing = nil
                    livePins = nil
                }
            })
    }
}

/// Turns the Canvas's pages on a sideways swipe anywhere over it, terminals included (SwiftTerm drops
/// sideways scrolls, and a scroll view needed a long swipe to page). A swipe is decided once it has moved
/// a few points: sideways ones turn the page after about 30 points and are kept from the tiles, up and down
/// ones are handed on untouched. It runs per scroll event, never on its own.
@MainActor
enum SidewaysScroll {
    private enum Route { case pass, undecided(PagerAnchor.View), pager(PagerAnchor.View) }
    private static var monitor: Any?
    /// Where the current swipe goes. Decided once per swipe; its momentum follows it.
    private static var route = Route.pass
    /// A swipe's first events, held until it's clear which way it's going, then handed to the tiles if it's
    /// up or down, so they still see the whole swipe.
    private static var held: [NSEvent] = []
    private static var moved = CGSize.zero
    private static var turned = false
    private static var replaying = false
    /// When a mouse wheel last turned the page, so one flick of a sideways wheel turns it once.
    private static var lastWheelTurn = Date.distantPast

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !replaying else { return event }
            let wheel = event.phase == [] && event.momentumPhase == []
            if wheel {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let pager = PagerAnchor.View.under(event) else { return event }
                if Date().timeIntervalSince(lastWheelTurn) > 0.35 {
                    lastWheelTurn = Date()
                    pager.turn(event.scrollingDeltaX < 0 ? 1 : -1)
                }
                return nil
            }
            if event.phase == .began || event.phase == .mayBegin {
                held = []
                moved = .zero
                turned = false
                route = PagerAnchor.View.under(event).map { .undecided($0) } ?? .pass
            }
            switch route {
            case .pass:
                return event
            case .pager(let pager):
                step(pager, event)
                return nil
            case .undecided(let pager):
                held.append(event)
                moved.width += abs(event.scrollingDeltaX)
                moved.height += abs(event.scrollingDeltaY)
                guard moved.width + moved.height >= 3 || event.phase == .ended || event.phase == .cancelled else { return nil }
                if moved.width > moved.height {
                    route = .pager(pager)
                    moved = .zero
                    held.forEach { step(pager, $0) }
                } else {
                    route = .pass
                    replaying = true
                    held.forEach { $0.window?.sendEvent($0) }
                    replaying = false
                }
                held = []
                return nil
            }
        }
    }

    /// Adds up a sideways swipe and turns the page once, when it has gone far enough.
    private static func step(_ pager: PagerAnchor.View, _ event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        moved.width += event.scrollingDeltaX
        if !turned && abs(moved.width) >= 30 {
            turned = true
            pager.turn(moved.width < 0 ? 1 : -1)
        }
    }
}

/// Sits behind a paged grid so `SidewaysScroll` can find it under the pointer and turn its pages.
struct PagerAnchor: NSViewRepresentable {
    let pages: Int
    let turn: (Int) -> Void

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        view.pages = pages
        view.onTurn = turn
    }

    final class View: NSView {
        var pages = 1
        var onTurn: ((Int) -> Void)?
        private static let all = NSHashTable<View>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Self.all.remove(self) } else { Self.all.add(self) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func turn(_ step: Int) { onTurn?(step) }

        /// The grid with more than one page under a scroll event, if any.
        static func under(_ event: NSEvent) -> View? {
            all.allObjects.first { view in
                guard view.pages > 1, view.window === event.window, !view.isHiddenOrHasHiddenAncestor else { return false }
                return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
        }
    }
}

/// One dot per page under a paged grid. Click one to go to that page.
private struct PageDots: View {
    let pages: Int
    let current: Int
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<pages, id: \.self) { i in
                Button { go(i) } label: {
                    Circle()
                        .fill(i == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 5, height: 5)
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Page \(i + 1) of \(pages)")
            }
        }
        .padding(.bottom, 1)
    }
}

/// Invisible strips along a tile's edges and squares at its corners. Hovering one shows the resize
/// cursor; dragging it sizes the tile. Double-click puts the tile back to fitting automatically.
private struct ResizeHandles: View {
    let gesture: (Edge.Set) -> AnyGesture<DragGesture.Value>
    let onReset: () -> Void

    private let edge: CGFloat = 6
    private let corner: CGFloat = 12

    var body: some View {
        ZStack {
            handle([.top], .top, width: nil, height: edge)
            handle([.bottom], .bottom, width: nil, height: edge)
            handle([.leading], .leading, width: edge, height: nil)
            handle([.trailing], .trailing, width: edge, height: nil)
            handle([.top, .leading], .topLeading, width: corner, height: corner)
            handle([.top, .trailing], .topTrailing, width: corner, height: corner)
            handle([.bottom, .leading], .bottomLeading, width: corner, height: corner)
            handle([.bottom, .trailing], .bottomTrailing, width: corner, height: corner)
        }
    }

    /// One strip or corner. An edge strip stops short of the corners, so they don't overlap.
    private func handle(_ edges: Edge.Set, _ alignment: Alignment, width: CGFloat?, height: CGFloat?) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.frameResize(position: Self.position(edges), directions: .all).push() } else { NSCursor.pop() }
            }
            .gesture(gesture(edges))
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            .help("Drag to resize. Double-click to fit automatically.")
            .padding(width == nil ? .horizontal : .vertical, width == nil || height == nil ? corner : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    static func position(_ edges: Edge.Set) -> NSCursor.FrameResizePosition {
        switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.leading), edges.contains(.trailing)) {
        case (true, _, true, _): .topLeft
        case (true, _, _, true): .topRight
        case (_, true, true, _): .bottomLeft
        case (_, true, _, true): .bottomRight
        case (true, _, _, _): .top
        case (_, true, _, _): .bottom
        case (_, _, true, _): .left
        default: .right
        }
    }
}

/// The snap grid, shown faintly while a tile is being sized or a sized tile is moved.
private struct SnapGridLines: View {
    let layout: TileLayout

    var body: some View {
        Path { path in
            for c in 0..<TilePin.columns {
                for r in 0..<TilePin.rows {
                    path.addRoundedRect(in: layout.rect(for: TilePin(col: c, row: r, width: 1, height: 1)),
                                        cornerSize: CGSize(width: 10, height: 10), style: .continuous)
                }
            }
        }
        .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Where every tile goes. With nothing sized by hand it's the even grid from `GridSlots`. Otherwise the
/// hand-sized tiles take their cells of the snap grid, and the rest split the leftover space between them.
struct TileLayout {
    /// Each tile's frame, in points.
    private(set) var frames: [UUID: CGRect] = [:]
    /// Hand-sized tiles that made it onto the grid, as saved.
    private(set) var placed: [UUID: TilePin] = [:]
    /// Those tiles' cells as drawn: bigger than saved when one soaks up a gap nothing else fits.
    private(set) var cells: [UUID: TilePin] = [:]
    private(set) var contentWidth: CGFloat = 0
    /// How many window-wide pages the tiles take. Hand-sized tiles stay on the first; tiles that
    /// don't fit beside them at a usable size go on pages to the right.
    private(set) var pages = 1
    private let spacing: CGFloat
    private let padding: CGFloat
    private let cell: CGSize

    init(ids: [UUID], pins: [UUID: TilePin], size: CGSize, spacing: CGFloat, padding: CGFloat, minTileHeight: CGFloat) {
        self.spacing = spacing
        self.padding = padding
        cell = CGSize(width: max((size.width - padding * 2 - spacing * CGFloat(TilePin.columns - 1)) / CGFloat(TilePin.columns), 0),
                      height: max((size.height - padding * 2 - spacing * CGFloat(TilePin.rows - 1)) / CGFloat(TilePin.rows), 0))

        // Hand-sized tiles in order; one that overlaps an earlier one goes back to filling.
        for id in ids {
            guard let pin = pins[id]?.clamped, !placed.values.contains(where: { $0.overlaps(pin) }) else { continue }
            placed[id] = pin
        }
        guard !placed.isEmpty else {
            let slots = GridSlots(count: ids.count, size: size, spacing: spacing, padding: padding, minTileHeight: minTileHeight)
            for (i, id) in ids.enumerated() { frames[id] = slots.frame(i) }
            contentWidth = slots.contentWidth
            pages = slots.pages
            return
        }
        cells = placed

        let filling = ids.filter { placed[$0] == nil }
        var free = Array(repeating: Array(repeating: true, count: TilePin.columns), count: TilePin.rows)
        for pin in placed.values {
            for r in pin.row..<pin.row + pin.height { for c in pin.col..<pin.col + pin.width { free[r][c] = false } }
        }
        var areas = Self.merged(Self.rectangles(free, rowsFirst: true))
        let columnsFirst = Self.merged(Self.rectangles(free, rowsFirst: false))
        if columnsFirst.count < areas.count { areas = columnsFirst }

        // As many tiles as fit beside the hand-sized ones without getting too small; the rest carry on
        // to the right, in pages laid out like an unsized Canvas.
        var onFirst = filling.count
        var first = fill(onFirst, areas: areas, ids: ids)
        while onFirst > 0 && !first.slots.allSatisfy({ $0.height >= minTileHeight && $0.width >= 300 }) {
            onFirst -= 1
            first = fill(onFirst, areas: areas, ids: ids)
        }
        if !filling.isEmpty { cells = first.cells }
        for (id, frame) in zip(filling, first.slots) { frames[id] = frame }
        for (id, pin) in cells { frames[id] = rect(for: pin) }

        let rest = Array(filling.dropFirst(onFirst))
        if !rest.isEmpty {
            let slots = GridSlots(count: rest.count, size: size, spacing: spacing, padding: padding, minTileHeight: minTileHeight)
            for (i, id) in rest.enumerated() { frames[id] = slots.frame(i).offsetBy(dx: size.width, dy: 0) }
            pages = 1 + slots.pages
        }
        contentWidth = size.width * CGFloat(pages)
    }

    /// The first page's free areas cut into `count` tiles, in reading order, and the hand-sized tiles'
    /// cells after growing over any gap left with no tile.
    private func fill(_ count: Int, areas: [TilePin], ids: [UUID]) -> (slots: [CGRect], cells: [UUID: TilePin]) {
        var areas = areas
        var cells = placed
        // More gaps than tiles to fill them: keep the biggest, and let a neighbour grow over the rest.
        if areas.count > count {
            let ranked = areas.sorted { $0.cells > $1.cells }
            var kept = Array(ranked.prefix(count))
            var spare = Array(ranked.dropFirst(count))
            var grew = true
            while grew && !spare.isEmpty {
                grew = false
                for (i, gap) in spare.enumerated() {
                    if let k = kept.firstIndex(where: { $0.union(gap) != nil }) {
                        kept[k] = kept[k].union(gap)!
                    } else if let id = ids.first(where: { cells[$0]?.union(gap) != nil }) {
                        cells[id] = cells[id]!.union(gap)!
                    } else { continue }
                    spare.remove(at: i)
                    grew = true
                    break
                }
            }
            areas = kept
        }
        guard count > 0 else { return ([], cells) }
        areas.sort { ($0.row, $0.col) < ($1.row, $1.col) }

        // Every area gets a tile, then each extra one goes where it leaves the most room per tile.
        var counts = Array(repeating: 1, count: areas.count)
        for _ in 0..<max(count - areas.count, 0) {
            if let i = areas.indices.max(by: { Double(areas[$0].cells) / Double(counts[$0] + 1) < Double(areas[$1].cells) / Double(counts[$1] + 1) }) {
                counts[i] += 1
            }
        }
        // Filled in reading order, so the tiles keep roughly the order they had.
        let slots = zip(areas, counts).flatMap { split(rect(for: $0), into: $1) }
            .sorted { ($0.minY.rounded(), $0.minX.rounded()) < ($1.minY.rounded(), $1.minX.rounded()) }
        return (slots, cells)
    }

    /// A span of cells in points.
    func rect(for pin: TilePin) -> CGRect {
        CGRect(x: padding + CGFloat(pin.col) * (cell.width + spacing),
               y: padding + CGFloat(pin.row) * (cell.height + spacing),
               width: CGFloat(pin.width) * cell.width + CGFloat(pin.width - 1) * spacing,
               height: CGFloat(pin.height) * cell.height + CGFloat(pin.height - 1) * spacing)
    }

    /// How far a tile's middle is from a point.
    func distance(of id: UUID, to point: CGPoint) -> CGFloat {
        guard let f = frames[id] else { return .infinity }
        return hypot(f.midX - point.x, f.midY - point.y)
    }

    /// The cells a tile of this many cells would snap to, centred on a point.
    func snap(center: CGPoint, width: Int, height: Int) -> TilePin {
        let size = rect(for: TilePin(col: 0, row: 0, width: width, height: height)).size
        let col = Int(((center.x - size.width / 2 - padding) / (cell.width + spacing)).rounded())
        let row = Int(((center.y - size.height / 2 - padding) / (cell.height + spacing)).rounded())
        return TilePin(col: col, row: row, width: width, height: height).clamped
    }

    /// `start` with the given edges moved by a drag to the nearest grid lines. Never smaller than one cell.
    func pin(resizing start: TilePin, from frame: CGRect, edges: Edge.Set, by drag: CGSize) -> TilePin {
        var left = start.col, right = start.col + start.width
        var top = start.row, bottom = start.row + start.height
        if edges.contains(.leading) { left = min(max(line(frame.minX + drag.width, along: \.width, leading: true), 0), right - 1) }
        if edges.contains(.trailing) { right = max(min(line(frame.maxX + drag.width, along: \.width, leading: false), TilePin.columns), left + 1) }
        if edges.contains(.top) { top = min(max(line(frame.minY + drag.height, along: \.height, leading: true), 0), bottom - 1) }
        if edges.contains(.bottom) { bottom = max(min(line(frame.maxY + drag.height, along: \.height, leading: false), TilePin.rows), top + 1) }
        return TilePin(col: left, row: top, width: right - left, height: bottom - top)
    }

    /// The cells closest to a frame in points.
    func pin(covering frame: CGRect) -> TilePin {
        let left = min(max(line(frame.minX, along: \.width, leading: true), 0), TilePin.columns - 1)
        let top = min(max(line(frame.minY, along: \.height, leading: true), 0), TilePin.rows - 1)
        let right = max(min(line(frame.maxX, along: \.width, leading: false), TilePin.columns), left + 1)
        let bottom = max(min(line(frame.maxY, along: \.height, leading: false), TilePin.rows), top + 1)
        return TilePin(col: left, row: top, width: right - left, height: bottom - top)
    }

    /// The grid line nearest a position: a cell's leading side, or the trailing side just before the gap.
    private func line(_ position: CGFloat, along axis: KeyPath<CGSize, CGFloat>, leading: Bool) -> Int {
        let step = cell[keyPath: axis] + spacing
        return Int(((position - padding + (leading ? 0 : spacing)) / step).rounded())
    }

    /// An area cut into `count` tiles: rows of about the same height, picked so the tiles come out
    /// closest to a terminal's usual shape. Rows lower down get fewer, wider tiles.
    private func split(_ area: CGRect, into count: Int) -> [CGRect] {
        guard count > 1 else { return [area] }
        let shape: (Int) -> Double = { rows in
            let perRow = Int(ceil(Double(count) / Double(rows)))
            let w = area.width / CGFloat(perRow), h = area.height / CGFloat(rows)
            return abs(log(max(Double(w / max(h, 1)), 0.01) / 1.5))
        }
        let rows = (1...count).min { shape($0) < shape($1) } ?? 1
        let height = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        var out: [CGRect] = []
        for r in 0..<rows {
            let inRow = count / rows + (r < count % rows ? 1 : 0)
            let width = (area.width - spacing * CGFloat(inRow - 1)) / CGFloat(inRow)
            for c in 0..<inRow {
                out.append(CGRect(x: area.minX + CGFloat(c) * (width + spacing), y: area.minY + CGFloat(r) * (height + spacing),
                                  width: max(width, 0), height: max(height, 0)))
            }
        }
        return out
    }

    /// The free cells as rectangles, scanning from the top left and growing each one across then
    /// down (or down then across).
    private static func rectangles(_ free: [[Bool]], rowsFirst: Bool) -> [TilePin] {
        var free = free
        var out: [TilePin] = []
        for r in 0..<TilePin.rows {
            for c in 0..<TilePin.columns where free[r][c] {
                var w = 1, h = 1
                if rowsFirst {
                    while c + w < TilePin.columns && free[r][c + w] { w += 1 }
                    while r + h < TilePin.rows && (c..<c + w).allSatisfy({ free[r + h][$0] }) { h += 1 }
                } else {
                    while r + h < TilePin.rows && free[r + h][c] { h += 1 }
                    while c + w < TilePin.columns && (r..<r + h).allSatisfy({ free[$0][c + w] }) { w += 1 }
                }
                for rr in r..<r + h { for cc in c..<c + w { free[rr][cc] = false } }
                out.append(TilePin(col: c, row: r, width: w, height: h))
            }
        }
        return out
    }

    /// Rectangles joined wherever two make a bigger one.
    private static func merged(_ rects: [TilePin]) -> [TilePin] {
        var rects = rects
        var joined = true
        while joined {
            joined = false
            outer: for i in rects.indices {
                for j in rects.indices where j > i {
                    if let u = rects[i].union(rects[j]) {
                        rects[i] = u
                        rects.remove(at: j)
                        joined = true
                        break outer
                    }
                }
            }
        }
        return rects
    }
}

/// Where each tile goes: 1, 2 or 3 columns depending on how many agents there are and how wide the
/// window is. Tiles share the height when they fit. Once they'd get too short, the grid fills a page the
/// width of the window and carries on onto pages to the right, so you swipe sideways rather than scroll
/// down through terminals. When a page's last row isn't full, the tiles above its empty slots stretch down to fill them.
struct GridSlots {
    let count: Int
    let columns: Int
    let rows: Int
    let pages: Int
    let pageWidth: CGFloat
    let tile: CGSize
    let spacing: CGFloat
    let padding: CGFloat
    let fits: Bool

    init(count: Int, size: CGSize, spacing: CGFloat, padding: CGFloat, minTileHeight: CGFloat) {
        self.count = count
        let wanted = count <= 1 ? 1 : count <= 4 ? 2 : 3
        columns = max(1, min(wanted, Int(size.width / 380)))
        let needed = max(1, Int(ceil(Double(count) / Double(columns))))
        let fitted = (size.height - padding * 2 - spacing * CGFloat(needed - 1)) / CGFloat(needed)
        fits = fitted >= minTileHeight
        if fits {
            rows = needed
        } else {
            rows = max(1, Int((size.height - padding * 2 + spacing) / (minTileHeight + spacing)))
        }
        pages = max(1, Int(ceil(Double(count) / Double(columns * rows))))
        pageWidth = size.width
        let width = (size.width - padding * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (size.height - padding * 2 - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        tile = CGSize(width: max(width, 0), height: max(height, minTileHeight))
        self.spacing = spacing
        self.padding = padding
    }

    var contentWidth: CGFloat { pageWidth * CGFloat(pages) }

    func frame(_ index: Int) -> CGRect {
        let perPage = columns * rows
        let page = index / perPage, slot = index % perPage
        let onPage = min(count - page * perPage, perPage)
        if pages > 1 && onPage < perPage {
            return fillingFrame(slot, of: onPage, page: page)
        }
        let col = slot % columns, row = slot / columns
        let stretch = slot + columns >= onPage && row < rows - 1
        return CGRect(x: CGFloat(page) * pageWidth + padding + CGFloat(col) * (tile.width + spacing),
                      y: padding + CGFloat(row) * (tile.height + spacing),
                      width: tile.width, height: stretch ? tile.height * 2 + spacing : tile.height)
    }

    /// A last page that isn't full: its tiles share the whole page, in as few rows as the columns allow,
    /// with any short row lowest and its tiles wider.
    private func fillingFrame(_ slot: Int, of onPage: Int, page: Int) -> CGRect {
        let pageRows = max(1, Int(ceil(Double(onPage) / Double(columns))))
        let pageHeight = tile.height * CGFloat(rows) + spacing * CGFloat(rows - 1)
        let height = (pageHeight - spacing * CGFloat(pageRows - 1)) / CGFloat(pageRows)
        var row = 0, first = 0
        var inRow = onPage / pageRows + (0 < onPage % pageRows ? 1 : 0)
        while slot >= first + inRow {
            first += inRow
            row += 1
            inRow = onPage / pageRows + (row < onPage % pageRows ? 1 : 0)
        }
        let width = (pageWidth - padding * 2 - spacing * CGFloat(inRow - 1)) / CGFloat(inRow)
        return CGRect(x: CGFloat(page) * pageWidth + padding + CGFloat(slot - first) * (width + spacing),
                      y: padding + CGFloat(row) * (height + spacing),
                      width: max(width, 0), height: height)
    }
}
