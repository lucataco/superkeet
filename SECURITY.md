# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Superkeet, please report it
responsibly:

1. **Do not open a public GitHub issue.**
2. Email the maintainer at **security@lucataco.com** with a description of the
   issue and reproduction steps if possible.
3. You should receive an acknowledgement within 48 hours.

## Scope

Security issues include but are not limited to:

- Crashes or hangs triggered by malformed audio input or daemon responses
- Privilege escalation through the global hotkey event tap or auto-paste
  functionality
- Unsafe handling of transcript history or usage stats on disk
- Code-signing or notarization bypass in the release pipeline

## Out of Scope

- The bundled `parakeet-cli` engine — report issues there to
  [lucataco/parakeet-cli](https://github.com/lucataco/parakeet-cli)
- Behavior that requires physical access to an unlocked Mac

## Disclosure

Once a fix is released, we will publish a GitHub Security Advisory crediting the
reporter (unless they prefer to remain anonymous).
