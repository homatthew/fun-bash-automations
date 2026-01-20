# Fun Bash Automations
Collection of scripts I created to make my personal workflows lazier

Table of contents:

1. Rebase All branches:
   1. rebases all local branches to the most recent commit on origin/{master or main}

Setup:
1. VS Code
	1. GitHub Markdown preview
	2. Gitless
	3. Git History
	4. One monokai
	5. Sort Lines
	6. Vim
	7. Sort Json objects
	8. Rainbow CSV
2. IntelliJ
	1. Atom One THeme / Solarized Chandrian Themes
	2. GitToolBox
	3. IdeaVim
	4. One Monokai Color Scheme
  5. Claude
3. MacOS
	1. BetterDisplay Pro
	2. AltServer
	3. BalanceLock
	4. Shottr
	7. F.lux
	9. Auto Collapse
	10. Rectangle / magnet
	11. Karabiner-elements
	12. OmniDiskSweeper
  13. MOS (Smooth Scrolling)

```
defaults write .GlobalPreferences com.apple.mouse.scaling -1
defaults write -g ApplePressAndHoldEnabled -bool false
```

To configure personal github for github.com
```
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
```

GhosTTY Needs this in the ssh
```
Host *
  SetEnv TERM=xterm-256color

```
