# 389 — one contract, two producers

The first slice of the iOS companion ([092](../.docs/092-ios-companion-plan.md) ·
S0). No behaviour changed and no feature landed; what moved is a boundary.

`CaptureRequest`, `ProvenanceDTO`, `VideoCaptureHeader`, the `Decoded*` family and
the `CaptureDecoder` funnel were living inside `AtelierServer`, which links FlyingFox
and does not exist on iOS. They are not server code. They are the answer to "what is
a capture, and how do I know this one is well-formed" — and that question has a
second asker now: the iOS share extension writes the same shape into an inbox instead
of POSTing it to a socket.

They now live in **`AtelierCapture`**, a package whose whole boundary is *nothing
about transport*. No FlyingFox, no sockets, no filesystem, no AppKit. It cannot tell
whether a capture arrived over a loopback connection or was found in a directory,
which is exactly the property that will let a memory-capped share extension link it
without dragging GRDB along.

The reason this is worth a package rather than a copied file: `AppServices.ingest`'s
18A dedup keys on provenance. Two decoders over one wire shape drift the first time a
field is added on one side, and the way that failure presents is not a crash — it is
a second asset quietly forking off the same bytes.

## Where the line fell

Not at the file boundary. `CaptureResponse` stayed behind, in a new
`CaptureResponse.swift` beside the routes that send it.

The test is *does a producer of captures need this?* The request shape and its decode
funnel have two producers. A reply has one — a capture written to the inbox has nobody
to answer. So the contract travels and the response doesn't.

`VideoCaptureHeader` / `decodeVideoHeader` / `provenanceHeaderName` went with the
contract despite being visibly HTTP-shaped, because `CaptureDecodeError` carries their
two cases and an error enum cannot be split across packages. The alternative — a
second error type for the header path — buys tidier layering with a worse API.

## The fixture that wouldn't move

Moving the decode suite to sit with its code broke it immediately:
`CaptureRequest.sample()` and `jsonData()` lived in `AtelierServer`'s TestSupport, and
SPM test targets are not products, so the other package cannot reach them. That
constraint is already recorded in `ServerTestEnv.swift`'s own header, where it was
solved by writing a small local copy.

Doing that again — a second `sample()` builder, on the two sides of a contract whose
entire purpose is to not disagree — would have been the bug this slice exists to
prevent, committed in the test layer. So the image fixtures and request builders
became **`AtelierCaptureTestSupport`**, a test-only product both suites depend on.

The synthesized H.264 MP4 stayed in the server: a video body is streamed as raw bytes
over HTTP and has no inbox counterpart, so nothing outside that package needs it.

## Files

    AtelierCapture/Package.swift                        new — zero transport deps
    AtelierCapture/Sources/AtelierCapture/CaptureDTO.swift
                                                        moved from AtelierServer
    AtelierCapture/Sources/AtelierCaptureTestSupport/CaptureFixtures.swift
                                                        new — the shared builders
    AtelierCapture/Tests/AtelierCaptureTests/CaptureDecoderTests.swift
                                                        moved, with its code
    AtelierServer/Sources/AtelierServer/CaptureResponse.swift
                                                        new — the reply stays home
    AtelierServer/Package.swift                         AtelierCapture dep; test dep
    AtelierServer/Sources/AtelierServer/{CaptureAuth,CaptureRoutes,CaptureServer}.swift
                                                        import AtelierCapture
    AtelierServer/Tests/…/TestSupport/ServerTestEnv.swift
                                                        video fixture only; imports trimmed
    AtelierServer/Tests/…/{CaptureRoutes,CaptureServerIntegration,JobRoutes,
      JobServerIntegration}Tests.swift                  imports; ServerFixtures →
                                                        CaptureFixtures at 16 call sites
    .github/workflows/ci.yml                            six packages, not four

85 server tests before → 23 + 62 after. Same total, same names, all passing.

## What the build proved

**Xcode needed no `project.pbxproj` change.** It resolved `AtelierCapture`
transitively through `AtelierServer`'s path dependency and the app target built
untouched — which is worth knowing, because 092 · S4 had budgeted for package-graph
surgery when the iOS targets land.

The extension's 524 node tests and the drift check are unaffected. The suite that
proves the cross-language wire contract reads
`extension/test/fixtures/capture-contract.json` by walking four directories up from
`#filePath`; the new location sits at exactly the same depth, so the JS and Swift
sides still read the same bytes with no path edit.

## Migration notes

None for users — no stored shape, wire shape, or endpoint changed, and the extension
is untouched.

For the build: `AtelierCapture` is a new local package in the graph, so a clean
checkout resolves one more path dependency. Anything importing the moved types needs
`import AtelierCapture`; within this repo that is three server sources and five test
files, all updated here.
