# Third-party notices

DesktopPet includes a pinned source snapshot and, in Apple Silicon release builds, a compiled runtime derived from DeepSeek Harness.

- Project: DeepSeek Harness
- Upstream: https://github.com/deepseek-ai/deepseek-harness
- Release: `dsh@0.1.0-rc.7`
- Commit: `99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`
- License: MIT

The complete upstream license is bundled beside this notice as `DeepSeekHarness-LICENSE.txt`. The pinned source snapshot remains available under `ThirdParty/deepseek-harness` for auditing and reproducible upgrades. DesktopPet carries a small local patch that adds abortable server-to-client JSON-RPC requests, the `desktopPet/approval.request` bridge, and the fail-closed DesktopPet structured tool policy.
