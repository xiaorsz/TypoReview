# TypoReview 上海同步服务

该服务把 App 的结构化数据迁移到独立 PostgreSQL，并让服务器负责每日计划唯一性和复习阶段推进。晨读/听写媒体资源文件及媒体索引不进入服务器。

## 隔离边界

- Compose 项目：`typo-review-sync`
- 容器网络：`typo-review-sync-internal`
- 数据卷：`typo-review-sync-postgres-data`
- 本机诊断端口：`127.0.0.1:18181`
- 公共 HTTPS 入口：`https://111.231.22.148/typo-review-sync/`（由现有 Caddy 的标准 `443` 转发）
- 过渡 HTTPS 入口：`18443`（独立 Caddy 容器和持久化内部 CA，供旧版 App 使用）
- 每日 PostgreSQL 自动备份：`/opt/typo-review-sync/backups`，保留 14 天
- API 额外加入 `luye-content-workbench_frontend` 网络；PostgreSQL 仍只在同步服务内部网络中
- 公共 Caddy 只增加 `/typo-review-sync/*` 路由，不连接或修改原应用与数据库容器

## 本地测试

```bash
cd server
PYTHONPATH=. python3 -m unittest discover -s tests
```

## 每日一句

- App 通过公开只读接口 `GET /v1/content/daily-quote` 获取服务器当天的内容。
- 日期固定按北京时间计算；同一天始终返回同一条，已分配内容永不重复使用。
- 当前 150 条内容位于 `app/daily_quotes.json`：保留首批 110 条古代名句，并追加
  20 条近现代名人名言和 20 条英文句子；三类内容在未使用队列中交错展示。
- 每条内容都包含正文、出处、白话解释和行动建议。
- 全部用完后接口返回 `status: "exhausted"`，App 显示“已用完”，不会回退到 AI 或 App 内置句库。

查看库存：

```bash
cd server
API_TOKEN='<管理令牌>' python3 scripts/daily_quotes_admin.py status
```

后续追加内容时，准备同结构 JSON 文件并导入。ID、正文和排序号不能重复；
已分配的 ID 会被保护，不会被后台修改：

```bash
cd server
API_TOKEN='<管理令牌>' python3 scripts/daily_quotes_admin.py import --file /path/to/new_quotes.json
```

远程管理时可通过 `TYPO_REVIEW_ADMIN_URL` 或 `--base-url` 指定服务器入口。

## 首次部署

1. 将目录发布到 `/opt/typo-review-sync`。
2. 从 `.env.example` 生成仅服务器可读的 `.env.production`，使用随机数据库密码和 API Token。
3. 执行 `docker compose --env-file .env.production -f compose.production.yml up -d --build`。
4. 通过服务器本机的 `http://127.0.0.1:18181/health` 验证。

新 TestFlight 客户端使用系统信任的公共 `443` 证书；旧版客户端仍可通过
独立 `18443` 入口和项目导出的 CA 证书同步。公共网关的已部署配置副本见
`Caddyfile.public-gateway`。

## 恢复备份

```bash
docker compose --project-name typo-review-sync --env-file /opt/typo-review-sync/.env.production \
  -f /opt/typo-review-sync/current/compose.production.yml exec -T backup \
  pg_restore --clean --if-exists --no-owner --dbname="$DATABASE_URL" \
  /backups/<backup>.dump
```

上述备份与数据库仍在同一台服务器，可防误操作，不能防整块磁盘故障；正式使用后应再加一份异机备份。
