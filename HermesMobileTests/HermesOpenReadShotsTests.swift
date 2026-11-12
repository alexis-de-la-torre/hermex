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
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        if let window { window.rootViewController = UIHostingController(rootView: ShotView(model: model)) }
        let opening = Task { await model.loadMessages() }
        return Open(model: model, engine: engine, host: host, pages: pages, opening: opening)
    }

    /// The chat's own rows, drawn by the app's own bubble.
    private struct ShotView: View {
        let model: ChatViewModel

        var body: some View {
            let rows = model.displayedTranscriptMessages
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rows.isEmpty ? "Opening the chat" : "The chat is open")
                        .font(.system(size: 17, weight: .semibold))
                    Text(rows.isEmpty
                         ? "transcript: empty · waiting for the handshake"
                         : "transcript: \(rows.count) rows · socket still recovering")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground))
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            MessageBubbleView(
                                message: row.message, transcriptMediaCacheNamespace: "contact-sheet",
                                textOnly: true
                            )
                        }
                    }
                    .padding(12)
                }
                Spacer(minLength: 0)
                Divider()
                Text("Hermex · iPhone 17 · HermesMobileTests")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(width: 393, height: 500)
            .background(Color(uiColor: .systemBackground))
        }
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
            guard request.url?.path == HermesOpenReadShotsTests.path,
                  let query = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems,
                  let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init)
            else { return nil }
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
