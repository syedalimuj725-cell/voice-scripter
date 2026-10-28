<#
.SYNOPSIS
    Speak a task out loud; get a reviewed PowerShell script back.

.DESCRIPTION
    v1 pipeline:
        Microphone -> System.Speech (offline dictation) -> LLM -> .ps1 file -> YOU review -> optional run

    Nothing is ever executed automatically. The generated script is written to disk,
    displayed, and only runs if you explicitly confirm.

.NOTES
    Requires: Windows PowerShell 5.1 or PowerShell 7+ on Windows.
    API key:  store it first, once, with:
                  $env:ANTHROPIC_API_KEY = 'sk-ant-...'      (session only)
              or, better:
                  Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
                  Register-SecretVault -Name LocalStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
                  Set-Secret -Name AnthropicApiKey -Secret 'sk-ant-...'
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool: colored status output is for the person at the keyboard, not the pipeline.')]
[CmdletBinding()]
param(
    # Where generated scripts land.
    [string]$OutputPath = "$env:USERPROFILE\Documents\VoiceScripts",

    # Seconds of silence before dictation stops listening.
    [int]$ListenTimeoutSeconds = 20,

    # Skip the mic and type the request instead (useful for testing / noisy rooms).
    [switch]$TypeInstead,

    # Model to use.
    [string]$Model = 'claude-sonnet-4-6'
)

#region ---------- Setup ----------

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

function Get-ApiKey {
    if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }

    if (Get-Command Get-Secret -ErrorAction SilentlyContinue) {
        try {
            return (Get-Secret -Name AnthropicApiKey -AsPlainText -ErrorAction Stop)
        } catch {
            Write-Verbose "No 'AnthropicApiKey' secret available: $($_.Exception.Message)"
        }
    }

    throw "No API key found. Set `$env:ANTHROPIC_API_KEY or store a secret named 'AnthropicApiKey'."
}

#endregion

#region ---------- Speech capture ----------

function Get-SpokenText {
    param([int]$TimeoutSeconds)

    Add-Type -AssemblyName System.Speech

    $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine
    try {
        $engine.SetInputToDefaultAudioDevice()
        $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))

        Write-Host "`n[LISTENING] Describe the script you want. Say 'end of request' when done.`n" -ForegroundColor Cyan

        $chunks = @()
        while ($true) {
            $result = $engine.Recognize([TimeSpan]::FromSeconds($TimeoutSeconds))

            if (-not $result) {
                Write-Host "[silence - stopping]" -ForegroundColor DarkGray
                break
            }

            $text = $result.Text
            Write-Host "  > $text" -ForegroundColor DarkGray

            if ($text -match 'end of request|that.s it|done talking') { break }
            $chunks += $text
        }

        return ($chunks -join ' ').Trim()
    }
    finally {
        $engine.Dispose()
    }
}

#endregion

#region ---------- LLM call ----------

$SystemPrompt = @'
You generate Windows PowerShell scripts for an enterprise IT help desk engineer working
in a locked-down, audited environment (Active Directory, SCCM, ServiceNow, ~1500 endpoints).

Rules you must follow every time:
1. Output ONLY the PowerShell script. No prose, no explanation, no markdown fences.
2. Begin with a comment-based help block (.SYNOPSIS, .DESCRIPTION, .PARAMETER, .EXAMPLE).
3. Wrap the logic in an advanced function with [CmdletBinding(SupportsShouldProcess)]
   whenever the script changes state. Gate every destructive action behind
   $PSCmdlet.ShouldProcess().
4. Use typed, validated parameters. Never hardcode server names, OUs, paths, or credentials.
5. Use try/catch with -ErrorAction Stop. Write meaningful errors; never swallow exceptions.
6. Prefer read-only discovery first. If the request is ambiguous or dangerous, generate the
   SAFEST reasonable interpretation and add a "# REVIEW:" comment explaining the assumption.
7. Output objects, not formatted text. Let the caller pipe to Export-Csv or Format-Table.
8. Add a "# SAFETY:" comment at the top listing what the script touches and its blast radius.
9. Never include Remove-Item -Recurse -Force on a variable path, Format-Volume, or
   mass account deletion without an explicit -WhatIf default and a hard confirmation prompt.
'@

function Invoke-ScriptGeneration {
    param([string]$Request, [string]$ApiKey, [string]$Model)

    $payload = @{
        model      = $Model
        max_tokens = 4000
        system     = $SystemPrompt
        messages   = @(
            @{ role = 'user'; content = $Request }
        )
    } | ConvertTo-Json -Depth 8

    $headers = @{
        'x-api-key'         = $ApiKey
        'anthropic-version' = '2023-06-01'
        'content-type'      = 'application/json'
    }

    $response = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' `
                                  -Method Post -Headers $headers `
                                  -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))

    $text = ($response.content | Where-Object { $_.type -eq 'text' } |
             ForEach-Object { $_.text }) -join "`n"

    # Strip fences if the model adds them anyway.
    return ($text -replace '(?m)^```(powershell|ps1)?\s*$', '').Trim()
}

#endregion

#region ---------- Main ----------

try {
    $apiKey = Get-ApiKey

    $request = if ($TypeInstead) {
        Read-Host "`nDescribe the script you want"
    } else {
        Get-SpokenText -TimeoutSeconds $ListenTimeoutSeconds
    }

    if ([string]::IsNullOrWhiteSpace($request)) {
        Write-Warning 'Nothing captured. Exiting.'
        return
    }

    Write-Host "`n[REQUEST] $request`n" -ForegroundColor Yellow

    # Let you fix transcription errors before spending a call.
    $edit = Read-Host 'Press Enter to accept, or type a corrected request'
    if (-not [string]::IsNullOrWhiteSpace($edit)) { $request = $edit }

    Write-Host '[GENERATING] ...' -ForegroundColor Cyan
    $script = Invoke-ScriptGeneration -Request $request -ApiKey $apiKey -Model $Model

    $stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $slug     = ($request -replace '[^\w\s]', '' -split '\s+' | Select-Object -First 5) -join '-'
    $filePath = Join-Path $OutputPath "$stamp`_$slug.ps1"

    $header = @"
<# ============================================================
   AI-GENERATED - REVIEW BEFORE RUNNING
   Spoken request : $request
   Generated      : $(Get-Date -Format 'u')
   Model          : $Model
   ============================================================ #>

"@

    ($header + $script) | Set-Content -Path $filePath -Encoding UTF8

    Write-Host "`n----------------- GENERATED SCRIPT -----------------`n" -ForegroundColor Green
    Write-Host $script
    Write-Host "`n----------------------------------------------------`n" -ForegroundColor Green
    Write-Host "Saved to: $filePath" -ForegroundColor Green

    # Static safety screen before you're even offered the run option.
    $redFlags = @(
        'Remove-Item.*-Recurse.*-Force',
        'Remove-ADUser', 'Remove-ADComputer', 'Remove-ADGroup',
        'Format-Volume', 'Clear-Disk',
        'Stop-Computer', 'Restart-Computer',
        'Set-ExecutionPolicy',
        'Invoke-Expression', 'iex '
    )
    $hits = $redFlags | Where-Object { $script -match $_ }
    if ($hits) {
        Write-Host "[!] Potentially destructive patterns detected:" -ForegroundColor Red
        $hits | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host "    Review line by line. Do not run this against production." -ForegroundColor Red
    }

    if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) {
        Write-Host "`n[LINT]" -ForegroundColor Cyan
        Invoke-ScriptAnalyzer -Path $filePath | Format-Table RuleName, Severity, Message -AutoSize
    }

    $choice = Read-Host "`n[O]pen in editor, [R]un in a separate session, or [Q]uit? (default: O)"
    switch ($choice.ToUpper()) {
        'R' {
            $confirm = Read-Host "Type RUN in caps to confirm execution"
            if ($confirm -ceq 'RUN') {
                Start-Process powershell -ArgumentList '-NoExit', '-NoProfile', '-File', "`"$filePath`""
            } else {
                Write-Host 'Cancelled.' -ForegroundColor Yellow
            }
        }
        'Q' { }
        default {
            if (Get-Command code -ErrorAction SilentlyContinue) { code $filePath }
            else { notepad $filePath }
        }
    }
}
catch {
    Write-Error "Voice scripter failed: $($_.Exception.Message)"
}

#endregion
