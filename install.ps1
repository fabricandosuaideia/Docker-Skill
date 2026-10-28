<#
.SYNOPSIS
  Install docker-image-playbook into a Claude Code skills directory (Windows
  PowerShell). For macOS/Linux/WSL, use install.sh.

.DESCRIPTION
  No git clone needed -- downloads SKILL.md + dev-speed.md +
  production-hardening.md + scaffolding-from-zero.md + scripts/ straight
  from GitHub and installs them into
  $HOME\.claude\skills\docker-image-playbook\ (default), or
  .\.claude\skills\docker-image-playbook\ with -Project.

  Run from inside a clone of this repo, it installs the local copy instead
  of downloading -- so editing a file and re-running `.\install.ps1 -Force`
  picks up the edit, no network involved.

  Uses only built-in PowerShell cmdlets in the download path -- no curl,
  tar, bash or WSL required. Requires PowerShell 5.1 or later (ships with
  Windows 10+).

.PARAMETER Project
  Install to .\.claude\skills\ instead of $HOME\.claude\skills\.

.PARAMETER Force
  Overwrite an existing install without prompting.

.PARAMETER Uninstall
  Remove the installed skill (no download needed).

.PARAMETER Version
  Install release vX.Y.Z (a git tag) instead of the branch tip, e.g. -Version 1.2.1.
  Also read from $env:DOCKER_SKILL_VERSION, which works with the piped form. Needs
  1.2.0 or newer (older tags have a different file layout). Refuses to install if the
  tag's SKILL.md declares another version. Downloads only: from a local clone, run
  `git checkout vX.Y.Z` first.

.EXAMPLE
  irm https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.ps1 | iex

.EXAMPLE
  # The piped form above cannot take parameters. For -Project or -Force,
  # download it first:
  irm https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.ps1 -OutFile install.ps1
  .\install.ps1 -Project -Force

Safe to re-run: without -Force it refuses to overwrite an existing install
rather than silently clobbering local edits.
#>
[CmdletBinding()]
param(
  [switch]$Project,
  [switch]$Force,
  [switch]$Uninstall,
  [string]$Version
)

$ErrorActionPreference = "Stop"

$Repo      = "fabricandosuaideia/Docker-Skill"
$Branch    = if ($env:DOCKER_SKILL_BRANCH) { $env:DOCKER_SKILL_BRANCH } else { "main" }
$SkillName = "docker-image-playbook"

# A pinned version names a git tag, so it must look like one. Accept a leading v.
$ReqVersion = if ($Version) { $Version } elseif ($env:DOCKER_SKILL_VERSION) { $env:DOCKER_SKILL_VERSION } else { "" }
$ReqVersion = $ReqVersion -replace '^[vV]', ''
if ($ReqVersion -and $ReqVersion -notmatch '^\d+\.\d+\.\d+$') {
  Write-Host "ERROR '$ReqVersion' is not a MAJOR.MINOR.PATCH version (e.g. 1.2.1)." -ForegroundColor Red
  exit 1
}

# The skill is these files and nothing else. Used to validate a download (or
# a local clone) before anything on disk is touched.
$RequiredFiles = @("dev-speed.md", "production-hardening.md", "scaffolding-from-zero.md")
$RequiredScripts = @("audit_dockerfile.py", "cache_report.py")

function Write-Status  { param($m) Write-Host "-> $m" }
function Write-Ok      { param($m) Write-Host "OK $m" -ForegroundColor Green }
function Write-Fail    { param($m) Write-Host "ERROR $m" -ForegroundColor Red }

if ($Project) {
  $Dest = Join-Path (Get-Location).Path ".claude\skills\$SkillName"
} else {
  $Dest = Join-Path $HOME ".claude\skills\$SkillName"
}

if ($Uninstall) {
  if (Test-Path -LiteralPath $Dest) {
    Remove-Item -LiteralPath $Dest -Recurse -Force
    Write-Host "Removed $Dest"
  } else {
    Write-Host "Not installed at $Dest"
  }
  exit 0
}

# ---------------------------------------------------------------------------
# Read the version out of a SKILL.md frontmatter, which carries it as an
# indented, QUOTED scalar:
#
#     metadata:
#       version: "1.0.0"
#
# so the quotes have to come off. Plain -match over the lines, nothing that
# needs PowerShell 7. A SKILL.md predating the field -- or one that cannot be
# read -- degrades to 'unknown' rather than throwing: $ErrorActionPreference
# is 'Stop', so an unguarded Get-Content would abort the whole install, and a
# missing version line is no reason to refuse to install.
# ---------------------------------------------------------------------------
function Get-SkillVersion {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return "unknown" }
  try { $lines = Get-Content -LiteralPath $Path } catch { return "unknown" }
  if (-not $lines) { return "unknown" }
  $inFrontmatter = $false
  foreach ($line in $lines) {
    if ($null -eq $line) { continue }
    # TrimEnd() so a CRLF checkout does not smuggle a stray \r into the
    # version string and make every comparison differ.
    $line = $line.TrimEnd()
    if ($line -eq "---") {
      if ($inFrontmatter) { break }
      $inFrontmatter = $true
      continue
    }
    if ($inFrontmatter -and $line -match '^\s*version:\s*"?([^"\s]+)') { return $Matches[1] }
  }
  return "unknown"
}

# ---------------------------------------------------------------------------
# Local-clone fast path: only reachable when this file is actually being
# executed from disk (`.\install.ps1`) with the rest of the repo sitting
# next to it. Piped via `irm ... | iex`, $PSCommandPath / $MyInvocation are
# empty (there is no script file on disk to point at), so this is skipped
# and the download path below always runs -- there is no ambiguity about
# which copy wins.
# ---------------------------------------------------------------------------
$LocalDir = $null
$ScriptPath = $PSCommandPath
if (-not $ScriptPath -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
  $ScriptPath = $MyInvocation.MyCommand.Path
}
if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath)) {
  $CandidateDir = Split-Path -Parent $ScriptPath
  $hasAll = (Test-Path (Join-Path $CandidateDir "SKILL.md")) `
    -and (Test-Path (Join-Path $CandidateDir "scripts\audit_dockerfile.py"))
  foreach ($f in $RequiredFiles) {
    $hasAll = $hasAll -and (Test-Path (Join-Path $CandidateDir $f))
  }
  if ($hasAll) { $LocalDir = $CandidateDir }
}

# ---------------------------------------------------------------------------
# Overwrite guard. Runs before the download so a piped install that's about
# to fail this check doesn't spend time fetching a zip first.
#
# `irm ... | iex` cannot pass parameters, so an interactive prompt is the
# only way a piped user can confirm. When the host is non-interactive we
# refuse loudly rather than guessing.
# ---------------------------------------------------------------------------
if ((Test-Path -LiteralPath $Dest) -and -not $Force) {
  Write-Host "An existing install was found at: $Dest"
  $interactive = $Host.UI.RawUI -and -not [Console]::IsInputRedirected
  if ($interactive) {
    $reply = Read-Host "Overwrite it? (y/N)"
    if ($reply -notmatch "^[Yy]") {
      Write-Host "Installation cancelled."
      exit 0
    }
  } else {
    Write-Fail "Non-interactive session and $Dest already exists."
    Write-Host "Download the script and re-run it with -Force:" -ForegroundColor Yellow
    Write-Host "  irm <url>/install.ps1 -OutFile install.ps1; .\install.ps1 -Force" -ForegroundColor Yellow
    exit 1
  }
}

$Tmp = $null
$Stage = "$Dest.tmp.$PID"

try {
  if ($LocalDir -and $ReqVersion) {
    Write-Fail "-Version installs a release downloaded from GitHub, but this is a local clone."
    Write-Host "Check the tag out first and install from it:  git checkout v$ReqVersion; .\install.ps1 -Force" -ForegroundColor Yellow
    exit 1
  }
  if ($LocalDir) {
    Write-Status "Installing from local clone at $LocalDir..."
    $SrcDir = $LocalDir
  } else {
    $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("docker-skill-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

    if ($ReqVersion) { $refLabel = "v$ReqVersion"; $refPath = "tags/v$ReqVersion" }
    else             { $refLabel = $Branch;        $refPath = "heads/$Branch" }
    Write-Status "Downloading $SkillName ($refLabel)..."
    $zipUrl = "https://github.com/$Repo/archive/refs/$refPath.zip"
    $zip    = Join-Path $Tmp "skill.zip"
    try {
      # TLS 1.2 for older Windows PowerShell defaults.
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
    } catch {
      Write-Fail "Failed to download $zipUrl"
      if ($ReqVersion) { Write-Host "Is there a release v${ReqVersion}? Tags: https://github.com/$Repo/tags" -ForegroundColor Yellow }
      Write-Host "If the repository or $refLabel is unreachable, install by hand from a clone:" -ForegroundColor Yellow
      Write-Host "  git clone https://github.com/$Repo.git; cd Docker-Skill; .\install.ps1" -ForegroundColor Yellow
      exit 1
    }

    Expand-Archive -Path $zip -DestinationPath $Tmp -Force
    $src = Get-ChildItem -Path $Tmp -Directory | Where-Object { $_.Name -like "Docker-Skill-*" } | Select-Object -First 1
    if (-not $src) { Write-Fail "Archive layout unexpected -- aborting."; exit 1 }
    $SrcDir = $src.FullName
  }

  # Validate the payload BEFORE touching the destination. A partial download
  # that yielded SKILL.md but not dev-speed.md/production-hardening.md would
  # install a skill whose own navigation table links to missing files --
  # silent capability loss.
  if (-not (Test-Path (Join-Path $SrcDir "SKILL.md"))) { Write-Fail "Source has no SKILL.md -- aborting."; exit 1 }
  $pinHint = ""
  if ($ReqVersion) { $pinHint = " Release v$ReqVersion predates this installer's file layout; -Version needs 1.2.0 or newer. For an older tag: git checkout v$ReqVersion; .\install.ps1" }
  foreach ($f in $RequiredFiles) {
    if (-not (Test-Path (Join-Path $SrcDir $f))) { Write-Fail "Source is missing $f -- aborting.$pinHint"; exit 1 }
  }
  $scrDir = Join-Path $SrcDir "scripts"
  if (-not (Test-Path $scrDir)) { Write-Fail "Source has no scripts\ -- aborting."; exit 1 }
  foreach ($s in $RequiredScripts) {
    if (-not (Test-Path (Join-Path $scrDir $s))) { Write-Fail "Source is missing scripts\$s -- aborting.$pinHint"; exit 1 }
  }

  # Announce which version is going in, and which one it displaces. This is
  # the only moment in the flow where the incoming version and the one
  # already on disk are both available -- say it out loud, or a user sitting
  # on an old install has no way to tell.
  $newVersion = Get-SkillVersion (Join-Path $SrcDir "SKILL.md")
  if ($ReqVersion -and $newVersion -ne $ReqVersion) {
    Write-Fail "Tag v$ReqVersion declares version $newVersion in its SKILL.md -- aborting. Nothing was installed."
    exit 1
  }
  if (Test-Path -LiteralPath $Dest) {
    $oldVersion = Get-SkillVersion (Join-Path $Dest "SKILL.md")
    if ($oldVersion -eq $newVersion) {
      Write-Status "already at $newVersion -- reinstalling"
    } else {
      Write-Status "installing $newVersion (replacing $oldVersion)"
    }
  } else {
    Write-Status "installing $newVersion"
  }

  # Stage into a sibling, then swap. The destination is never left half-written.
  Write-Status "Installing to $Dest..."
  if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
  $stageScripts = Join-Path $Stage "scripts"
  New-Item -ItemType Directory -Path $stageScripts -Force | Out-Null
  Copy-Item (Join-Path $SrcDir "SKILL.md") $Stage
  foreach ($f in $RequiredFiles) { Copy-Item (Join-Path $SrcDir $f) $Stage }
  foreach ($s in $RequiredScripts) { Copy-Item (Join-Path $scrDir $s) $stageScripts }

  $parent = Split-Path $Dest -Parent
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
  Move-Item -LiteralPath $Stage -Destination $Dest

  if ($newVersion -eq "unknown") {
    Write-Ok "$SkillName (version unknown) installed at $Dest"
  } else {
    Write-Ok "$SkillName v$newVersion installed at $Dest"
  }
  Write-Host ""
  Write-Host "Installed:"
  Write-Host "  SKILL.md"
  foreach ($f in $RequiredFiles) { Write-Host "  $f" }
  foreach ($s in $RequiredScripts) { Write-Host "  scripts\$s" }
  Write-Host ""
  if ($Project) {
    Write-Host "This may be a new top-level skills directory for this session --"
    Write-Host "restart Claude Code (or start a new session) in this project to load it."
  } else {
    Write-Host "If a Claude Code session is already running, it picks up changes under"
    Write-Host "~\.claude\skills\ live. Otherwise it's ready the next time you start one."
  }
  Write-Host ""
  Write-Host "Run the scripts yourself with:"
  Write-Host "  python3 $Dest\scripts\audit_dockerfile.py Dockerfile"
  Write-Host "  python3 $Dest\scripts\cache_report.py   # why is the build cache big?"
}
finally {
  if ($Tmp -and (Test-Path -LiteralPath $Tmp)) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
}
