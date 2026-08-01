# Security Policy

Parrot records microphone and system audio, so security reports get top priority here.

## Reporting

Please report vulnerabilities privately via [GitHub Security Advisories](https://github.com/turantekin/Parrot/security/advisories/new) rather than public issues. This is a solo-maintainer project, so "within a few days" is the honest response time — but audio-privacy issues jump every queue.

Especially interested in:

- anything that makes audio or transcript data leave the machine without an explicit opt-in
- key material escaping the Keychain (into logs, files, or crash reports)
- permission or entitlement escalations beyond the two the app asks for

## Supported versions

Only the [latest release](https://github.com/turantekin/Parrot/releases) is supported. Updates ship as notarized DMGs, and the app checks GitHub once a day and tells you when one is available.
