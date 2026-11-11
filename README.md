# PCSetup

Set up a freshly installed Windows PC the way you like it: pick your apps, install them with
[winget](https://learn.microsoft.com/windows/package-manager/winget/), apply your usual Windows
settings, and work through a checklist of the steps only you can do.

It is a single PowerShell script with a normal window. Windows 10 and 11 already have everything it
needs, so there is nothing to install first.

## Start

1. Download this folder, or copy it to a USB drive.
2. Double-click `Start-PCSetup.bat` and allow the administrator prompt.

The first time, nothing is ticked. Tick what you want and press **Save my profile**. From then on your
ticks are loaded every time you open it.

## What the tabs do

- **Install** shows each app as already installed, needing an update, or not installed. Tick apps and
  press **Install selected**. Apps install one at a time, and one failure does not stop the rest.
- **Updates** lists apps with a newer version. Nothing updates unless you tick it. **Lock** keeps an app
  at its current version.
- **Settings** applies common Windows settings. Old values are saved first, so **Undo** puts them back.
  **Capture from this PC** saves the settings your PC already uses as your profile.
- **Checklist** holds the steps to do by hand, with your own steps added.
- **Log** shows what was run and why anything failed.

## Good to know

- Pressing Install or Update accepts each app's license terms on your behalf. PCSetup asks first.
- Apps that winget does not have can be added with a download link or your own setup file. Without a
  setup file they are added to your Checklist.
- PCSetup never restarts the PC without asking. If a restart is needed in the middle of a run, the run
  continues by itself afterwards.
- "Turn off admin prompts (UAC)" lowers security. It is never ticked for you.
- Passwords and license keys are never stored.

## Your profile

Everything personal is kept in the `profiles` folder next to the script: your ticked apps and settings,
your PC name, the apps and checklist steps you added, and your column widths. Back that folder up, and
copy it along to use the same choices on another PC. Delete it to start again from blank.

## Copy to a USB drive

Run `Copy-To-USB.bat` and type the drive letter. Answer **Y** when asked if the copy is for someone
else, and it leaves out your profile so they start blank.

## A PC without winget

A fresh Windows install can have a missing or broken winget. PCSetup offers to repair it and downloads
winget from Microsoft. To make that work without internet, put these three files from the latest
[winget release](https://github.com/microsoft/winget-cli/releases/latest) in a `bootstrap` folder next
to the script: the `.msixbundle`, `DesktopAppInstaller_Dependencies.zip` and the `License1.xml` file.

## Adding to the shared lists

The lists everyone gets are plain files in `data`: `apps.json`, `tweaks.json` and `checklist.json`.
Keep personal details out of them. The tests check for that.

## Tests

```
powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\Test-PCSetup.ps1
```

The tests never show a window, install anything or change a real setting. They use a made-up profile,
a stand-in for winget and a throwaway registry key, and they do read the list of apps on your PC.

`tests\sandbox\Run-Sandbox-Test.bat` runs real installs, updates and setting changes on a clean
Windows inside Windows Sandbox, and writes a report to `sandbox-results`.

## Limits

- It does not remove the apps that come with Windows.
- It does not set default apps or file associations, which Windows protects from scripts.
- It does not restore each app's own settings or sign-ins.

Use it at your own risk. It changes Windows settings and installs software with administrator rights.

MIT license. See `LICENSE`.
