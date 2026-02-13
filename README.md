# nftables Forward Manager

交互式管理 Debian VPS 上的 `nftables` 端口转发规则，包含两种模式：

- `nft.sh`：通用转发（`masquerade`）
- `nft-po0.sh`：专线/内网出口模式（固定 `snat to RELAY_LAN_IP`）

## 功能

- 交互式添加规则：`本机端口 -> 对端IP:端口`（支持 `tcp/udp/both`）
- 添加前检测本机端口占用（`ss`）
- 查看当前规则（格式：`1234/tcp -> 1.2.3.4:1234`）
- 删除指定规则
- 自动检测 `nftables` 是否安装（可交互安装）
- 修改后自动生效
- 支持 `systemctl enable --now nftables`
- 规则统一写入并管理 `/etc/nftables.conf`（覆盖式）

## 两个脚本的区别

### `nft.sh`（通用）

- `DNAT`：把本机端口转发到对端
- `SNAT`：`masquerade`
- 适合普通公网出口场景

### `nft-po0.sh`（专线）

- `DNAT`：同上
- `SNAT`：固定 `snat to $RELAY_LAN_IP`
- 额外支持 `TCP MSS`（默认 `1452`，可在菜单里改，`0` 表示关闭）
- 适合你 PO0/专线固定内网源 IP 场景

## 在 VPS 上直接下载（curl）

> 仓库：`https://github.com/Tiiwoo/nftables`

```bash
curl -fsSL https://raw.githubusercontent.com/Tiiwoo/nftables/main/nft.sh -o nft.sh
curl -fsSL https://raw.githubusercontent.com/Tiiwoo/nftables/main/nft-po0.sh -o nft-po0.sh
chmod +x nft.sh nft-po0.sh
```

如果你也要下载说明文档：

```bash
curl -fsSL https://raw.githubusercontent.com/Tiiwoo/nftables/main/README.md -o README.md
```

## 使用

### 通用模式

```bash
sudo ./nft.sh
```

### 专线模式

```bash
sudo ./nft-po0.sh
```

## 重要说明

- 两个脚本都管理同一个文件：`/etc/nftables.conf`
- 不建议同一台机器混用两种模式
- 生产环境建议先备份：

```bash
sudo cp /etc/nftables.conf /etc/nftables.conf.bak.$(date +%F-%H%M%S)
```

## 无破坏测试模式

用于演练脚本逻辑，不下发 nft 规则、不动 systemctl：

```bash
NFTMGR_TEST_MODE=1 NFTMGR_SKIP_ROOT_CHECK=1 NFT_CONF=/tmp/nft-test.conf ./nft.sh
NFTMGR_TEST_MODE=1 NFTMGR_SKIP_ROOT_CHECK=1 NFT_CONF=/tmp/nft-po0-test.conf ./nft-po0.sh
```

