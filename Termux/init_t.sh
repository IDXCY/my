#!/data/data/com.termux/files/usr/bin/bash
set -e

echo "==> Termux Modern Setup (Zsh + P10k + CLI)"

# 1. 检测网络并自动切换 Termux 镜像源
SOURCES_LIST="$PREFIX/etc/apt/sources.list"
TUNA_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
TEST_URL="https://raw.githubusercontent.com/github/gitignore/main/README.md"

if ! curl -fsSL --connect-timeout 3 "$TEST_URL" >/dev/null 2>&1; then
    echo "[*] 切换至清华大学镜像源..."
    if [ -f "$SOURCES_LIST" ] && ! grep -q "mirrors.tuna.tsinghua.edu.cn" "$SOURCES_LIST"; then
        cp "$SOURCES_LIST" "${SOURCES_LIST}.bak"
        sed -i "s@^\(deb.*stable main\)$@#\1\ndeb ${TUNA_MIRROR} stable main@g" "$SOURCES_LIST"
    fi
fi

echo "[*] 更新系统..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive
apt-get upgrade -y

# 2. 探测 GitHub 加速代理
GH_MIRRORS=("https://ghfast.top" "https://gh-proxy.com" "https://mirror.ghproxy.com")
GH_PROXY=""

if ! curl -fsSL --connect-timeout 3 "$TEST_URL" >/dev/null 2>&1; then
    for mirror in "${GH_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 4 "${mirror}/${TEST_URL}" >/dev/null 2>&1; then
            GH_PROXY="$mirror"
            echo "[+] 使用 GitHub 代理: $GH_PROXY"
            break
        fi
    done
fi

github_url() { echo "${GH_PROXY:+${GH_PROXY}/}$1"; }

# 3. 辅助函数 (支持多行块去重追加)
safe_append() {
    local TEXT="$1" FILE="$2"
    [ -z "$TEXT" ] && return 0
    touch "$FILE"
    local CLEAN_TEXT
    CLEAN_TEXT=$(printf '%s' "$TEXT" | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}')
    if ! awk -v block="$CLEAN_TEXT" '
        BEGIN { RS=""; FS="\n" }
        index($0, block) > 0 { found=1; exit }
        END { exit !found }
    ' "$FILE" 2>/dev/null; then
        printf '\n%s\n' "$CLEAN_TEXT" >> "$FILE"
    fi
}

clone_or_update() {
    local REPO="$1" TARGET="$2"
    if [ -d "$TARGET/.git" ]; then
        git -C "$TARGET" pull --ff-only >/dev/null 2>&1 || true
    else
        rm -rf "$TARGET"
        git clone --depth=1 "$(github_url "$REPO")" "$TARGET"
    fi
}

# 4. 存储权限与工具安装
[ ! -d "$HOME/storage" ] && termux-setup-storage
echo "[*] 安装工具包..."
pkg install -y zsh git curl wget vim tree htop ncdu lf fzf ripgrep fd bat zoxide fastfetch
pkg install -y eza 2>/dev/null || pkg install -y exa 2>/dev/null || true

# 5. Oh My Zsh 与插件
ZSH_DIR="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$ZSH_DIR/custom"

clone_or_update "https://github.com/ohmyzsh/ohmyzsh.git" "$ZSH_DIR"
mkdir -p "$ZSH_CUSTOM/themes" "$ZSH_CUSTOM/plugins"

clone_or_update "https://github.com/romkatv/powerlevel10k.git" "$ZSH_CUSTOM/themes/powerlevel10k"
clone_or_update "https://github.com/zsh-users/zsh-autosuggestions.git" "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
clone_or_update "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"

# 6. Zsh 与 P10k 配置
ZSHRC_BLOCK=$(cat <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)

[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

export LANG=en_US.UTF-8
export HISTFILE=$HOME/.zsh_history
export HISTSIZE=10000
export SAVEHIST=10000

command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v fzf >/dev/null 2>&1 && source <(fzf --zsh) 2>/dev/null || true

if command -v eza >/dev/null 2>&1; then
    alias ls="eza --icons"
    alias ll="eza -lah --icons"
    alias la="eza -a --icons"
elif command -v exa >/dev/null 2>&1; then
    alias ls="exa --icons"
    alias ll="exa -lah --icons"
    alias la="exa -a --icons"
fi

alias ff="fastfetch"
alias zi="zoxide query -i"
alias cls="clear"
alias p10kcfg="p10k configure"
EOF
)

safe_append "$ZSHRC_BLOCK" "$HOME/.zshrc"

if [ ! -f "$HOME/.p10k.zsh" ]; then
    cat > "$HOME/.p10k.zsh" <<'EOF'
typeset -g POWERLEVEL9K_MODE=nerdfont-v3
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs prompt_char)
typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status command_execution_time background_jobs time)
typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
typeset -g POWERLEVEL9K_DIR_FOREGROUND=51
typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178
typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M}'
EOF
fi

# 7. 字体与 OneDark 配色
mkdir -p "$HOME/.termux"
FONT_URL=$(github_url "https://raw.githubusercontent.com/romkatv/powerlevel10k-media/master/MesloLGS%20NF%20Regular.ttf")

if curl -fsSL --connect-timeout 10 "$FONT_URL" -o "$HOME/.termux/font.ttf.tmp"; then
    mv "$HOME/.termux/font.ttf.tmp" "$HOME/.termux/font.ttf"
else
    rm -f "$HOME/.termux/font.ttf.tmp"
fi

cat > "$HOME/.termux/colors.properties" <<'EOF'
background: #1e2127
foreground: #abb2bf
cursor: #528bff
color0: #1e2127
color1: #e06c75
color2: #98c379
color3: #e5c07b
color4: #61afef
color5: #c678dd
color6: #56b6c2
color7: #abb2bf
color8: #5c6370
color9: #e06c75
color10: #98c379
color11: #e5c07b
color12: #61afef
color13: #c678dd
color14: #56b6c2
color15: #ffffff
EOF

# 8. 默认 Shell 与收尾
command -v chsh >/dev/null 2>&1 && chsh -s zsh || true
safe_append "exec zsh" "$HOME/.bashrc"
termux-reload-settings >/dev/null 2>&1 || true
pkg clean

echo "==> 安装完成，请重启 Termux 生效"
