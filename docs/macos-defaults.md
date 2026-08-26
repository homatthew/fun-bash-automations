# macOS preferences inventory

This repository does not write macOS defaults. System preferences are
machine-local state: inspect them on a new Mac, choose values deliberately in
System Settings or a private bootstrap, and record private workstation policy
outside this public repository.

The historical shell configuration noted these optional preferences:

| Domain and key | Historical value | Purpose |
| --- | ---: | --- |
| Global `com.apple.trackpad.scaling` | `5.0` | Faster trackpad pointer |
| `.GlobalPreferences` `com.apple.mouse.scaling` | `-1` | Disable mouse acceleration |
| Global `ApplePressAndHoldEnabled` | `false` | Prefer key repeat to accent selection |

These values are an inventory, not an installation contract. The supported
portable setup installs files and dependencies only; it performs no preference
database writes and does not restart macOS services.
