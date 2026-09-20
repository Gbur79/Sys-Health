Markdown

## Installation

Download the script to your local bin directory and make it executable:

mkdir -p ~/bin
curl -o ~/bin/eos-cleaner.sh https://raw.githubusercontent.com/Gbur79/eos-cleaner/main/eos-cleaner.sh
chmod +x ~/bin/eos-cleaner.sh

## Add to Application Menu (Optional)

To create a shortcut in your system's application launcher, run the following command in your terminal. This uses a universal path ($HOME) so it works for any user profile.

mkdir -p ~/.local/share/applications
cat << 'EOF' > ~/.local/share/applications/eos-cleaner.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=System Maintenance & Repair
GenericName=Maintenance & Self-Repair
Comment=Interactive system cleanup and health audit
Exec=konsole -e bash -ic "$HOME/bin/eos-cleaner.sh"
Icon=utilities-system-monitor
Terminal=false
Categories=System;Utility;Maintenance;
StartupNotify=false
EOF

<img width="708" height="1067" alt="image" src="https://github.com/user-attachments/assets/3e349a4a-a570-43d8-9aee-de5ef588e01c" />
