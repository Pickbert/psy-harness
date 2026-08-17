# Third-party notices

DesktopPet includes a pinned source snapshot and, in Apple Silicon release builds, a compiled runtime derived from DeepSeek Harness.

- Project: DeepSeek Harness
- Upstream: https://github.com/deepseek-ai/deepseek-harness
- Commit: `47f943859bef60e4160492346772ded9b24f765a`
- License: MIT

The complete upstream license is bundled beside this notice as `DeepSeekHarness-LICENSE.txt`. The pinned source snapshot remains available under `ThirdParty/deepseek-harness` for auditing and reproducible upgrades. DesktopPet carries a small local patch that adds abortable server-to-client JSON-RPC requests, the `desktopPet/approval.request` bridge, and the fail-closed DesktopPet structured tool policy.
