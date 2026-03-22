# nftables Forward Manager

交互式管理 Debian/Ubuntu VPS 上的 nftables 端口转发规则，支持交互菜单和命令行两种模式。

## 概览

| 脚本 | 场景 | SNAT 方式 | 独立 table |
|------|------|-----------|------------|
| `nft.sh` | 通用公网出口 | `masquerade` | `nft_mgr_nat` |
| `nft-po0.sh` | 专线/内网固定源 IP | `snat to $RELAY_LAN_IP` | `nft_po0_nat` / `nft_po0_filter` |

> 每台机器只用其中一个脚本，不要混用。

## 功能

- 交互式菜单 + 命令行子命令双模式
- 快速添加规则：`PORT [PROTO] IP[:RPORT]`，一行完成
- 添加前自动检测本机端口占用（`ss`）
- 添加 / 删除操作前确认（CLI 可 `-y` 跳过）
- 自动检测并安装 nftables
- 修改后自动语法校验并生效
- Docker-safe：不使用 `flush ruleset`，仅管理脚本自己的独立 table
- 支持 `systemctl enable --now nftables` 开机自启

## 安装

```bash
# 通用模式
curl -fsSL https://raw.githubusercontent.com/Tiiwoo/nftables/main/nft.sh -o nft.sh
chmod +x nft.sh

# 专线模式
curl -fsSL https://raw.githubusercontent.com/Tiiwoo/nftables/main/nft-po0.sh -o nft-po0.sh
chmod +x nft-po0.sh
```

## 使用

### 交互式菜单

```bash
sudo ./nft.sh        # 通用模式
sudo ./nft-po0.sh    # 专线模式
```

### 命令行模式

**nft.sh：**

```bash
sudo ./nft.sh list                          # 列出规则
sudo ./nft.sh add 10086 172.81.1.1:33333    # 添加规则 (both tcp+udp)
sudo ./nft.sh add 10086 tcp 172.81.1.1      # 添加规则 (tcp only, 远端端口=本机端口)
sudo ./nft.sh del 1                         # 删除规则 #1 (需确认)
sudo ./nft.sh del 1 -y                      # 删除规则 #1 (跳过确认)
sudo ./nft.sh apply                         # 重新应用规则
sudo ./nft.sh help                          # 显示帮助
```

**nft-po0.sh 额外支持：**

```bash
sudo ./nft-po0.sh set-ip 10.100.1.1        # 设置 RELAY_LAN_IP
sudo ./nft-po0.sh set-mss 1400             # 设置 TCP MSS (0=关闭)
```

### 快速添加格式

添加规则时（交互式或命令行）支持一行输入：

```
PORT [PROTO] IP[:RPORT]
```

| 输入 | 效果 |
|------|------|
| `10086 172.81.1.1:33333` | both tcp+udp, 远端端口 33333 |
| `10086 tcp 172.81.1.1:33333` | 仅 tcp |
| `10086 172.81.1.1` | both tcp+udp, 远端端口 = 本机端口 10086 |

交互式菜单中选择"Add"后，可直接输入快速格式，也可回车进入逐步引导。

## 两个脚本的区别

### nft.sh（通用）

- DNAT 将本机端口流量转发到远端
- SNAT 使用 `masquerade`（自动取出口 IP）
- 适合普通公网 VPS

### nft-po0.sh（专线）

- DNAT 同上
- SNAT 使用固定 `snat to $RELAY_LAN_IP`（专线内网 IP）
- 启动时如果已有 `RELAY_LAN_IP` 配置，直接加载并跳过询问
- 支持 TCP MSS 钳制（默认 1452，`0` 关闭），防止 MTU 不匹配导致断流
- 适合 PO0 / 专线中转场景

## 生成的 nft 规则示例

以 `nft-po0.sh` 为例，添加两条 both 规则后生成的配置：

```nft
define RELAY_LAN_IP = 10.100.1.1
define TCP_MSS = 1452

table ip nft_po0_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        meta l4proto { tcp, udp } th dport 10086 dnat to 172.81.1.1:33333
        meta l4proto { tcp, udp } th dport 20086 dnat to 82.40.2.2:44444
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr 172.81.1.1 meta l4proto { tcp, udp } th dport 33333 snat to $RELAY_LAN_IP
        ip daddr 82.40.2.2 meta l4proto { tcp, udp } th dport 44444 snat to $RELAY_LAN_IP
    }
}

table ip nft_po0_filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
        ip daddr { 172.81.1.1, 82.40.2.2 } tcp flags syn tcp option maxseg size set $TCP_MSS
    }
}
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `NFT_CONF` | `/etc/nftables.conf` | nftables 配置文件路径 |
| `SYSCTL_FILE` | `/etc/sysctl.d/99-nft-*.conf` | IPv4 forwarding 持久化文件 |
| `NFTMGR_TEST_MODE` | `0` | 测试模式，不实际执行 nft / systemctl |
| `NFTMGR_SKIP_ROOT_CHECK` | `0` | 跳过 root 权限检查 |
| `NFTMGR_SKIP_PORT_CHECK` | `0` | 跳过端口占用检查 |
| `DEFAULT_MSS` | `1452`（仅 nft-po0.sh） | TCP MSS 默认值 |

## 测试模式

不下发 nft 规则、不动 systemctl，用于安全地演练脚本逻辑：

```bash
# 通用
NFTMGR_TEST_MODE=1 NFTMGR_SKIP_ROOT_CHECK=1 NFT_CONF=/tmp/nft-test.conf ./nft.sh

# 专线
NFTMGR_TEST_MODE=1 NFTMGR_SKIP_ROOT_CHECK=1 NFT_CONF=/tmp/nft-po0-test.conf ./nft-po0.sh

# CLI 测试
NFTMGR_TEST_MODE=1 NFTMGR_SKIP_ROOT_CHECK=1 NFT_CONF=/tmp/nft-test.conf ./nft.sh add 10086 172.81.1.1:33333 -y
NFTMGR_TEST_MODE=1 NFTMGR_SKIP_ROOT_CHECK=1 NFT_CONF=/tmp/nft-test.conf ./nft.sh list
```

## 注意事项

- 两个脚本默认都写入 `/etc/nftables.conf`，同一台机器只用一个
- 生产环境建议先备份：`sudo cp /etc/nftables.conf /etc/nftables.conf.bak.$(date +%F-%H%M%S)`
- 需要 bash 4.0+（关联数组支持）
- 需要 `ss`（iproute2）用于端口占用检测
