# 颐和园多媒体展示系统 —— 基于安路 FPGA 的 HDMI 图像 / 音频 / 频谱可视化

> 2026 年 FPGA 创新设计竞赛作品（r41 版）

本项目基于**安路 EG4S20BG256 FPGA**（康芯 HX4S20 开发板），实现了一个以**颐和园风景展示**为主线的多媒体系统：从 TF 卡读取 BMP 图片经 SDRAM 帧缓存、通过 HDMI 输出，叠加 OSD 字幕 / 转场特效 / 音频播放与**半对数频谱可视化**。

---

## 一、功能特性

- **TF 卡图片读取**：支持多张 640×480 24-bit BMP 自动扫描与加载，SDRAM 双缓冲无缝切换。
- **HDMI 1.4b 视频输出**：640×480@60Hz，经开发板 `HDMI_B` 接口上屏。
- **OSD 叠加**：状态栏、时间戳、滚动字幕（颐和园导览文案）。
- **转场特效**：直接切换 / 淡入淡出 / 横向黑幕 / 幕布开合四档（SW1+SW2 组合）。
- **音频播放**：HDMI 音频（I2S），支持音阶 tone、片内 ROM、SD 卡流式三档音源。
- **半对数频谱可视化**：80 柱频谱（前 32 柱线性 + 后 48 柱对数分箱），音乐能量按人耳对数特性铺开。

---

## 二、硬件平台

| 项目 | 说明 |
|---|---|
| 开发板 | 康芯 **HX4S20** |
| 主控 FPGA | 安路 **EG4S20BG256**（4 输入 LUT 架构，29 个 DSP） |
| IDE | Tang Dynasty（TD） |
| 显示 | HDMI_B 接口 → 显示器 |
| 存储 | TF 卡（FAT32，BMP 图片） |
| 缓存 | SDRAM（`sdr_as_ram` IP） |

### 关键引脚映射

| 实物丝印 | FPGA 引脚 | 代码端口 | 用途 |
|---|---|---|---|
| KEY01 | A2 | `rst_n` | 复位 |
| KEY02 | B2 | `key1` | 手动切下一张图 |
| KEY04 | C1 | `key2` | 自动轮播 开 / 关 |
| SW1 | C8 | `sw1` | 转场模式低位 |
| SW2 | C7 | `sw2` | 转场模式高位 |
| SW3 | C6 | `sw3` | 字幕文案选择 |
| SW4 | C5 | `sw4` | 音频总开关（拨上=开） |

> ⚠️ 代码端口名与实物丝印错位：代码 `key1` 接实物 KEY02、`key2` 接实物 KEY04。
> ⚠️ TF 卡必须**断电插拔**，带电热插拔会导致 SD 初始化失败。

---

## 三、目录结构

```
r41/
├── src/
│   ├── user_source/               # 核心源码
│   │   ├── hdl_source/            # Verilog/VHDL 逻辑
│   │   │   ├── SD/                # SD 卡读取、帧缓存、时序
│   │   │   ├── audio/             # FFT 频谱引擎
│   │   │   ├── IP/                # FIFO、SDRAM、PLL 等 IP 封装
│   │   │   ├── rom/               # I2S ROM 播放器
│   │   │   └── top_tf_hdmi_audio.v  # 顶层模块
│   │   ├── constraints_source/    # 引脚约束 pin.adc、时序 sdc
│   │   ├── ip_source/             # PLL IP
│   │   └── python/                # 字模生成等辅助脚本
│   ├── td_phy/                    # 布线脚本（flow_seed7.tcl）
│   ├── td_probe/                  # 综合脚本
│   └── td_project/al_ip/          # PLL、音频 ROM 等 IP
├── doc/
│   ├── TF卡图片_颐和园/           # 演示图片（BMP + 源图 + 打包脚本）
│   ├── convert/                   # 图片转换 / SD 卡同步工具
│   └── *.md                       # 设计说明文档
├── verification/                  # 版本归档与验证
└── 音频可视化/                    # 音频频谱效果图
```

---

## 四、编译与烧录

### 综合（opt_gate）

```bash
cd src/td_probe
td_commands_prompt.exe D:/TD/doc/scripts/DefaultFlow.tcl < /dev/null
```

### 布线（place & route）

```bash
cd src/td_phy
td_commands_prompt.exe flow_seed7.tcl < /dev/null
```

> ⚠️ 布线**必须用 seed 7**（`flow_seed7.tcl`），默认 seed 8 在 `sd_card_clk`（100MHz）组产生时序违例。

### 下载

改代码 → Run（只编译）→ BitWriter（下载）→ 观察板卡。

---

## 五、TF 卡图片要求

```
格式：BMP（不能把 PNG/JPG 直接改后缀）
分辨率：640 × 480
颜色：24-bit RGB
压缩：非压缩
```

推荐使用 `doc/convert/` 下的辅助脚本：

- `convert_images_to_bmp.py` —— 一键将 JPG/PNG/WebP 批量转换为符合 FPGA 要求的 BMP。
- `sync_to_sd.py` —— SD 卡一键安全同步（自动清理旧图片物理扇区残留，防止读到旧图）。

---

## 六、演示图片（颐和园）

8 张颐和园风景图，位于 `doc/TF卡图片_颐和园/`：

- `有名字1/`、`有名字2/`、`椭圆羽化无名字/` —— 三种风格的 640×480 BMP（带景点名 / 带名字 / 椭圆羽化）。
- `源图/` —— 原始 JPG 素材。

---

## 七、设计文档

| 文档 | 内容 |
|---|---|
| `代码说明.md` | 工程功能与最简复现说明 |
| `开发板基础信息.md` | 硬件引脚映射速查 |
| `doc/频谱分箱改动说明.md` | 半对数频谱分箱设计 |
| `doc/滚动字幕修改说明.md` | 滚动字幕字模说明 |
| `doc/调试踩坑记录.md` | 调试经验与已知问题 |

---

## 八、版本状态

- 当前源码基线：**r41**（半对数频谱分箱）
- 已上板验证：r34（TF 卡图片 + HDMI + OSD 稳定版本）
- 详见 `doc/*.md` 与 `verification/` 目录。
