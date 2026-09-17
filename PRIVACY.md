# Privacy

Codex Bridge is a local-first application for macOS and Windows. The project does not operate a developer cloud relay, telemetry collector, analytics endpoint, account database, or billing system.

## Local data

The background service stores project registrations, configuration, task history, conversation messages, and execution evidence in the current operating-system user's application data directory. Registered projects remain in their existing locations.

Connection credentials and Tunnel Runtime Keys use macOS Keychain or Windows Credential Manager. The embedded browser maintains a persistent profile for the current system user. Installation packages do not contain user databases, browser cookies, or user credentials.

## External services

- ChatGPT, Codex, and other configured agents may send prompts, project content, and execution results to the services selected by the user.
- Connected MCP clients receive the results of authorized tool calls. Depending on project permissions and the requested tool, these results can include file content and task output.
- Secure MCP Tunnel carries MCP transport traffic through the packaged OpenAI tunnel helper.
- Configured model, search, and MCP servers receive the requests required for their enabled functions.

Codex Bridge does not add an independent analytics or crash-reporting transmission path.

## Logs and sharing

Logs and diagnostic output apply credential and path redaction. Review logs, task output, screenshots, and diagnostic files before sharing them, since user-provided content may contain private information.

## User control

Project permissions, task modes, agent capabilities, and local approvals determine the access granted to a request. Users can disconnect clients, disable agents, change project permissions, and remove registered projects in the app.

Application data, browser profiles, and operating-system credentials are separate from the installed program. Windows uninstall preserves these data. Deleting Bridge data does not delete registered project directories or the user's external agent accounts.
