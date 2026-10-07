# MakeBot Console installers

One pasted line takes a new machine to a running MakeBot Console.

## Windows

Open PowerShell as administrator (the script also elevates itself if you forget), then paste:

```powershell
irm https://raw.githubusercontent.com/proxychef/makebot-install/main/install.ps1 | iex
```

## Mac

Open Terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/proxychef/makebot-install/main/install.sh | bash
```

For now the Mac line only says when the Mac console arrives; run it again then.

## What the line does

- Installs Git and Node.js if they are missing.
- Signs in to GitHub in your browser the first time, then downloads the console to `MakeBot/gui` in your home folder, or updates it if it is already there.
- Runs the console's own setup, which finds MakeBot, starts the console at every boot and checks that everything works.
- Stops with a plain sentence if something is missing, and says what to do.
- Changes no security setting on your computer.

Run the same line again to update or repair a machine. It updates the files; the console picks the update up at its next restart, or right away with Update now in the app.

Install MakeBot first; the installer finds it.
