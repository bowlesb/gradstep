# Mac approval shared-hook handoff

These files are a reviewable integration proposal against `44bf3c2`, **not applied shared code or passing enrollment tests**. Shared native ownership remains with Claude. The standalone Mac code is in `ScienceReader/Mac/MacDeviceApproval.swift`; it is not reachable from the recovery screen yet.

- `mac-shared-hooks.patch`: four small shared touchpoints. DeviceKeys gets a Catalyst-only request/poll method using its existing pending recipient, operation lock, request RPCs and authenticated envelope activation. ReaderModel fences activation with account, session and manager identity. RecoveryView gets a Catalyst-only QR/recovery toggle. PaperView publishes the figure-gallery callback.
- `MacEnrollmentTests.swift.draft`: proposed Catalyst-only regression file to place in `ScienceReaderTests` after the hook reservation clears, then regenerate the Xcode project. It is intentionally outside all test targets until then.

The pending QR candidate uses the existing Codable record: bundle is nil and envelope empty until external approval or a switch to recovery. No schema, wire format, server API, authority token or second key store is introduced. Existing recovery fills the same candidate's bundle/envelope. Renewal changes only the request ID. The old recipient survives expiry, restarts, transport failures and key rotation; positive revocation alone permits a replacement.

Root reviewed candidate reuse, finish-before-activation, positive-revocation retirement and backend authentication-generation fencing on 2026-10-08. Integration still requires the nine proposed enrollment tests to compile and pass, including cancellation after the durable write and same-account logout/login with a delayed approval response. Shared-owner coordination and real Mac restore UI/camera verification remain open.

Local standalone evidence: `MacApprovalUnits.xcresult` contains five passing signed Catalyst tests, including Vision decoding of the Core Image QR back to its exact Mac GSDA1 payload. That proves the renderer/poller components, not the staged DeviceKeys/ReaderModel integration. UI tests currently fail during automation initialization before assertions; see `MAC_APP.md`.
