# NanaZip Patch Tool 🧰

## 📋 Project description

Welcome to **NanaZip Patch Tool** (`RemoveSponsorshipAndInstall.ps1`) — a universal patching and build tool for [NanaZip](https://github.com/M2Team/NanaZip) sources.

Out of the box it ships with one patch — **complete sponsorship removal** (toolbar button, dialog, Store API) — then builds a **Release** package, signs it with a test certificate, installs it via `msixbundle`, and cleans up the certificate afterwards.

## 🚀 Functional capabilities

- **🧹 Sponsorship removal**: Deletes the Sponsor button without shifting the toolbar, removes the sponsor dialog, Store-license checks, `AcquireSponsorEdition` handling and all related strings/resources.
- **🖥️ Interactive menu**: Pick sources folder, patches, build, signing and install steps — no programming knowledge required. Can be launched from anywhere.
- **🔨 Release build**: Switches the tree from Preview to Release (`NanaZipBuildPreviewRelease=false`), restores NuGet packages and builds an x64 `msixbundle` with VS Build Tools.
- **🔏 Test signing**: Generates a self-signed certificate matching the package Publisher, signs the bundle (SHA256) and verifies the signature.
- **📦 One-command install**: Installs the signed bundle via `Add-AppxPackage` (asks for admin rights automatically).
- **🧽 Certificate cleanup**: Removes the test certificate from all stores and wipes PFX/CER files after install.
- **💾 Automatic backups**: Every touched file is copied to `.nosponsor-backup-<date>` before patching.
- **🛡️ Fail-safe patching**: Anchor-based edits, XML DOM for project files, brace-balance validation — on any doubt the step fails without touching files. Re-runs are idempotent.

## ✅ Requirements

- **Windows 10/11 x64** with PowerShell 5.1+.
- **Visual Studio Build Tools** with `VC.Tools.x86.x64` workload.
- **Windows SDK 10** (provides `signtool.exe` / `makeappx.exe`).
- **Administrator rights** for the install step (the script relaunches itself elevated).

## 🛠️ Installation and startup

1. **Place the script** into the NanaZip sources root (or anywhere — the path can be picked in the menu):

   ```powershell
   Copy-Item RemoveSponsorshipAndInstall.ps1 C:\path\to\NanaZip-main\
   ```

2. **Run it**:

   ```powershell
   powershell -ExecutionPolicy Bypass -File RemoveSponsorshipAndInstall.ps1
   ```

3. **Use the menu**:

   ```
   === NanaZip Patch Tool ===
     1. Исходники NanaZip : C:\path\to\NanaZip-main
     2. Патчи…            : выбрано 1/1
     3. Сборка и установка…
     0. СТАРТ   Q. Выход
   ```

   - `1` — change the sources folder (validated automatically).
   - `2` — toggle patches (more patches can be added in the future).
   - `3` — toggle build / sign / install / certificate cleanup.
   - `0` — start. `Q` — quit.

4. **After install, restart all Explorer processes** via Task Manager so the context menu appears.

5. **Non-interactive (automation) mode**:

   ```powershell
   # Everything, no questions:
   powershell -ExecutionPolicy Bypass -File RemoveSponsorshipAndInstall.ps1 -NoMenu

   # Patches only, no build/install:
   powershell -ExecutionPolicy Bypass -File RemoveSponsorshipAndInstall.ps1 -PatchOnly

   # Install a ready bundle from Output without rebuilding:
   powershell -ExecutionPolicy Bypass -File RemoveSponsorshipAndInstall.ps1 -SkipBuild
   ```

## 📂 Menu / automation reference

- `-SourcePath`: NanaZip sources root (default: script folder).
- `-DisablePatches`: comma-separated list to skip, e.g. `NoSponsor`.
- `-SkipPatches`, `-PatchOnly`, `-SkipBuild`, `-SkipSign`, `-SkipInstall`, `-KeepCert`.
- `-Menu` / `-NoMenu`: force or suppress the interactive menu.

## 📝 Notes

- The bundle is **x64-only Release** (`40174MouriNaruto.NanaZip`, not Preview).
- The test certificate (`CN=E310A153-…`, 10 years, password `nanazip`) is deleted after install by default.
- On Windows 10 the context menu does not appear on drives (MSIX limitation, needs Windows 11 22H2+).

## 📝 License

Free to use and modify for any purpose: [MIT License](https://github.com/exlocus/nanazip-patch-tool/blob/main/LICENSE).

---

*Note: **NanaZip Patch Tool** is a third-party helper and is not affiliated with the [NanaZip](https://github.com/M2Team/NanaZip) developers.*
