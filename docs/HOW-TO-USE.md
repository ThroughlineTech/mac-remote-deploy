# How to Use RemoteDeploy

RemoteDeploy is a macOS menu bar app that builds your iOS and macOS apps, signs them, and serves them over HTTPS so you can install them on your iPhone from anywhere -- no USB cable, no TestFlight, no waiting. You just open a URL in Safari and tap Install.

As of v2.0, you can also trigger builds and monitor progress from your phone using the **RemoteDeploy Companion** iOS app, or from any browser using the built-in **web PWA** at `/app/`.

This guide walks through the entire process from first launch to a working app on your phone.

---

## Prerequisites

Before you launch RemoteDeploy, you need four things in place:

**1. Tailscale on your Mac and iPhone**

Tailscale is what connects your Mac and iPhone securely, even when they're on different networks. Install it on both devices and sign in with the same account (or join the same tailnet). This is what makes "deploy from anywhere" work — your phone can reach your Mac whether you're at home, at a coffee shop, or on the other side of the world.

- Mac: [tailscale.com/download/macos](https://tailscale.com/download/macos)
- iPhone: [App Store - Tailscale](https://apps.apple.com/app/tailscale/id1470499037)

Make sure both devices show as connected in the Tailscale admin console before continuing.

**2. Xcode installed**

RemoteDeploy calls `xcodebuild` under the hood to archive and export your app. You need a full Xcode installation — Command Line Tools alone are not enough. Any recent version that can build your project will work.

**3. Apple Developer account with ad-hoc signing**

Your app needs to be signed with an ad-hoc (or development) provisioning profile that includes the UDID of every iPhone you want to install on. This is an Apple requirement for sideloading outside the App Store.

What you need specifically:
- An Apple Developer Program membership ($99/year)
- A distribution certificate (or development certificate) in your keychain
- A provisioning profile that lists your iPhone's UDID
- Your Development Team ID (a 10-character string like `ABCDE12345`)

If you don't know your iPhone's UDID, plug it into your Mac, open Finder, click the phone, and click the serial number area until it shows the UDID. Add that UDID to your provisioning profile in the [Apple Developer Portal](https://developer.apple.com/account/resources/devices/list).

**4. Your iOS project builds successfully in Xcode**

Before trying RemoteDeploy, make sure your project builds and archives cleanly in Xcode itself. If Xcode can't build it, RemoteDeploy can't either — it's calling the same tools.

---

## First Launch

When you first open RemoteDeploy, it appears as a small package icon in your menu bar (top-right of your screen). There's no dock icon and no main window — everything lives in that menu bar dropdown.

Since you have no projects configured yet, the app automatically opens the **Setup Assistant** — a 5-step wizard that walks you through everything. You can also re-open this wizard at any time from the menu bar by clicking **Setup Guide**.

---

## The Setup Assistant

### Step 1: Tailscale

The first screen checks whether Tailscale is running on your Mac. If it is, you'll see a green indicator and your Mac's Tailscale hostname (something like `your-mac.tail12345.ts.net`).

If Tailscale isn't running or isn't installed, the assistant explains what you need and gives you a link to install it. Once you've got it running, hit **Check Again** and it should detect the connection.

Your Tailscale hostname is important — it becomes the URL you'll use to install apps on your phone.

### Step 2: Certificates

iOS refuses to install apps over plain HTTP. It requires HTTPS with a valid certificate. Tailscale makes this easy — it can generate a real Let's Encrypt certificate for your Mac's MagicDNS hostname.

The assistant offers two options:
- **Generate automatically** — the app runs `tailscale cert` for you to create the certificate
- **Browse to existing files** — if you've already generated a cert, point the app to the `.crt` and `.key` files

If the certificate is valid, the assistant shows a success state with the cert's expiry date.

More details on doing this manually are in the next section.

### Step 3: Add Your First Project

This is where you tell RemoteDeploy about the iOS app you want to deploy. You can either click the file picker button or drag-and-drop your `.xcodeproj` or `.xcworkspace` file into the window.

Once you select a project, the assistant auto-detects:
- **Available schemes** — shown as a dropdown so you can pick the right one
- **Bundle ID** — read from the project if possible
- **Team ID** — read from your signing settings if possible

You'll also see a brief explanation of ad-hoc signing and a link to the Apple Developer Portal in case you need to register a device UDID.

### Step 4: Push Notifications (Optional)

This step lets you set up push notifications so your phone gets a ping when a build finishes. This is entirely optional — you can skip it and come back later in Settings.

Three providers are supported: Prowl, Pushover, and ntfy. Each one has a **Send Test Notification** button so you can verify it works before moving on. Details on configuring each one are in the [Push Notifications](#push-notifications-optional) section below.

Hit **Skip** if you don't need push notifications right now.

### Step 5: Done

The final screen shows a summary of everything you configured:
- Your Tailscale hostname
- Certificate status
- The project you added
- Your install URL

The install URL is displayed prominently — something like:

```
https://your-mac.tail12345.ts.net:8443/rejog/
```

There's a **Copy URL** button so you can send it to yourself (AirDrop, iMessage, email — whatever). This is the URL you'll open on your iPhone to install apps.

The server starts automatically at this point. The menu bar icon should show a green status indicator.

---

## Setting Up Tailscale Certificates

If you want to set up certificates manually (instead of through the setup assistant), here's exactly how.

### Generate the certificate

Open Terminal on your Mac and run:

```bash
tailscale cert your-hostname.tail12345.ts.net
```

Replace `your-hostname.tail12345.ts.net` with your actual Tailscale MagicDNS hostname. You can find it by running:

```bash
tailscale status --self --json | jq -r '.Self.DNSName'
```

(It'll have a trailing dot — ignore that.)

The `tailscale cert` command creates two files in your current directory:
- `your-hostname.tail12345.ts.net.crt` — the certificate
- `your-hostname.tail12345.ts.net.key` — the private key

### Where to put them

RemoteDeploy looks for certificates in:

```
~/Library/Application Support/RemoteDeploy/certs/
```

You can either:
1. Move the files there yourself
2. Leave them wherever they are and point RemoteDeploy to them in Settings (Settings > TLS cert path / key path)

### How the app finds them

In Settings, there are two fields: **TLS cert path** and **TLS key path**. Set these to the full paths of your `.crt` and `.key` files. The app loads them when the server starts.

If you used the setup assistant to generate the cert automatically, these paths are already configured and the files live in the Application Support directory.

### Certificate renewal

Tailscale certs are Let's Encrypt certificates, so they expire after 90 days. RemoteDeploy handles renewal — it periodically re-runs `tailscale cert` to refresh the certificate. You shouldn't need to think about this after initial setup.

---

## Adding Your First Project

You can add a project either through the setup assistant (Step 3) or through Settings at any time.

### Via Settings

1. Click the RemoteDeploy menu bar icon
2. Click **Settings...**
3. In the Projects section, click **+ Add Project**
4. Fill in the project details (see below)

### Via the menu bar

In the menu bar dropdown, click **+ Add Project...** under the projects list.

### What each field means

| Field | What it is | Example |
|-------|-----------|---------|
| **Project path** | The folder containing your `.xcodeproj` or `.xcworkspace`. You can type a path, click Browse, or drag-and-drop. | `/Users/you/src/my-app` |
| **Scheme** | The Xcode scheme to build. Auto-detected from your project — pick from the dropdown. | `my-app` |
| **Bundle ID** | Your app's bundle identifier. Auto-detected if possible. | `com.example.myapp` |
| **Team ID** | Your Apple Development Team ID. A 10-character alphanumeric string. Auto-detected from your project's signing settings if available. | `ABCDE12345` |
| **Provisioning profile** | Usually set to automatic (`signingStyle=automatic`), which lets Xcode pick the right profile. You can also type a specific profile name as a fallback. | `automatic` |
| **Build configuration** | Debug or Release. Default is Release. Release builds are smaller and faster but don't include debug symbols. | `Release` |
| **URL path** | The path on the server where this project is served. Used for multi-project setups. | `/my-app/` |

### How auto-detection works

When you select a project path, RemoteDeploy runs `xcodebuild -list` against it to discover available schemes. It also reads your project's build settings to try to fill in the bundle ID and team ID automatically. If auto-detection doesn't find everything, you'll need to fill in the blanks manually.

If you have multiple projects configured, they each get their own URL path on the server. The root URL (`/`) shows an index page listing all your projects.

---

## Building and Deploying

Once your project is configured, building is a one-click operation.

### Start a build

1. Click the RemoteDeploy menu bar icon
2. Make sure the right project is selected in the dropdown next to **Build & Deploy** (if you have more than one)
3. Click **Build & Deploy**

### What happens during the build

Behind the scenes, RemoteDeploy does four things in sequence:

1. **Archive** — Runs `xcodebuild archive` with your project settings. This compiles the app and creates an `.xcarchive`.
2. **Export** — Runs `xcodebuild -exportArchive` with an ad-hoc export options plist. This signs the app and produces an `.ipa` file.
3. **Copy** — Moves the `.ipa` into RemoteDeploy's serving directory (`~/Library/Application Support/RemoteDeploy/serve/<project-slug>/app.ipa`).
4. **Generate manifest** — Creates the `manifest.plist` that iOS needs for OTA installation.

The build status updates in the menu bar as it progresses. You'll see messages like "Archiving...", "Exporting...", etc.

### Reading the build log

Click **View Build Log** in the menu bar dropdown to see the full `xcodebuild` output in real time. The log is color-coded:
- **Red** — errors
- **Yellow** — warnings
- Normal text — everything else

This is the same output you'd see if you ran `xcodebuild` in Terminal. If a build fails, the error messages here will tell you why.

### What success looks like

When the build succeeds:
- The menu bar shows a green status and "Last build: just now (success)"
- A macOS notification pops up saying the build succeeded
- If you configured push notifications, your phone gets a ping with the install URL
- The HTTPS server starts automatically (if it wasn't already running)
- The install URL is live and ready to use

---

## Installing on iPhone

This is the payoff. Your Mac just built and signed the app, and it's now being served over HTTPS via Tailscale. Here's how to get it on your phone.

### 1. Open Safari on your iPhone

It has to be Safari. Chrome, Firefox, and other browsers can't trigger iOS app installs. This is an Apple restriction.

### 2. Navigate to the install URL

Type or paste the URL shown in the RemoteDeploy menu bar. It looks something like:

```
https://your-mac.tail12345.ts.net:8443/rejog/
```

Make sure Tailscale is connected on your iPhone, or the URL won't resolve.

### 3. Tap "Install on This Device"

You'll see a simple page with your app name, version, and a big blue Install button. Tap it.

### 4. Confirm the install

iOS shows a system dialog: **"Would you like to install [App Name]?"** — tap **Install**.

The app icon appears on your home screen and shows a loading indicator. It typically takes about 10 seconds for the download and install to complete over Tailscale.

### 5. Trust the developer certificate

**The first time you install an app from your developer account**, iOS blocks it from launching. You'll see a message saying the developer is not trusted.

To fix this:
1. Open **Settings** on your iPhone
2. Go to **General** > **VPN & Device Management** (on older iOS versions, this is **General** > **Profiles & Device Management**)
3. Find your developer certificate under "Developer App"
4. Tap it and tap **Trust**
5. Confirm when prompted

You only need to do this once per developer certificate. After that, all apps signed with the same cert will work without this step.

### 6. Launch the app

Go back to your home screen and tap the app icon. It should launch normally.

### Save as a home screen bookmark

Since you'll probably be installing updates frequently, save the install URL as a bookmark on your home screen:

1. Open the install URL in Safari
2. Tap the **Share** button (the square with an arrow)
3. Tap **Add to Home Screen**
4. Give it a name (like "Install Rejog" or "Deploy")
5. Tap **Add**

Now you have a one-tap shortcut. When you want to check for a new build, just tap the bookmark, and if a new version is available, tap Install. The whole update cycle takes about 15 seconds.

---

## Importing a Pre-Built IPA

Sometimes you don't want RemoteDeploy to build the app — you already have an `.ipa` file from another source (CI pipeline, a colleague, an older build). You can import it directly and serve it for OTA install without any build step.

### When to use this

- You built the IPA in Xcode manually and just want to serve it
- Your CI system (GitHub Actions, Buildkite, etc.) produced an IPA and you want to deploy it quickly
- Someone sent you an IPA to test
- You want to serve an older build that you saved

The IPA must still be signed with an ad-hoc profile that includes the target device's UDID. An unsigned or App Store-signed IPA won't install via OTA.

### How to import

**Option 1: Menu bar**
1. Click the RemoteDeploy menu bar icon
2. Click **Import IPA...**
3. Select your `.ipa` file in the file picker

**Option 2: Drag and drop**
Drag the `.ipa` file onto the RemoteDeploy Settings window.

### What happens next

RemoteDeploy reads the bundle ID and version number from the IPA's embedded `Info.plist`, copies the file into its serving directory, generates a manifest, and registers it with the HTTPS server. The server starts if it isn't already running.

The app is immediately available for install at its URL. No build step needed.

---

## Push Notifications (Optional)

RemoteDeploy can send push notifications to your phone when builds start, succeed, or fail. This is useful when you kick off a build remotely (via SSH or a script) and want to know when it's done without watching the screen.

Three services are supported. You can enable one, two, or all three simultaneously.

### Setting up Prowl

[Prowl](https://www.prowlapp.com/) is a push notification app for iOS.

1. Install the Prowl app on your iPhone from the App Store
2. Create an account at [prowlapp.com](https://www.prowlapp.com/)
3. Go to [prowlapp.com/api_settings](https://www.prowlapp.com/api_settings) and generate an API key
4. In RemoteDeploy, open **Settings** > **Push Notifications**
5. Enable **Prowl** and paste your API key
6. Click **Send Test Notification** to verify it works

You should get a test notification on your phone within a few seconds. If you don't, double-check your API key and make sure the Prowl app is installed and notifications are enabled in iOS Settings.

### Setting up Pushover

[Pushover](https://pushover.net/) is another push notification service with iOS, Android, and desktop clients.

1. Install the Pushover app on your iPhone and create an account
2. Go to [pushover.net/apps/build](https://pushover.net/apps/build) and create a new application (name it "RemoteDeploy" or whatever you like)
3. Copy the **App Token** from the application you just created
4. Copy your **User Key** from the Pushover dashboard (top of the page after login)
5. In RemoteDeploy, open **Settings** > **Push Notifications**
6. Enable **Pushover** and paste both the App Token and User Key
7. Click **Send Test Notification** to verify

Pushover has a nice feature: when a build succeeds, the notification includes a clickable URL that opens the install page directly. Tap the notification and you're taken straight to the Install button in Safari.

### Setting up ntfy

[ntfy](https://ntfy.sh/) is a free, open-source push notification service. You can use the public server at `ntfy.sh` or self-host your own.

1. Install the ntfy app on your iPhone from the App Store
2. Pick a topic name — something unique like `remotedeploy-yourname` (anyone who knows the topic name can send to it on the public server, so don't use something guessable, or self-host)
3. In the ntfy app, subscribe to your topic
4. In RemoteDeploy, open **Settings** > **Push Notifications**
5. Enable **ntfy**
6. Set the **Server URL** to `https://ntfy.sh` (or your self-hosted server URL)
7. Set the **Topic** to the topic name you chose
8. Click **Send Test Notification** to verify

Like Pushover, ntfy supports clickable URLs — the install link is included in success notifications.

### Notification events

In Settings, you can toggle which events trigger notifications:

| Event | Default | What it sends |
|-------|---------|--------------|
| Build started | On | Project name |
| Build success | On | Project name + install URL |
| Build failure | On | Project name + first error line |

Build failures are sent at high priority so they break through Do Not Disturb on most notification services.

---

## Troubleshooting

### "Server Stopped" — the server isn't running

The HTTPS server needs valid TLS certificates to start. If you see "Server Stopped" in the menu bar:

- Check that your certificate files exist at the paths configured in Settings
- Certificates may have expired — re-run `tailscale cert your-hostname.tail12345.ts.net` in Terminal to get fresh ones, then update the paths in Settings if needed
- Make sure the port (default 8443) isn't being used by another application

### "Tailscale Disconnected"

The menu bar shows the Tailscale connection status with a colored indicator. If it shows disconnected:

- Open the Tailscale app on your Mac and make sure it's connected
- Check that Tailscale is running in the menu bar (look for the Tailscale icon)
- If you just restarted your Mac, Tailscale might take a few seconds to reconnect

RemoteDeploy checks Tailscale status every 30 seconds, so give it a moment after reconnecting.

### Build fails

Click **View Build Log** to see the full `xcodebuild` output. Common causes:

- **Signing errors** — Your provisioning profile might be expired, or your certificate might not be in the keychain. Open Xcode, go to the project's Signing & Capabilities settings, and make sure everything is green.
- **Scheme not found** — Make sure the scheme name in RemoteDeploy matches exactly what's in your Xcode project. Schemes are case-sensitive.
- **Dependencies not resolved** — If your project uses CocoaPods, run `pod install` first. If it uses Swift Package Manager, open the project in Xcode once so packages resolve before building with RemoteDeploy.
- **Wrong project type** — If your project uses a `.xcworkspace` (common with CocoaPods), make sure the project path points to the workspace, not the `.xcodeproj`.

As a sanity check: if you can't archive and export the app manually in Xcode, RemoteDeploy won't be able to either. Fix it in Xcode first.

### Can't install on iPhone — "Unable to Install"

This almost always means the device's UDID is not in the provisioning profile.

1. Find your iPhone's UDID (connect to Mac, open Finder, click on the phone, click the serial number until it shows the Identifier/UDID)
2. Go to the [Apple Developer Portal](https://developer.apple.com/account/resources/devices/list)
3. Add the UDID as a registered device
4. Regenerate your provisioning profile to include the new device
5. Download the new profile (or let Xcode manage it automatically)
6. Rebuild in RemoteDeploy

Other possible causes:
- Tailscale isn't connected on the iPhone (the URL won't load at all)
- You're using a browser other than Safari (only Safari can trigger OTA installs)
- The certificate doesn't match the hostname (regenerate with `tailscale cert`)

### App installs but won't launch — "Untrusted Developer"

This is normal for the first install from a given developer certificate. See [Step 5 in the Installing on iPhone section](#5-trust-the-developer-certificate) above. Go to Settings > General > VPN & Device Management, find your developer certificate, and trust it.

### App doesn't appear on home screen after tapping Install

- Wait 10-15 seconds — the download happens in the background and there's no progress bar
- Check if the app icon appeared on a different home screen page
- If it still doesn't show, go to Settings > General > VPN & Device Management and see if the app profile is listed there
- Try tapping Install again — sometimes the first attempt silently fails

### The install page loads but tapping Install does nothing

- Make sure you're in Safari, not an in-app browser
- Try opening the URL in a new Safari tab directly (copy-paste it)
- Check that both the manifest URL and IPA URL are accessible — you can test by navigating to `https://your-hostname:8443/your-project/manifest.plist` in Safari and seeing if it downloads

### Server was working but stopped after Mac sleep/restart

RemoteDeploy restarts the server automatically when the app launches. If you've enabled **Launch at Login** in Settings, the app starts with your Mac and the server comes back up automatically. If you haven't enabled that, just click the RemoteDeploy icon in your Applications folder (or wherever you installed it) to relaunch it.

---

## Tips

- **You only need physical access to the Mac once** — for the initial setup (Tailscale, certs, adding projects). After that, you can SSH into the Mac to launch builds or manage the app remotely. The iPhone side is just Safari.

- **Multiple projects work fine.** Add as many as you want in Settings. Each one gets its own URL path. The root URL (`/`) shows an index page listing all configured projects with install links.

- **The server handles multiple projects simultaneously.** You don't need to stop one to serve another — all configured projects are available at their respective URLs at the same time.

- **Keep the menu bar icon visible.** It gives you at-a-glance status: server running (green), build in progress (building indicator), build failed (red), Tailscale disconnected (warning).
