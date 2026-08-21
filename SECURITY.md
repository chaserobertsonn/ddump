# Security Policy

Public DDump releases are signed with Developer ID and notarized by Apple.
Local development builds are explicitly named `-unsigned` and must not be
published. Report any public download that triggers an unidentified-developer
warning because it may be incomplete or tampered with.

Please do not publish secrets in issues. Redact:

- Google Drive/rclone tokens
- ntfy topics if you treat them as private
- Slack webhook URLs
- Local usernames, client names, and private folder paths

To report a security concern, open a GitHub issue with a minimal description and
state that details should be shared privately.
