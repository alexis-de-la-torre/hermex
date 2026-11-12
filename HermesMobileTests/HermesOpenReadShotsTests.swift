import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// A chat open reads its transcript beside the attach, not after the handshake (#HMX-2).
/// These park the socket at `session.resume`, so the handshake never finishes, and hold the
/// read to its own time: the rows are on screen while the connection is still recovering.
///
/// With `HERMEX_SHOT_FOLDER` set the same open captures the two frames the contact sheet is
/// made from — parked, and connected — and asserts nothing, so the frames can be shot on a
/// tree without the fix for comparison.
@MainActor
final class HermesOpenReadShotsTests: XCTestCase {
    private static let path = "/api/sessions/tip/messages"
    private static let connection = BotConnection(
        id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
        username: "user", password: "fixture"
    )

    /// The name of the folder the frames are written to, inside the simulator's own
    /// temporary directory; the workflow copies them out of the app's data container.
    private var shotFolder: String? { ProcessInfo.processInfo.environment["HERMEX_SHOT_FOLDER"] }

    private var shotDirectory: URL? {
        shotFolder.map { FileManager.default.temporaryDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: The read

    /// The handshake is parked at `session.resume`, and the transcript is already up: the
    /// read went out from `activate()`, so it costs the read's time and not the handshake's.
    func testTheTranscriptIsUpWhileTheHandshakeIsStillParked() async throws {
        if shotDirectory != nil { throw XCTSkip("the contact-sheet run captures frames instead") }
        let open = try await openChat()
        await waitUntil("the transcript to show the settled rows", timeout: 30) {
            !open.model.displayedTranscriptMessages.isEmpty
        }
        XCTAssertEqual(open.rows, 4)
        XCTAssertNotEqual(open.engine.connectionState, .connected, "the rows are up before the socket is")
        XCTAssertEqual(open.pages.offsets, [0], "one read, and it is the open's own")

        open.host.allow("session.resume")
        await open.opening.value
        XCTAssertEqual(open.engine.connectionState, .connected)
        XCTAssertEqual(open.rows, 4, "the rebuild keeps the rows it joined")
        XCTAssertEqual(open.pages.offsets, [0], "and sends no second read for them")
    }

    // MARK: The contact sheet

    /// Two frames of one open, shot from the running chat view: the transcript up while the
    /// handshake is parked, and the same chat once it connects. `HERMEX_SHOT_DIR` names where
    /// they land; the notes beside them carry what the run saw, which is the sheet's caption.
    func testTheContactSheetFrames() async throws {
        guard let directory = shotDirectory else { throw XCTSkip("HERMEX_SHOT_FOLDER unset") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let window = try shotWindow()
        let open = try await openChat(window: window)
        // The runner is slow and the fix is not instant: give the read a generous window, and
        // record when the rows arrived so the sheet can say how long the open took.
        let started = ContinuousClock().now
        _ = await rowsArrived(open.model, within: 30)
        let elapsed = started.duration(to: ContinuousClock().now)
        await settle(window, passes: 6)
        try capture(window, directory: directory, name: "01-open")
        let parked = Notes(
            rows: open.rows,
            connected: open.engine.connectionState == .connected,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            offsets: open.pages.offsets
        )

        open.host.allow("session.resume")
        await open.opening.value
        await waitUntil("the chat to connect", timeout: 30) { open.engine.connectionState == .connected }
        await settle(window, passes: 6)
        try capture(window, directory: directory, name: "02-connected")
        let connected = Notes(
            rows: open.rows, connected: open.engine.connectionState == .connected,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            offsets: open.pages.offsets
        )

        let notes = try JSONEncoder().encode(["open": parked, "connected": connected])
        try notes.write(to: directory.appendingPathComponent("notes.json"))
        // The sheet's captions are these numbers, and the container a test writes to belongs to
        // a device clone that is thrown away, so the notes ride in the result bundle too.
        let notesAttachment = XCTAttachment(data: notes, uniformTypeIdentifier: "public.json")
        notesAttachment.name = "notes"
        notesAttachment.lifetime = .keepAlways
        add(notesAttachment)
    }

    /// What one frame's run saw; the sheet prints it under the frame.
    private struct Notes: Codable {
        let rows: Int
        let connected: Bool
        let seconds: Double
        let offsets: [Int]
    }

    // MARK: The chat

    @MainActor
    private struct Open {
        let model: ChatViewModel
        let engine: HermesConversation
        let host: BotSocketHost
        let pages: Pages
        let opening: Task<Void, Never>
        var rows: Int { model.displayedTranscriptMessages.count }
    }

    /// A chat opening on session `tip`, its socket parked at `session.resume` until released,
    /// its history served as one page of four settled rows.
    private func openChat(window: UIWindow? = nil) async throws -> Open {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        host.withhold("session.resume")
        let client = BotClient(http: host.connection(Self.connection))
        let pages = Pages([0: Self.rows])
        _ = HermesHostFixture.configuration { pages.answer($0) }
        let engine = HermesConversation(
            server: URL(string: "https://hermes.example")!, connection: Self.connection,
            target: .session(profile: "default", key: "tip"), wire: client
        )
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let session = SessionSummary(profile: "default")
        let model = ChatViewModel(
            session: session, server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        let opening = Task { await model.loadMessages() }
        if let window {
            // The app's own chat screen, showing the chat this test drives over the scripted
            // host: `continuity` is how a `ChatView` adopts a model instead of building one, so
            // the frames are of what a reader sees rather than a stand-in drawn for the sheet.
            let continuity = ChatContinuity()
            continuity.viewAppeared(UUID(), model: model, returnsWaitingSend: { _, _ in })
            let chat = ChatView(
                session: session, server: URL(string: "https://hermes.example")!,
                onAPIError: { _ in }, continuity: continuity
            )
            // The chat writes its cache through the view's context, so give it the app's own
            // store, in memory: the frames then come from a chat that loads as it does in the app.
            let store = CacheContainer.container(for: ModelConfiguration(isStoredInMemoryOnly: true))
            window.rootViewController = UIHostingController(rootView: chat.modelContainer(store))
        }
        return Open(model: model, engine: engine, host: host, pages: pages, opening: opening)
    }

    private func shotWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 500)
        window.makeKeyAndVisible()
        return window
    }

    private func capture(_ window: UIWindow, directory: URL, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        // A test run clones the destination device, and the clone's container goes with it, so
        // the frame also rides in the result bundle, where the runner can always reach it.
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for the rows on their own signal, and says whether they came: the base tree has
    /// no fix, so its frames are shot of a chat that never fills, and the run must not fail on
    /// the way to them. `waitUntil` is the failing version, for the trees that should fill.
    @MainActor
    private func rowsArrived(_ model: ChatViewModel, within seconds: TimeInterval) async -> Bool {
        let deadline = ContinuousClock().now + .seconds(seconds)
        while ContinuousClock().now < deadline {
            if !model.displayedTranscriptMessages.isEmpty { return true }
            let changed = XCTestExpectation(description: "the transcript's rows")
            withObservationTracking { _ = model.displayedTranscriptMessages } onChange: {
                changed.fulfill()
            }
            _ = await XCTWaiter().fulfillment(of: [changed], timeout: 5)
        }
        return !model.displayedTranscriptMessages.isEmpty
    }

    /// The transcript pages the scripted host serves, by offset, and the offsets it was asked for.
    private final class Pages: @unchecked Sendable {
        private let lock = NSLock()
        private let pages: [Int: [BotJSON]]
        private var asked: [Int] = []

        init(_ pages: [Int: [BotJSON]]) { self.pages = pages }

        var offsets: [Int] { lock.withLock { asked } }

        func answer(_ request: URLRequest) -> HermesHostFixture.Reply? {
            // The chat's own sign-in, over HTTP: the read that goes out before the socket needs
            // it, and the host answers it the same way the real one does.
            switch request.url?.path {
            case "/api/status":
                return .json(200, .object([
                    "auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                    "version": .string("0.23.1")
                ]))
            case "/auth/password-login":
                return .json(200, .object(["ok": .bool(true)]))
            case "/api/auth/me":
                return .json(200, .object(["provider": .string("basic"), "future": .array([])]))
            case "/api/auth/ws-ticket":
                return .json(200, .object(["ticket": .string("ticket-1")]))
            default:
                break
            }
            // The open's read asks for the newest rows without an offset; a page read names one.
            guard request.url?.path == "/api/sessions/tip/messages" else { return nil }
            let items = request.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let offset = items.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            return lock.withLock {
                asked.append(offset)
                guard let rows = pages[offset] else { return .json(500, .object(["detail": .string("unavailable")])) }
                return .json(200, .object([
                    "session_id": .string("tip"), "profile": .string("default"), "messages": .array(rows),
                    "pagination": .object(["limit": .number(100), "offset": .number(Double(offset)),
                                           "order": .string("latest"), "returned": .number(Double(rows.count))])
                ]))
            }
        }
    }

    /// Four settled rows: two prompts and the replies to them.
    private static let rows: [BotJSON] = [1, 2, 3, 4].map { id in
        .object([
            "id": .number(Double(id)), "session_id": .string("tip"),
            "role": .string(id.isMultiple(of: 2) ? "assistant" : "user"),
            "content": .string(id.isMultiple(of: 2) ? "Answer \(id)" : "Question \(id)"),
            "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1), "compacted": .number(0),
            "tool_call_id": .null, "tool_calls": .null, "display_kind": .null, "display_metadata": .null
        ])
    }
}
