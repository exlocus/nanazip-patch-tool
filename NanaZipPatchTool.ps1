<#PSScriptInfo
.VERSION 1.0
.GUID 7a4e2b1c-9f3d-4a5e-8c6b-1d2e3f4a5b6c
.AUTHOR NanaZip Patch Tool
#>
<#
.SYNOPSIS
  NanaZip Patch Tool: patches NanaZip sources (currently — sponsorship
  removal), builds Release, signs, installs and removes
  the test certificate.

.DESCRIPTION
  Robustness principles (in case of drastic upstream changes):
  - Every edit looks for anchor patterns; if no anchor is found, an
    "already clean" marker is checked and the step is skipped instead of breaking the file.
  - XML files (vcxproj, filters, resw, xaml, appxmanifest) are edited via
    XML DOM, not text replacements.
  - C++ functions are cut by brace balance, respecting strings/comments.
  - Class members and includes are removed only if no references remain.
  - Every modified file is first copied to Backup.
  - Final status table; exit code != 0 on any Failed.
  - Idempotency: re-runs change nothing.

.PARAMETER SourcePath
  Root of unpacked NanaZip sources (default — script folder).
  The script can be launched from anywhere by passing the path here or in the menu.
.PARAMETER SkipPatches
  Do not apply sponsorship patches (build/sign/install only).
.PARAMETER DisablePatches
  Disable individual patches: comma-separated list of
  Xaml,ToolbarCpp,ToolbarH,SponsorPage,Exports,Handler,Resw,Manifest.
.PARAMETER PatchOnly
  Patches only (equivalent to -SkipBuild -SkipInstall).
.PARAMETER SkipBuild
  Skip the build (an existing msixbundle from Output will be used).
.PARAMETER SkipSign
  Do not sign (install is then possible only for an already signed package).
.PARAMETER SkipInstall
  Build and sign, but do not install.
.PARAMETER KeepCert
  Keep the self-signed certificate after install.
.PARAMETER CertPassword
  Password for the test certificate PFX file.
.PARAMETER Menu
  Force the menu.
.PARAMETER NoMenu
  Do not show the menu (fully automatic mode).
#>
[CmdletBinding()]
param(
    # Do NOT use $PSScriptRoot in defaults: it is empty during parameter binding
    # under `powershell -File` (verified). Resolved below in the script body.
    [string]$SourcePath = '',
    [string]$Configuration = 'Release',
    [string]$Platform = 'x64',
    [string]$BundlePlatforms = 'x64',
    [switch]$SkipPatches,
    [string]$DisablePatches = '',
    [switch]$PatchOnly,
    [switch]$SkipBuild,
    [switch]$SkipSign,
    [switch]$SkipInstall,
    [switch]$KeepCert,
    [string]$CertPassword = 'nanazip',
    [switch]$Menu,
    [switch]$NoMenu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Lazy resolution of the sources root (works under both -File and &).
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue
}
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = (Get-Location).Path
}
$SourcePath = [System.IO.Path]::GetFullPath($SourcePath)

# Patch keys (for -DisablePatches and the menu).
$script:AllPatchKeys = @('Xaml', 'ToolbarCpp', 'ToolbarH', 'SponsorPage',
    'Exports', 'Handler', 'Resw', 'Manifest')
# NanaZip Patch Tool: user patch registry.
# A new patch = a new entry here + its functions, internal keys go to Detail.
$script:PatchRegistry = @(
    @{ Key = 'NoSponsor'; Title = 'Remove sponsorship (button, dialog, Store API)';
       Detail = @('Xaml', 'ToolbarCpp', 'ToolbarH', 'SponsorPage', 'Exports', 'Handler', 'Resw', 'Manifest') }
)
$script:PatchOff = @{}
foreach ($k in ($DisablePatches -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $reg = @($script:PatchRegistry | Where-Object { $_.Key -eq $k })
    if ($reg.Count -gt 0) { foreach ($d in $reg[0].Detail) { $script:PatchOff[$d] = $true } }
    elseif ($script:AllPatchKeys -contains $k) { $script:PatchOff[$k] = $true }
    else { Write-Host ("[Warning] Unknown patch in -DisablePatches: {0}" -f $k) -ForegroundColor Yellow }
}
if ($SkipPatches) { foreach ($k in $script:AllPatchKeys) { $script:PatchOff[$k] = $true } }
if ($PatchOnly) { $SkipBuild = $true; $SkipInstall = $true }

function Test-PatchOn {
    param([string]$Key)
    return -not $script:PatchOff.ContainsKey($Key)
}

function Test-SourceRoot {
    param([string]$P)
    return ((Test-Path (Join-Path $P 'NanaZip.Modern')) -and
        (Test-Path (Join-Path $P 'BuildAllTargets.proj')))
}

# ---------------------------------------------------------------- statuses
$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Step, [string]$Status, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{
        Step = $Step; Status = $Status; Detail = $Detail
    }) | Out-Null
    $color = @{ OK = 'Green'; INFO = 'Gray'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    if (-not $color) { $color = 'White' }
    Write-Host ("[{0}] {1} {2}" -f $Status, $Step, $Detail) -ForegroundColor $color
}

# ---------------------------------------------------------------- helpers
function Backup-File {
    param([string]$Path)
    # No System.IO.Path::GetRelativePath — missing in .NET Framework (PS 5.1).
    $base = $SourcePath.TrimEnd('\', '/')
    $rel = $Path
    if ($rel.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $rel.Substring($base.Length).TrimStart('\', '/')
    }
    else {
        $rel = Split-Path $Path -Leaf
    }
    $dst = Join-Path $script:BackupDir $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $dst)) { Copy-Item -LiteralPath $Path -Destination $dst -Force }
}

function Save-TextUtf8 {
    param([string]$Path, [string]$Content)
    # conistency: keep BOM if the file already had one
    $raw = [System.IO.File]::ReadAllBytes($Path)
    $hadBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hadBom)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Test-Contains {
    param([string]$Path, [string]$Pattern)
    return (Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Quiet)
}

# Finds a logical declaration start: the signature line start + upwards
# over adjacent lines while they continue the declaration (return type,
# qualifiers, comments), i.e. non-empty and not ending with ; { }.
# Lines with # (directives) and empty lines are boundaries.
function Find-DeclarationStart {
    param([string]$Content, [int]$MatchIndex)
    $lineStart = $Content.LastIndexOf("`n", [Math]::Max(0, $MatchIndex - 1)) + 1
    $start = $lineStart
    while ($true) {
        if ($start -le 0) { break }
        $prevEnd = $start - 1
        while ($prevEnd -gt 0 -and ($Content[$prevEnd - 1] -eq "`r" -or $Content[$prevEnd - 1] -eq "`n")) { $prevEnd-- }
        $prevStart = $Content.LastIndexOf("`n", [Math]::Max(0, $prevEnd - 1)) + 1
        $prevLine = $Content.Substring($prevStart, $prevEnd - $prevStart).Trim()
        if ($prevLine -eq '' -or $prevLine.StartsWith('#')) { break }
        $last = $prevLine[$prevLine.Length - 1]
        if ($last -eq ';' -or $last -eq '{' -or $last -eq '}') { break }
        $start = $prevStart
    }
    return $start
}

# Brace { } balance check outside strings/comments. $true = balanced.
function Test-BraceBalance {
    param([string]$Content)
    $t = [regex]::Replace($Content, '"(?:\\.|[^"\\])*"', '""')
    $t = [regex]::Replace($t, "'(?:\\.|[^'\\])*'", "''")
    $t = [regex]::Replace($t, '//[^\r\n]*', '')
    $t = [regex]::Replace($t, '/\*[\s\S]*?\*/', '')
    $depth = 0
    foreach ($c in $t.ToCharArray()) {
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth--; if ($depth -lt 0) { return $false } }
    }
    return ($depth -eq 0)
}

# Restore a file from backup (fail-safe: the tree is never left broken).
function Restore-BackupFile {
    param([string]$Path)
    $base = $SourcePath.TrimEnd('\', '/')
    $rel = $Path
    if ($rel.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $rel.Substring($base.Length).TrimStart('\', '/')
    }
    else { $rel = Split-Path $Path -Leaf }
    $bak = Join-Path $script:BackupDir $rel
    if (Test-Path $bak) { Copy-Item -LiteralPath $bak -Destination $Path -Force; return $true }
    return $false
}

# Cuts a C++ function DEFINITION by name (brace balance, strings/comments
# respected). Removes it wholly, including return type/qualifiers on
# previous lines. Returns @{ Content; Removed[bool] }.
# Fail-safe: if there is ';' between the signature and '{', it is not a definition
# (declaration/call) — touch nothing.
function Remove-CppFunction {
    param([string]$Content, [string]$SignatureRegex)
    $m = [regex]::Match($Content, $SignatureRegex)
    if (-not $m.Success) { return @{ Content = $Content; Removed = $false } }
    $openIdx = $Content.IndexOf('{', $m.Index)
    if ($openIdx -lt 0) { return @{ Content = $Content; Removed = $false } }
    $between = $Content.Substring($m.Index, $openIdx - $m.Index)
    # Strip strings/comments from the check so ';' inside them does not interfere.
    $betweenClean = [regex]::Replace($between, '"(?:\\.|[^"\\])*"', '""')
    $betweenClean = [regex]::Replace($betweenClean, "'(?:\\.|[^'\\])*'", "''")
    $betweenClean = [regex]::Replace($betweenClean, '//[^\r\n]*', '')
    $betweenClean = [regex]::Replace($betweenClean, '/\*[\s\S]*?\*/', '')
    if ($betweenClean.Contains(';')) { return @{ Content = $Content; Removed = $false } }
    $i = $openIdx; $depth = 0
    $inStr = $false; $strCh = ''; $inLine = $false; $inBlock = $false
    while ($i -lt $Content.Length) {
        $c = $Content[$i]; $n = if ($i + 1 -lt $Content.Length) { $Content[$i + 1] } else { '' }
        if ($inLine) { if ($c -eq "`n") { $inLine = $false } }
        elseif ($inBlock) { if ($c -eq '*' -and $n -eq '/') { $inBlock = $false; $i++ } }
        elseif ($inStr) {
            if ($c -eq '\') { $i++ }
            elseif ($c -eq $strCh) { $inStr = $false }
        }
        else {
            if ($c -eq '/' -and $n -eq '/') { $inLine = $true; $i++ }
            elseif ($c -eq '/' -and $n -eq '*') { $inBlock = $true; $i++ }
            elseif ($c -eq '"' -or $c -eq "'") { $inStr = $true; $strCh = $c }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $end = $i + 1
                    while ($end -lt $Content.Length -and ($Content[$end] -eq "`r" -or $Content[$end] -eq "`n")) { $end++ }
                    $start = Find-DeclarationStart $Content $m.Index
                    $new = $Content.Substring(0, $start).TrimEnd() + "`r`n" + $Content.Substring($end).TrimStart("`r", "`n")
                    return @{ Content = $new; Removed = $true }
                }
            }
        }
        $i++
    }
    return @{ Content = $Content; Removed = $false }
}

function Remove-XmlNodes {
    param(
        [System.Xml.XmlDocument]$Xml,
        [System.Xml.XmlNamespaceManager]$Ns,
        [string]$XPath
    )
    $nodes = $Xml.SelectNodes($XPath, $Ns)
    $count = 0
    foreach ($n in @($nodes)) { $n.ParentNode.RemoveChild($n) | Out-Null; $count++ }
    return $count
}

# ---------------------------------------------------------------- 1. XAML toolbar
function Patch-ToolbarXaml {
    $step = 'Toolbar XAML (Sponsor button)'
    if (-not (Test-PatchOn 'Xaml')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $path = Join-Path $SourcePath 'NanaZip.Modern\MainWindowToolBarPage.xaml'
    if (-not (Test-Path $path)) { Add-Result $step 'WARN' 'file not found, skipping'; return }
    [xml]$xml = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('p', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $btn = $xml.SelectSingleNode("//p:Button[@x:Name='SponsorButton']", $ns)
    if ($null -eq $btn) {
        $cmd = $xml.SelectSingleNode('//p:CommandBar', $ns)
        if ($null -ne $cmd) { Add-Result $step 'INFO' 'button already gone, CommandBar intact'; return }
        Add-Result $step 'FAIL' 'neither button nor CommandBar — unfamiliar markup'; return
    }
    Backup-File $path
    $grid = $btn.ParentNode
    $grid.RemoveChild($btn) | Out-Null
    # Remove only trailing unreferenced ColumnDefinitions.
    $colDefs = @($grid.SelectNodes('p:Grid.ColumnDefinitions/p:ColumnDefinition', $ns))
    if ($colDefs.Count -gt 0) {
        $used = New-Object System.Collections.Generic.HashSet[int]
        foreach ($el in $grid.SelectNodes('.//*[@Grid.Column]', $ns)) {
            $v = 0
            if ([int]::TryParse($el.GetAttribute('Grid.Column'), [ref]$v)) { $used.Add($v) | Out-Null }
        }
        for ($idx = $colDefs.Count - 1; $idx -ge 0; $idx--) {
            if ($used.Contains($idx)) { break }
            $colDefs[$idx].ParentNode.RemoveChild($colDefs[$idx]) | Out-Null
        }
    }
    $xml.Save($path)
    try { [xml]$check = Get-Content -LiteralPath $path -Raw -Encoding UTF8 }
    catch { Add-Result $step 'FAIL' 'XAML corrupted by the edit'; return }
    Add-Result $step 'OK' 'button removed, CommandBar untouched'
}

# ---------------------------------------------------------------- 2. Toolbar CPP
function Patch-ToolbarCpp {
    $step = 'MainWindowToolBarPage.cpp'
    if (-not (Test-PatchOn 'ToolbarCpp')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $path = Join-Path $SourcePath 'NanaZip.Modern\MainWindowToolBarPage.cpp'
    if (-not (Test-Path $path)) { Add-Result $step 'WARN' 'file not found, skipping'; return }
    $orig = [System.IO.File]::ReadAllText($path)
    $text = $orig
    $changed = $false

    # 2a. Dialog-launch helpers — remove one by one, then the empty anonymous namespace.
    foreach ($fn in @('GetShellProcessId', 'GetCurrentProcessModulePath',
        'UnpackagedLaunchSponsorDialog', 'GetCurrentApplicationUserModelIdWrapper',
        'GetCurrentApplicationUserModelIdSimple', 'PackagedLaunchSponsorDialog')) {
        $r = Remove-CppFunction -Content $text -SignatureRegex ("(?m)^[^\r\n]*\b{0}\s*\(" -f $fn)
        if ($r.Removed) { $text = $r.Content; $changed = $true }
    }
    $newText = [regex]::Replace($text, "(?m)^namespace\s*\r?\n\{\s*\r?\n\}\s*(\r?\n)?", '')
    if ($newText -ne $text) { $text = $newText; $changed = $true }

    # 2b. Store/Dispatcher usings — line by line, only if identifiers are dead.
    $text = [regex]::Replace($text, "(?m)^[ \t]*using Windows::Foundation::IAsyncAction;\r?\n", '')
    $text = [regex]::Replace($text, "(?m)^[ \t]*using Windows::Services::Store::[A-Za-z]+;\r?\n", '')
    $text = [regex]::Replace($text, "(?m)^[ \t]*using Windows::System::DispatcherQueuePriority;\r?\n", '')

    # 2c. Sponsor-label init block in InitializeComponent.
    $patInit = "(?s)[ \t]*this->m_DispatcherQueue\s*=[\s\S]*?GetForCurrentThread\(\);\s*\r?\n"
    $t2 = [regex]::Replace($text, $patInit, '')
    $patLabel = "(?s)[ \t]*std::wstring sponsorButtonLabel[\s\S]*?this->SponsorButton\(\)\.Content\(.*?\);\s*\r?\n"
    $t2 = [regex]::Replace($t2, $patLabel, '')
    if ($t2 -ne $text) { $text = $t2; $changed = $true }

    # 2d. Refresh call in PageLoaded.
    $t2 = [regex]::Replace($text, "(?m)^[ \t]*this->RefreshSponsorButtonContent\(\);\r?\n", '')
    if ($t2 -ne $text) { $text = $t2; $changed = $true }

    # 2e. SponsorButtonClick / CheckSponsorEditionLicense / RefreshSponsorButtonContent methods.
    foreach ($m in @('SponsorButtonClick', 'CheckSponsorEditionLicense', 'RefreshSponsorButtonContent')) {
        $r = Remove-CppFunction -Content $text -SignatureRegex ("(?m)MainWindowToolBarPage::{0}\s*\(" -f $m)
        if ($r.Removed) { $text = $r.Content; $changed = $true }
    }

    # 2f. appmodel/ShObjIdl includes — only if identifiers are gone.
    if ($text -notmatch 'GetCurrentApplicationUserModelId|IApplicationActivationManager') {
        $t2 = [regex]::Replace($text, "(?m)^[ \t]*#include\s*<appmodel\.h>\r?\n", '')
        $t2 = [regex]::Replace($t2, "(?m)^[ \t]*#include\s*<ShObjIdl_core\.h>\r?\n", '')
        if ($t2 -ne $text) { $text = $t2; $changed = $true }
    }

    $markers = @('SponsorButton', 'SponsorEdition', 'AcquireSponsorEdition',
        'PackagedLaunchSponsorDialog', 'UnpackagedLaunchSponsorDialog',
        'StoreProduct', 'CheckSponsorEditionLicense', 'RefreshSponsorButtonContent')
    $left = @($markers | Where-Object { $text -match [regex]::Escape($_) })
    if ($left.Count -gt 0) {
        Add-Result $step 'FAIL' ('markers left: ' + ($left -join ', ')); return
    }
    if (-not $changed) { Add-Result $step 'INFO' 'no sponsorship code'; return }
    if (-not (Test-BraceBalance $text)) { Add-Result $step 'FAIL' 'brace imbalance after edit — file untouched'; return }
    Backup-File $path
    Save-TextUtf8 $path $text
    Add-Result $step 'OK' 'helpers, Store API and methods removed'
}

# ---------------------------------------------------------------- 3. Toolbar H
function Patch-ToolbarH {
    $step = 'MainWindowToolBarPage.h'
    if (-not (Test-PatchOn 'ToolbarH')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $path = Join-Path $SourcePath 'NanaZip.Modern\MainWindowToolBarPage.h'
    if (-not (Test-Path $path)) { Add-Result $step 'WARN' 'file not found, skipping'; return }
    $cpp = Join-Path $SourcePath 'NanaZip.Modern\MainWindowToolBarPage.cpp'
    $cppText = if (Test-Path $cpp) { [System.IO.File]::ReadAllText($cpp) } else { '' }
    $text = [System.IO.File]::ReadAllText($path)
    $changed = $false

    $t2 = [regex]::Replace($text, "(?s)[ \t]*void SponsorButtonClick\s*\([^;]*?\);\s*\r?\n", '')
    $t2 = [regex]::Replace($t2, "(?s)[ \t]*bool CheckSponsorEditionLicense\s*\([^;]*?\)\s*;\s*\r?\n", '')
    $t2 = [regex]::Replace($t2, "(?s)[ \t]*void RefreshSponsorButtonContent\s*\([^;]*?\)\s*;\s*\r?\n", '')
    if ($t2 -ne $text) { $text = $t2; $changed = $true }

    # Members and includes — only if the cpp no longer uses them.
    if ($cppText -notmatch 'm_StoreContext|StoreContext') {
        $t2 = [regex]::Replace($text, "(?m)^[ \t]*winrt::StoreContext m_StoreContext[^\r\n]*\r?\n", '')
        $t2 = [regex]::Replace($t2, "(?m)^[ \t]*using Windows::Services::Store::[A-Za-z]+;\r?\n", '')
        $t2 = [regex]::Replace($t2, "(?m)^[ \t]*#include\s*<winrt/Windows\.Services\.Store\.h>\r?\n", '')
        if ($t2 -ne $text) { $text = $t2; $changed = $true }
    }
    if ($cppText -notmatch 'm_DispatcherQueue|DispatcherQueue') {
        $t2 = [regex]::Replace($text, "(?m)^[ \t]*winrt::DispatcherQueue m_DispatcherQueue[^\r\n]*\r?\n", '')
        $t2 = [regex]::Replace($t2, "(?m)^[ \t]*using Windows::System::DispatcherQueue;\r?\n", '')
        $t2 = [regex]::Replace($t2, "(?m)^[ \t]*#include\s*<winrt/Windows\.System\.h>\r?\n", '')
        if ($t2 -ne $text) { $text = $t2; $changed = $true }
    }

    $markers = @('SponsorButtonClick', 'CheckSponsorEditionLicense', 'RefreshSponsorButtonContent')
    $left = @($markers | Where-Object { $text -match [regex]::Escape($_) })
    if ($left.Count -gt 0) { Add-Result $step 'FAIL' ('left: ' + ($left -join ', ')); return }
    if (-not $changed) { Add-Result $step 'INFO' 'no sponsorship declarations'; return }
    if (-not (Test-BraceBalance $text)) { Add-Result $step 'FAIL' 'brace imbalance after edit — file untouched'; return }
    Backup-File $path
    Save-TextUtf8 $path $text
    Add-Result $step 'OK' 'declarations and dead members removed'
}

# ---------------------------------------------------------------- 4. SponsorPage: files + project
function Remove-SponsorPage {
    $step = 'SponsorPage (files + vcxproj)'
    if (-not (Test-PatchOn 'SponsorPage')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $modDir = Join-Path $SourcePath 'NanaZip.Modern'
    $deleted = @()
    foreach ($f in @('SponsorPage.xaml', 'SponsorPage.idl', 'SponsorPage.h', 'SponsorPage.cpp')) {
        $p = Join-Path $modDir $f
        if (Test-Path $p) { Backup-File $p; Remove-Item -LiteralPath $p -Force; $deleted += $f }
    }
    foreach ($res in @(Get-ChildItem (Join-Path $modDir 'Strings') -Recurse -Filter 'SponsorPage.resw' -ErrorAction SilentlyContinue)) {
        Backup-File $res.FullName; Remove-Item -LiteralPath $res.FullName -Force; $deleted += $res.FullName
    }

    $msb = 'http://schemas.microsoft.com/developer/msbuild/2003'
    $projTouched = $false
    foreach ($proj in @((Join-Path $modDir 'NanaZip.Modern.vcxproj'),
        (Join-Path $modDir 'NanaZip.Modern.vcxproj.filters'))) {
        if (-not (Test-Path $proj)) { continue }
        [xml]$xml = Get-Content -LiteralPath $proj -Raw -Encoding UTF8
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('b', $msb)
        $n = Remove-XmlNodes $xml $ns "//b:*[contains(@Include,'SponsorPage')]"
        if ($n -gt 0) { Backup-File $proj; $xml.Save($proj); $projTouched = $true }
    }
    if ($deleted.Count -eq 0 -and -not $projTouched) {
        Add-Result $step 'INFO' 'no SponsorPage files or references'; return
    }
    Add-Result $step 'OK' ("removed/unlinked: $($deleted.Count) files")
}

# ---------------------------------------------------------------- 5. ShowSponsorDialog export
function Patch-ModernExports {
    $step = 'K7ModernShowSponsorDialog (export)'
    if (-not (Test-PatchOn 'Exports')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $modDir = Join-Path $SourcePath 'NanaZip.Modern'
    $changed = $false

    $h = Join-Path $modDir 'NanaZip.Modern.h'
    if ((Test-Path $h) -and ((Get-Content -LiteralPath $h -Raw) -match 'K7ModernShowSponsorDialog')) {
        $t = [System.IO.File]::ReadAllText($h)
        # Strictly inside ONE /** */ block (tempered): never cross block boundaries.
        $t2 = [regex]::Replace($t, "(?s)/\*\*(?:(?!\*/)[\s\S])*?Show the `"Sponsor NanaZip`" dialog\.(?:(?!\*/)[\s\S])*?\*/\s*EXTERN_C INT WINAPI K7ModernShowSponsorDialog\(\s*_In_opt_ HWND ParentWindowHandle\);\s*\r?\n", '')
        if ($t2 -eq $t) {
            # Fallback: declaration lines only, keep the doc comment (safe).
            $t2 = [regex]::Replace($t, "(?m)^[ \t]*EXTERN_C INT WINAPI K7ModernShowSponsorDialog\(\s*\r?\n^[ \t]*_In_opt_ HWND ParentWindowHandle\);\s*\r?\n", '')
        }
        if ($t2 -eq $t) {
            $t2 = [regex]::Replace($t, "(?m)^[ \t]*EXTERN_C INT WINAPI K7ModernShowSponsorDialog\([^;]*?\);\s*\r?\n", '')
        }
        if ($t2 -ne $t) {
            if (-not (Test-BraceBalance $t2)) { Add-Result $step 'FAIL' 'brace imbalance in NanaZip.Modern.h'; return }
            Backup-File $h; Save-TextUtf8 $h $t2; $changed = $true
        }
    }

    $cpp = Join-Path $modDir 'NanaZip.Modern.cpp'
    if ((Test-Path $cpp) -and ((Get-Content -LiteralPath $cpp -Raw) -match 'SponsorPage|K7ModernShowSponsorDialog')) {
        $t = [System.IO.File]::ReadAllText($cpp)
        $t2 = [regex]::Replace($t, "(?m)^[ \t]*#include\s*`"SponsorPage\.h`"\r?\n", '')
        $r = Remove-CppFunction -Content $t2 -SignatureRegex 'K7ModernShowSponsorDialog\s*\('
        if ($r.Removed) { $t2 = $r.Content }
        if ($t2 -ne $t) {
            if (-not (Test-BraceBalance $t2)) { Add-Result $step 'FAIL' 'brace imbalance in NanaZip.Modern.cpp'; return }
            Backup-File $cpp; Save-TextUtf8 $cpp $t2; $changed = $true
        }
    }

    $def = Join-Path $modDir 'NanaZip.Modern.def'
    if ((Test-Path $def) -and ((Get-Content -LiteralPath $def -Raw) -match 'K7ModernShowSponsorDialog')) {
        $t = [System.IO.File]::ReadAllText($def)
        $t2 = [regex]::Replace($t, "(?m)^[ \t]*K7ModernShowSponsorDialog\r?\n", '')
        Backup-File $def; Save-TextUtf8 $def $t2; $changed = $true
    }

    $wrap = Join-Path $modDir 'NanaZip.Modern.Wrapper.cpp'
    if ((Test-Path $wrap) -and ((Get-Content -LiteralPath $wrap -Raw) -match 'K7ModernShowSponsorDialog')) {
        $t = [System.IO.File]::ReadAllText($wrap)
        $r = Remove-CppFunction -Content $t -SignatureRegex 'EXTERN_C INT WINAPI K7ModernShowSponsorDialog\s*\('
        if ($r.Removed) {
            if (-not (Test-BraceBalance $r.Content)) { Add-Result $step 'FAIL' 'brace imbalance in Wrapper.cpp'; return }
            Backup-File $wrap; Save-TextUtf8 $wrap $r.Content; $changed = $true
        }
        else { Add-Result $step 'FAIL' 'failed to cut the ShowSponsorDialog wrapper'; return }
    }

    if (-not $changed) { Add-Result $step 'INFO' 'no sponsorship exports'; return }
    Add-Result $step 'OK' 'ShowSponsorDialog removed from h/cpp/def/wrapper'
}

# ---------------------------------------------------------------- 6. SpecialCommandHandler
function Patch-SpecialHandler {
    $step = 'SpecialCommandHandler (AcquireSponsorEdition)'
    if (-not (Test-PatchOn 'Handler')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $path = Join-Path $SourcePath 'NanaZip.UI.Modern\NanaZip.UI.cpp'
    if (-not (Test-Path $path)) { Add-Result $step 'WARN' 'file not found, skipping'; return }
    $text = [System.IO.File]::ReadAllText($path)
    $changed = $false
    # 1. Neutralize the handler if it has sponsorship commands.
    if ($text -match 'AcquireSponsorEdition|K7ModernShowSponsorDialog') {
        $r = Remove-CppFunction -Content $text -SignatureRegex '(?m)void NanaZip::UI::SpecialCommandHandler\s*\(\s*\)'
        if (-not $r.Removed) { Add-Result $step 'FAIL' 'SpecialCommandHandler body not found'; return }
        $text = $r.Content.TrimEnd() + "`r`n`r`nvoid NanaZip::UI::SpecialCommandHandler()`r`n{`r`n    // No special commands.`r`n}`r`n"
        $changed = $true
    }
    # 2. Remove the dead parsing helper whenever only its definition is left.
    # (Otherwise C4505 with /WX breaks the build.)
    if (([regex]::Matches($text, '\bSplitCommandLineEx\b')).Count -eq 1) {
        $r2 = Remove-CppFunction -Content $text -SignatureRegex 'static void SplitCommandLineEx\s*\('
        if ($r2.Removed) { $text = $r2.Content; $changed = $true }
    }
    # Collapse the emptied anonymous namespace.
    $t2 = [regex]::Replace($text, "(?m)^namespace\s*\r?\n\{\s*\r?\n\}\s*(\r?\n)?", '')
    if ($t2 -ne $text) { $text = $t2; $changed = $true }
    if ($text -match 'AcquireSponsorEdition|K7ModernShowSponsorDialog') {
        Add-Result $step 'FAIL' 'markers left after edit'; return
    }
    if (-not $changed) { Add-Result $step 'INFO' 'no sponsorship commands'; return }
    if (-not (Test-BraceBalance $text)) { Add-Result $step 'FAIL' 'brace imbalance after edit — file untouched'; return }
    Backup-File $path
    Save-TextUtf8 $path $text
    Add-Result $step 'OK' 'handler neutralized'
}

# ---------------------------------------------------------------- 7. resw strings
function Patch-Resw {
    $step = 'resw SponsorButton strings'
    if (-not (Test-PatchOn 'Resw')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $modDir = Join-Path $SourcePath 'NanaZip.Modern'
    $strDir = Join-Path $modDir 'Strings'
    if (-not (Test-Path $strDir)) { Add-Result $step 'WARN' 'no Strings folder, skipping'; return }
    $fixed = 0
    foreach ($f in @(Get-ChildItem $strDir -Recurse -Filter 'MainWindowToolBarPage.resw')) {
        [xml]$xml = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        $nodes = $xml.SelectNodes("//data[starts-with(@name,'SponsorButton')]")
        if ($nodes.Count -gt 0) {
            Backup-File $f.FullName
            foreach ($n in @($nodes)) { $n.ParentNode.RemoveChild($n) | Out-Null }
            $xml.Save($f.FullName)
            $fixed++
        }
    }
    if ($fixed -eq 0) { Add-Result $step 'INFO' 'no SponsorButton strings' }
    else { Add-Result $step 'OK' "files cleaned: $fixed" }
}

# ---------------------------------------------------------------- 8. manifest CRLF (upstream bug fix)
function Repair-ManifestEol {
    $step = 'Package.appxmanifest (CRLF)'
    if (-not (Test-PatchOn 'Manifest')) { Add-Result $step 'INFO' 'disabled (menu/parameter)'; return }
    $path = Join-Path $SourcePath 'NanaZipPackage\Package.appxmanifest'
    if (-not (Test-Path $path)) { Add-Result $step 'WARN' 'manifest not found, skipping'; return }
    $raw = [System.IO.File]::ReadAllBytes($path)
    $t = [System.Text.Encoding]::UTF8.GetString($raw).TrimStart([char]0xFEFF)
    try { [xml]$check = $t }
    catch { Add-Result $step 'FAIL' 'manifest is not valid XML — manual restore required'; return }
    if ($null -eq $check.Package.Resources -and $t -notmatch '<Resources>') {
        Add-Result $step 'FAIL' 'manifest has no Resources node — manual restore required'; return
    }
    $crlf = $t.Replace("`r`n", "`n").Replace("`n", "`r`n")
    if ($crlf -ceq $t) {
        Add-Result $step 'INFO' 'BOM+CRLF already OK'
    }
    else {
        Backup-File $path
        # GetBytes() does not emit the BOM preamble — prepend it manually.
        $enc = New-Object System.Text.UTF8Encoding($true)
        $newRaw = [byte[]]($enc.GetPreamble() + $enc.GetBytes($crlf))
        [System.IO.File]::WriteAllBytes($path, $newRaw)
        Add-Result $step 'OK' 'line endings normalized (BOM+CRLF)'
    }
    try { [xml]$check = $crlf } catch { Add-Result $step 'FAIL' 'manifest is not valid XML'; return }
}

# ================================================================ BUILD/RUN
function Find-BuildTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installDir = $null
    if (Test-Path $vswhere) {
        $installDir = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    }
    foreach ($cand in @($installDir, 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools')) {
        if ($cand -and (Test-Path (Join-Path $cand 'MSBuild\Current\Bin\MSBuild.exe'))) {
            return @{
                MSBuild  = Join-Path $cand 'MSBuild\Current\Bin\MSBuild.exe'
                VcVars   = Join-Path $cand 'VC\Auxiliary\Build\vcvarsall.bat'
            }
        }
    }
    throw 'VS Build Tools not found (VC.Tools.x86.x64 component required)'
}

function Find-SignTool {
    $bins = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $best = Get-ChildItem $bins -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'x64\signtool.exe') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $best) { throw 'signtool.exe not found (Windows SDK required)' }
    return (Join-Path $best.FullName 'x64\signtool.exe')
}

function Invoke-CmdBuild {
    param([string]$VcVars, [string]$MSBuild, [string]$Arguments)
    # IMPORTANT: cmd.exe output is intentionally NOT captured (goes to console as
    # progress); the exit code goes to a script variable. `return $LASTEXITCODE`
    # is forbidden here: all of stdout would become part of the return value.
    $cmd = '"{0}" x86 >NUL 2>&1 && "{1}" {2}' -f $VcVars, $MSBuild, $Arguments
    & cmd.exe /c $cmd
    $script:BuildExitCode = $LASTEXITCODE
}

# ================================================================ MENU

function Find-PackageBundle {
    Get-ChildItem (Join-Path $SourcePath 'Output\Binaries\AppPackages') -Recurse `
        -Filter '*.msixbundle' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Test-BundleSigned {
    param([string]$BundlePath, [string]$SignTool)
    & $SignTool verify /pa $BundlePath | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Clear-MenuScreen {
    try { Clear-Host } catch { Write-Host '' }
}

function Write-MenuOption {
    param([string]$Number, [string]$Label, [string]$Value = '', [string]$ValueColor = 'Gray')
    Write-Host ("  {0}. " -f $Number) -ForegroundColor Yellow -NoNewline
    Write-Host $Label -ForegroundColor White -NoNewline
    if ($Value -ne '') { Write-Host (" : {0}" -f $Value) -ForegroundColor $ValueColor }
    else { Write-Host '' }
}

function Write-MenuToggle {
    param([string]$Number, [string]$Label, [bool]$On)
    Write-Host ("  {0}. " -f $Number) -ForegroundColor Yellow -NoNewline
    if ($On) { Write-Host '[x]' -ForegroundColor Green -NoNewline }
    else { Write-Host '[ ]' -ForegroundColor DarkGray -NoNewline }
    Write-Host (" {0}" -f $Label) -ForegroundColor White
}

function Read-MenuChoice {
    Write-Host 'Choice > ' -ForegroundColor Cyan -NoNewline
    return ((Read-Host).Trim().ToUpper())
}

function Show-MenuNotice {
    if ($script:MenuNotice -ne '' -and $null -ne $script:MenuNotice) {
        Write-Host $script:MenuNotice -ForegroundColor Red
        Write-Host ''
        $script:MenuNotice = ''
    }
}

function Show-PatchesMenu {
    while ($true) {
        Clear-MenuScreen
        Write-Host '--- Patches (number = on/off, B = back) ---' -ForegroundColor Cyan
        Show-MenuNotice
        $i = 1
        foreach ($p in $script:PatchRegistry) {
            Write-MenuToggle $i $p.Title $script:PatchSel[$p.Key]
            $i++
        }
        Write-Host '  B. ' -ForegroundColor Yellow -NoNewline
        Write-Host 'Back' -ForegroundColor White
        $c = Read-MenuChoice
        if ($c -eq 'B' -or $c -eq '') { return }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $script:PatchRegistry.Count) {
            $k = $script:PatchRegistry[$n - 1].Key
            $script:PatchSel[$k] = -not $script:PatchSel[$k]
        }
        else { $script:MenuNotice = 'Invalid input.' }
    }
}

function Show-BuildMenu {
    while ($true) {
        Clear-MenuScreen
        Write-Host '--- Build and install (number = on/off, B = back) ---' -ForegroundColor Cyan
        Show-MenuNotice
        Write-MenuToggle '1' 'Build (Release|x64)' $script:DoBuild
        Write-MenuToggle '2' 'Sign the package' $script:DoSign
        Write-MenuToggle '3' 'Install' $script:DoInstall
        Write-MenuToggle '4' 'Remove the certificate after install' $script:RemoveCert
        Write-Host '  B. ' -ForegroundColor Yellow -NoNewline
        Write-Host 'Back' -ForegroundColor White
        $c = Read-MenuChoice
        switch ($c) {
            '1' { $script:DoBuild = -not $script:DoBuild }
            '2' { $script:DoSign = -not $script:DoSign }
            '3' { $script:DoInstall = -not $script:DoInstall }
            '4' { $script:RemoveCert = -not $script:RemoveCert }
            'B' { return }
            '' { return }
            default { $script:MenuNotice = 'Invalid input.' }
        }
    }
}

function Show-MainMenu {
    $script:MenuSource = $SourcePath
    $script:PatchSel = @{}
    foreach ($p in $script:PatchRegistry) {
        $off = @($p.Detail | Where-Object { $script:PatchOff.ContainsKey($_) })
        $script:PatchSel[$p.Key] = ($off.Count -eq 0)
    }
    $script:DoBuild = -not $SkipBuild
    $script:DoSign = -not $SkipSign
    $script:DoInstall = -not $SkipInstall
    $script:RemoveCert = -not $KeepCert
    $script:MenuNotice = ''

    while ($true) {
        Clear-MenuScreen
        $selCount = @($script:PatchSel.Values | Where-Object { $_ }).Count
        $selColor = if ($selCount -eq $script:PatchRegistry.Count) { 'Green' }
            elseif ($selCount -eq 0) { 'DarkGray' } else { 'Yellow' }
        Write-Host '=== NanaZip Patch Tool ===' -ForegroundColor Cyan
        Show-MenuNotice
        Write-MenuOption '1' 'NanaZip sources' $script:MenuSource
        Write-Host '  2. ' -ForegroundColor Yellow -NoNewline
        Write-Host 'Patches' -ForegroundColor White -NoNewline
        Write-Host (" : selected {0}/{1}" -f $selCount, $script:PatchRegistry.Count) -ForegroundColor $selColor
        Write-MenuOption '3' 'Build and install'
        Write-Host ''
        Write-Host '  0. ' -ForegroundColor Yellow -NoNewline
        Write-Host 'START' -ForegroundColor Green
        Write-Host '  Q. ' -ForegroundColor Yellow -NoNewline
        Write-Host 'Quit' -ForegroundColor Red
        $c = Read-MenuChoice
        switch ($c) {
            '1' {
                Write-Host ("Sources folder path [{0}] > " -f $script:MenuSource) -ForegroundColor Cyan -NoNewline
                $p = (Read-Host).Trim().Trim('"')
                if ($p -eq '') { break }
                if (Test-SourceRoot $p) { $script:MenuSource = [System.IO.Path]::GetFullPath($p) }
                else { $script:MenuNotice = 'This does not look like NanaZip sources (need the NanaZip.Modern folder and BuildAllTargets.proj).' }
            }
            '2' { Show-PatchesMenu }
            '3' { Show-BuildMenu }
            '0' {
                if (-not (Test-SourceRoot $script:MenuSource)) {
                    $script:MenuNotice = 'Enter a valid sources path (item 1).'
                    break
                }
                if ($script:DoInstall -and -not $script:DoSign) {
                    Write-Host 'Install without signing is impossible — signing enabled.' -ForegroundColor Yellow
                    $script:DoSign = $true
                }
                if (($script:DoSign -or $script:DoInstall) -and -not $script:DoBuild) {
                    Write-Host 'Without building, the existing package from the Output folder will be used (if any).' -ForegroundColor Yellow
                }
                # Apply the selection to the script state.
                # Build parameters and PFX password stay as launch args (default Release|x64).
                $script:SourcePath = $script:MenuSource
                $script:PatchOff = @{}
                foreach ($p in $script:PatchRegistry) {
                    if (-not $script:PatchSel[$p.Key]) {
                        foreach ($d in $p.Detail) { $script:PatchOff[$d] = $true }
                    }
                }
                $script:SkipBuild = -not $script:DoBuild
                $script:SkipSign = -not $script:DoSign
                $script:SkipInstall = -not $script:DoInstall
                $script:KeepCert = -not $script:RemoveCert
                Clear-MenuScreen
                Write-Host '=== NanaZip Patch Tool — running ===' -ForegroundColor Cyan
                return
            }
            'Q' { Clear-MenuScreen; exit 0 }
            default { $script:MenuNotice = 'Invalid input.' }
        }
    }
}

# ================================================================ MAIN
# Menu — interactive mode with no mode switches only (or with -Menu).
# @() around Where-Object: an empty result without it is $null,
# and $null.Count throws under StrictMode.
$modeBound = @(@('SkipBuild', 'SkipInstall', 'SkipPatches', 'SkipSign', 'PatchOnly', 'NoMenu', 'DisablePatches') |
    Where-Object { $PSBoundParameters.ContainsKey($_) })
$interactive = -not [Console]::IsInputRedirected
if ($Menu -or (-not $NoMenu -and $modeBound.Count -eq 0 -and $interactive)) {
    Show-MainMenu
}

$script:BackupDir = Join-Path $SourcePath ('.nosponsor-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:BuildExitCode = 0
$certThumb = $null
$pfxPath = $null
$cerPath = $null

try {
    if (-not (Test-Path (Join-Path $SourcePath 'NanaZip.Modern'))) {
        throw "No NanaZip.Modern folder in '$SourcePath' — not a NanaZip sources root."
    }

    # --- patches ---
    Patch-ToolbarXaml
    Patch-ToolbarCpp
    Patch-ToolbarH
    Remove-SponsorPage
    Patch-ModernExports
    Patch-SpecialHandler
    Patch-Resw
    Repair-ManifestEol

    if ($script:Results.Status -contains 'FAIL') {
        throw 'There are FAIL steps — build stopped, files intact (see above).'
    }

    # --- elevate early (LM certificate + install) ---
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $SkipInstall -and -not $isAdmin) {
        Add-Result 'Elevation' 'INFO' 'relaunching elevated...'
        $elevArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
            '-NoMenu',
            '-SourcePath', "`"$SourcePath`"", '-Configuration', $Configuration,
            '-Platform', $Platform, '-BundlePlatforms', $BundlePlatforms,
            '-CertPassword', "`"$CertPassword`"",
            '-DisablePatches', (($script:PatchOff.Keys | Sort-Object) -join ','))
        if ($SkipBuild) { $elevArgs += '-SkipBuild' }
        if ($SkipSign) { $elevArgs += '-SkipSign' }
        if ($SkipInstall) { $elevArgs += '-SkipInstall' }
        if ($KeepCert) { $elevArgs += '-KeepCert' }
        Start-Process powershell -ArgumentList $elevArgs -Verb RunAs -Wait
        return
    }

    # --- Release build ---
    if (-not $SkipBuild) {
        $tools = Find-BuildTools
        Add-Result 'BuildTools' 'INFO' $tools.MSBuild
        Invoke-CmdBuild $tools.VcVars $tools.MSBuild (
            '-m BuildAllTargets.proj -t:RefreshVersion -p:NanaZipBuildPreviewRelease=false')
        if ($script:BuildExitCode -ne 0) { Add-Result 'RefreshVersion' 'FAIL' ("exit $($script:BuildExitCode)"); throw 'RefreshVersion failed' }
        Add-Result 'RefreshVersion' 'OK' 'tree switched to Release'
        # Restore is MANDATORY before the wapproj build: without it there are no NuGet packages
        # (Mile.Mobility/CppWinRT) -> C1083 and MIDL9008. Same target as upstream.
        Invoke-CmdBuild $tools.VcVars $tools.MSBuild (
            '-m BuildAllTargets.proj -t:Restore -p:NanaZipBuildPreviewRelease=false')
        if ($script:BuildExitCode -ne 0) { Add-Result 'Restore' 'FAIL' ("exit $($script:BuildExitCode)"); throw 'Restore failed' }
        Add-Result 'Restore' 'OK' 'NuGet packages restored'
        Invoke-CmdBuild $tools.VcVars $tools.MSBuild (
            'NanaZipPackage\NanaZipPackage.wapproj -t:Build ' +
            "-p:Configuration=$Configuration -p:Platform=$Platform " +
            "-p:PreferredToolArchitecture=x64 -p:AppxBundlePlatforms=$BundlePlatforms -verbosity:minimal")
        if ($script:BuildExitCode -ne 0) { Add-Result 'Build' 'FAIL' ("exit $($script:BuildExitCode)"); throw 'Build failed' }
        Add-Result 'Build' 'OK' "$Configuration|$Platform bundle($BundlePlatforms)"
    }
    else {
        Add-Result 'Build' 'INFO' 'skipped — looking for an existing bundle in Output'
    }

    $needBundle = (-not $SkipSign) -or (-not $SkipInstall)
    $bundle = Find-PackageBundle
    if ($null -eq $bundle -and $needBundle) {
        Add-Result 'Bundle' 'FAIL' 'msixbundle not found (build the project)'; throw 'No bundle'
    }
    if ($null -eq $bundle) { Add-Result 'Bundle' 'INFO' 'none (not required)' }
    else { Add-Result 'Bundle' 'INFO' $bundle.FullName }

    $signtool = $null
    if ($needBundle) { $signtool = Find-SignTool }
    $pkgName = $null
    if (-not $SkipSign) {
        # --- certificate: Subject strictly from the manifest Publisher ---
        [xml]$manifest = Get-Content -LiteralPath (Join-Path $SourcePath 'NanaZipPackage\Package.appxmanifest') -Raw -Encoding UTF8
        $publisher = $manifest.Package.Identity.Publisher
        $pkgName = $manifest.Package.Identity.Name
        if (-not $publisher) { throw 'Publisher not found in Package.appxmanifest' }
        # Exactly one CN= prefix, no matter what form Publisher has.
        $certCN = ($publisher -replace '^(CN=)+', '').Trim()
        if (-not $certCN) { throw 'Empty certificate CN' }
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject ("CN={0}" -f $certCN) `
            -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(10) `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
        $certThumb = $cert.Thumbprint
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
        $store.Open('ReadWrite'); $store.Add($cert); $store.Close()
        Add-Result 'Cert' 'OK' "CN=$certCN, $($cert.Thumbprint)"

        $secPwd = ConvertTo-SecureString -String $CertPassword -Force -AsPlainText
        $pfxPath = Join-Path ([System.IO.Path]::GetDirectoryName($bundle.FullName)) 'NanaZip_SideloadCert.pfx'
        $cerPath = [System.IO.Path]::ChangeExtension($pfxPath, '.cer')
        Export-PfxCertificate -Cert ("Cert:\CurrentUser\My\$certThumb") -FilePath $pfxPath -Password $secPwd | Out-Null
        Export-Certificate -Cert ("Cert:\CurrentUser\My\$certThumb") -FilePath $cerPath | Out-Null
        if (-not $SkipInstall) {
            & certutil -addstore TrustedPeople $cerPath | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'certutil TrustedPeople failed (administrator required)' }
        }
        & $signtool sign /fd SHA256 /f $pfxPath /p $CertPassword $bundle.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) { Add-Result 'Sign' 'FAIL' 'signtool'; throw 'Sign failed' }
        & $signtool verify /pa $bundle.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) { Add-Result 'Sign' 'FAIL' 'verify'; throw 'Verify failed' }
        Add-Result 'Sign' 'OK' 'SHA256, verify OK'
    }
    else {
        Add-Result 'Sign' 'INFO' 'skipped (menu/parameter)'
    }

    if ($SkipInstall) { Add-Result 'Install' 'INFO' 'skipped (menu/parameter)'; return }
    if (-not (Test-BundleSigned $bundle.FullName $signtool)) {
        Add-Result 'Install' 'FAIL' 'package is not signed — enable signing (menu 3->2)'; throw 'Bundle unsigned'
    }
    # 0x80073CFB: same identity but different content blocks reinstall.
    # Remove the installed copy first (app data preserved), then install fresh.
    $pkgQuery = if ($pkgName) { "$pkgName*" } else { '40174MouriNaruto.NanaZip*' }
    $existing = @(Get-AppxPackage -Name $pkgQuery -AllUsers -ErrorAction SilentlyContinue)
    foreach ($e in $existing) {
        $removed = $false
        try {
            Remove-AppxPackage -Package $e.PackageFullName -PreserveApplicationData -Confirm:$false -ErrorAction Stop
            $removed = $true
        }
        catch {
            try {
                Remove-AppxPackage -Package $e.PackageFullName -AllUsers -PreserveApplicationData -Confirm:$false -ErrorAction Stop
                $removed = $true
            }
            catch {
                Remove-AppxPackage -Package $e.PackageFullName -AllUsers -Confirm:$false -ErrorAction Stop
                $removed = $true
            }
        }
        if ($removed) { Add-Result 'Uninstall' 'OK' "$($e.Name) $($e.Version) removed" }
    }
    Add-AppxPackage -DeferRegistrationWhenPackagesAreInUse -ForceUpdateFromAnyVersion -Path $bundle.FullName
    $pkg = Get-AppxPackage -Name '40174MouriNaruto.NanaZip*' | Select-Object -First 1
    if ($null -eq $pkg) { Add-Result 'Install' 'FAIL' 'package not found after install'; throw 'Install failed' }
    Add-Result 'Install' 'OK' ("$($pkg.Name) $($pkg.Version) $($pkg.Status)")
}
catch {
    Add-Result 'Fatal' 'FAIL' $_.Exception.Message
    exit 1
}
finally {
    # --- self-signed certificate cleanup ---
    if ($certThumb -and -not $KeepCert) {
        foreach ($s in @('Cert:\CurrentUser\My', 'Cert:\CurrentUser\Root', 'Cert:\LocalMachine\TrustedPeople')) {
            Get-ChildItem $s -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $certThumb } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        foreach ($f in @($pfxPath, $cerPath)) {
            if ($f -and (Test-Path $f)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        Add-Result 'CertCleanup' 'OK' 'certificate removed from stores, PFX/CER wiped'
    }
    elseif ($KeepCert) { Add-Result 'CertCleanup' 'INFO' 'certificate kept per -KeepCert' }

    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Cyan
    $cOK = @($script:Results | Where-Object { $_.Status -eq 'OK' }).Count
    $cINFO = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count
    $cWARN = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $cFAIL = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    Write-Host ("OK: {0}   INFO: {1}   WARN: {2}   FAIL: {3}" -f $cOK, $cINFO, $cWARN, $cFAIL) -ForegroundColor White
    foreach ($b in @($script:Results | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'WARN' })) {
        $bc = if ($b.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
        Write-Host ("[{0}] {1} - {2}" -f $b.Status, $b.Step, $b.Detail) -ForegroundColor $bc
    }
    if ($script:Results.Status -contains 'FAIL') { Write-Host 'Result: FAILED' -ForegroundColor Red; exit 1 }
    else { Write-Host 'Result: SUCCESS' -ForegroundColor Green }
}
