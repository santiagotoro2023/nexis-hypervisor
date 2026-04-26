# Nexis Ecosystem — Versioning Standard

All Nexis repositories follow identical versioning rules.

## Format

```
vMAJOR.MINOR.PATCH
```

**Examples:** `v1.0.0`, `v1.2.0`, `v2.0.0`

## Rules

| Bump | When |
|------|------|
| MAJOR | Breaking API changes, incompatible protocol changes between components |
| MINOR | New features, new capabilities, backwards-compatible changes |
| PATCH | Bug fixes, security patches, dependency updates |

## Tagging

All repositories use the same tag format. To release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This triggers the release workflow automatically in each repo.

## Display Strings

In all UI and CLI output, versions are displayed as:

| Repo | Display format |
|------|----------------|
| nexis-hypervisor | `NX-HV · BUILD 1.0.0` |
| nexis-controller | `NX-CTL · BUILD 1.0.0` |
| nexis-worker (Android) | `NX-WRK · BUILD 1.0.0` |
| nexis-worker (Desktop) | `NX-WRK-DT · BUILD 1.0.0` |

## Ecosystem Compatibility

Components of the same MAJOR version are guaranteed compatible.
Cross-component communication (hypervisor ↔ controller ↔ worker) is tested
at each MINOR release.
