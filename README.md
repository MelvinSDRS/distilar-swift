# Distilar for Swift

The iOS SDK for Distilar. It adds a form your users fill
to report a bug or suggest a feature, with one optional screenshot, and sends it
to your Distilar project. Distilar groups the reports that ask for the same
thing, so you see what matters to the most people.

- One SwiftUI form, in English and French.
- Reports wait on the device when there is no connection, and go out once there is.
- A retry never stores a report twice.
- A screenshot leaves the device without its location or other metadata.
- No dependencies.

## Requirements

- iOS 17 or later. The package also builds for macOS 14, where its tests run.
- Xcode 26.4 or later (Swift 6.3).

## Install

In Xcode, choose **File › Add Package Dependencies…** and enter
`https://github.com/MelvinSDRS/distilar-swift`. In a `Package.swift`:

```swift
.package(url: "https://github.com/MelvinSDRS/distilar-swift", from: "0.1.0"),
```

## Use

Configure Distilar once at launch, with the project key from your dashboard.
The key is meant to ship inside your app.

```swift
import Distilar

@main
struct MyApp: App {
    init() {
        Distilar.configure(projectKey: "dpk_…")
    }
    // …
}
```

When a user signs in or out, pass your own id for them, never an email address
or a name. One person's reports then count once, across all their devices.

```swift
Distilar.identify(appUserID: user.id)   // at sign-in
Distilar.identify(appUserID: nil)       // at sign-out
```

Present the form in a sheet. It brings its own navigation bar, with Cancel and Send.

```swift
@State private var feedback: FeedbackKind?

Button("Report a Bug") { feedback = .bug }
Button("Suggest a Feature") { feedback = .feature }
    .sheet(item: $feedback) { kind in
        DistilarFeedbackForm(kind: kind)
    }
```

`onSubmit` tells you how it went, if you want to know: success once the report
is sent or saved to send later, failure when it cannot be taken. The form
thanks the user, or says what went wrong, either way.

## When there is no connection

A report is saved on the device before the first attempt to send it, with the
key that identifies it to the server. If it cannot go out, the form says it is
saved and will be sent automatically. The SDK tries again:

- when the app starts, comes back to the foreground, or gets a connection;
- after a delay that doubles from 5 seconds up to 10 minutes while the app runs;
- no sooner than the server asks, when it says to wait.

A report the server refuses, such as one sent with an unknown project key, is
dropped, and the reason goes to the system log under `com.distilar.sdk`. So is a
report still waiting after 30 days. At most 20 reports wait at once; the form
says so when that is full.

Waiting reports live in the app's Application Support folder, excluded from backups.

## Screenshots

The user picks one image with the system photo picker, which needs no access to
their library. Before it leaves the device the SDK turns it upright, fits it in
2,560 pixels on its longest side, converts it to sRGB, and encodes it afresh:
PNG for a screenshot, JPEG for a photo or anything over 5 MB as a PNG. No
location or other metadata survives. The server decodes and encodes it once
more.

## What a report contains

| Field | Example | Where it comes from |
|---|---|---|
| Kind | `bug` | the form the user opened |
| Text | what the user typed | the form, at most 8,192 characters |
| Screenshot | an image | the form, optional |
| Install id | a random UUID | made once, kept in the Keychain on this device only, never synced |
| User id | your id for the user | `Distilar.identify(appUserID:)`, if you call it |
| App version | `2.4 (318)` | your app's Info.plist |
| System | `iOS 26.1` | the device |
| Device model | `iPhone17,1` | the device |
| Locale | `fr_CA` | the app's language and region |

## App Store privacy

The SDK ships a privacy manifest that lists what it collects. When you answer
the App Privacy questions in App Store Connect, declare these, all for **App
Functionality**, none for tracking:

- **User Content › Customer Support**: the text of each report.
- **User Content › Photos or Videos**: the screenshot, when the user attaches one.
- **Identifiers › Device ID**: the install id.
- **Identifiers › User ID**: only if you call `identify`.
- **Diagnostics › Other Diagnostic Data**: the app version, system and device model.

Declare them as linked to the user if you call `identify`.

## Languages

The form is in English and French. It shows French only when your app lists
French among its localizations, as an app translated into French already does.

## UI tests

The text field has the accessibility identifier `distilar.text`, and the Send
button `distilar.send`.

## Example app and live tests

`Example/DistilarExample.xcodeproj` opens the form and can point the SDK at a
closed port, to show reports waiting on the device. Enter your server and
project key in the app, or pass them at launch:
`-server http://127.0.0.1:8080 -key dpk_…`.

Against a running Distilar server, the package's end-to-end tests and the
Example's UI tests send real reports:

```sh
DISTILAR_E2E_URL=http://127.0.0.1:8080 DISTILAR_E2E_KEY=dpk_… swift test

TEST_RUNNER_DISTILAR_URL=http://127.0.0.1:8080 TEST_RUNNER_DISTILAR_KEY=dpk_… \
  xcodebuild test -project Example/DistilarExample.xcodeproj -scheme DistilarExample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Without those variables the live tests are skipped, and `swift test` runs the rest.
