# Security Policy

`csw` handles Claude credentials and reads and writes the macOS Keychain, so security reports are taken seriously.

## Supported versions

Only the latest [release](https://github.com/mtxr/claude-switch/releases/latest) receives security fixes. Run `csw update` to get it.

## Reporting a vulnerability

Do not open a public issue. Report it privately with [GitHub private vulnerability reporting](https://github.com/mtxr/claude-switch/security/advisories/new) for `mtxr/claude-switch`.

Include the affected version (`csw --version`), your OS and architecture, and the steps to reproduce. Never include real tokens, credentials or Keychain contents in a report.

## Scope

In scope:

- **Credential handling:** profile logins, tokens and files written under `~/.claude*`, including permissions, leaks to logs, output or the environment, and cross-profile exposure.
- **Keychain access:** how `csw` reads, writes and deletes Keychain entries, including access to entries it does not own.
- **Install and update integrity:** `install.sh`, `csw update`, release assets and their verification, and the packaging in this repository.

Out of scope:

- Issues that require an already compromised account or machine.
- Vulnerabilities in Claude Code, Claude Desktop or macOS themselves.
