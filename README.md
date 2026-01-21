# Graph Administrator Toolbox (GratBox)

A Portable PowerShell admin toolkit for Microsoft Graph workflows using delegated device-code authentication.

## Quick start (portable)

1. Download the latest release ZIP and extract to a folder, for example:
   `C:\Tools\GratBox\`

2. Launch the toolkit (recommended):
   - `Launch-GratBox.cmd`

3. Follow the device-code login prompt.

## Folder layout

- `\`  - cmd launchers for portable use
- `Scripts\`    - utility scripts
- `modules\`    - bundled PowerShell components used by the toolkit
- `Logs\`       - runtime logs (not committed)
- `Reports\`    - exported reports (not committed)
- `Imports\`    - optional input data (not committed)

## Adding your own scripts/modules

- Drop scripts into `Scripts\`
- Drop additional modules under `modules\`

## Known limitations

- Some Microsoft Graph behaviors are limited under device-code auth. Where applicable, cmdlets will warn and exit cleanly rather than producing partial/incorrect results.
