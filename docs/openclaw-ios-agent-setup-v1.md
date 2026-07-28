# Remote iOS Agentic Workflow Setup: OpenClaw + Slack

This guide provides concise, step-by-step instructions for configuring a dedicated macOS host to run parallel iOS development agents orchestrated via Slack.

### Prerequisites
*   A dedicated macOS host (e.g., bare-metal cloud provider or a local headless Mac Mini).
*   Xcode downloaded and installed on the host.
*   Admin access to a Slack Workspace.

---

### Step 1: Secure Remote Access
Ensure reliable, headless access to the macOS host without exposing it to the public internet. Install and authenticate the host on your Tailscale network, then enable SSH:
1. On the Mac host, go to **System Settings > General > Sharing**.
2. Toggle on **Remote Login**.
3. You can now securely connect from your phone or main workstation using: `ssh user@<tailscale-ip>`

### Step 2: Prepare the iOS Toolchain
SSH into your remote Mac and configure the environment for headless execution.

1. **Accept Xcode Licenses:**
   ```bash
   sudo xcodebuild -license accept
   xcode-select --install
   ```
2. **Install XcodeBuildMCP:**
   This provides the agent with the necessary tools to compile your SwiftUI modules and run UI tests without getting blocked by GUI permission prompts.
   ```bash
   npm install -g @sentry/xcodebuildmcp
   ```

### Step 3: Configure the Slack App
Create the secure bridge for OpenClaw to communicate with your Slack workspace.

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App** (from scratch).
2. Go to **Socket Mode** in the left sidebar and toggle it **On**. Generate an App-Level Token (start with `xapp-`) with `connections:write` scope. Keep this token safe.
3. Go to **OAuth & Permissions**. Under **Bot Token Scopes**, add:
   *   `app_mentions:read`
   *   `chat:write`
   *   `im:history`
   *   `im:read`
   *   `im:write`
4. Install the app to your workspace and copy the **Bot User OAuth Token** (starts with `xoxb-`).

### Step 4: Install and Configure OpenClaw
1. **Install OpenClaw** on the remote Mac:
   ```bash
   brew install openclaw
   ```
2. **Initialize the Configuration:**
   ```bash
   openclaw init
   ```
3. **Edit the Configuration:**
   Open the generated config file (usually `~/.openclaw/config.yaml`) and update the Slack and Plugin sections:
   ```yaml
   platform:
     type: slack
     slack_bot_token: "xoxb-YOUR-BOT-TOKEN"
     slack_app_token: "xapp-YOUR-APP-TOKEN"
   
   plugins:
     - name: openclaw-code-agent
       enabled: true
       settings:
         parallel_execution: true
         isolation_mode: "worktree"
   ```

### Step 5: Start and Pair the Daemon
1. **Start the OpenClaw Daemon:**
   ```bash
   openclaw daemon start
   ```
   *The bot should now show as "Active" in your Slack workspace.*
2. **Pair Your Slack User:**
   Send a Direct Message to the OpenClaw bot in Slack. It will reply with a secure 6-digit pairing code.
3. **Approve the Pairing (Terminal):**
   Run the following command in your SSH session to grant your Slack user administrative rights:
   ```bash
   openclaw pairing approve slack <6-digit-code>
   ```

### Step 6: Define the Worktree Protocol
To ensure parallel agents do not collide, provide OpenClaw with a baseline instruction for your repositories. You can do this by messaging the bot in Slack:

> **@OpenClaw Bot:** "Update your system instructions: Whenever starting a new iOS task, you must first create a new git worktree, use `xcrun simctl clone` to create a dedicated simulator for that task, and set the derivedDataPath to a local folder within the worktree before executing xcodebuildmcp."

---
**You are now fully configured.** You can disconnect your SSH session and manage all iOS development directly from your Slack app on any device.
