# VoiceScripter

[![Tests](https://github.com/syedalimuj725-cell/voice-scripter/actions/workflows/test.yml/badge.svg)](https://github.com/syedalimuj725-cell/voice-scripter/actions/workflows/test.yml)

Speak an IT task out loud. Get a reviewed PowerShell script back.

VoiceScripter is a single PowerShell script. It listens to your voice, sends the request to the Anthropic API, and writes a clean `.ps1` file for you to review. It never runs anything on its own.

## How it works

```
Microphone -> offline dictation (System.Speech) -> you fix the transcript
           -> Anthropic API with a strict PowerShell system prompt
           -> timestamped .ps1 file -> safety scan + lint -> you decide
```

## Safety guardrails

- **No auto-run.** The script is saved and shown first. To run it, you must type `RUN` in caps.
- **Strict system prompt.** Every output must use `[CmdletBinding(SupportsShouldProcess)]`, typed parameters, `try/catch`, and a `# SAFETY:` comment that lists what the script touches.
- **Red-flag scan.** The tool checks for risky commands such as `Remove-Item -Recurse -Force`, `Remove-ADUser`, `Format-Volume`, and `Invoke-Expression`.
- **Lint pass.** If PSScriptAnalyzer is installed, the tool lints the new script.
- **Transcript check.** You can correct the speech-to-text result before the API call.

## Requirements

- Windows with PowerShell 5.1 or PowerShell 7+
- An Anthropic API key
- Optional: the `PSScriptAnalyzer` module

## Setup

Store your API key. The script never holds a key in the code.

```powershell
# Option 1: this session only
$env:ANTHROPIC_API_KEY = 'your-key-here'

# Option 2: encrypted local vault (recommended)
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore
Register-SecretVault -Name LocalStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name AnthropicApiKey -Secret 'your-key-here'
```

## Usage

```powershell
.\Start-VoiceScripter.ps1 -TypeInstead   # type the request to test the pipeline
.\Start-VoiceScripter.ps1                # speak the request
```

Say "end of request" when you finish talking.

| Parameter | Default | What it does |
|---|---|---|
| `-OutputPath` | `Documents\VoiceScripts` | Folder for generated scripts |
| `-ListenTimeoutSeconds` | `20` | Silence before listening stops |
| `-TypeInstead` | off | Type the request instead of speaking |
| `-Model` | `claude-sonnet-4-6` | Model to use |

## Testing

Every push runs automatic tests on Windows, in both Windows PowerShell 5.1 and PowerShell 7:

- **PSScriptAnalyzer:** any error or warning fails the build.
- **Pester unit tests:** these check the API request, the code-fence cleanup, the API key lookup, and the safety rules. They mock the API, so no key or microphone is needed.

Run them yourself:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester ./tests
```

## Data note

Your request text goes to an external API. Do not say names, case numbers, or hostnames that your data policy does not allow you to share.

## Roadmap

1. Whisper transcription for better accuracy with technical terms
2. Conversation memory for follow-up edits
3. Wake word and system tray mode
4. Local model option through Ollama for fully offline use

## License

MIT
