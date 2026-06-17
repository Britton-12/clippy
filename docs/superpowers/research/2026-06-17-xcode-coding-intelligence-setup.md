# Xcode 26 Coding Intelligence: Setup and Use

Research date: 2026-06-17
Method: Fetched Apple Developer documentation. The doc pages render client-side, so
the prose lives in the DocC JSON endpoints under
`https://developer.apple.com/tutorials/data/documentation/xcode/<page>.json`. Content
below is taken verbatim from those JSON sources.

Sources:
- Coding intelligence (landing): https://developer.apple.com/documentation/xcode/coding-intelligence
- Setting up coding intelligence: https://developer.apple.com/documentation/xcode/setting-up-coding-intelligence
- Writing code with intelligence in Xcode: https://developer.apple.com/documentation/xcode/writing-code-with-intelligence-in-xcode
- Using coding intelligence in the source editor: https://developer.apple.com/documentation/xcode/using-coding-intelligence-in-the-source-editor
- Extending and customizing agents: https://developer.apple.com/documentation/xcode/extending-and-customizing-agents

---

## 1. What Coding Intelligence is

Coding intelligence is Xcode's built-in AI layer. You interact with an "agent" or a
large language model ("chat" model) by typing natural language prompts to ask questions
and give instructions. (Source: Writing code with intelligence in Xcode.)

Capabilities Apple lists:
- Explore code, add features, refine your interface, and use skills such as
  localization and accessibility. (Source: Coding intelligence landing.)
- Generate code, navigate unfamiliar codebases, and fix or refactor existing code.
  (Source: Writing code with intelligence.)
- Two interaction surfaces:
  1. The Coding Assistant (a conversation sidebar plus transcript and artifacts panes,
     behaves like the Project navigator; you can run multiple agents in parallel in
     separate panes).
  2. The source editor, via the coding tools popover (inline prompts, Explain, Generate
     a Preview, Generate a Playground, Document, Generate Fix for Issue).

Agents vs chat models (a distinction Apple draws explicitly):
- Agent: when chosen, it automatically has access to Xcode capabilities (building and
  testing your app), can iterate, build to verify, auto-fix warnings/errors, enter plan
  mode, and run command-line tools (with permission).
- Chat model (chat product): proposes or applies code edits; exposes a "Project Context"
  toggle and an "Automatically apply code changes" toggle.

Note: Apple's docs do not use the phrase "predictive code completion" on these pages.
The inline assistance described is the coding tools popover and per-issue "Generate Fix"
in the source editor, not a separate keystroke-level completion feature. Do not claim a
"predictive completion" toggle exists unless verified in the running app.

---

## 2. Requirements

NOT STATED on these documentation pages. Apple's coding-intelligence docs do not list
a specific minimum macOS version, Xcode version, hardware, Apple Intelligence
prerequisite, or account requirement.

What the docs do imply:
- Built-in providers shown "where available" are Claude (Claude Sonnet & Opus) and
  ChatGPT in Xcode. Availability is gated ("Where available, you can turn on Claude or
  ChatGPT").
- ChatGPT works with or without an account; a free or paid (ChatGPT Plus) account
  raises limits.
- Claude requires signing in.
- The History (rollback) feature requires the project to have a Git repository (Xcode
  offers to create one if absent).

Verify exact macOS/Xcode version floors against Xcode 26 release notes before quoting a
number. These pages do not provide them.

---

## 3. Enable Coding Intelligence and add model providers

Menu path to the settings (verbatim): "Choose Xcode > Settings and select Intelligence
in the sidebar." In Intelligence settings you turn on the agent and chat products you
want. (Source: Setting up coding intelligence.)

### 3a. Enable an agent (e.g. Claude agent)
1. In Intelligence settings, click **Get** next to the agent you want to enable, under
   **Agents**.
2. In the dialog that appears, click **Install**.
3. If you have an account, sign in: in the agent settings, click the **More** button
   (the `...`) in the **Account** row, then follow the prompts (including a browser
   window if one appears) to enter credentials.

To add an agent that does not appear in Intelligence settings but supports the Agent
Client Protocol: click **Add an Agent** under Agents, fill in the sheet, click **Add**.

After download, Xcode auto-updates agents when possible.

### 3b. Enable the built-in chat option: ChatGPT in Xcode
1. In Intelligence settings, click **Turn On** in the **ChatGPT in Xcode** row under
   **Chat**.
2. In the dialogs, click **Next**, then **Turn On ChatGPT**.

To sign in (free account, or paid for higher limits):
1. In ChatGPT in Xcode settings, toggle **ChatGPT in Xcode** on.
2. In the **ChatGPT** row, click **Sign In**, then **Sign In** again in the dialog.
3. Complete sign-in in the browser window that appears.

Upgrade path: **Upgrade to ChatGPT Plus** at the bottom of the ChatGPT in Xcode settings.
Reasoning level: for some models, pick the reasoning level in the **Reasoning** pop-up
menu at the bottom of the message text field in the conversation transcript.
Turn off: toggle **ChatGPT in Xcode** off in its settings.

### 3c. Enable the built-in chat option: Claude
1. In Intelligence settings, click **Claude Sonnet & Opus** under **Chat**.
2. In the **Claude** row, click **Sign In**.
3. Complete sign-in in the browser window.

### 3d. Add ANOTHER chat provider (this is the LOCAL model path)
Click the **Add a Chat Provider** button under **Chat**. (Source: Setting up coding
intelligence, "Use another chat provider".)

Two choices in the dialog:
- **Internet Hosted**: enter the **URL** and other details, then click **Add**. (Use
  this for a hosted endpoint, including an OpenAI-compatible cloud gateway.)
- **Locally Hosted**: enter a **port** and an optional **description**, then click
  **Add**. (Use this for a local server such as Ollama or LM Studio running on your Mac.)

Compatibility requirement (verbatim intent): an added provider must support the **Chat
Completions API**. Xcode expects these two endpoints, relative to the provider URL:
- `{Model provider URL}/v1/models`
- `{Model provider URL}/v1/chat/completions`

Practical mapping for local servers:
- Ollama exposes an OpenAI-compatible API at `http://localhost:11434/v1` (default port
  11434), so it satisfies `/v1/models` and `/v1/chat/completions`.
- LM Studio exposes an OpenAI-compatible server (default port 1234) at the same `/v1`
  paths.
- For "Locally Hosted," Apple asks only for the port (and optional description); for
  "Internet Hosted," it asks for the full URL.

Gotcha: Apple's docs name only the port + description fields for Locally Hosted and a
URL field for Internet Hosted. They do not enumerate a separate "model name" or
"API key" field on these pages. The exact field set may differ in the shipping UI;
confirm in the running app. The hard contract is the two `/v1` endpoints above.

### 3e. MDM / managed devices
To disable the coding assistant on managed devices, set the
`CodingAssistantAllowExternalIntegrations` key to `false` in an MDM profile. (Source:
Setting up coding intelligence, "Configure managed devices".)

---

## 4. Using it in the editor

### 4a. Coding Assistant (conversation sidebar)
- Open: click the **Coding Assistant** button or press **Command-0**, click **New
  Conversation**, and choose an agent (under Agents) or a model (under Chat) from the
  pop-up menu. Or click **New Conversation** in the project window toolbar to start with
  the current agent/model.
- Switch agent/model mid-flow: press **Command-0** and choose another from the New
  Conversation pop-up.
- Enter prompts in the message text field at the bottom of the transcript; press
  **Return** or click **Submit**. **Stop** cancels; **Undo Changes** reverts the last
  response's edits.
- Responses appear in the transcript; the **Assistant Activity** button in the toolbar
  spins while working. Click filenames/arrows in a response to open changed files
  (multicolor change bars mark edits).
- Project changes appear in the **artifacts pane** (comparison view or preview per
  file). Hover a line number and click the `@` to add an inline annotation prompt.
- Plan mode (agents): iterate on a design before any code changes. Invoke with `/plan`;
  exit with `/exit` then `/exit-plan`.
- Apply mode (chat models): if **Automatically apply code changes** is off, Xcode labels
  output as "Proposal"; click a snippet, then **Apply** (or **Create New File**).
- History / rollback: choose **History** from the More button above the transcript, use
  the slider to unwind/redo per-prompt changes, click **Restore**. Requires a Git repo.
- Organize: create groups with **New Group**; rename, drag, archive conversations.

### 4b. Source editor (coding tools popover)
Open the popover by either:
- Control-click a symbol or selection -> **Show Coding Tools > Show Coding Tools**.
- Select code and click the coding assistant button in the editor gutter.
- Press **Command-Option-0** anywhere in the source editor.

Then type a prompt or click a context button: **Explain**, **Generate a Preview**,
**Generate a Playground**, **Document** (drafts DocC-style comments). For diagnostics,
click the issue icon and click **Generate** next to "Generate Fix for Issue."

### 4c. Project context settings (what the model can see)
- Inline references: type `@` in the message field to reference specific symbols/files.
- Attachments pop-up (lower-left): "Add context from project" or "Upload files" (files
  inside or outside the project).
- **Project Context** button (chat models only, lower-left, on by default): lets Xcode
  share relevant project code/context with the model. Turn off its automatic search to
  narrow scope and rely on explicit `@` references instead.
- Agent customization (Extending and customizing agents):
  - Permissions: Intelligence settings > **Permissions** row under Agents -> manage
    **Allowed Commands** (add/remove with +/-) and **Allowed Tools** (remove with -).
  - Per-agent config files live under `~/Library/Developer/Xcode/CodingAssistant`, e.g.
    `ClaudeAgentConfig`, `codex`, `gemini` subfolders (set default model, add MCP
    servers, define skills). These only affect agents launched inside Xcode.
  - Plug-ins: Intelligence settings > **Plug-ins** row under Agents -> **Add Plug-in**
    (e.g. Add from URL) to add subagents, MCP servers, and skills.

---

## 5. Privacy and data handling

- When you enter prompts, "the agent or model that you set up in the Intelligence
  settings may access your project files and other information when processing your
  requests." (Source: Setting up coding intelligence.)
- The canonical privacy explanation is an in-app dialog, not a public web page: click
  **"About Intelligence in Xcode & Privacy..."** in the Intelligence settings. There is
  no separate Apple Developer privacy URL for this; do not invent one.
- Per-provider legal terms appear at the bottom of each provider's settings:
  "OpenAI Terms of Use...", "Anthropic Terms of Use...", and the agent's privacy
  policy / terms-of-use links.
- Local-vs-cloud reality: built-in Claude and ChatGPT are cloud providers (require
  sign-in / send data off-device). A "Locally Hosted" provider (Ollama, LM Studio) keeps
  inference on your Mac, which is the privacy-preserving path. Whether project files
  leave the machine depends on which provider you select per conversation.
- Project Context (chat models) is on by default and shares relevant code with the
  model; turn it off to restrict what is sent.

### Gotchas / gaps
- No specific macOS/Xcode version, Apple Intelligence, or hardware requirement is stated
  on these pages. Confirm against Xcode 26 release notes.
- "Predictive code completion" is not a documented term here; inline help is the coding
  tools popover and Generate Fix for Issue. Do not assert a dedicated completion toggle.
- The local-provider dialog documents only port + optional description (Locally Hosted)
  or URL + details (Internet Hosted). Model-name and API-key field specifics are not
  enumerated; verify in the running app. The firm requirement is the OpenAI-compatible
  `/v1/models` and `/v1/chat/completions` endpoints.
- History/rollback needs a Git repository.
- A model-providers-specific JSON page (e.g.
  `.../xcode/coding-intelligence-model-providers.json` and
  `.../configuring-coding-intelligence-model-providers`) returned HTTP 404; provider
  setup lives inside "Setting up coding intelligence," not a standalone page.
