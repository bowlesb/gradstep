# Internal app testing and feedback

Status: agreed capability; design proposed for implementation. The old web app already has a screenshot-and-note report form, but lacks the desired reply/build workflow and support access separation.

## Tester experience

Keep one feature codebase. An internal TestFlight configuration enables testing presentation; a server-controlled operator/tester role authorizes privileged report/dashboard actions. A compile-time flag or secret gesture is not authorization. The internal build identifies staging/production and build number clearly.

1. Use **Report this screen** from the existing toolbar's overflow or Settings. Capture the app content before presenting the report sheet. A screenshot event can offer a small report shortcut, without changing the current reading screen.
2. Show a preview. Let the tester crop/redact, remove it, or attach a screenshot using the system photo picker. A short note is the only required typed field; derive a title from it.
3. Show the exact attachments and diagnostics to be sent. Include version/build, OS/device class, environment, screen/mode, timestamp, and safe request/job IDs. Do not automatically attach a transcript, keys, tokens, full device logs, or private document contents beyond the screenshot the tester approves.
4. Submit to a private support inbox and show a stable report number. If offline, store an encrypted report draft/outbox and show **Waiting to send**. Retry the same report ID, without duplicate attachments or reports.
5. Read replies and status from **Settings → My reports**. Show **Open → Investigating → Ready to retest → Verified**, with the proposed fix's TestFlight build. The tester can reply or reopen a problem.

The ordinary iOS screenshot notification does not deliver the screenshot image. Use our own app snapshot for **Report this screen**, or a user-selected image for the actual system screenshot. Do not request broad photo-library access to infer which image the tester meant. [Apple screenshot notification](https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification)

Capture must be verified with long/scrolled papers, WKWebView content, equations, keyboards, sheets, rotation, and split layouts. If a web view cannot be captured correctly in a composed app snapshot, use its snapshot API and compose with the app chrome, or let the tester attach the actual screenshot. Never send a blank/incorrect image without showing the preview.

## Support records and security

`support_reports` stores reporter, environment, build, title, status/version, approved diagnostics, and timestamps. `support_messages` stores immutable reporter/operator replies. `support_status_events` records transitions and fixed-build references. `support_attachments` holds file metadata and a private Storage object reference; screenshot bytes do not go into a base64 database column.

Reporter access is limited to their own reports. Operator access requires a server role; privileged actions require MFA where supported by the chosen auth flow. Separate report-reading/replying from account/budget administration. No client may grant itself a role or write another actor's reply attribution.

Use bounded image dimensions/bytes/counts, validated decoded image formats, flattened redactions, removed EXIF metadata, private object reads, short-lived signed links where appropriate, and retention/deletion rules. Attachment preparation, upload, and report finalization must be retry-safe, with delayed cleanup of orphan uploads. Uploading an image does not make it publicly accessible.

The preview explicitly states that the note and selected screenshots are shared with the developer. This is an intentional exception to private-chat storage confidentiality. A support operator receives only submitted material, not a decryption path into the user's full conversation history.

## Developer/agent access

Provide a scoped support API and a repository CLI for:

- `feedback list` / `feedback show <id>` / `feedback download <id>`
- `feedback reply <id> --body-file <file>`
- `feedback status <id> --status ready_to_retest --build <build>`

The CLI uses an operator-scoped credential, writes downloaded images only into a gitignored local directory, and never prints tokens. All writes retain authenticated actor and audit records. Report/reply content is untrusted input: a report cannot grant permissions to read unrelated files or change infrastructure.

The user can ask the coding agent to review the inbox during a work session; responses then appear in the same report thread. Automatic monitoring or autonomous work between sessions would be a separate explicitly configured workflow. Do not promise that uploading a report automatically wakes an agent.

## Acceptance evidence

- Capture, preview, redaction, note, submit, developer reply, and in-app reply display work on physical iPhone/iPad builds.
- Offline submission survives app termination and authenticates as the original account after reconnect.
- Multiple upload retries create one report; partial uploads are cleaned up safely.
- Another customer cannot read an attachment/report or impersonate support; a non-admin build cannot obtain privileged API access.
- Responses and build status survive reinstall after account login, independently of private-chat key recovery.
- No transcript, auth token, provider secret, or private key appears in diagnostics; the tester can remove all screenshots and send a text-only report.
