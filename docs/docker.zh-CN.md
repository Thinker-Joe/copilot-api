# Docker 部署与迁移

强化镜像以非 root 的 `bun` 用户运行，持久化目录统一为 `/data`，应用代码保持 root 所有。Compose 默认只向宿主机 `127.0.0.1` 发布端口。容器内部仍监听 `0.0.0.0`，因此必须先配置网关 API Key；GitHub Token 不能代替网关 Key。

## 全新部署

在仓库根目录执行：

```sh
cp .env.example .env
docker compose build
docker compose run --rm copilot-api auth keys --add YOUR_GATEWAY_API_KEY
docker compose run --rm copilot-api auth login
docker compose up -d --no-build
docker compose ps
```

请使用高强度网关 Key。初始化 Key 的参数会出现在 shell 历史或进程列表中，只应在可信主机上操作，不要把真实 Key 粘贴到日志或 issue。登录命令是交互式的；也可以在未跟踪的 `.env` 中设置 `COPILOT_API_GITHUB_TOKEN`，它优先于旧变量 `GH_TOKEN`。不要通过命令行传 GitHub Token。

默认镜像为从当前代码构建的 `copilot-api:local`，上游尚未合入这些改动也能使用。若改用镜像仓库，先将 `COPILOT_API_IMAGE` 设置为支持本部署约定的版本或 digest，再执行 `docker compose pull` 和 `docker compose up -d --no-build`。旧上游镜像不一定支持 `/data`。

命名卷 `copilot-api-data` 随 Compose 项目隔离，容器重建或 `docker compose down` 不会删除它。**除非明确要删除数据，否则不要执行 `docker compose down -v`。** 升级时保留相同的 Compose 项目名。默认启用只读根文件系统、可写临时目录、移除 capabilities、禁止提权和日志轮转；初始化命令和服务使用相同的数据卷与限制。

## 保留现有 SV 部署

**已有 `./data:/data` 的部署不能直接换成基础 Compose 单文件。** 否则会切换到新的空命名卷。应使用显式覆盖文件：

```sh
cp .env.sv.example .env.sv
# 编辑 .env.sv，保留原 Token、代理、端口、绑定地址和数据目录绝对路径。
docker compose --env-file .env.sv -f docker-compose.yaml -f docker-compose.sv.yaml config --quiet
docker compose --env-file .env.sv -f docker-compose.yaml -f docker-compose.sv.yaml pull
docker compose --env-file .env.sv -f docker-compose.yaml -f docker-compose.sv.yaml up -d --no-build
```

不要覆盖已有环境文件，请手动转移配置并限制文件读取权限。覆盖文件默认使用 `ghcr.io/thinker-joe/copilot-api:dev`，并挂载 `COPILOT_API_DATA_DIR`（默认 `./data`）。目录必须事先存在，路径拼错时不会自动创建空目录。保留原 Compose 项目名，必要时显式传入 `-p`。

dev 分支推送仍自动发布 `dev` 镜像。fork 默认保留开发版 `latest` 别名，以兼容旧服务器的拉取脚本；非 fork 仓库默认将 `latest` 留给稳定发布。可通过仓库 Actions 变量 `DOCKER_LATEST_CHANNEL` 显式选择 `dev` 或 `release`。SV 推荐明确使用 `dev`，避免未来稳定渠道调整影响部署。本次代码改动不会自动修改服务器配置。

## root 镜像或旧路径迁移

旧镜像目录为 `/root/.local/share/copilot-api`。改变镜像或挂载目标不会自动迁移权限，构建时的 `chown /data` 也不能修复宿主机 bind mount。

1. 使用 `docker inspect` 记录旧镜像 digest、项目名和真实挂载源。先停止旧服务，避免备份 SQLite 数据库及其 sidecar 文件时发生并发写入。
2. 将整个数据目录备份到构建上下文外的受保护位置，包括配置、Token、provider 凭据、数据库和 OAuth 应用子目录。不要输出凭据内容。
3. 保留原宿主机数据源，把容器挂载目标改为 `/data`。查询目标镜像的 UID/GID，不要盲目假设用户 ID。
4. 修复目录及其内部文件的所有权。只修改父目录不够，旧 root 所有的 `0600` 文件仍不可读。
5. 使用新镜像和相同挂载私下执行 `auth keys --list`（它会显示 Key），确认配置保留，再启动服务，检查健康状态和带鉴权的请求。暂时保留备份。

以下仅适用于 Linux 宿主机上的 rootful Docker，且必须先停止并备份服务：

```sh
IMAGE=ghcr.io/thinker-joe/copilot-api:dev
DATA_DIR=/absolute/path/to/existing/data
test -d "$DATA_DIR" || exit 1
test "$DATA_DIR" != / || exit 1
docker pull "$IMAGE"
APP_UID=$(docker run --rm --entrypoint id "$IMAGE" -u bun)
APP_GID=$(docker run --rm --entrypoint id "$IMAGE" -g bun)
sudo chown -R "$APP_UID:$APP_GID" "$DATA_DIR"
sudo chmod 700 "$DATA_DIR"
```

递归调整前确认真实路径，不要使用 `chmod 777`、不要修改无关目录，也不要改写文件内容。rootless Docker、用户命名空间映射、Docker Desktop 和 SELinux 需要各自的 UID 映射或共享/标签配置，不能照搬 rootful 命令。应以实际运行身份先验证挂载。

回滚时先停止新服务，再恢复受保护备份、旧镜像及原挂载定义。排查期间不要删除现有数据。配置保护逻辑采用与上游 `5d7ea5b` 相同的修复：只有配置确实不存在才初始化，权限或其他文件系统错误不再覆盖旧配置。

## 端口、代理和健康检查

- 宿主机发布由 `COPILOT_API_BIND` 和 `COPILOT_API_PORT` 控制；Compose 内部端口固定为 4141，不能只改 CLI 端口而不改映射。
- 单独 `docker run` 时，`--port`/`-p` 优先于 `PORT`，最终默认 4141。健康检查读取实际绑定地址，支持 IPv6 和动态端口；地址文件由 `COPILOT_API_HEALTHCHECK_FILE` 指定，镜像默认放在临时目录，不写入持久化数据。
- 服务启动默认启用环境代理，可传 `--no-proxy-env` 关闭。Compose 接受大小写 HTTP/HTTPS/ALL/NO proxy 变量，优先选择非空大写值。HTTP 代理支持不等于支持任意 SOCKS 配置。
- 代理 URL 中的 `127.0.0.1` 指容器自身，不是宿主机。应使用容器可达的地址；Linux 宿主机代理可能需要显式配置 `host-gateway` 映射。
- 健康检查显式绕过代理并限制连接、总请求时间。它只检查本地服务存活，不验证 provider、额度或 GitHub 凭据。Docker 的 unhealthy 状态本身不会自动重启容器，`restart: unless-stopped` 针对进程退出。
- 企业 CA 应只读挂载并按运行时要求配置，不要为了代理关闭证书验证。

## 发布和测试

稳定发布保留 `vX.Y.Z`、`vX.Y`、`vX`，额外提供无 v 前缀别名。预发布版本不更新稳定滚动标签。分支标签和完整 commit-SHA 标签继续提供；release 渠道的 `latest` 归稳定版本，dev 渠道则只归 dev 分支。并发限制按 Git ref 隔离，发布一个版本不会取消另一个版本；PR 验证没有镜像仓库写权限。不适合滚动更新的部署应固定版本或 digest。

Docker workflow 在 Linux AMD64、ARM64 原生 runner 上先验证 Compose、运行应用测试、构建并运行真实容器，成功后才发布。集成测试使用独立测试卷、合成 Key、无容器外网及与 Compose 相同的权限限制：

```sh
bun test tests/docker-entrypoint.test.ts tests/docker-healthcheck.test.ts tests/server-health.test.ts
docker build -t copilot-api:test .
COPILOT_API_DOCKER_TEST_IMAGE=copilot-api:test bun test tests/docker-smoke.test.ts
```

未设置环境变量时 smoke 测试会跳过，不接触已部署容器或旧数据卷。镜像输出 provenance 和 SBOM，但这不能替代漏洞扫描或仓库权限控制。提交上游时建议将通用容器改进与 SV 专属覆盖配置区分，开发镜像发布策略单独与维护者确认。
