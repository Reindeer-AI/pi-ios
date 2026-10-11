# Apple Watch companion

`PiWatch` is a SwiftUI watchOS 26 app embedded in `PiMobile`. WatchConnectivity carries prompts, recorded audio,
recent sessions, and task results. The agent, credentials, workspaces, and full transcripts stay on iPhone.

## Development

Follow the native dependency and engine build steps in the main README, then open `App/PiMobile.xcodeproj`.
Install the iOS and watchOS platforms in Xcode. Both devices need OS version 26 or later.

1. Select the same signing team for **PiMobile** and **PiWatch**. Set a unique `PI_BUNDLE_ID`; the Watch and companion
   identifiers derive from it. Connect your iPhone, trust the Mac, and enable Developer Mode when prompted.
2. Run **PiMobile** on iPhone, configure a model provider, and choose a default model. Cloud models can run during
   the phone's background execution time; on-device models require Pi to be active on iPhone.
3. In Pi Settings → Apple Watch, enable voice transcription and allow Speech Recognition. Enable completion alerts
   if wanted, and enable Pi notification mirroring in the iPhone Watch app.
4. Run **PiWatch** on the paired Watch. Open both apps and refresh. New session and Reply start recording immediately.
   Allow microphone access on Watch, tap Stop, review the transcription, then Send. System input is an optional fallback.

Personal Team device development is subject to Apple's reprovisioning and entitlement limits. The phone's
increased-memory-limit entitlement may require a development configuration without that entitlement and a cloud model.
Manual distribution signing needs both `--profile PHONE.mobileprovision` and `--watch-profile WATCH.mobileprovision`.
The Watch profile must match `<PI_BUNDLE_ID>.watchkitapp`.

## Ownership and delivery

- `PiWatchLink` owns versioned wire messages, validation, and payload limits. Full prompts, submission IDs, and notification receipts live in `PiMobile`;
  the prompt outbox, one audio draft, and hidden list rows live in `PiWatch`.
- Recording is limited to 60 seconds of mono AAC and 512 KB. `transferFile` queues audio for the paired phone.
  Apple Speech prefers on-device recognition where supported; otherwise Apple may process the audio. Incoming audio
  never opens a permission dialog. Failed or interrupted transcription leaves the Watch recording available to retry.
- Transcription starts no agent task. Only Send admits the reviewed text with the recording's stable request ID and
  original destination. Cancel discards the local draft. Received phone audio is deleted after transcription;
  successful transcripts are cached to avoid repeating recognition on transfer retries.
- `sendMessage` acknowledges a prompt after the phone saves it. `transferUserInfo` delivers retries and terminal results;
  `updateApplicationContext` carries the latest snapshot. Live snapshots are coalesced to once per second.
- Stable UUIDs deduplicate phone receipts, session creation, and durable input submission across retries and restarts.
  Session metadata and its conversation are created in one transaction. Results refer to that submission's answer.
  Extension input handlers run before submission; arbitrary extension side effects are not guaranteed exactly once.
- The Watch shows 20 recent sessions, 8 recent tasks, and the last 8 text messages of a selected session. Long text
  is shortened. Listen uses `AVSpeechSynthesizer`. Full conversations and extension interactions stay on iPhone.
- Swipe left to remove a task or session from this Watch. Hidden rows survive refresh and restart; this does not delete
  phone sessions or stop received work. Removing an unsent prompt cancels queued delivery when possible.
- Background execution is finite. Transcription cancels when its delivery background task expires. Long agent runs may
  pause until Pi is opened again. WatchConnectivity is a paired-device transport; cellular internet alone does not make
  this companion a phone-free coding client.

## Verification

```sh
scripts/test-watch.sh
cd engine && npm run typecheck && npm test && npm run build && cd ..
xcodebuild -project App/PiMobile.xcodeproj -scheme PiMobile -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The host checks cover wire limits, persistent receipts and hidden rows, and simulator chunk ordering.
Engine tests use the durable harness and SQLite storage with Node’s `node:sqlite` driver to check concurrent retries,
restart recovery, interrupted creation commits, and nonblocking lookup of the exact submission answer. The app uses
the same storage adapter with its native SQLite bridge.

Before release, verify on a physical paired iPhone and Watch:

- Allow and deny permissions; record a new prompt and a reply; Stop, review, Send, Cancel, Record again, and Retry.
  Check the 60-second limit, system input, English and the Watch language, and that transcription alone starts no task.
- Lock the phone; transfer, transcribe, submit, and receive a result. Disconnect and reconnect; restart both apps;
  simulate a lost acknowledgement and verify one session and one prompt. Check recovery after background suspension.
- Check notification mirroring and tap routing, Listen with speaker and headphones, swipe removal after restart,
  deleted sessions, extension questions, and switching the phone's session store.

Debug simulators use acknowledged 32 KB message chunks because Simulator does not support `transferFile`. That transport
is excluded from Release builds. Build for an arm64 simulator with `ONLY_ACTIVE_ARCH=YES`, and keep ad-hoc signing enabled
(`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) for phone Keychain access. Simulator recognition permits Apple's network
recognizer; errors such as `kLSRErrorDomain` code 300 require testing on devices. Simulator builds do not verify physical
microphone input, speech recognition, notification mirroring, wake-ups, or background execution time.
