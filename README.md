<img width="708" height="1067" alt="image" src="https://github.com/user-attachments/assets/3e349a4a-a570-43d8-9aee-de5ef588e01c" />

# EOS Cleaner & System Health 
EndeavourOS maintenance toolkit that safely cleans system cache/rubbish and generates structured health reports for AI agents. Designed to be highly conservative—it avoids aggressive package removal and prioritizes system stability over reclaiming every last byte.

## Dependencies

The script utilizes standard tools to generate its audits. While `gum` is installed automatically, ensure you have the following optional diagnostic packages for the best results:
```bash
sudo pacman -S --needed pacman-contrib jq bind smartmontools lm_sensors
```
## Installation
Download the script to your local bin directory and make it executable:
```bash
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/Gbur79/eos-cleaner/main/eos-cleaner.sh -o ~/bin/eos-cleaner.sh
chmod +x ~/bin/eos-cleaner.sh
```

## Add to Application Menu (Optional)

To create a shortcut in your system's application launcher, run the following command in your terminal. This uses a universal path ($HOME) so it works for any user profile.
```bash
mkdir -p ~/.local/share/applications
cat << 'EOF' > ~/.local/share/applications/eos-cleaner.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=System Maintenance & Repair
GenericName=Maintenance & Self-Repair
Comment=Interactive system cleanup and health audit
Exec=bash -ic "$HOME/bin/eos-cleaner.sh"
Icon=utilities-system-monitor
Terminal=true
Categories=System;Utility;Maintenance;
StartupNotify=false
EOF
```
