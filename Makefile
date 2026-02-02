# ==========================================
# The Things Stack 運用・管理用 Makefile
# ==========================================

# --- 環境設定 ---
SERVER_IP      := $(shell ip route get 1 | awk '{for(i=1;i<=NF;i++) if($$i=="src") print $$(i+1)}' | head -1)
ADMIN_ID       := admin
ADMIN_EMAIL    := admin@localhost
ADMIN_PW       := admin123
CONSOLE_SECRET := console-secret

# ファイルパス定義
TEMPLATE_FILE  := config/stack/ttn-lw-stack-docker-template.yml
CONFIG_FILE    := config/stack/ttn-lw-stack-docker.yml
BACKUP_DIR     := backups

# --- コマンド定義 ---

all: up

# 1. コンテナの起動
up:
	docker compose up -d

# 2. コンテナの停止
down:
	docker compose down

# 3. 再起動
restart: down up

# 4. ログの表示
logs:
	docker compose logs -f stack

# 5. 初期セットアップ
init: conf-gen cert-gen fix-perms wait-db db-migrate user-create cli-create console-create
	@echo "---------------------------------------------------"
	@echo "Setup Finished!"
	@echo "Access: https://$(SERVER_IP)"
	@echo "Login:  $(ADMIN_ID) / $(ADMIN_PW)"
	@echo "---------------------------------------------------"

# 6. 完全消去
clean:
	@echo "!!! DELETING ALL GENERATED FILES AND DATA !!!"
	@echo "Target: Docker Volumes, Database, Certs, Generated Config"
	@echo "Waiting 3 seconds... Press Ctrl+C to cancel."
	@sleep 3
	docker compose down --volumes --remove-orphans || true
	rm -f $(CONFIG_FILE)
	sudo rm -rf certs
	sudo rm -rf acme
	sudo rm -rf .env/data
	sudo rm -rf .env/cache
	@echo "Cleanup complete."

# 7. リセット
reset: clean init up

# 8. コンテナの状態確認
status:
	@echo "SERVER_IP: $(SERVER_IP)"
	@echo ""
	@docker compose ps

# 9. stackコンテナにシェル接続
shell:
	docker compose exec stack sh

# 10. DBバックアップ (PostgreSQL)
backup:
	@mkdir -p $(BACKUP_DIR)
	@echo ">>> Backing up PostgreSQL..."
	@docker compose exec postgres pg_dump -U root ttn_lorawan_dev | gzip > $(BACKUP_DIR)/ttn_db_$$(date +%Y%m%d_%H%M%S).sql.gz
	@echo ">>> Backup saved to $(BACKUP_DIR)/"
	@ls -lh $(BACKUP_DIR)/*.sql.gz | tail -1

# 11. DBリストア (最新のバックアップ、またはFILE=で指定)
restore:
	$(eval FILE ?= $(shell ls -t $(BACKUP_DIR)/*.sql.gz 2>/dev/null | head -1))
	@if [ -z "$(FILE)" ]; then \
		echo "Error: No backup file found in $(BACKUP_DIR)/"; \
		exit 1; \
	fi
	@echo ">>> Restoring from: $(FILE)"
	@echo "Waiting 3 seconds... Press Ctrl+C to cancel."
	@sleep 3
	@docker compose exec -T postgres dropdb -U root --if-exists ttn_lorawan_dev
	@docker compose exec -T postgres createdb -U root ttn_lorawan_dev
	@gunzip -c $(FILE) | docker compose exec -T postgres psql -U root -d ttn_lorawan_dev -q
	@echo ">>> Restore complete."

# 12. Dockerイメージの更新
update:
	@echo ">>> Pulling latest images..."
	docker compose pull
	@echo ">>> Recreating containers..."
	docker compose up -d
	@echo ">>> Update complete."

# 13. ヘルプ
help:
	@echo "============================================="
	@echo " The Things Stack 管理コマンド"
	@echo "============================================="
	@echo ""
	@echo "  make up        - コンテナの起動"
	@echo "  make down      - コンテナの停止"
	@echo "  make restart   - 再起動"
	@echo "  make logs      - stackログの表示"
	@echo "  make status    - コンテナの状態と検出したIPの表示"
	@echo "  make shell     - stackコンテナにシェル接続"
	@echo ""
	@echo "  make init      - 初期セットアップ (証明書, DB, ユーザー作成)"
	@echo "  make clean     - 全データ削除 (DB, 証明書, 設定)"
	@echo "  make reset     - clean + init + up"
	@echo ""
	@echo "  make backup    - DBバックアップ (backups/ に保存)"
	@echo "  make restore   - DBリストア (最新のバックアップ)"
	@echo "  make restore FILE=backups/xxx.sql.gz"
	@echo "                 - 指定ファイルからDBリストア"
	@echo ""
	@echo "  make update    - Dockerイメージの更新と再起動"
	@echo "  make help      - このヘルプを表示"
	@echo ""
	@echo "  SERVER_IP: $(SERVER_IP)"
	@echo "============================================="

# --- 以下、内部タスク ---

conf-gen:
	@echo ">>> Generating config file from template..."
	@if [ ! -f $(TEMPLATE_FILE) ]; then \
		echo "Error: $(TEMPLATE_FILE) not found!"; \
		exit 1; \
	fi
	@cp $(TEMPLATE_FILE) $(CONFIG_FILE)
	@echo ">>> Updating config file with SERVER_IP: $(SERVER_IP)..."
	@sed -i 's/thethings\.example\.com/$(SERVER_IP)/g' $(CONFIG_FILE)

cert-gen:
	@echo ">>> Generating Self-Signed Certificates..."
	@sudo rm -rf certs
	@mkdir -p certs
	@# 証明書作成 (SAN にIPを含めないとGoのTLS検証が失敗する)
	@openssl req -x509 -newkey rsa:4096 -keyout certs/key.pem -out certs/cert.pem \
		-days 3650 -nodes -subj "/CN=$(SERVER_IP)" \
		-addext "subjectAltName=IP:$(SERVER_IP),IP:127.0.0.1,DNS:localhost"
	@cp certs/cert.pem certs/ca.pem

fix-perms:
	@echo ">>> Fixing certificate permissions..."
	@sudo chown -R 886:886 ./certs
	@sudo chmod 644 ./certs/* || true

wait-db:
	@echo ">>> Waiting for PostgreSQL to be ready..."
	@docker compose up -d postgres redis
	@until docker compose exec postgres pg_isready -U root -d ttn_lorawan_dev > /dev/null 2>&1; do \
		sleep 1; \
	done
	@echo ">>> PostgreSQL is ready."

db-migrate:
	@echo ">>> Migrating Database..."
	docker compose run --rm stack is-db migrate

user-create:
	@echo ">>> Creating Admin User..."
	-docker compose run --rm stack is-db create-admin-user \
		--id $(ADMIN_ID) \
		--email $(ADMIN_EMAIL) \
		--password '$(ADMIN_PW)'

cli-create:
	@echo ">>> Creating CLI Client..."
	-docker compose run --rm stack is-db create-oauth-client \
		--id cli \
		--name "Command Line Interface" \
		--owner $(ADMIN_ID) \
		--no-secret \
		--redirect-uri "local-callback" \
		--redirect-uri "code"

console-create:
	@echo ">>> Creating/Updating Console Client..."
	@docker compose run --rm stack is-db create-oauth-client \
		--id console \
		--name "Console" \
		--owner $(ADMIN_ID) \
		--secret '$(CONSOLE_SECRET)' \
		--redirect-uri "https://$(SERVER_IP)/console/oauth/callback" \
		--redirect-uri "/console/oauth/callback" \
		--logout-redirect-uri "https://$(SERVER_IP)/console" \
		--logout-redirect-uri "/console" \
	|| docker compose run --rm stack is-db update-oauth-client console \
		--secret '$(CONSOLE_SECRET)' \
		--redirect-uri "https://$(SERVER_IP)/console/oauth/callback" \
		--redirect-uri "/console/oauth/callback" \
		--logout-redirect-uri "https://$(SERVER_IP)/console" \
		--logout-redirect-uri "/console"

.PHONY: all up down restart logs init clean reset status shell backup restore update help \
	conf-gen cert-gen fix-perms wait-db db-migrate user-create cli-create console-create
