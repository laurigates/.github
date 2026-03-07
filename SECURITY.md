# Security Policy

## Supported Versions

Security patches are applied to the latest release of each project. Older versions are not actively maintained.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, use [GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-managing-vulnerabilities/privately-reporting-a-security-vulnerability) to report vulnerabilities privately. Navigate to the affected repository's **Security** tab and click **Report a vulnerability**.

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Any suggested remediation

I will acknowledge receipt within 3 business days and aim to provide an initial assessment within 7 business days.

## Disclosure Policy

I follow coordinated disclosure. Please allow reasonable time to investigate and patch before public disclosure. I will credit reporters in release notes unless anonymity is requested.

## Security Practices

- Dependencies are monitored for vulnerabilities via Renovate and GitHub Dependabot
- Container images are scanned with Trivy on every release
- Secrets are never committed to source control
