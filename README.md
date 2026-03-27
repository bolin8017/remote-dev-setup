# Remote Dev Setup

一鍵設定 WSL2 遠端開發環境。透過 Tailscale + SSH，從任何地方用 VSCode Remote SSH 連回家中的 WSL2。

## 架構

```
Client (macOS / Windows / Linux)           Home (Windows 11 + WSL2)
┌─────────────────┐                       ┌─────────────────────────┐
│  VSCode         │                       │  Windows 11             │
│  Remote SSH     │─── Tailscale VPN ───▶ │  └─ WSL2 (Ubuntu)      │
│  + Tailscale    │    (100.x.x.x)        │     ├─ SSH Server      │
│                 │                       │     ├─ Tailscale       │
└─────────────────┘                       │     └─ Your Code       │
                                          └─────────────────────────┘
```

**Why Tailscale?** 不需要固定 IP、不需要 port forwarding、不需要 DDNS。點對點加密，開箱即用。

## Quick Start

### 一鍵安裝（在 WSL2 內執行）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bolin8017/remote-dev-setup/main/install.sh)"
```

或帶參數安裝（非互動模式）：

```bash
curl -fsSL https://raw.githubusercontent.com/bolin8017/remote-dev-setup/main/install.sh | bash -s -- --github-user YOUR_GITHUB_USERNAME --yes
```

安裝完成後，畫面會顯示你的 Tailscale IP 和需要在客戶端設定的 SSH config。

### 手動安裝

```bash
git clone https://github.com/bolin8017/remote-dev-setup.git ~/.remote-dev-setup
cd ~/.remote-dev-setup
bash setup.sh
```

## 安裝選項

| 選項 | 說明 |
|------|------|
| `--generate-key` | 在本機生成 ed25519 key pair（推薦） |
| `--pubkey "ssh-ed25519 AAAA..."` | 直接提供 SSH 公鑰 |
| `--github-user <username>` | 從 GitHub 取得公鑰 |
| `--ssh-port <port>` | SSH 連接埠（預設 22） |
| `--skip-tailscale` | 跳過 Tailscale 安裝 |
| `--yes` / `-y` | 非互動模式，使用預設值 |
| `--uninstall` | 移除本腳本的設定 |

## 安裝流程

腳本會自動完成以下步驟（已安裝的會跳過）：

```
[1/7] OpenSSH Server        安裝 SSH 伺服器，產生 host key
[2/7] Tailscale              安裝 Tailscale VPN
[3/7] SSH hardening          套用安全設定（drop-in config，不覆蓋原設定）
[4/7] SSH authorized keys    設定 SSH 公鑰認證
[5/7] WSL boot               設定開機自動啟動服務（systemd 或 wsl.conf）
[6/7] Starting services      啟動 SSH + Tailscale
[7/7] Summary                顯示連線資訊和客戶端設定
```

## 檔案結構

```
remote-dev-setup/
├── install.sh                       # curl one-liner 入口
├── setup.sh                         # 主安裝腳本
├── config/
│   ├── sshd_hardening.conf          # SSH 安全設定（drop-in）
│   ├── wsl-boot.sh                  # WSL 開機腳本（non-systemd）
│   └── ssh_client_config.example    # 客戶端 SSH config 範例
└── README.md
```

## SSH 安全設定

使用 drop-in config（`/etc/ssh/sshd_config.d/99-remote-dev.conf`），不修改主設定檔。

| 設定 | 值 | 說明 |
|------|-----|------|
| `PermitRootLogin` | `no` | 禁止 root 登入 |
| `PasswordAuthentication` | `no` | 關閉密碼登入（key-only） |
| `PubkeyAuthentication` | `yes` | 公鑰認證 |
| `MaxAuthTries` | `3` | 最多嘗試 3 次 |
| `ClientAliveInterval` | `60` | 每 60 秒 keep-alive |
| `AllowTcpForwarding` | `yes` | VSCode Remote SSH 必要 |
| `AllowAgentForwarding` | `yes` | SSH agent 轉發（git push 等） |
| `X11Forwarding` | `no` | 關閉（不需要） |

## 客戶端設定（外出電腦）

### 1. 安裝 Tailscale

到 [tailscale.com/download](https://tailscale.com/download) 下載安裝，使用同一個帳號登入。

### 2. 產生 SSH Key（如果還沒有）

```bash
ssh-keygen -t ed25519
```

### 3. 設定 SSH Config

安裝完成後畫面會顯示完整的 config，將其加到 `~/.ssh/config`：

```
Host wsl-dev
    HostName <YOUR_TAILSCALE_IP>
    User <YOUR_USERNAME>
    IdentityFile ~/.ssh/id_ed25519
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

### 4. 連線

```bash
# 命令列
ssh wsl-dev

# VSCode
# Ctrl+Shift+P → Remote-SSH: Connect to Host → wsl-dev
```

## SSH Key 流程說明

**安裝時有四種方式處理 SSH key：**

1. **`--generate-key`**（推薦）— 在 WSL 上直接生成 ed25519 key pair，安裝完成後在畫面上顯示 private key，複製到外出電腦的 `~/.ssh/id_ed25519_wsl_dev` 即可
2. **`--github-user`** — 自動從 GitHub 取得你的公鑰
3. **`--pubkey`** — 直接傳入公鑰字串
4. **互動模式** — 不帶參數時，腳本會提供選單讓你選擇（生成 / 貼上 / 跳過）

**如果選擇跳過：**
- 密碼登入會暫時保留作為 fallback
- 之後可以用 `ssh-copy-id` 加入公鑰
- 加完後刪除暫時設定：`sudo rm /etc/ssh/sshd_config.d/99-remote-dev-auth.conf && sudo service ssh restart`

## 疑難排解

### SSH 連不上

```bash
# 確認 SSH 有在跑
sudo service ssh status

# 確認 Tailscale 有連線
tailscale status

# 查看 SSH 設定是否有語法錯誤
sudo sshd -t

# 查看安裝 log
cat /tmp/remote-dev-setup-*.log
```

### WSL 重啟後服務沒啟動

```powershell
# 重啟 WSL
wsl --shutdown
wsl

# 進入 WSL 後確認
sudo service ssh status
tailscale status
```

### 被鎖在外面（忘記加 key 就關了密碼登入）

從 Windows 直接進 WSL（不需要 SSH）：

```powershell
wsl
```

然後手動修復：

```bash
# 方法一：移除硬化設定（恢復密碼登入）
sudo rm /etc/ssh/sshd_config.d/99-remote-dev.conf
sudo service ssh restart

# 方法二：加入你的公鑰
echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys
```

### 移除所有設定

```bash
bash ~/.remote-dev-setup/setup.sh --uninstall
```

## 技術細節

- **systemd 偵測**：自動偵測 WSL2 是否啟用 systemd。有 systemd 用 `systemctl enable`，沒有則透過 `wsl.conf [boot] command` 啟動服務。
- **冪等設計**：重複執行不會重複安裝或覆蓋設定。設定檔相同時會跳過。
- **sudo 處理**：腳本以普通使用者執行，只在需要時透過 `sudo` 提權。開頭會快取 sudo 權限。
- **Drop-in config**：SSH 設定使用 `/etc/ssh/sshd_config.d/` 目錄，不修改主設定檔，方便管理和移除。
