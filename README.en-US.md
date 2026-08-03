

# Caddy Reverse Proxy for EMBY One-Click Script

![Language](https://img.shields.io/badge/Language-Bash-green.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-V4.0-orange.svg)

This is a one-click configuration script for a Caddy reverse proxy, specifically designed for **Emby**.
It supports automatic HTTPS certificate application, automatic startup on boot, reverse proxying for remote HTTPS servers, and includes built-in automatic port conflict resolution.

## 🚀 Quick Start (One-Click Install)

**Run as Root user** in your terminal using the following command:

```bash
bash <(curl -sL https://raw.githubusercontent.com/AiLi1337/install_caddy_emby/main/install_caddy_emby.sh)
```

## 🚀 New Core Features in V5
   * **Multi-Site Support (Append Mode)**: You can choose to "append" a new domain reverse proxy without overwriting previous configurations. One server, unlimited Emby instances!

   * **Targeted Deletion**: Lists all current reverse proxy domains, allowing you to specify and remove one without affecting other sites.

   * **Smart Duplicate Prevention**: Automatically checks if a domain already exists when adding a new one, preventing Caddy errors.
## ✨ Core Features (V4 Updates)

  * **⚡️ Rapid Configuration**: Automatically detects the OS (Debian/Ubuntu/CentOS) and installs the latest version of Caddy.
  * **🛠 Automatic Port Repair**: One-click detection and forced termination of Nginx/Apache processes occupying ports 80/443, resolving Caddy startup failures.
  * **🔒 Seamless HTTPS Support**:
      * Automatically applies for and renews Let's Encrypt SSL certificates.
      * **Supports HTTPS Backend Reverse Proxy**: Automatically fixes the Host header, perfectly reverse proxying remote Emby servers (resolves 404/403 errors).
  * **🚀 Performance Optimization**:
      * Enables Gzip compression.
      * Passes real IP (`X-Forwarded-For`), allowing Emby to identify clients easily.
      * Automatically configures startup on boot.

## 📖 User Guide

### 1\. Run the Script

After entering the one-click command above, you will see the following menu:

```text
#################################################
#    Caddy + Emby Multi-Site Management Script (V5 Pro)       #
#################################################
 1. Install Environment & Caddy
 2. Add/Overwrite Reverse Proxy Config (Multi-Site Supported)
 3. Delete Specific Site Config (NEW!)
 4. View Caddy Config File
-------------------------------------------------
 5. Stop Caddy
 6. Restart Caddy
 7. Check 443/80 Port Usage
 8. Force Resolve Port Conflicts (Fix Startup Failures)
 9. Uninstall Caddy
-------------------------------------------------
 0. Exit Script

  Please enter a number [0-9]: 
```
### 2\. Recommended Steps

1.  **Install**: Enter `1` to install Caddy.
2.  **Clear Ports** (Optional but recommended): If your server has had Nginx installed, it's recommended to enter `7` to ensure the ports are free.
3.  **Configure**: Enter `2` and follow the prompts to input your domain and Emby address.
      * *Domain Example*: `emby.yourdomain.com` (Ensure it resolves to your server's IP)
      * *Backend Example*: `127.0.0.1:8096` or `https://remote-emby.com:443`

## ❓ FAQ

**Q: Startup fails with "bind: address already in use"?**
A: This occurs because ports 80 or 443 are occupied by Nginx/Apache. Select **[7] Force Resolve Port Conflicts** from the script menu, then reselect **[4] Restart Caddy**.

**Q: Emby fails to play or shows 404 after reverse proxying?**
A: The script automatically handles the Host header. Please ensure the backend address you entered is correct. If using a remote HTTPS backend, be sure to include the `https://` prefix.

**Q: How to view runtime logs?**
A: Use the command `systemctl status caddy -l` or `journalctl -u caddy -f`.
