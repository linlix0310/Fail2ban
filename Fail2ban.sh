#!/bin/bash
# 仅修改 SSH 默认端口 + 配置 Fail2ban

# 想要改成的 SSH 端口
NEW_SSH_PORT=22222

# Fail2ban 参数
JAIL_MAX_RETRY=5            # 最大失败次数
JAIL_FIND_TIME=600          # 统计失败登录时间窗（秒）
JAIL_BAN_TIME=86400         # 封禁时长（秒），默认 1 天

set -euo pipefail

# 1. 检查是否 root
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行此脚本"
  exit 1
fi

echo "=== 1. 备份并修改 /etc/ssh/sshd_config 端口 ==="
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

cp "$SSHD_CONFIG" "$BACKUP_FILE"
echo "已备份 sshd_config 到: $BACKUP_FILE"

# 修改端口
if grep -qE "^[# ]*Port " "$SSHD_CONFIG"; then
  sed -i "s/^[# ]*Port .*/Port ${NEW_SSH_PORT}/" "$SSHD_CONFIG"
else
  echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"
fi
echo "已将 SSH 端口设置为: $NEW_SSH_PORT"

echo "=== 2. 检查 sshd 配置并重启 SSH 服务 ==="
if sshd -t 2>/dev/null; then
  echo "sshd 配置检查通过，正在重启 SSH 服务..."
  if command -v systemctl &>/dev/null; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh
  else
    service sshd restart 2>/dev/null || service ssh restart
  fi
  echo "SSH 服务已重启。"
else
  echo "sshd 配置检查失败，将恢复备份文件: $BACKUP_FILE"
  cp "$BACKUP_FILE" "$SSHD_CONFIG"
  exit 1
fi

echo "=== 3. 尝试为防火墙放行新 SSH 端口（如存在） ==="
if command -v ufw &>/dev/null; then
  ufw allow "${NEW_SSH_PORT}/tcp" || true
  echo "已尝试通过 ufw 放行端口 ${NEW_SSH_PORT}/tcp"
fi

if command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-port=${NEW_SSH_PORT}/tcp || true
  firewall-cmd --reload || true
  echo "已尝试通过 firewalld 放行端口 ${NEW_SSH_PORT}/tcp"
fi

echo "=== 4. 安装 Fail2ban ==="
if command -v apt &>/dev/null; then
  apt update
  apt install -y fail2ban
elif command -v yum &>/dev/null; then
  yum install -y epel-release || true
  yum install -y fail2ban
else
  echo "未检测到 apt 或 yum，请手动安装 fail2ban 后再配置。"
  exit 1
fi

echo "=== 5. 配置 Fail2ban 规则 ==="
JAIL_LOCAL="/etc/fail2ban/jail.local"

# 根据系统选择合适的 backend 和日志配置：
# - 有 /var/log/auth.log 或 /var/log/secure 就按文件模式读
# - 否则如果有 systemd journal，就用 backend=systemd，不写 logpath
BACKEND="auto"
LOGPATH_LINE=""

if [[ -f /var/log/auth.log ]]; then
  LOGPATH_LINE="logpath = /var/log/auth.log"
elif [[ -f /var/log/secure ]]; then
  LOGPATH_LINE="logpath = /var/log/secure"
elif [[ -S /run/systemd/journal/socket ]]; then
  # 没有传统日志文件，但有 systemd 日志
  BACKEND="systemd"
  # 不写 logpath，让 fail2ban 自己从 journal 中找 sshd 日志
else
  # 实在啥都没有，就先默认写 /var/log/auth.log，后续你可以手动调整
  LOGPATH_LINE="logpath = /var/log/auth.log"
fi

cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
bantime  = ${JAIL_BAN_TIME}
findtime = ${JAIL_FIND_TIME}
maxretry = ${JAIL_MAX_RETRY}
backend  = ${BACKEND}

[sshd]
enabled = true
port    = ${NEW_SSH_PORT}
filter  = sshd
${LOGPATH_LINE}
EOF

echo "Fail2ban 配置已写入 $JAIL_LOCAL"

echo "=== 6. 启动并设置 Fail2ban 开机自启 ==="
if command -v systemctl &>/dev/null; then
  systemctl enable fail2ban
  systemctl restart fail2ban
else
  service fail2ban restart
fi

echo "=== 完成！当前设置摘要 ==="
echo "SSH 新端口: ${NEW_SSH_PORT}"
echo "Fail2ban: 失败 ${JAIL_MAX_RETRY} 次，封禁 ${JAIL_BAN_TIME} 秒"
echo "请使用新端口测试登录，例如：ssh root@服务器IP -p ${NEW_SSH_PORT}"
echo "如果有其它防火墙（安全组、云厂商控制台），记得也要放行该端口。"
