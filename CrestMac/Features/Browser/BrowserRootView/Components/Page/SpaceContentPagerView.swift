import AppKit
import QuartzCore
import SwiftUI

/// A passive set of real content surfaces, one per Space. Only the sidebar
/// owns gestures; web history gestures continue to belong to WebKit. The page
/// area does not slide with the sidebar: it switches to a Space's page in
/// place as soon as the switch is decided, as a tab switch does, and keeps the
/// page it showed above the new one until that one has drawn.
@MainActor
final class SpaceContentPagerView<Content: View & Equatable>: NSView {
    /// How many display frames the page shown before a switch stays above the
    /// page replacing it, as `BrowserWebHostView` holds a replaced tab: longer
    /// than the frames a page shown again takes to draw.
    private static var holdFrames: Int { 5 }

    private var spaces: [SpaceModel] = []
    private var selectedSpaceID: UUID?
    private var lockedSpaceIDs: Set<UUID> = []
    private var layoutDirection = LayoutDirection.leftToRight
    private var presentation: SpacePagerPresentation?
    private var snapshot: SpacePagerPresentation.Snapshot?
    /// The Space whose page the area shows.
    private var shownSpaceID: UUID?
    /// The Space shown before `shownSpaceID`, kept above it while its page
    /// draws its first frames.
    private var heldSpaceID: UUID?
    private var heldFramesLeft = 0
    private var heldDisplayLink: CADisplayLink?
    private lazy var holdObserver = SpaceContentHoldObserver { [weak self] in self?.heldFrameElapsed() }
    private var hosts: [BrowserSpaceRuntimeAssignment: SpacePageHost<Content>] = [:]
    private var makeRoot: ((SpaceModel, Bool) -> SpacePageRoot<Content>)?
    private var lastSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func update(
        spaces: [SpaceModel], selectedSpaceID: UUID, lockedSpaceIDs: Set<UUID>,
        layoutDirection: LayoutDirection, presentation: SpacePagerPresentation?,
        makeRoot: @escaping (SpaceModel, Bool) -> SpacePageRoot<Content>
    ) {
        let changedLocks = self.lockedSpaceIDs.symmetricDifference(lockedSpaceIDs)
        let assignments = Set(spaces.map(BrowserSpaceRuntimeAssignment.init(space:)))
        // Withdraw old clear surfaces before admitting roots for a new lock or
        // profile assignment. In-flight reversal cannot resurrect those hosts.
        for key in hosts.keys where changedLocks.contains(key.spaceID) || !assignments.contains(key) {
            hosts.removeValue(forKey: key)?.removeFromSuperview()
        }
        self.spaces = spaces
        self.selectedSpaceID = selectedSpaceID
        self.lockedSpaceIDs = lockedSpaceIDs
        self.layoutDirection = layoutDirection
        self.makeRoot = makeRoot
        if self.presentation !== presentation {
            disconnect()
            self.presentation = presentation
            presentation?.observe(owner: self) { [weak self] in self?.receive($0) }
        }
        let current = matchingSnapshot ?? restingSnapshot(selectedSpaceID)
        snapshot = current
        show(shownID(in: current), refresh: current.phase == .idle)
        updateAccessibility()
    }

    func disconnect() {
        presentation?.removeObserver(owner: self)
        presentation = nil
        endHold()
    }

    override func layout() {
        super.layout()
        guard lastSize != bounds.size else { return }
        lastSize = bounds.size
        for host in hosts.values {
            // Keep offscreen pages cached without reflowing their native content.
            if host.hostingView.rootView.contentPresentation != .inactive, host.frame.size != bounds.size {
                host.setFrameSize(bounds.size)
            }
        }
        refreshShownHosts()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)),
            snapshot?.phase == .idle, snapshot?.destinationID == selectedSpaceID
        else { return nil }
        return super.hitTest(point)
    }

    private var matchingSnapshot: SpacePagerPresentation.Snapshot? {
        guard let value = presentation?.snapshot, value.spaceIDs == spaces.map(\.id) else { return nil }
        return value
    }

    private func restingSnapshot(_ id: UUID) -> SpacePagerPresentation.Snapshot {
        .init(
            generation: 0, spaceIDs: spaces.map(\.id),
            position: CGFloat(spaces.firstIndex { $0.id == id } ?? 0), phase: .idle, destinationID: id)
    }

    private func receive(_ value: SpacePagerPresentation.Snapshot) {
        guard value.spaceIDs == spaces.map(\.id) else { return }
        // A selection that arrives mid-switch leaves the roots built for the
        // Space selected before it, so the page it lands on would never take
        // input. A settled switch supplies the latest roots, as the sidebar's
        // pager does.
        let settles = value.phase == .idle && snapshot?.phase != .idle
        snapshot = value
        show(shownID(in: value), refresh: settles)
        updateAccessibility()
    }

    // MARK: - Actions - Switching

    /// The Space whose page the area shows for `snapshot`: the one a switch
    /// goes to as soon as it is decided, and while fingers still move the
    /// sidebar, the one shown already.
    private func shownID(in snapshot: SpacePagerPresentation.Snapshot) -> UUID? {
        snapshot.phase == .tracking ? shownSpaceID ?? selectedSpaceID : snapshot.destinationID
    }

    /// Shows `id`'s page in place. A page not drawn yet waits beneath the page
    /// it replaces for a few frames, as a tab switch does, so the switch never
    /// shows a blank page.
    private func show(_ id: UUID?, refresh: Bool) {
        guard let id, spaces.contains(where: { $0.id == id }) else { return }
        if let previous = shownSpaceID, previous != id, let previousKey = assignment(for: previous),
            hosts[previousKey] != nil
        {
            let drawn =
                assignment(for: id).flatMap { hosts[$0] }
                .map { $0.hostingView.rootView.contentPresentation != .inactive } ?? false
            if drawn { endHold() } else { beginHold(previous) }
        }
        shownSpaceID = id
        refreshShownHosts(refresh: refresh)
    }

    /// Prepares and places the hosts around the Space shown now.
    private func refreshShownHosts(refresh: Bool = false) {
        guard let id = shownSpaceID, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let position = CGFloat(index)
        prepareHosts(at: position, destination: id, refresh: refresh, preparesNeighbors: snapshot?.phase == .idle)
        positionHosts(at: position)
    }

    private func assignment(for id: UUID) -> BrowserSpaceRuntimeAssignment? {
        spaces.first { $0.id == id }.map(BrowserSpaceRuntimeAssignment.init(space:))
    }

    private func beginHold(_ id: UUID) {
        heldDisplayLink?.invalidate()
        heldSpaceID = id
        heldFramesLeft = Self.holdFrames
        let link = displayLink(target: holdObserver, selector: #selector(SpaceContentHoldObserver.frameElapsed(_:)))
        link.add(to: .main, forMode: .common)
        heldDisplayLink = link
    }

    private func heldFrameElapsed() {
        heldFramesLeft -= 1
        guard heldFramesLeft <= 0 else { return }
        endHold()
        refreshShownHosts()
        updateAccessibility()
    }

    private func endHold() {
        heldDisplayLink?.invalidate()
        heldDisplayLink = nil
        heldSpaceID = nil
    }

    private func prepareHosts(
        at position: CGFloat, destination: UUID?, refresh: Bool, preparesNeighbors: Bool = true
    ) {
        guard !spaces.isEmpty, let makeRoot else { return }
        let center = min(spaces.count - 1, max(0, Int(position.rounded())))
        let target = destination.flatMap { id in spaces.firstIndex { $0.id == id } } ?? center
        var visible = Set([Int(position.rounded(.down)), Int(position.rounded(.up)), target])
        if snapshot?.phase != .idle, let selected = spaces.firstIndex(where: { $0.id == selectedSpaceID }) {
            // A selection made mid-slide is where the slide goes next.
            visible.insert(selected)
        }
        if let heldSpaceID, let held = spaces.firstIndex(where: { $0.id == heldSpaceID }) {
            visible.insert(held)
        }
        let neighbors = preparesNeighbors ? [target - 1, target + 1, center - 1, center + 1] : []
        var indices = visible.filter { spaces.indices.contains($0) }
        // Warmed neighbors need hosts even across the ends of the Spaces.
        let warmed = (snapshot?.warmedSpaceIDs ?? []).compactMap { id in spaces.firstIndex { $0.id == id } }
        for index in warmed where indices.count < 4 { indices.insert(index) }
        for index in neighbors where indices.count < 4 && spaces.indices.contains(index) { indices.insert(index) }
        let cached = spaces.indices.filter { hosts[BrowserSpaceRuntimeAssignment(space: spaces[$0])] != nil }
            .sorted { abs($0 - target) < abs($1 - target) }
        for index in cached where indices.count < 4 { indices.insert(index) }
        let required = Set(indices.map { BrowserSpaceRuntimeAssignment(space: spaces[$0]) })
        for key in hosts.keys where !required.contains(key) {
            hosts.removeValue(forKey: key)?.removeFromSuperview()
        }
        for index in indices.sorted() {
            let space = spaces[index]
            let key = BrowserSpaceRuntimeAssignment(space: space)
            let contentPresentation = contentPresentation(at: index)
            if let host = hosts[key] {
                let previous = host.hostingView.rootView.contentPresentation
                if contentPresentation != .inactive, host.frame.size != bounds.size {
                    host.setFrameSize(bounds.size)
                }
                if previous == .inactive, contentPresentation != .inactive {
                    // Cached geometry may predate a sidebar resize. Restore
                    // the release origin before its native animation starts.
                    host.setFrameOrigin(origin(for: key, at: position))
                }
                var root = refresh ? makeRoot(space, space.id == selectedSpaceID) : host.hostingView.rootView
                root.contentPresentation = contentPresentation
                // A page off screen is hidden as well: on macOS 26, another
                // hosting view beside the selected page can take its clicks.
                host.isHidden = contentPresentation == .inactive
                if host.hostingView.rootView.content != root.content || previous != contentPresentation {
                    if contentPresentation != .interactive,
                        let responder = window?.firstResponder as? NSView, responder.isDescendant(of: host)
                    {
                        window?.makeFirstResponder(nil)
                    }
                    host.hostingView.rootView = root
                    if previous == .inactive, contentPresentation != .inactive {
                        // Admit the destination before moving its first frame
                        // into view, without refreshing roots on progress ticks.
                        host.hostingView.layoutSubtreeIfNeeded()
                    }
                }
            } else {
                var root = makeRoot(space, space.id == selectedSpaceID)
                root.contentPresentation = contentPresentation
                let host = SpacePageHost(root: root)
                host.frame = CGRect(origin: origin(for: key, at: position), size: bounds.size)
                host.hostingView.frame = host.bounds
                host.isHidden = contentPresentation == .inactive
                hosts[key] = host
                addSubview(host)
            }
        }
    }

    private func contentPresentation(at index: Int) -> SpaceContentPresentation {
        guard let snapshot else { return .inactive }
        let id = spaces[index].id
        // The page held above a switch's new page stays drawn until it lets go.
        if id == heldSpaceID { return .preview }
        if id == shownSpaceID {
            return snapshot.phase == .idle && id == selectedSpaceID ? .interactive : .preview
        }
        // A page warmed ahead of a likely swipe, or the one a swipe in progress
        // heads for, is drawn off screen so the switch shows it at once.
        let heading = snapshot.phase == .tracking && id == snapshot.destinationID
        return snapshot.warmedSpaceIDs.contains(id) || heading ? .preview : .inactive
    }

    /// Where `key`'s page sits while the strip shows `position`, placed
    /// around the ends as near `reference`: a slide keeps each page where it
    /// began, so none switches ends partway.
    private func origin(
        for key: BrowserSpaceRuntimeAssignment, at position: CGFloat, placedNear reference: CGFloat? = nil
    ) -> CGPoint {
        let index = spaces.firstIndex { $0.id == key.spaceID } ?? 0
        let placed = SpacePagerInterpolation.index(index, near: reference ?? position, count: spaces.count)
        let direction: CGFloat = layoutDirection == .leftToRight ? 1 : -1
        return CGPoint(x: (CGFloat(placed) - position) * bounds.width * direction, y: 0)
    }

    private func positionHosts(at position: CGFloat) {
        for (key, host) in hosts {
            // The held page covers the shown one in place until it has drawn.
            let held = key.spaceID == heldSpaceID
            var origin = held ? .zero : origin(for: key, at: position)
            if host.hostingView.rootView.contentPresentation == .inactive {
                guard host.frame.intersects(bounds) else { continue }
                // A wider viewport can expose a cached frame. Park it beyond
                // the clip until prepareHosts shows it.
                origin.x =
                    origin.x < 0 ? min(origin.x, -host.frame.width) : max(origin.x, bounds.maxX + host.frame.width)
            }
            host.layer?.zPosition = held ? 1 : 0
            if host.frame.origin != origin { host.setFrameOrigin(origin) }
        }
    }

    private func updateAccessibility() {
        for (key, host) in hosts {
            host.setAccessibilityHidden(
                snapshot?.phase != .idle || snapshot?.destinationID != selectedSpaceID || key.spaceID != selectedSpaceID
            )
        }
    }
}

/// Keeps the Objective-C display-link target independent of the generic page root.
@MainActor
private final class SpaceContentHoldObserver: NSObject {
    let elapsed: @MainActor () -> Void

    init(elapsed: @escaping @MainActor () -> Void) { self.elapsed = elapsed }

    @objc func frameElapsed(_ link: CADisplayLink) { elapsed() }
}
