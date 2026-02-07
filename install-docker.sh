#!/bin/bash
set -euo pipefail

echo "=== Docker & Docker Compose インストールスクリプト ==="

# root権限チェック
if [ "$EUID" -ne 0 ]; then
  echo "エラー: root権限で実行してください (sudo ./install-docker.sh)"
  exit 1
fi

# OS確認
if [ ! -f /etc/os-release ]; then
  echo "エラー: サポートされていないOSです"
  exit 1
fi

. /etc/os-release

echo "検出されたOS: ${PRETTY_NAME}"

# 古いDockerパッケージの削除
echo "--- 古いDockerパッケージを削除中..."
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# 必要なパッケージのインストール
echo "--- 前提パッケージをインストール中..."
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  gnupg

# Docker公式GPGキーの追加
echo "--- Docker公式GPGキーを追加中..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Dockerリポジトリの追加
echo "--- Dockerリポジトリを追加中..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} \
  ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

# Docker Engine & Docker Compose プラグインのインストール
echo "--- Docker Engine & Docker Compose をインストール中..."
apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Dockerサービスの有効化・起動
echo "--- Dockerサービスを有効化・起動中..."
systemctl enable docker
systemctl start docker

# 現在のユーザー(sudo実行元)をdockerグループに追加
ACTUAL_USER="${SUDO_USER:-$USER}"
if [ "$ACTUAL_USER" != "root" ]; then
  echo "--- ユーザー '${ACTUAL_USER}' をdockerグループに追加中..."
  usermod -aG docker "$ACTUAL_USER"
  echo "注意: グループ変更を反映するにはログアウト→ログインが必要です"
fi

# バージョン確認
echo ""
echo "=== インストール完了 ==="
docker --version
docker compose version
