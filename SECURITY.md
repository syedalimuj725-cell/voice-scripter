# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report it privately through GitHub instead: open the **Security** tab of this repository and click **Report a vulnerability**. Only the maintainer can see the report.

Please include the steps to reproduce the problem and what you expected to happen.

## Supported versions

Only the latest version on the `main` branch gets fixes.

## Design notes

- The tool never stores an API key in the code. It reads the key from the `ANTHROPIC_API_KEY` environment variable or an encrypted SecretStore vault.
- Generated scripts are never run automatically. They run only after you type `RUN` in capital letters, in a separate PowerShell window.
- Before that prompt, the tool flags risky commands and lints the script with PSScriptAnalyzer.
- Your request text is sent to the Anthropic API. Do not dictate names, case numbers, hostnames, or other data that your organization does not allow you to share.
