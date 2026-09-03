<#
.SYNOPSIS
  Install docker-image-playbook into a Claude Code skills directory (Windows
  PowerShell). For macOS/Linux/WSL, use install.sh.

.EXAMPLE
  ./install.ps1                  # global install:  $HOME/.claude/skills/docker-image-playbook
.EXAMPLE
  ./install.ps1 -Project         # project install:  ./.claude/skills/docker-image-playbook
.EXAMPLE
  ./install.ps1 -Force           # overwrite an existing install
.EXAMPLE
  ./install.ps1 -Uninstall       # remove the installed skill

Safe to re-run: without -Force it refuses to overwrite an existing install
rather than silently clobbering local edits.
#>
param(
  [switch]$Project,
  [switch]$Force,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$SkillName = "docker-image-playbook"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Files = @("SKILL.md", "dev-speed.md", "production-hardening.md", "scripts")

if ($Project) {
  $TargetRoot = Join-Path (Get-Location) ".claude/skills"
} else {
  $TargetRoot = Join-Path $HOME ".claude/skills"
}
$Target = Join-Path $TargetRoot $SkillName

if ($Uninstall) {
  if (Test-Path $Target) {
    Remove-Item -Recurse -Force $Target
    Write-Host "Removed $Target"
  } else {
    Write-Host "Not installed at $Target"
  }
  exit 0
}

foreach ($f in $Files) {
  $src = Join-Path $ScriptDir $f
  if (-not (Test-Path $src)) {
    Write-Error "error: $src not found -- run this script from a full clone of the repo"
    exit 1
  }
}

if ((Test-Path $Target) -and (-not $Force)) {
  Write-Error "error: $Target already exists. Re-run with -Force to overwrite."
  exit 1
}

New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
New-Item -ItemType Directory -Force -Path $Target | Out-Null
foreach ($f in $Files) {
  Copy-Item -Recurse (Join-Path $ScriptDir $f) (Join-Path $Target $f)
}

Write-Host "Installed $SkillName -> $Target"
if ($Project) {
  Write-Host "This may be a new top-level skills directory for this session --"
  Write-Host "restart Claude Code (or start a new session) in this project to load it."
} else {
  Write-Host "If a Claude Code session is already running, it picks up changes under"
  Write-Host "~/.claude/skills/ live. Otherwise it's ready the next time you start one."
}
