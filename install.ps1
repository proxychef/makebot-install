<#
  Sets up a Windows 11 PC to run MakeBot Console, from one pasted line:

    irm https://raw.githubusercontent.com/proxychef/makebot-install/main/install.ps1 | iex

  It relaunches itself as administrator if it is not (Windows' own prompt appears), installs Git
  and Node.js with winget if they are missing, clones the console to %USERPROFILE%\MakeBot\gui (or
  updates it, fast-forward only), and runs scripts\setup-pc.ps1 from there, which does the rest.
  Install the MakeBot engine first; setup finds it. Safe to run again: it updates or repairs.

  Written to work both piped into iex (no script file, so no param block and no script root) and
  saved and run with -File. Plain ASCII: Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

  Set MAKEBOT_INSTALL_DRYRUN=1 to print each step's intended action and change nothing: no winget,
  no git, no setup run, no elevation, no folders.

  This changes no system-wide setting: no execution policy, registry, power, Defender or Smart App
  Control change. The execution-policy bypass on the setup run applies to that one process only.
#>

# Everything runs inside one child scope: the helper functions and variables vanish when it ends,
# so pasting this into a window leaves nothing behind. The block's output is NOT captured by an
# assignment: setup-pc.ps1's questions and progress must reach the operator's console, and a
# captured block swallowed all of it (a silent wait at "Use this engine folder? [Y/n]").
& {
  $ErrorActionPreference = 'Stop'

  $RawUrl = 'https://raw.githubusercontent.com/proxychef/makebot-install/main/install.ps1'
  $RepoUrl = 'https://github.com/proxychef/makebot-gui'
  $ConsoleUrl = 'http://127.0.0.1:8752/api/remote-hosts'
  $DryRun = ($env:MAKEBOT_INSTALL_DRYRUN -eq '1')

  function Write-Step([int]$Number, [string]$Title) {
    Write-Host ''
    Write-Host "Step $Number - $Title" -ForegroundColor Cyan
  }
  function Write-Ok([string]$Message) { Write-Host "[ok]   $Message" -ForegroundColor Green }
  function Write-Skip([string]$Message) { Write-Host "[skip] $Message" -ForegroundColor DarkGray }
  function Write-Bad([string]$Message) { Write-Host "[!!]   $Message" -ForegroundColor Yellow }
  function Write-Note([string]$Message) { Write-Host "       $Message" }

  function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }

  function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
  }

  # winget puts a new program on the Machine and User PATH, not on the one this window started
  # with. Rebuilding the session's PATH from both means git and node are found without the
  # operator closing the window and opening another.
  function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  }

  # One tool: look first, install only what is missing. winget's exit code is not trusted either
  # way (it differs for "already there", "needs a restart" and real failures); what counts is
  # whether the command can be found afterwards. winget shares this console, so its progress shows.
  function Install-Tool([string]$Id, [string]$Name, [string]$Command) {
    if (Test-Command $Command) {
      Write-Skip "$Name is already installed."
      return $true
    }
    if ($DryRun) {
      Write-Skip "Dry run: would run: winget install --id $Id -e --source winget --accept-source-agreements --accept-package-agreements"
      return $true
    }
    if (-not (Test-Command 'winget')) {
      Write-Bad "$Name is missing and winget is not available. In this window run: Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe  - or install App Installer from the Microsoft Store - then run the same line again."
      return $false
    }
    Write-Note "Installing $Name with winget..."
    $winget = Start-Process winget -ArgumentList 'install', '--id', $Id, '-e', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements' -NoNewWindow -Wait -PassThru
    Update-SessionPath
    if (Test-Command $Command) {
      Write-Ok "$Name installed."
      return $true
    }
    Write-Bad "$Name did not install (winget exit code $($winget.ExitCode)), or Windows needs a restart first. Restart if asked, then run the same line again."
    return $false
  }

  # Any answer at all, even a refusal, means the console is up and listening (the same probe as
  # setup-pc.ps1's Test-ConsoleUp).
  function Test-ConsoleUp([string]$Url) {
    try {
      $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      return $true
    } catch {
      return ($null -ne $_.Exception.Response)
    }
  }

  # setup-pc.ps1 exits 0 even when the startup task was not registered or the console never
  # answered, so the closing line waits for a real answer.
  function Wait-ConsoleUp([string]$Url, [int]$Seconds = 30) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ($true) {
      if (Test-ConsoleUp $Url) { return $true }
      if ((Get-Date) -ge $until) { return $false }
      Start-Sleep -Seconds 2
    }
  }

  # The setup script asks questions (which engine folder, the account sign-in) and prints a
  # checklist. Started with -NoNewWindow it inherits this console, so all of that is seen and
  # answered here; running it with & inside a captured block hid it.
  function Invoke-SetupScript([string]$Setup) {
    $p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Setup`"" -NoNewWindow -Wait -PassThru
    $p.WaitForExit()
    if ($null -eq $p.ExitCode) { return 1 }
    return [int]$p.ExitCode
  }

  function Invoke-MakeBotInstall {
    try {
      # === STEP 1: administrator ===
      Write-Step 1 'Administrator'
      if (Test-Elevated) {
        Write-Ok 'Running as administrator.'
      } elseif ($DryRun) {
        Write-Skip 'Dry run: would relaunch in an elevated PowerShell (Start-Process -Verb RunAs) and stop here.'
      } else {
        Write-Note "Not elevated. Windows will ask you to allow this; it opens a new window that carries on."
        $relaunch = "-NoExit -NoProfile -ExecutionPolicy Bypass -Command `"irm $RawUrl | iex`""
        try {
          Start-Process powershell -Verb RunAs -ArgumentList $relaunch
        } catch {
          Write-Bad "The administrator prompt was declined or could not open. Open PowerShell as administrator and paste the line again."
          return 1
        }
        Write-Ok 'Carrying on in the elevated window.'
        return 0
      }

      # === STEP 2: git and node ===
      Write-Step 2 'Git and Node.js'
      $gitOk = Install-Tool 'Git.Git' 'Git' 'git'
      $nodeOk = Install-Tool 'OpenJS.NodeJS.LTS' 'Node.js' 'node'
      if (-not ($gitOk -and $nodeOk)) { return 1 }
      if ($DryRun) {
        Write-Skip 'Dry run: would refresh PATH for this window from the Machine and User environment.'
      } else {
        Update-SessionPath
        Write-Ok 'PATH refreshed for this window.'
      }

      # === STEP 3: the console ===
      Write-Step 3 'The console'
      $MakeBotDir = Join-Path $env:USERPROFILE 'MakeBot'
      $Clone = Join-Path $MakeBotDir 'gui'
      if (Test-Path -LiteralPath (Join-Path $Clone '.git')) {
        if ($DryRun) {
          Write-Skip "Dry run: would run: git -C `"$Clone`" pull --ff-only"
        } else {
          Write-Note "Updating $Clone ..."
          & git -C $Clone pull --ff-only | Out-Host
          if ($LASTEXITCODE -ne 0) {
            Write-Bad "The console in $Clone could not be brought up to date (changes made there, it has diverged, or the console is updating itself right now - wait a minute and run the same line again). Nothing was changed. If it keeps failing, fix that folder or ask your assistant."
            return 1
          }
          Write-Ok 'The console is up to date.'
        }
      } else {
        $inTheWay = $null
        if (Test-Path -LiteralPath $Clone) { $inTheWay = Get-ChildItem -LiteralPath $Clone -Force -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($inTheWay) {
          Write-Bad "$Clone exists but is not a git clone, and it is not empty. Move it aside, then run the same line again."
          return 1
        }
        if ($DryRun) {
          Write-Skip "Dry run: would run: git clone $RepoUrl `"$Clone`""
          Write-Note 'GitHub sign-in opens in your browser the first time.'
        } else {
          if (-not (Test-Path -LiteralPath $MakeBotDir)) { New-Item -ItemType Directory -Path $MakeBotDir | Out-Null }
          Write-Note 'Cloning the console. GitHub sign-in opens in your browser the first time.'
          & git clone $RepoUrl $Clone | Out-Host
          if ($LASTEXITCODE -ne 0) {
            Write-Bad 'The clone did not finish. Complete the GitHub sign-in with the account that has access to proxychef/makebot-gui, then run the same line again.'
            return 1
          }
          Write-Ok "The console is cloned to $Clone."
        }
      }

      # === STEP 4: setup ===
      Write-Step 4 'Setup'
      $Setup = Join-Path $Clone 'scripts\setup-pc.ps1'
      if ($DryRun) {
        Write-Skip "Dry run: would run: powershell -NoProfile -ExecutionPolicy Bypass -File `"$Setup`""
        Write-Skip "Dry run: would check that the console answers at $ConsoleUrl (for up to 30 seconds) before saying it is running."
        Write-Skip 'Dry run: nothing was changed.'
        return 0
      }
      if (-not (Test-Path -LiteralPath $Setup)) {
        Write-Bad "$Setup is missing from the clone. Run the same line again; if it is still missing, ask your assistant."
        return 1
      }
      $setupExit = Invoke-SetupScript $Setup
      if ($setupExit -ne 0) {
        Write-Bad "Setup stopped (exit code $setupExit). Read its last lines above. Once that is fixed, run the same line again."
        return [int]$setupExit
      }
      Write-Ok 'Setup finished.'
      Write-Note 'Waiting for the console to answer...'
      if (-not (Wait-ConsoleUp $ConsoleUrl 30)) {
        Write-Bad 'Setup finished, but the console is not answering yet. Run this line again, or open Settings once it starts.'
        return 1
      }
      Write-Ok 'The console is answering.'
      Write-Host ''
      Write-Host 'The console is running. Open Settings -> Group to join your machines.' -ForegroundColor Green
      return 0
    } catch {
      Write-Host ''
      Write-Bad "The installer stopped on something it did not expect: $($_.Exception.Message)"
      Write-Note 'Nothing was left half-done that running the same line again cannot finish. Send this line to your assistant.'
      return 1
    }
  }

  $installExit = [int](@(Invoke-MakeBotInstall)[-1])
  # Under -File the exit code goes to the caller. Piped into iex there is no script file, and exit
  # would close the operator's window with the result still unread.
  if ($PSCommandPath) { exit $installExit }
}
