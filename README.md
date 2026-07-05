# AGRO - Aggro Guard and Raid Observer

AGRO warns when a non-tank group member is close to pulling threat from the target you are actively tanking.

It is built for World of Warcraft Classic TBC Anniversary.

## Installation

Download `AGRO.zip` from the latest GitHub Release and extract it into:

```text
World of Warcraft/_anniversary_/Interface/AddOns/
```

After extraction, the addon folder should be:

```text
World of Warcraft/_anniversary_/Interface/AddOns/AGRO/
```

Restart the game or reload the UI.

Do not use GitHub's green **Code > Download ZIP** button for installation. That downloads the source repository snapshot, not the packaged addon.

## Defaults

- Enabled.
- Requires the player to be assigned the tank role.
- Monitors `target` and `focus`.
- Warns at 90% weighted threat.
- Rearms after the player drops below 75%.
- Sends warnings to `/say` by default.
- Uses an 8 second global delay and a 30 second per-player cooldown.

Default warning format:

```text
Playername: 90%+ threat
```

## Commands

Use `/agro config` to open the configuration screen. The same options are also available through slash commands:

```text
/agro help
/agro config
/agro on
/agro off
/agro toggle
/agro status
/agro local
/agro group
/agro threshold <80-99>
/agro reset <50-95>
/agro global <3-60>
/agro player <5-120>
/agro focus
/agro role
/agro show
/agro hide
/agro lock
/agro test
```

## Indicator

- Green: enabled and monitoring a valid tanked target.
- Yellow: enabled, but waiting for tank role or a valid tanked target.
- Gray: disabled.

Left-click the indicator to toggle alerts. Drag it to move. Use `/agro lock` to lock or unlock the indicator.

## Compatibility

Built for WoW TBC Classic Anniversary client:

```text
Interface: 20505
```
