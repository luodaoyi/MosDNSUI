好的，为了您的 MosDNS 监控面板能够方便地在 GitHub 上发布和使用，我为您准备了一份详尽的 Markdown 格式使用手册 (`README.md`)。

这份手册涵盖了项目的介绍、主要功能、安装步骤、使用方法、配置选项、故障诊断以及如何卸载等关键信息，并特别强调了您脚本的“一键部署”和“无闪烁刷新”等亮点。

---

```markdown
# MosDNS 独立监控面板

![MosDNS Monitor Panel Screenshot]
_![image](https://github.com/user-attachments/assets/bfb2a0d0-5c34-45aa-9057-fadf1b472149)
_

![MosDNS Monitor Panel Screenshot Dark]
_![image](https://github.com/user-attachments/assets/e4e39bf1-855f-4ae3-a488-29099f75e840)
_
## 简介

MosDNS 独立监控面板是一个简洁、美观且功能强大的 MosDNS 服务实时监控解决方案。它以独立的 Web 应用形式运行（基于 Python Flask），通过抓取 MosDNS 自身的 `/metrics` 接口数据，为您提供直观、易于理解的运行状态报告。

与 MosDNS 自带的 UI 互不影响，本面板旨在提供一个专注于监控和管理核心缓存指标的界面，并支持多种主题切换以适应不同用户偏好。

## 主要功能

*   **实时性能监控**：展示 MosDNS 的请求总数、缓存命中、过期缓存命中、缓存条目数等关键指标。
*   **系统资源概览**：监控 MosDNS 进程的 CPU 时间、常驻内存 (RSS)、堆内存、Go 版本、线程数和文件描述符数量等系统信息。
*   **多主题支持**：内置 **默认亮色**、**默认暗色**、**赛博朋克**、**静谧森林**、**日落余晖** 和 **高级灰** 多种主题，一键切换，满足您的视觉偏好。
*   **直观的饼图展示**：通过甜甜圈饼图清晰展示缓存的命中率和过期缓存命中率。
*   **无闪烁数据刷新**：智能区分刷新类型，自动刷新时仅更新数据，避免整个页面闪烁，提供流畅的视觉体验。
*   **可控的自动刷新**：提供开关，可选择是否启用 5 秒自动刷新，或手动点击按钮立即刷新。
*   **一键清空 FakeIP 缓存**：方便快捷地执行 MosDNS 的 FakeIP 缓存清空操作。
*   **独立的 Web 服务**：作为独立的 Flask 应用运行，不依赖或修改 MosDNS 自身配置，互不干扰。
*   **一键部署与回滚脚本**：提供 Bash 脚本，简化部署和卸载流程。
*   **集成诊断与修复**：脚本内置诊断功能，可自动检查并尝试修复常见部署问题。

## 部署要求

*   **操作系统**：基于 Debian / Ubuntu 的 Linux 发行版（脚本基于 `apt` 包管理器）。
*   **MosDNS**：已正确安装并运行，且其 HTTP Metrics 接口（默认为 `http://localhost:9099/metrics`）可访问。
*   **权限**：需要 `sudo` 权限来安装系统依赖、创建服务和配置防火墙。

## 快速开始 (一键部署)

1.  **下载部署脚本**：
    将 `deploy.sh` 文件下载到您的服务器。

    ```bash
    # 如果您已经将脚本复制到本地，请跳过此步骤
    # 或者从GitHub仓库直接下载（请将YOUR_USERNAME和YOUR_REPO替换为实际信息）
    # 例如：wget https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/deploy.sh
    ```

2.  **赋予执行权限**：
    ```bash
    chmod +x deploy.sh
    ```

3.  **运行部署脚本**：
    以 `sudo` 权限运行脚本，它将引导您完成部署过程。

    ```bash
    sudo ./deploy.sh
    ```

    脚本将提示您选择操作。选择 `部署 MosDNS 监控面板`。

    **脚本部署步骤概览：**
    *   检查 MosDNS Metrics 接口可访问性。
    *   安装 Python3、pip 和 `python3-venv` 等必要依赖。
    *   创建项目目录 `/opt/mosdns_monitor_panel`。
    *   创建 Python 虚拟环境并安装 Flask、Gunicorn 和 Requests。
    *   创建 Flask 后端应用 `app.py`。
    *   创建网站图标 `favicon.png`。
    *   创建 HTML 前端页面 `index.html`。
    *   创建 Systemd 服务并启动监控面板。
    *   自动配置 UFW 防火墙以允许访问默认端口 `5001`。

4.  **访问监控面板**：
    部署完成后，您将看到提示信息，通常可以通过以下地址访问您的监控面板：

    ```
    http://<您的服务器IP地址>:5001
    ```
    例如：`http://192.168.1.100:5001`

    如果您的服务器有域名解析，也可以使用域名访问。

## 使用说明

监控面板分为以下几个主要区域：

*   **缓存状态卡片**：
    *   显示各类缓存（全部、国内、国外、节点）的详细统计数据，包括请求总数、命中数、过期命中数、命中率、过期命中率和条目数。
    *   每个卡片顶部有一个状态点，绿色表示有活跃请求，黄色表示无请求。
    *   饼图直观展示命中率。

*   **系统信息**：
    *   展示 MosDNS 进程的启动时间、CPU 占用时间、常驻内存、空闲堆内存、Go 版本、线程数和打开文件描述符数量。

*   **底部控制面板**：
    这是一个集中的操作区域，包含以下功能：
    *   **显示卡片** (`<i class="fas fa-eye"></i>`)：
        *   您可以勾选/取消勾选来控制页面上显示哪些缓存卡片。选择后页面会自动刷新以应用更改。
    *   **主题切换** (`<i class="fas fa-palette"></i>`)：
        *   提供多种内置主题按钮。点击即可实时切换面板的主题样式。
    *   **操作与刷新** (`<i class="fas fa-tools"></i>`)：
        *   **启用自动刷新 (5s)**：勾选此项，面板将每 5 秒自动更新数据，且更新过程无闪烁。取消勾选则停止自动刷新。
        *   **立即刷新**：手动点击此按钮可立即获取最新数据并更新页面，保持无闪烁体验。
        *   **清空 FakeIP 缓存**：点击此按钮将向 MosDNS 发送指令，清空 FakeIP 缓存。此操作会触发页面重新加载以反映最新状态。
        *   **最后更新**：显示面板数据最后一次更新的时间。

## 配置

您可以修改部署脚本 `deploy.sh` 开头的变量来定制面板：

*   `FLASK_PORT=5001`：Web 监控面板运行的端口。如果您希望在其他端口运行，请在部署前修改此值。
*   `MOSDNS_METRICS_URL="http://localhost:9099/metrics"`：MosDNS Metrics 接口的完整 URL。如果您的 MosDNS 监听在不同的 IP 或端口，请相应修改。
*   `WEB_USER="www-data"`：运行 Flask 应用的系统用户。默认是 `www-data`，这是一个常见的 Web 服务器用户。

**请注意：** 如果您在部署后修改了这些配置，需要先执行回滚/清理操作，然后重新部署。

## 故障诊断与修复

如果监控面板无法正常工作，您可以运行部署脚本中的“一键诊断并尝试修复”选项：

```bash
sudo ./deploy.sh
```
选择 `一键诊断并尝试修复`。

脚本将执行以下检查并尝试自动修复常见问题：

*   **MosDNS Metrics 接口可访问性**：检查 MosDNS 是否正在运行以及其 `/metrics` 接口是否可访问。
*   **监控面板服务状态**：检查 Flask 应用的 Systemd 服务是否运行，如果未运行，会尝试启动。
*   **防火墙规则**：检查 UFW 防火墙是否允许 `FLASK_PORT` 端口的入站连接，并尝试添加规则。

如果问题依然存在，您可以手动查看监控面板的日志：

```bash
sudo journalctl -u mosdns_monitor_panel -f
```

这将显示服务的实时日志，帮助您定位问题。

## 回滚 / 卸载

如果您想移除 MosDNS 监控面板，可以运行部署脚本并选择“回滚/清理部署”选项：

```bash
sudo ./deploy.sh
```
选择 `回滚/清理部署`。

脚本将执行以下操作：

*   停止并禁用 `mosdns_monitor_panel.service` Systemd 服务。
*   删除 `/etc/systemd/system/mosdns_monitor_panel.service` 服务文件。
*   删除项目目录 `/opt/mosdns_monitor_panel`（包括虚拟环境和所有相关文件）。

## 贡献

欢迎对本项目进行贡献！如果您有任何建议、功能请求或 Bug 修复，请随时提交 Issue 或 Pull Request。

## 许可证

本项目基于 [MIT 许可证](LICENSE) 发布。

## 致谢

*   **ChatGPT** - 提供核心代码和创意支持。
*   **MosDNS 团队** - 提供了优秀的 DNS 转发工具。
*   **Chart.js** - 强大的图表库。
*   **Font Awesome** - 提供精美图标。
*   所有为开源社区做出贡献的开发者和项目。

---

**请务必替换 `your-username` 和 `your-repo-name` 以及截图链接，并上传您的截图文件到 `screenshots` 目录下。** 祝您的项目在 GitHub 上顺利！
