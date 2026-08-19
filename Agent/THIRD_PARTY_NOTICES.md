# Third-party notices

DesktopPet includes a pinned source snapshot and a bundled runtime derived from DeepSeek Harness in Apple Silicon and Windows Agent release builds.

- Project: DeepSeek Harness
- Upstream: https://github.com/deepseek-ai/deepseek-harness
- Release: `dsh@0.1.0-rc.7`
- Commit: `99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`
- License: MIT

The complete upstream license is bundled beside this notice as `DeepSeekHarness-LICENSE.txt`. The pinned source snapshot remains available under `ThirdParty/deepseek-harness` for auditing and reproducible upgrades. DesktopPet carries a small local patch that adds abortable server-to-client JSON-RPC requests, the `desktopPet/approval.request` bridge, and the fail-closed DesktopPet structured tool policy.

DesktopPet also uses the following pinned Swift packages for local, read-only XLSX/XLSM parsing:

- CoreXLSX `0.14.2` — https://github.com/CoreOffice/CoreXLSX — Apache-2.0
- XMLCoder `0.14.0` — https://github.com/maxdesiatov/XMLCoder — MIT
- ZIPFoundation `0.9.11` — https://github.com/weichsel/ZIPFoundation — MIT

Their complete licenses are bundled beside this notice as `CoreXLSX-LICENSE.txt`, `XMLCoder-LICENSE.txt`, and `ZIPFoundation-LICENSE.txt`.

Windows Agent packages also redistribute the official Node.js executable used to host the audited Harness dependency closure. Node.js is distributed under the MIT license and includes third-party components under the terms listed in its complete `LICENSE` file, bundled as `NodeJS-LICENSE.txt`.

Windows Agent packages include the following pinned libraries for isolated, local document extraction:

- ExcelJS `4.4.0` — https://github.com/exceljs/exceljs — MIT
- Mammoth `1.12.0` — https://github.com/mwilliamson/mammoth.js — BSD-2-Clause
- PDF.js `6.2.108` — https://github.com/mozilla/pdf.js — Apache-2.0

Their complete top-level licenses are bundled as `ExcelJS-LICENSE.txt`, `Mammoth-LICENSE.txt`, and `PDFJS-LICENSE.txt`. The exact production dependency closure and integrity hashes are recorded in `Agent/windows-file-analysis/package-lock.json`; ExcelJS's `uuid` dependency is overridden to `11.1.1` to avoid the vulnerable pre-11.1.1 buffer-handling implementation.
