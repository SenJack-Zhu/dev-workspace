# MoRead 模块系统

MoRead 内置 JavaScript 模块系统，允许通过编写 JS 文件来自定义几乎所有核心功能，无需重新编译 APK。

## 工作原理

1. 模块打包为 **.mrm 文件**（本质是 ZIP 压缩包）
2. 通过 **设置 → 模块管理 → 导入模块包** 导入，或从文件管理器直接打开 .mrm 文件
3. 导入后自动解包到 **内部存储** 专用目录（不会被文件管理器误删）
4. App 启动时自动加载所有模块并注册钩子
5. Kotlin 代码在关键位置检查钩子，有模块处理则使用模块结果

## .mrm 模块包格式

```
my-module.mrm (ZIP 格式)
  ├── manifest.json    (模块元数据，必需)
  ├── *.js             (一个或多个 JS 模块文件，至少一个)
  ├── config.json      (可选，键值对会合并到共享配置)
  └── lib/             (可选，模块需要的额外资源)
```

### manifest.json 格式

```json
{
    "name": "custom-tts",
    "displayName": "自定义 TTS",
    "version": "1.0.0",
    "author": "your-name",
    "description": "将 TTS 请求转发到自定义服务端点",
    "minAppVersion": "",
    "hooks": ["tts.synthesize"],
    "overwrite": true
}
```

## 可用钩子点

| 事件名 | 触发位置 | 参数 | 返回值 |
|--------|---------|------|--------|
| `tts.synthesize` | TTS 语音合成 | text, voice, model, provider, speed, emotion | `{ "audio": "<base64>", "mediaType": "audio/mp3" }` 或纯 base64 字符串 |
| `tts.voices` | 音色列表获取 | (无) | `[{"voiceId":"...","displayName":"...","gender":"MALE","tags":"...","providerHint":"..."}]` JSON 字符串 |
| `dialogue.segment` | 对白/旁白切分 | text | `[{"start":0,"end":48,"role":"张三","kind":"DIALOGUE","confidence":0.9}]` JSON 字符串 |
| `chunk.split` | 章节切片(RAG向量) | text | `[{"text":"...","start":0,"end":480}]` JSON 字符串 |
| `listen.sentence` | 听书句子切分 | body, maxChars | `[{"start":0,"end":48}]` JSON 字符串 |

## MoRead API (JS 端可用)

```javascript
// 注册钩子
MoRead.hook("tts.synthesize", function(params) {
    // params.text, params.voice, params.model, ...
    return JSON.stringify({ audio: base64Audio, mediaType: "audio/mp3" });
});

// HTTP 请求
var resp = MoRead.httpGet("http://localhost:8080/api", { "Authorization": "Bearer xxx" });
// resp = { status: 200, body: "...", ok: true, json: "..." }

var resp = MoRead.httpPost(url, body, "application/json", headers);

// 配置 (config.json，所有模块共享)
MoRead.configGet("tts.endpoint", "default");
MoRead.configSet("key", "value");
MoRead.configSave();

// 持久化存储 (storage.json，所有模块共享)
MoRead.storageGet("key", "default");
MoRead.storageSet("key", "value");
MoRead.storageRemove("key");

// 工具
MoRead.base64Decode(str);        // → ByteArray
MoRead.base64Encode(data);       // → String
MoRead.pcmToWav(base64, 24000); // PCM → WAV base64
MoRead.log("message");          // 写入模块日志
MoRead.getModuleDir();           // 模块目录路径
MoRead.getAppVersion();           // App 版本号
MoRead.reload();                 // 请求重新加载所有模块
```

## 安装模块

### 方式一：从文件管理器导入
1. 将 .mrm 文件放到设备上
2. 在文件管理器中点击打开 .mrm 文件
3. 选择用 MoRead 打开
4. 模块自动解包安装并重新加载

### 方式二：从设置导入
1. 打开 **设置 → 模块管理**
2. 点击 **导入模块包**
3. 选择 .mrm 或 .zip 文件
4. 模块自动解包安装并重新加载

### Root 用户直接编辑
1. 模块目录在内部存储（设置 → 模块管理 可看到路径）
2. Root 用户可直接编辑该目录下的 .js 文件
3. 在模块管理页面点 **重新加载** 即可生效

### 非 Root 用户更新模块
1. 改完 .js 文件
2. 和 manifest.json 一起打包为 ZIP（改扩展名为 .mrm）
3. 重新导入（会覆盖同名旧模块包）

## 导出模块

### 导出单个包
在 **设置 → 模块管理** 中，点击模块包右侧的 **下载图标**，
选择保存位置，模块会打包为 .mrm 文件。

### 导出全部模块
在模块管理页点击 **导出全部模块**，所有已安装的模块包
会打包成一个 .mrm 文件。

### 在 App 内查看和编辑源码
在模块管理页中，点击模块包右侧的 **代码图标** 可查看
包内所有文件列表，点击文件可查看源码，点击编辑按钮
可直接在 App 内修改并保存。

## 示例模块

- `custom-tts.js` — 自定义 TTS 端点（OpenAI 兼容格式）
- `edge-tts-free.js` — 免费微软 Edge TTS（需本地 WebSocket 桥接）
- `custom-segmenter.js` — 自定义对白切分规则
- `multitts-bridge.js` — MultiTTS 服务器桥接

## 配置

编辑 .mrm 包中的 `config.json`，导入后值会合并到共享配置：

```json
{
    "tts.endpoint": "http://localhost:8080",
    "tts.apiKey": "",
    "tts.model": "cosyvoice-v1",
    "tts.defaultVoice": "alloy",
    "edgeTts.bridgeUrl": "http://localhost:9880",
    "edgeTts.voice": "zh-CN-XiaoxiaoNeural"
}
```

## 模块加载顺序

模块按包名→文件名的字母顺序加载。如需控制加载顺序，在包名前加数字前缀
（如 `01-tts.mrm`, `02-segmenter.mrm`）。
