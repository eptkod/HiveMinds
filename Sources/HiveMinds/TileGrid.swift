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
/// Drag any edge or corner to size it: it snaps to the grid and keeps that size, and the tiles
/// you haven't sized share whatever space is left. While a tile is moved or sized it gets a ring, the
/// others dim a little, and a dashed outline shows where it will land.
struct TileGrid<Tile: View>: View {
    let items: [UUID]
    /// Tiles you've sized by hand.
    let pins: [UUID: TilePin]
    /// Called with the new order when a dragged tile is dropped.
    let onReorder: ([UUID]) -> Void
    /// Called with every hand-sized tile once a move or resize ends.
    let onPin: ([UUID: TilePin]) -> Void
    /// Tiles carried onto pages of their own, by group (see `TileLayout`).
    var groups: [UUID: Int] = [:]
    /// Called with the new groups when a tile is carried to another page. Without it, a tile can only be
    /// carried onto pages that are already there.
    var onGroup: (([UUID: Int]) -> Void)?
    /// A tile, given whether it's being dragged and the gesture its title bar should use.
    @ViewBuilder let tile: (UUID, Bool, AnyGesture<DragGesture.Value>) -> Tile

    /// The order on screen while a tile is being moved or sized. Saved when it's let go.
    @State private var order: [UUID] = []
    @State private var dragging: UUID?
    @State private var dragStart: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    /// The hand-sized tiles while one is being moved or resized. Saved when it's let go.
    @State private var livePins: [UUID: TilePin]?
    /// The page groups while a tile is being moved. Saved when it's let go.
    @State private var liveGroups: [UUID: Int]?
    @State private var resizing: UUID?
    /// Where the tile being resized started, in points on the visible page and in cells.
    @State private var resizeFrame: CGRect = .zero
    @State private var resizeOrigin = TilePin(col: 0, row: 0, width: 1, height: 1)
    /// The edges being dragged and how far, so an outline can follow the pointer exactly.
    @State private var resizeEdges: Edge.Set = []
    @State private var resizeTranslation: CGSize = .zero
    /// The page showing, when there are more tiles than fit and they carry on to the right.
    @State private var page = 0
    /// Which way the page turns while a moved tile is held at the grid's left (-1) or right (1) edge.
    @State private var edgeSide = 0
    @State private var edgeTurn: Task<Void, Never>?
    /// Whether holding at the edge has turned the page yet; if not, letting go there turns it once.
    @State private var edgeTurned = false

    private let spacing: CGFloat = 10
    /// How close to the grid's side a moved tile's pointer has to be to turn the page.
    private let edgeZone: CGFloat = 60
    private let padding: CGFloat = 14
    private let minTileHeight: CGFloat = 260
    private let corner: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let ids = displayOrder(items)
            let layout = makeLayout(ids, size: geo.size)
            let shown = min(page, layout.pages - 1)
            let active = dragging ?? resizing
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if livePins != nil {
                        SnapGridLines(layout: layout)
                    }
                    // Where the tile being moved will land.
                    if let dragging, let slot = layout.frames[dragging] {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                            .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .frame(width: slot.width, height: slot.height)
                            .position(x: slot.midX, y: slot.midY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    ForEach(ids, id: \.self) { id in
                        if let slot = layout.frames[id] {
                            let isDragged = dragging == id
                            tile(id, isDragged, dragGesture(id: id, ids: ids, layout: layout, size: geo.size, left: geo.frame(in: .global).minX))
                                .environment(\.tileWidth, slot.width)
                                .frame(width: slot.width, height: slot.height)
                                .overlay {
                                    // The tile you're holding, so it's clear which one moves.
                                    if active == id {
                                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                                            .scaleEffect(isDragged ? 1.03 : 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .overlay {
                                    if !isDragged {
                                        ResizeHandles { edges in
                                            resizeGesture(id: id, edges: edges, ids: ids, layout: layout, size: geo.size, shown: shown)
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
                                .opacity(active == nil || active == id ? 1 : 0.6)
                                .position(isDragged
                                          ? CGPoint(x: dragStart.x + dragTranslation.width, y: dragStart.y + dragTranslation.height)
                                          : CGPoint(x: slot.midX, y: slot.midY))
                                .zIndex(isDragged ? 2 : active == id ? 1 : 0)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                }
                // Tiles added, closed, reordered or resized from elsewhere spring into place. Not during a
                // drag, where the dragged tile has to stay under the pointer.
                .animation(active == nil ? Motion.bouncy : nil, value: items)
                .animation(active == nil ? Motion.bouncy : nil, value: pins)
                .animation(active == nil ? Motion.bouncy : nil, value: groups)
                .frame(width: layout.contentWidth, height: geo.size.height, alignment: .topLeading)
                .offset(x: -CGFloat(shown) * geo.size.width)

                // The size you're dragging out, right under the pointer; the tile itself snaps to the grid.
                if resizing != nil {
                    let rect = stretched(resizeFrame, edges: resizeEdges, by: resizeTranslation)
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }

                // The side a held tile is about to turn the page to.
                if edgeSide != 0 {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: 3, height: geo.size.height * 0.4)
                        .position(x: edgeSide > 0 ? geo.size.width - 4 : 4, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .animation(Motion.press, value: active)
            .animation(Motion.press, value: edgeSide)
#if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: TileGridDebug.hold)) {
                debugHold($0.object as? TileGridDebug.Hold, ids: ids, layout: layout, size: geo.size, shown: shown)
            }
#endif
            .background(PagerAnchor(pages: layout.pages) { step in turn(by: step, of: layout.pages) })
            .overlay(alignment: .bottom) {
                if layout.pages > 1 {
                    PageDots(pages: layout.pages, current: shown) { target in turn(by: target - shown, of: layout.pages) }
                }
            }
        }
        .coordinateSpace(.named("grid"))
    }

    /// The layout as it stands mid-gesture.
    private func makeLayout(_ ids: [UUID], pins: [UUID: TilePin]? = nil, groups: [UUID: Int]? = nil, size: CGSize) -> TileLayout {
        TileLayout(ids: ids, pins: pins ?? livePins ?? self.pins, groups: groups ?? liveGroups ?? self.groups, size: size,
                   spacing: spacing, padding: padding, minTileHeight: minTileHeight)
    }

    private func turn(by step: Int, of pages: Int) {
        let next = min(max(min(page, pages - 1) + step, 0), pages - 1)
        guard next != page else { return }
        withAnimation(Motion.pageTurn) { page = next }
    }

    /// The saved order, with anything the gesture doesn't know about yet added at the end.
    private func displayOrder(_ current: [UUID]) -> [UUID] {
        guard dragging != nil || resizing != nil else { return current }
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

    /// Applies new hand-sized tiles mid-gesture. The tiles filling the rest are handed the new spaces
    /// nearest where they are now, rather than in reading order, so they shift instead of swapping round.
    private func reflow(to next: [UUID: TilePin], size: CGSize) {
        let before = makeLayout(order, size: size)
        let after = makeLayout(order, pins: next, size: size)
        let filling = order.filter { after.placed[$0] == nil }
        let slots = filling.compactMap { after.frames[$0] }
        var seated: [UUID: Int] = [:]
        if slots.count == filling.count {
            var pairs: [(id: UUID, slot: Int, d: CGFloat)] = []
            for id in filling {
                guard let was = before.frames[id] else { continue }
                for (i, s) in slots.enumerated() { pairs.append((id, i, hypot(was.midX - s.midX, was.midY - s.midY))) }
            }
            var taken = Set<Int>()
            for p in pairs.sorted(by: { $0.d < $1.d }) where seated[p.id] == nil && !taken.contains(p.slot) {
                seated[p.id] = p.slot
                taken.insert(p.slot)
            }
            // Tiles new to the grid take whatever's left, in order.
            var free = slots.indices.filter { !taken.contains($0) }.makeIterator()
            for id in filling where seated[id] == nil { seated[id] = free.next() }
        }
        var refilled = filling.sorted { (seated[$0] ?? 0) < (seated[$1] ?? 0) }.makeIterator()
        let reordered = order.map { after.placed[$0] == nil ? refilled.next() ?? $0 : $0 }
        withAnimation(Motion.reflow) {
            livePins = next
            if seated.count == filling.count { order = reordered }
        }
    }

    /// `left` is where the grid starts in the window, to find the pointer from the mouse event itself.
    private func dragGesture(id: UUID, ids: [UUID], layout: TileLayout, size: CGSize, left: CGFloat) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("grid"))
            .onChanged {
                dragChanged(id: id, by: $0.translation, ids: ids, layout: layout, size: size)
                let x = NSApp.currentEvent.map { $0.locationInWindow.x - left } ?? $0.location.x
                holdAtEdge(x, id: id, size: size)
            }
            .onEnded { _ in dragEnded(size: size) })
    }

    /// A moved tile held at the grid's left or right edge turns the page that way after a moment, and
    /// keeps turning while it's held there, so you can carry a tile onto another page. The tile stays
    /// under the pointer and lands in the nearest slot on the new page.
    private func holdAtEdge(_ x: CGFloat, id: UUID, size: CGSize) {
        let side = x > size.width - edgeZone ? 1 : x < edgeZone ? -1 : 0
        let turnable = side != 0 && destination(of: id, side: side, layout: makeLayout(displayOrder(items), size: size)) != nil ? side : 0
        guard turnable != edgeSide else { return }
        edgeSide = turnable
        edgeTurn?.cancel()
        edgeTurn = nil
        guard turnable != 0 else { return }
        edgeTurned = false
        edgeTurn = Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, dragging == id else { return }
                guard carry(id, side: turnable, size: size) else {
                    edgeSide = 0
                    return
                }
                edgeTurned = true
            }
        }
    }

    /// The group a held tile joins when carried one page `side`, or nil when there's nowhere to go. Past the
    /// last page that's a new page of its own, unless it's already alone on the last page.
    private func destination(of id: UUID, side: Int, layout: TileLayout) -> Int? {
        let groups = liveGroups ?? self.groups
        let next = min(page, layout.pages - 1) + side
        if layout.pageGroups.indices.contains(next) { return layout.pageGroups[next] }
        guard side > 0, onGroup != nil else { return nil }
        let mine = groups[id] ?? 0
        guard displayOrder(items).contains(where: { $0 != id && (groups[$0] ?? 0) == mine }) else { return nil }
        return (displayOrder(items).map { groups[$0] ?? 0 }.max() ?? 0) + 1
    }

    /// Carries the held tile one page `side`: it joins that page's group (or a new page past the last), the
    /// grid turns to the page it's now on, and the tile slides along so it stays under the pointer, then takes
    /// the nearest slot there. False when there's nowhere to go.
    private func carry(_ id: UUID, side: Int, size: CGSize) -> Bool {
        let ids = displayOrder(items)
        let layout = makeLayout(ids, size: size)
        guard let target = destination(of: id, side: side, layout: layout) else { return false }
        let shown = min(page, layout.pages - 1)
        var groups = liveGroups ?? self.groups
        if target != (groups[id] ?? 0) {
            groups[id] = target == 0 ? nil : target
            // Hand-sized tiles only live on the first page.
            if let live = livePins, live[id] != nil, target != makeLayout(ids, groups: groups, size: size).pageGroups.first {
                var next = live
                next[id] = nil
                reflow(to: next, size: size)
            }
            withAnimation(Motion.reflow) { liveGroups = groups }
        }
        let after = makeLayout(ids, size: size)
        // The page the tile is on now: the next one, or where its group starts if earlier pages shrank.
        let landed = after.pageGroups.indices.contains(shown + side) && after.pageGroups[shown + side] == target
            ? shown + side : after.pageGroups.firstIndex(of: target) ?? shown
        withAnimation(Motion.pageTurn) {
            page = landed
            dragStart.x += CGFloat(landed - shown) * size.width
        }
        dragChanged(id: id, by: dragTranslation, ids: ids, layout: after, size: size)
        return true
    }

    private func dragChanged(id: UUID, by translation: CGSize, ids: [UUID], layout: TileLayout, size: CGSize) {
        if dragging != id {
            order = ids
            let start = layout.frames[id] ?? .zero
            dragStart = CGPoint(x: start.midX, y: start.midY)
            if layout.placed[id] != nil { livePins = layout.placed }
            withAnimation(Motion.press) { dragging = id }
            NSCursor.closedHand.push()
        }
        dragTranslation = translation
        let center = CGPoint(x: dragStart.x + translation.width, y: dragStart.y + translation.height)
        if let live = livePins, let pin = live[id] {
            if center.x > size.width {
                // Carried onto a later page. Hand-sized tiles live on the first, so it goes back to filling.
                var next = live
                next[id] = nil
                reflow(to: next, size: size)
                swapToNearest(id, center: center, layout: makeLayout(order, pins: next, size: size))
                return
            }
            // A hand-sized tile keeps its size and snaps to the cells under it.
            let target = layout.snap(center: center, width: pin.width, height: pin.height)
            if target != pin, let next = placing(target, for: id, in: live, ids: ids) {
                reflow(to: next, size: size)
            }
        } else {
            swapToNearest(id, center: center, layout: layout)
        }
    }

    /// A filling tile being moved swaps places with whichever filling tile is nearest.
    private func swapToNearest(_ id: UUID, center: CGPoint, layout: TileLayout) {
        let groups = liveGroups ?? self.groups
        let filling = order.filter { layout.placed[$0] == nil && (groups[$0] ?? 0) == (groups[id] ?? 0) }
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

    /// Groups renumbered 0, 1, 2… in page order, leaving out tiles that are gone and the first group.
    private static func compacted(_ groups: [UUID: Int], ids: [UUID]) -> [UUID: Int] {
        let keys = Set(ids.map { groups[$0] ?? 0 }).sorted()
        var out: [UUID: Int] = [:]
        for id in ids { if let i = keys.firstIndex(of: groups[id] ?? 0), i > 0 { out[id] = i } }
        return out
    }

    private func dragEnded(size: CGSize) {
        edgeTurn?.cancel()
        edgeTurn = nil
        // Let go at the edge before the page turned: it still goes to the page that way.
        if let dragging, edgeSide != 0, !edgeTurned { _ = carry(dragging, side: edgeSide, size: size) }
        edgeSide = 0
        NSCursor.pop()
        if order != items { onReorder(order) }
        if let live = livePins, live != pins { onPin(live) }
        if let live = liveGroups, live != groups { onGroup?(Self.compacted(live, ids: order)) }
        withAnimation(Motion.drop) {
            dragging = nil
            dragTranslation = .zero
            livePins = nil
            liveGroups = nil
        }
    }

    /// Dragging one of a tile's edges or corners: those edges follow the pointer, snapped to grid lines.
    /// Nothing else moves until the size actually changes by a cell.
    private func resizeGesture(id: UUID, edges: Edge.Set, ids: [UUID], layout: TileLayout, size: CGSize, shown: Int) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("grid"))
            .onChanged { resizeChanged(id: id, edges: edges, by: $0.translation, ids: ids, layout: layout, size: size, shown: shown) }
            .onEnded { _ in resizeEnded() })
    }

    private func resizeChanged(id: UUID, edges: Edge.Set, by translation: CGSize, ids: [UUID], layout: TileLayout, size: CGSize, shown: Int) {
        if resizing != id {
            order = ids
            // Measured on the visible page: a tile sized on a later page moves to the first one,
            // where the hand-sized tiles live, and the grid slides along with it.
            let frame = (layout.frames[id] ?? .zero).offsetBy(dx: -CGFloat(shown) * size.width, dy: 0)
            resizeFrame = frame
            resizeOrigin = layout.cells[id] ?? layout.pin(covering: frame)
            resizeEdges = edges
            livePins = layout.placed
            resizing = id
            NSCursor.frameResize(position: ResizeHandles.position(edges), directions: .all).push()
        }
        resizeTranslation = translation
        guard let live = livePins else { return }
        let target = layout.pin(resizing: resizeOrigin, from: resizeFrame, edges: edges, by: translation)
        guard target != (live[id] ?? resizeOrigin), let next = placing(target, for: id, in: live, ids: ids) else { return }
        if page != 0 {
            withAnimation(Motion.reflow) { page = 0 }
        }
        // A tile carried onto a page of its own goes back to the first page with the other hand-sized ones.
        let groups = liveGroups ?? self.groups
        if let mine = groups[id], mine != makeLayout(ids, size: size).pageGroups.first {
            var next = groups
            next[id] = nil
            withAnimation(Motion.reflow) { liveGroups = next }
        }
        reflow(to: next, size: size)
    }

    private func resizeEnded() {
        NSCursor.pop()
        if order != items { onReorder(order) }
        if let live = livePins, live != pins { onPin(live) }
        if let live = liveGroups, live != groups { onGroup?(Self.compacted(live, ids: order)) }
        withAnimation(Motion.drop) {
            resizing = nil
            resizeTranslation = .zero
            livePins = nil
            liveGroups = nil
        }
    }

#if DEBUG
    /// `DebugSnapshot` holds a tile mid-move or mid-resize through the same steps a drag takes, since
    /// synthetic mouse events don't reach SwiftUI's gestures.
    private func debugHold(_ hold: TileGridDebug.Hold?, ids: [UUID], layout: TileLayout, size: CGSize, shown: Int) {
        guard let hold else {
            if dragging != nil { dragEnded(size: size) }
            if resizing != nil { resizeEnded() }
            return
        }
        guard ids.indices.contains(hold.index) else { return }
        let by = CGSize(width: hold.by.width * size.width, height: hold.by.height * size.height)
        if let edges = hold.edges {
            resizeChanged(id: ids[hold.index], edges: edges, by: by, ids: ids, layout: layout, size: size, shown: shown)
        } else {
            dragChanged(id: ids[hold.index], by: by, ids: ids, layout: layout, size: size)
            holdAtEdge(dragStart.x - CGFloat(shown) * size.width + by.width, id: ids[hold.index], size: size)
        }
    }
#endif

    /// A frame with some of its edges moved by a drag, never smaller than a sized tile can be.
    private func stretched(_ frame: CGRect, edges: Edge.Set, by drag: CGSize) -> CGRect {
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        let least = TileLayout.minPinned
        if edges.contains(.leading) { minX = min(frame.minX + drag.width, maxX - least.width) }
        if edges.contains(.trailing) { maxX = max(frame.maxX + drag.width, minX + least.width) }
        if edges.contains(.top) { minY = min(frame.minY + drag.height, maxY - least.height) }
        if edges.contains(.bottom) { maxY = max(frame.maxY + drag.height, minY + least.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

#if DEBUG
enum TileGridDebug {
    static let hold = Notification.Name("TileGridDebug.hold")
    /// A tile (by its place on screen) held moved by `by`, a fraction of the grid's size. With `edges`, those
    /// edges are dragged instead of the title bar. Posting nil lets go.
    final class Hold {
        let index: Int, by: CGSize, edges: Edge.Set?
        init(index: Int, by: CGSize, edges: Edge.Set? = nil) { self.index = index; self.by = by; self.edges = edges }
    }
}
#endif

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
            guard let event = forTiles(event) else { return nil }
            return TerminalScroll.take(event) ? nil : event
        }
    }

    /// The event if it's for the tiles, or nil if a paged grid took it (or is holding it for now).
    private static func forTiles(_ event: NSEvent) -> NSEvent? {
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
                held.forEach { if !TerminalScroll.take($0) { $0.window?.sendEvent($0) } }
                replaying = false
            }
            held = []
            return nil
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
/// The strips reach `outset` past the tile into the gap around it, so the edge is easy to catch. The top
/// one sits mostly above the tile, leaving the title bar for moving it.
private struct ResizeHandles: View {
    let gesture: (Edge.Set) -> AnyGesture<DragGesture.Value>
    let onReset: () -> Void

    /// How far past the tile the strips reach. Half the gap between tiles, so neighbours don't overlap.
    static let outset: CGFloat = 5
    private let edge: CGFloat = 12
    private let top: CGFloat = 9
    private let corner: CGFloat = 20

    var body: some View {
        ZStack {
            handle([.top], .top, width: nil, height: top)
            handle([.bottom], .bottom, width: nil, height: edge)
            handle([.leading], .leading, width: edge, height: nil)
            handle([.trailing], .trailing, width: edge, height: nil)
            handle([.top, .leading], .topLeading, width: corner, height: corner)
            handle([.top, .trailing], .topTrailing, width: corner, height: corner)
            handle([.bottom, .leading], .bottomLeading, width: corner, height: corner)
            handle([.bottom, .trailing], .bottomTrailing, width: corner, height: corner)
        }
        .padding(-Self.outset)
    }

    /// One strip or corner. An edge strip stops short of the corners, so they don't overlap.
    private func handle(_ edges: Edge.Set, _ alignment: Alignment, width: CGFloat?, height: CGFloat?) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
            .contentShape(Rectangle())
            // A pointer style rather than a pushed NSCursor: the title bar's grab style won over a pushed
            // cursor on the top edge, and the terminal reset it on the others.
            .pointerStyle(.frameResize(position: Self.pointerPosition(edges)))
            .gesture(gesture(edges))
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            .help("Drag to resize. Double-click to fit automatically.")
            .padding(width == nil ? .horizontal : .vertical, width == nil || height == nil ? corner : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    static func pointerPosition(_ edges: Edge.Set) -> FrameResizePosition {
        switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.leading), edges.contains(.trailing)) {
        case (true, _, true, _): .topLeading
        case (true, _, _, true): .topTrailing
        case (_, true, true, _): .bottomLeading
        case (_, true, _, true): .bottomTrailing
        case (true, _, _, _): .top
        case (_, true, _, _): .bottom
        case (_, _, true, _): .leading
        default: .trailing
        }
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
    /// The group each page belongs to (see `groups` in `init`).
    private(set) var pageGroups: [Int] = []
    private let spacing: CGFloat
    private let padding: CGFloat
    private let cell: CGSize

    /// `groups` puts tiles you've carried onto later pages together: tiles with the lowest group (no entry
    /// is group 0) are laid out first, as below, and each higher group starts on a page of its own after
    /// them, laid out like an unsized Canvas. Only the first group's hand-sized tiles count.
    init(ids: [UUID], pins: [UUID: TilePin], groups: [UUID: Int] = [:], size: CGSize, spacing: CGFloat, padding: CGFloat, minTileHeight: CGFloat) {
        self.spacing = spacing
        self.padding = padding
        cell = CGSize(width: max((size.width - padding * 2 - spacing * CGFloat(TilePin.columns - 1)) / CGFloat(TilePin.columns), 0),
                      height: max((size.height - padding * 2 - spacing * CGFloat(TilePin.rows - 1)) / CGFloat(TilePin.rows), 0))

        let keys = Set(ids.map { groups[$0] ?? 0 }).sorted()
        let first = keys.first ?? 0
        layOutFirst(ids.filter { (groups[$0] ?? 0) == first }, pins: pins, size: size, minTileHeight: minTileHeight)
        pageGroups = Array(repeating: first, count: pages)
        for key in keys.dropFirst() {
            let members = ids.filter { (groups[$0] ?? 0) == key }
            let slots = GridSlots(count: members.count, size: size, spacing: spacing, padding: padding, minTileHeight: minTileHeight)
            for (i, id) in members.enumerated() { frames[id] = slots.frame(i).offsetBy(dx: size.width * CGFloat(pages), dy: 0) }
            pages += slots.pages
            pageGroups += Array(repeating: key, count: slots.pages)
        }
        contentWidth = size.width * CGFloat(pages)
    }

    /// The first group: hand-sized tiles take their cells, the rest fill around them and carry on to the right.
    private mutating func layOutFirst(_ ids: [UUID], pins: [UUID: TilePin], size: CGSize, minTileHeight: CGFloat) {
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
        // to the right, in pages laid out like an unsized Canvas. Never so few that part of the first page
        // is left empty: a smaller tile there looks better than a hole.
        let tries = (0...filling.count).reversed().map { (count: $0, fill: fill($0, areas: areas, ids: ids)) }
        let whole = tries.filter { $0.fill.gaps == 0 }
        let roomy = whole.first { $0.fill.slots.allSatisfy { $0.height >= Self.minBeside.height && $0.width >= Self.minBeside.width } }
        let chosen = roomy ?? whole.last ?? tries[0]
        let onFirst = chosen.count, first = chosen.fill
        cells = first.cells
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
    /// `gaps` counts free areas that ended up with no tile and nothing to grow over them.
    private func fill(_ count: Int, areas: [TilePin], ids: [UUID]) -> (slots: [CGRect], cells: [UUID: TilePin], gaps: Int) {
        var areas = areas
        var cells = placed
        var gaps = 0
        // Areas too small for a tile, or more of them than tiles: keep the biggest roomy ones, and let a
        // neighbour grow over the rest.
        let roomy = { (a: TilePin) in let r = rect(for: a); return r.width >= Self.minBeside.width && r.height >= Self.minBeside.height }
        let keep = min(count, areas.contains(where: roomy) ? areas.filter(roomy).count : areas.count)
        if areas.count > keep {
            let ranked = areas.sorted { (roomy($0) ? 1 : 0, $0.cells) > (roomy($1) ? 1 : 0, $1.cells) }
            var kept = Array(ranked.prefix(keep))
            var spare = Array(ranked.dropFirst(keep))
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
            // Whatever's left: grow a neighbour a row or column at a time over it, filling tiles before
            // hand-sized ones, so hand-sized tiles stay as you left them where possible.
            var owned = Array(repeating: Array(repeating: false, count: TilePin.columns), count: TilePin.rows)
            for r in kept + Array(cells.values) { Self.mark(&owned, r) }
            var grown = true
            while grown {
                grown = false
                for i in kept.indices { if let g = Self.grow(kept[i], into: &owned) { kept[i] = g; grown = true } }
                if grown { continue }
                for id in ids where cells[id] != nil {
                    if let g = Self.grow(cells[id]!, into: &owned) { cells[id] = g; grown = true }
                }
            }
            areas = kept
            gaps = owned.joined().filter { !$0 }.count
        }
        guard count > 0 else { return ([], cells, gaps) }
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
        return (slots, cells, gaps)
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

    /// The smallest a tile next to hand-sized ones gets before it moves to the next page. Lower than an
    /// unsized grid's smallest height, so sizing one tile doesn't push its neighbours off the page.
    static let minBeside = CGSize(width: 280, height: 200)

    /// The smallest a tile can be sized by hand. Below this its title bar and terminal don't fit.
    static let minPinned = CGSize(width: 240, height: 160)

    /// `start` with the given edges moved by a drag to the nearest grid lines. Never smaller than
    /// `minPinned`, or one cell when the window is too small for that.
    func pin(resizing start: TilePin, from frame: CGRect, edges: Edge.Set, by drag: CGSize) -> TilePin {
        let across = min(max(Int(ceil((Self.minPinned.width + spacing) / (cell.width + spacing))), 1), TilePin.columns)
        let down = min(max(Int(ceil((Self.minPinned.height + spacing) / (cell.height + spacing))), 1), TilePin.rows)
        var left = start.col, right = start.col + start.width
        var top = start.row, bottom = start.row + start.height
        if edges.contains(.leading) { left = max(min(line(frame.minX + drag.width, along: \.width, leading: true), right - across), 0) }
        if edges.contains(.trailing) { right = min(max(line(frame.maxX + drag.width, along: \.width, leading: false), left + across), TilePin.columns) }
        if edges.contains(.top) { top = max(min(line(frame.minY + drag.height, along: \.height, leading: true), bottom - down), 0) }
        if edges.contains(.bottom) { bottom = min(max(line(frame.maxY + drag.height, along: \.height, leading: false), top + down), TilePin.rows) }
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

    private static func mark(_ owned: inout [[Bool]], _ r: TilePin) {
        for row in r.row..<r.row + r.height { for c in r.col..<r.col + r.width { owned[row][c] = true } }
    }

    /// `r` grown by one row or column into cells nobody owns, if a whole side's worth of them is free.
    private static func grow(_ r: TilePin, into owned: inout [[Bool]]) -> TilePin? {
        let sides = [TilePin(col: r.col - 1, row: r.row, width: 1, height: r.height),
                     TilePin(col: r.col + r.width, row: r.row, width: 1, height: r.height),
                     TilePin(col: r.col, row: r.row - 1, width: r.width, height: 1),
                     TilePin(col: r.col, row: r.row + r.height, width: r.width, height: 1)]
        for side in sides where side.col >= 0 && side.row >= 0 && side.col + side.width <= TilePin.columns && side.row + side.height <= TilePin.rows {
            guard (side.row..<side.row + side.height).allSatisfy({ row in (side.col..<side.col + side.width).allSatisfy { !owned[row][$0] } }) else { continue }
            mark(&owned, side)
            return r.union(side)
        }
        return nil
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

/// How wide the tile a view sits in is, set by `TileGrid`. Written out by hand: `@Entry` needs Xcode.
private struct TileWidthKey: EnvironmentKey { static let defaultValue = CGFloat.infinity }

extension EnvironmentValues {
    var tileWidth: CGFloat {
        get { self[TileWidthKey.self] }
        set { self[TileWidthKey.self] = newValue }
    }
}

/// Shows a title bar extra only in tiles at least `width` points wide, so a narrow tile drops its extras
/// instead of spilling out of its card.
private struct ShownInTiles: ViewModifier {
    @Environment(\.tileWidth) private var tileWidth
    let width: CGFloat

    func body(content: Content) -> some View {
        if tileWidth >= width { content }
    }
}

extension View {
    func shownInTiles(from width: CGFloat) -> some View { modifier(ShownInTiles(width: width)) }
}
