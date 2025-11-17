#!/bin/bash
# 加强 SSH 安全：改端口、新用户、Fail2ban

NEW_SSH_PORT=22222          # 想要改到的高位端口
NEW_SSH_USER="itachilin"   # 新登录用户名
NEW_SSH_PASS="ASa123321@"             # 新用户密码（留空则执行时手动输入）

JAIL_MAX_RETRY=5            # Fail2ban 最大失败次数
JAIL_FIND_TIME=600          # 统计失败登录时间窗（秒）
JAIL_BAN_TIME=86400         # 封禁时长（秒），默认 1 天

set -euo pipefail

# 检查是否 root
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行此脚本"
  exit 1
fi

echo "=== 1. 创建新用户：$NEW_SSH_USER ==="
if id "$NEW_SSH_USER" &>/dev/null; then
  echo "用户 $NEW_SSH_USER 已存在，跳过创建。"
else
  # 密码逻辑：优先用脚本变量 NEW_SSH_PASS，留空则交互输入
  NEW_SSH_PASS="${NEW_SSH_PASS:-""}"

  if [[ -z "$NEW_SSH_PASS" ]]; then
    read -s -p "请输入新用户 $NEW_SSH_USER 的密码: " NEW_PASS
    echo
    read -s -p "请再输入一次密码确认: " NEW_PASS_CONFIRM
    echo
    if [[ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]]; then
      echo "两次密码不一致，退出。"
      exit 1
    fi
  else
    NEW_PASS="$NEW_SSH_PASS"
  fi

  # 创建用户并设置密码
  useradd -m -s /bin/bash "$NEW_SSH_USER"
  echo "${NEW_SSH_USER}:${NEW_PASS}" | chpasswd
  echo "用户 $NEW_SSH_USER 创建完成。"
fi

echo "=== 2. 给新用户授予 sudo 权限 ==="
# 使用 /etc/sudoers.d 的方式，比较安全、通用
if [[ ! -d /etc/sudoers.d ]]; then
  mkdir -p /etc/sudoers.d
  chmod 750 /etc/sudoers.d
fi

SUDO_FILE="/etc/sudoers.d/${NEW_SSH_USER}"

# 如果已经有文件就不覆盖，避免重复写
if [[ -f "$SUDO_FILE" ]]; then
  echo "sudoers.d 中已存在 $SUDO_FILE，保留原有配置。"
else
  echo "${NEW_SSH_USER} ALL=(ALL) ALL" > "$SUDO_FILE"
  chmod 440 "$SUDO_FILE"
  echo "已在 $SUDO_FILE 中为用户 ${NEW_SSH_USER} 配置 sudo 权限。"
fi

# 兼容性：如果系统有 sudo/wheel 组，也顺便加入（非必须，但常见）
if getent group sudo &>/dev/null; then
  usermod -aG sudo "$NEW_SSH_USER" || true
  echo "已将用户 ${NEW_SSH_USER} 加入 sudo 组。"
fi

if getent group wheel &>/dev/null; then
  usermod -aG wheel "$NEW_SSH_USER" || true
  echo "已将用户 ${NEW_SSH_USER} 加入 wheel 组。"
fi

echo "=== 3. 备份并修改 /etc/ssh/sshd_config ==="
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

# 禁止 root 远程登录
if grep -qE "^[# ]*PermitRootLogin" "$SSHD_CONFIG"; then
  sed -i "s/^[# ]*PermitRootLogin.*/PermitRootLogin no/" "$SSHD_CONFIG"
else
  echo "PermitRootLogin no" >> "$SSHD_CONFIG"
fi
echo "已禁止 root 远程登录。"

# 只允许新用户登录
if grep -qE "^[# ]*AllowUsers" "$SSHD_CONFIG"; then
  sed -i "s/^[# ]*AllowUsers.*/AllowUsers ${NEW_SSH_USER}/" "$SSHD_CONFIG"
else
  echo "AllowUsers ${NEW_SSH_USER}" >> "$SSHD_CONFIG"
fi
echo "已设置只允许用户 ${NEW_SSH_USER} 通过 SSH 登录。"

echo "=== 4. 重启 SSH 服务使配置生效 ==="
if command -v systemctl &>/dev/null; then
  systemctl restart sshd 2>/dev/null || systemctl restart ssh
else
  service sshd restart 2>/dev/null || service ssh restart
fi
echo "SSH 服务已重启。"

echo "=== 5. 安装 Fail2ban ==="
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

echo "=== 6. 配置 Fail2ban 规则 ==="
JAIL_LOCAL="/etc/fail2ban/jail.local"

cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
bantime  = ${JAIL_BAN_TIME}
findtime = ${JAIL_FIND_TIME}
maxretry = ${JAIL_MAX_RETRY}

[sshd]
enabled = true
port    = ${NEW_SSH_PORT}
filter  = sshd
logpath = /var/log/auth.log
         /var/log/secure
backend = systemd
EOF

echo "Fail2ban 配置已写入 $JAIL_LOCAL"

echo "=== 7. 启动并设置 Fail2ban 开机自启 ==="
if command -v systemctl &>/dev/null; then
  systemctl enable fail2ban
  systemctl restart fail2ban
else
  service fail2ban restart
fi

echo "=== 完成！当前设置摘要 ==="
echo "SSH 新端口: ${NEW_SSH_PORT}"
echo "新登录用户: ${NEW_SSH_USER}"
echo "新用户已拥有 sudo 权限（/etc/sudoers.d/${NEW_SSH_USER})"
echo "Fail2ban: 失败 ${JAIL_MAX_RETRY} 次，封禁 ${JAIL_BAN_TIME} 秒"
echo "注意：请用 'ssh ${NEW_SSH_USER}@服务器IP -p ${NEW_SSH_PORT}' 测试新登录 + sudo 后再断开当前连接！"
