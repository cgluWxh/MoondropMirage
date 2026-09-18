# MOONDROP MIRAGE 官方 App 静态协议记录

## 样本

- APK：`android-release.apk`
- SHA-256：`04756b49acfea523758d86101c96c1824b7b209ae3a8836c07837088e795d2d5`
- 工具：JADX 1.5.5
- 反编译输出：`official-app-jadx/`

## GAIA PDU

官方 App 内置 Qualcomm GAIA/QTiL SDK。V3 PDU 为：

```text
[vendor:2 BE][commandValue:2 BE][payload]
commandValue = (feature << 9) | (type << 7) | command
vendor = 0x001D
type: 0=COMMAND, 1=NOTIFICATION, 2=RESPONSE
```

MIRAGE 当前已验证通过 Classic Bluetooth RFCOMM/SPP 通道 1 通信，外层使用 GAIA V4：

```text
FF 04 flags payloadLength PDU
```

## 已验证命令

| 功能 | Feature | GET | SET | Payload |
|---|---:|---:|---:|---|
| 电量 | `0x0D` | `1` | — | GET `[01 02]`；回包为 `(id, level)` 对 |
| DAC 增益 | `0x0F` | `1` | `2` | MIRAGE 实测 `00=高, 01=中, 02=低` |
| ANC V2 | `0x20` | `3` | `4` | `00=关, 01=自适应, 02=通透, 03=抗风, 04=基础降噪`（仍需逐档验证 MIRAGE） |

MIRAGE 真机能力响应：

```text
00 00 02 01 01 05 01 0D 01 0E 01 0F 01 10 01 13 01 14 01 16 01 20 01
```

确认支持：Basic v2、Earbud、EQ、Battery、Voice、DAC Gain、Codec、LED、One-bring-two、Touch V2、ANC V2（其余为 v1）。

电量回包的 level 只有 `0...100` 是百分比。`FF` 是不可用/未上报哨兵值，例如充电盒 `03 FF`。

## 官方 SDK 确认的一拖二协议

Feature 为 `0x14`（`ONEBRINGTWO`）：

| Command | 含义 | Payload/回包 |
|---:|---|---|
| `1` | 查询一拖二开关 | 回包首字节 `0/1` |
| `2` | 设置一拖二开关 | `0=关, 1=开` |
| `3` | 查询超时 | 回包首字节 timeout |
| `4` | 设置超时 | timeout |
| `5` | 查询当前设备 | `[status/deviceNum][MAC 6B][UTF-8 name]` |
| `6` | 查询下一设备 | `[status/deviceNum][MAC 6B][UTF-8 name]` |
| `7` | 断开指定设备 | 官方 Repository 传入字节数组；预计为设备标识/MAC，尚未真机验证 |

主要证据：

- `V3OnebringtwoPlugin.java`：完整 command 表及收发逻辑。
- `DeviceInfo.java`：设备回包布局。
- `OneBringTwoRepositoryImpl.java`：开关、超时、设备查询和断开入口。
- `DeviceInfoHandler.java`：官方 Flutter UI 确实调用这些 Repository，并非未使用 SDK 残留。

另有旧式 Feature `0x07`（`HANDSET_SERVICE`）cmd `0`，payload `0/1` 表示 single/multipoint；但 MIRAGE 应先以能力查询结果决定走 `0x14` 还是 `0x07`。

MIRAGE 已真机确认 Feature `0x14`：GET STATE 返回 `01`（开启）。cmd `5/6` 分别返回两台已连接主机。两份回包首字节均为 `01`，所以该字段更可能是状态/有效标志，或设备编号并不保证唯一；客户端应以命令 `5/6` 区分“当前/下一”槽位，不应依赖该字节作为唯一编号。

### 双设备断开与超时

- 断开指定设备：Feature `0x14` / cmd `7`，payload 是目标设备的 6 字节 MAC，按显示顺序发送。例如 `54:74:E2:D8:A6:50` → `54 74 E2 D8 A6 50`。
- 超时查询/设置：cmd `3/4`，单字节枚举。
- 官方 Flutter AOT 中存在五个本地化键 `double_device_timeout_0...4`，以及 `关闭 / 5 min / 10 min / 30 min / 60 min` 五个 UI 文案，并以 `timeoutIndex` 传给 native。
- 高可信候选映射：`0=关闭, 1=5 分钟, 2=10 分钟, 3=30 分钟, 4=60 分钟`。需要用官方 App 改动一次设置并分别读取 cmd `3`，完成最终真机确认。

## ANC 按键循环配置

MIRAGE 使用 ANC V2 Feature `0x20`：

```text
GET cmd=41 (0x29)
SET cmd=42 (0x2A), payload 固定 5 字节
[STATE][ANC_ON][ANC_OFF][TP][ORDER]
```

前四个字段是动作开关：`0=DISABLED, 1=ENABLED`；官方解析器也把 `FF` 当作 `DISABLED`。`TP` 表示 Transparent。

`ORDER` 枚举：

| 值 | 循环顺序 |
|---:|---|
| 0 | ANC_ON → ANC_OFF → TP |
| 1 | ANC_OFF → ANC_ON → TP |
| 2 | TP → ANC_ON → ANC_OFF |
| 3 | ANC_ON → TP → ANC_OFF |
| 4 | ANC_OFF → TP → ANC_ON |
| 5 | TP → ANC_OFF → ANC_ON |

官方 App 的设置接口字段名就是 `STATE / ANC_ON / ANC_OFF / TP / ORDER`。这套配置描述哪些档位参与按键循环以及三种基础模式的循环顺序；自适应、抗风和基础降噪的设备模式值不直接出现在该五字节配置中。

## 耳机提示音

Feature `0x0E`（VOICE）：

```text
GET cmd=1
SET cmd=2
新版 payload: [enabled][volume][voiceIndex]
```

- `enabled`：`0/1`，提示音关闭/开启。
- `volume`：单字节音量；Java 层未限制范围，实际 UI 范围需通过 MIRAGE GET 回包和官方 UI 验证。
- `voiceIndex`：提示音语言/音色索引。
- 旧固件可能只返回 1～2 字节，官方 SDK 会把它当作旧版“仅 voice index”格式。

官方 App SET 明确按 `[voiceEnabled, voiceVolume, voiceIndex]` 发送，切换开关或音量时应先 GET 并保留未修改字段。

## LHDC

Feature `0x10`（CODEC_TYPE）：

```text
LHDC GET cmd=5
LHDC SET cmd=6, payload [0/1]
```

官方通用 SDK 同时定义 LC3 `1/3`、LDAC `2/4`、LHDC `5/6`，但这不表示 MIRAGE 支持全部三种；产品 UI/真机回包决定实际可用项。AAC/SBC 是基础 A2DP codec，不在这组 GAIA 开关命令中。MIRAGE 应只验证 LHDC `5/6`。

## EQ / Music Processing（仅 SDK 静态分析）

MIRAGE 的能力表声明 Feature `0x05` v1。官方 App 使用
`V3MusicProcessingPlugin`，命令表如下；本节仅记录 APK 内 SDK 的实现，**没有进行 CLI 实现或 MIRAGE 真机验证**。

| Command | 方向 | 含义 | Payload / response data |
|---:|---|---|---|
| `0` | GET | 查询 EQ 是否存在 | 回包 `[state]`：`0=NOT_PRESENT, 1=PRESENT` |
| `1` | GET | 查询可用预设 | 回包 `[count][preset0]...[presetN-1]` |
| `2` | GET | 查询当前预设 | 回包 `[presetValue]` |
| `3` | SET | 选择预设 | `[presetValue]` |
| `4` | GET | 查询用户 EQ 频段数 | 回包 `[bandCount]` |
| `5` | GET | 读取用户 EQ 频段 | `[startBand][endBand]`；回包见下文 |
| `6` | SET | 写入用户 EQ 配置 | 通常为 `[startBand][endBand]` 后跟每段 7 字节；厂商变体见下文 |
| `7` | SET | 写入/保存用户 EQ | SDK 的 Airoha storage 路径使用，格式见下文 |
| `8` | SET | 设置 NV ID | SDK 固定发送 `[2C E4]`，标记为 Airoha 专用路径 |

预设值不是 UI 列表下标，而是设备返回的实际 `presetValue`：

- `0`：EQ OFF。
- `63 (0x3F)`：USER，自定义 EQ。
- 其他值：`PRE_SET`，SDK 不定义每个数值对应的具体曲线名称；官方 App 会在可用预设列表中查找值，再转换成 UI 下标。

### 用户 EQ 标准数据结构

cmd `5` 请求范围：

```text
[startBand:u8][endBand:u8]       # 两端都包含
```

标准回包：

```text
[startBand:u8][endBand:u8][Band × N]
N = endBand - startBand + 1
Band = [frequency:u16][q:u16][filter:u8][gain:s16]   # 共 7 字节
```

SDK 的 `BandInfo` 解码规则：

- `frequency`：无符号 16 位整数，直接作为频率值。
- `Q = qRaw / 4096.0`。
- `gain(dB) = gainRaw / 60.0`，`gainRaw` 为有符号 16 位。
- 多字节字段由 SDK 的 `BytesUtils`/native helper 编解码；仅凭反编译 Java 未独立确认字节序，实际实现前应结合抓包确认。
- SDK 根据最大 GAIA payload 自动拆分 cmd `5` 的读取范围；App Repository 还会先读 `0...6`，再按设备报告的总频段数读取尾部，说明频段数可能超过 7。

`filter` 枚举：

| 值 | 类型 | 值 | 类型 |
|---:|---|---:|---|
| `0` | BYPASS | `7` | LOW_PASS_2 |
| `1` | LOW_PASS_1 | `8` | HIGH_PASS_2 |
| `2` | HIGH_PASS_1 | `9` | ALL_PASS_2 |
| `3` | ALL_PASS_1 | `10` | LOW_SHELF_2 |
| `4` | LOW_SHELF_1 | `11` | HIGH_SHELF_2 |
| `5` | HIGH_SHELF_1 | `12` | TILT_2 |
| `6` | TILT_1 | `13` | PARAMETRIC_EQUALIZER |

标准 cmd `6` 写入与标准 cmd `5` 回包采用相同的范围头和每段 7 字节结构。JADX 对
`setUserSetGains` 的局部 offset 表达式恢复明显异常、存在互相覆盖，因此这里以
`BandInfo` 解码结构和另外两条完整编码路径为准，不把该反编译方法里的具体 offset 当作可靠证据。

### SDK 中的厂商兼容分支

这些代码存在于官方 App 的通用 SDK 中，不能据此认定 MIRAGE 使用对应芯片或格式：

- **Bluetrum cmd `6`**：`[start][end][totalGain:s16][Band × N]`，头部 4 字节；每个 Band 仍为
  `[frequency:s16][q:s16][filter:u8][gain:s16]`。`totalGain` 与 band gain 都按 `×60` 编码，Q 按 `×4096` 编码。SDK 每包最多写 7 段。cmd `5` 回包若长度满足 `4 + 7N`，解析器会把它识别为该格式，并从 offset 4 开始读 Band。
- **Airoha cmd `6`**：App 可把上层提供的一整块 PEQ 二进制数据按每块最多 63 字节切分；每个 GAIA payload 为 `[chunkIndex][chunkData，固定缓冲区共 64B]`。数据块内部还有 TLV/系数格式，但当前 Java 调用只透传上层生成的数据，无法从此处完整恢复其内容定义。
- **Airoha cmd `7`**：SDK 编码为
  `[start][end][totalGain:s16][Band × N]`，Band 字段与上面的 7 字节形式一致，用于 storage/save 路径。
- **Airoha cmd `8`**：固定 payload `[2C E4]`，方法名为 `setAirohaNvId`。

### EQ 通知

Feature `0x05` 还定义三种 notification command：

| Notification command | 含义 | Data |
|---:|---|---|
| `0` | EQ state 改变 | `[state]` |
| `1` | 当前预设改变 | `[presetValue]` |
| `2` | 用户 EQ 频段改变 | `[count][bandId0]...[bandIdN-1]` |

主要静态证据：

- `core/gaia/qtil/plugins/v3/V3MusicProcessingPlugin.java`：Feature 命令、通知和厂商分支。
- `core/gaia/qtil/data/BandInfo.java`、`Filter.java`、`PreSet.java`、`PreSetType.java`：字段缩放和枚举。
- `repository/musicprocessing/MusicProcessingRepositoryImpl.java`：读取顺序、分段聚合和写入入口。
- `native/handlers/EqHandler.java`：官方 Flutter 层实际调用 `getEQState/getPEQ/setEQ/setPEQ/setBluetrumPEQ`。

## 其他官方 SDK 命令

以下命令存在于官方 App，但是否由 MIRAGE 固件支持必须以 `BASIC.GET_SUPPORTED_FEATURES` 回包为准：

- LED `0x13`：GET `1`，SET `2`，payload `0/1`。
- Codec `0x10`：LC3 GET/SET `1/3`，LDAC `2/4`，LHDC `5/6`。
- EQ `0x05`：详见上一节；状态、预设、参数 EQ、通知及厂商兼容路径均已静态整理。
- Touch V2 `0x16`：默认动作 GET `1`，当前动作 GET `2`，SET `3`；payload 结构需继续解析。
- 左右声道 `0x1E`：GET `1`，SET `2`。
- 自动关机/待机 `0x19`：关机超时 GET/SET `1/2`，待机超时 `3/4`。
- 动态低音 `0x1B`、空间音频 `0x12`、电源控制 `0x18` 等也有 Repository/Plugin。

## CLI

`moondrop_mirage.swift` / `moondrop-mirage` 当前提供：

```text
features
battery
anc get|set
anc cycle get|set
gain get|set
voice get|on|off|volume|index
lhdc get|on|off
led get|on|off
multipoint get|on|off
multipoint devices
multipoint timeout|get/set
multipoint disconnect MAC
```

写入策略：提示音的开关、音量和 index 是同一个三字节 SET payload，但 CLI 每次先 GET 当前配置，只替换用户指定的一个字段，再原样保留另外两个字段，避免联动修改。

先运行 `features`，只对设备明确报告的 Feature 开展后续真机测试。
