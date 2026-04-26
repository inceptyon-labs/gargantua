# Security Policy

Gargantua runs with elevated trust on a user's machine — it reads, classifies, and in opt-in modes removes files. We take reports of security issues seriously and will prioritize them accordingly.

## Supported Versions

Pre-1.0: only the latest released version receives security fixes. Once 1.0 ships, we'll document a stable support window here.

## Reporting a Vulnerability

Please report security issues **privately**, not in public GitHub issues.

- **Email:** <jnew00@gmail.com> (subject: `[gargantua security]`)
- **GitHub:** use [private vulnerability reporting](https://github.com/inceptyon-labs/gargantua/security/advisories/new) on this repo

Include:

- A description of the issue and its impact
- Steps to reproduce, or a proof-of-concept
- Affected version / commit SHA
- Your assessment of severity and any suggested mitigation

We aim to acknowledge reports within 3 business days and to have an initial assessment within 7 days. Coordinated disclosure timelines are negotiated per-report but we default to 90 days before public disclosure.

## What We Consider In-Scope

- Privilege escalation through the `GargantuaPrivilegedHelper` XPC interface
- Rules-engine paths that could trick the app into removing a `protected`-classified file
- MCP server guardrail bypasses (rate-limit evasion, audit-trail tampering, cancel-notification bypass)
- Untrusted-input handling in YAML rule loading
- Any path where a local unprivileged process can cause destructive disk operations it could not otherwise perform

## What We Consider Out-of-Scope

- Issues that require the user to install a malicious rule bundle they authored themselves
- Denial of service against the local user's own machine (crashes, hangs)
- Vulnerabilities in third-party dependencies without a demonstrated path to exploit Gargantua itself (report upstream)
- Social-engineering attacks that rely on the user approving a destructive action after being shown an accurate diff
