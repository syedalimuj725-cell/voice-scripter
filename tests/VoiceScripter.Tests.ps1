# Pester 5 tests for Start-VoiceScripter.ps1.
# The script runs its main block when it loads, so the tests do not dot-source it.
# Instead they pull the functions and the system prompt out of the parsed script
# (AST) and load only those. No microphone, no API key and no network are needed.

BeforeAll {
    $script:Path = Join-Path $PSScriptRoot '..\Start-VoiceScripter.ps1'
    $tokens = $null; $parseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$parseErrors)
    $script:ParseErrors = $parseErrors

    # Load every function definition into this scope.
    $script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

    # Load the $SystemPrompt assignment that Invoke-ScriptGeneration depends on.
    $assign = $script:Ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $args[0].Left.Extent.Text -eq '$SystemPrompt'
    }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($assign.Extent.Text))
}

Describe 'Script file' {
    It 'parses with no syntax errors' {
        $script:ParseErrors.Count | Should -Be 0
    }

    It 'defines the expected functions' {
        foreach ($name in 'Get-ApiKey', 'Get-SpokenText', 'Invoke-ScriptGeneration') {
            Get-Command $name -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'contains no hardcoded API key' {
        Get-Content $script:Path -Raw | Should -Not -Match 'sk-ant-[A-Za-z0-9_-]{20,}'
    }

    It 'never runs a generated script without the typed RUN confirmation' {
        $text = Get-Content $script:Path -Raw
        $text | Should -Match "-ceq 'RUN'"
        # The only Start-Process call sits inside the RUN check.
        ([regex]::Matches($text, 'Start-Process')).Count | Should -Be 1
    }
}

Describe 'System prompt' {
    It 'enforces the safety rules' {
        $SystemPrompt | Should -Match 'SupportsShouldProcess'
        $SystemPrompt | Should -Match '# SAFETY:'
        $SystemPrompt | Should -Match 'try/catch'
        $SystemPrompt | Should -Match 'Output ONLY the PowerShell script'
    }
}

Describe 'Get-ApiKey' {
    BeforeEach { $script:SavedKey = $env:ANTHROPIC_API_KEY }
    AfterEach  { $env:ANTHROPIC_API_KEY = $script:SavedKey }

    It 'returns the key from the environment variable' {
        $env:ANTHROPIC_API_KEY = 'test-key-123'
        Get-ApiKey | Should -Be 'test-key-123'
    }

    It 'throws a clear error when no key is set' {
        $env:ANTHROPIC_API_KEY = $null
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-Secret' }
        { Get-ApiKey } | Should -Throw '*No API key found*'
    }
}

Describe 'Invoke-ScriptGeneration' {
    It 'sends the right request to the Messages API' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = 'Get-Service' }) }
        }

        Invoke-ScriptGeneration -Request 'list services' -ApiKey 'test-key' -Model 'test-model' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $body = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            $Uri -eq 'https://api.anthropic.com/v1/messages' -and
            $Method -eq 'Post' -and
            $Headers['x-api-key'] -eq 'test-key' -and
            $Headers['anthropic-version'] -eq '2023-06-01' -and
            $body.model -eq 'test-model' -and
            $body.messages[0].role -eq 'user' -and
            $body.messages[0].content -eq 'list services' -and
            $body.system -match 'SupportsShouldProcess'
        }
    }

    It 'strips markdown code fences from the reply' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = "``````powershell`nGet-Process`n``````" }) }
        }
        Invoke-ScriptGeneration -Request 'x' -ApiKey 'k' -Model 'm' | Should -Be 'Get-Process'
    }

    It 'joins multiple text blocks and ignores non-text blocks' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ content = @(
                [pscustomobject]@{ type = 'text'; text = 'line one' },
                [pscustomobject]@{ type = 'thinking'; text = 'ignore me' },
                [pscustomobject]@{ type = 'text'; text = 'line two' }
            ) }
        }
        $out = Invoke-ScriptGeneration -Request 'x' -ApiKey 'k' -Model 'm'
        $out | Should -Match 'line one'
        $out | Should -Match 'line two'
        $out | Should -Not -Match 'ignore me'
    }
}
