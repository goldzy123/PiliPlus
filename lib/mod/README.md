# `lib/mod/` — PiliPlus mod 的独立代码区

这个目录**只放 mod 自己的代码**，目标是：官方版本升级后能低成本 rebase。

## 目录

| 路径 | 作用 |
| --- | --- |
| `speed/` | 快捷倍速：`speed_buttons.dart`（两个倍速按钮，点按切倍速 / 长按设 UP 强制倍速；**按 `isFullScreen` 决定放控制条还是 UP 行**）、`playback_speed_service.dart`（按视频/UP/规则/AI 记忆倍速）、`speed_auto_set.dart`（「智能倍速」设置页，含两个按钮取值） |
| `card_date/` | 卡片发布日期：`card_date.dart`。app 端推荐接口**完全不返回日期**，这里按 bvid 补拉 `/x/web-interface/view` 并长期缓存 |
| `settings/` | 设置项收藏：`setting_favorites.dart`、`setting_refs.dart`、`favorite_settings_page.dart` |
| `lan_sync/` | 局域网接力：`lan_sync_service.dart`、`models.dart`、`panel.dart` |
| `local_video/` | 本地视频 tab：`controller.dart`（选片/持久化/打开）、`view.dart` |
| `settings_sync/` | 配置同步：`sync_service.dart`（采集/应用/上传/拉取/自动同步）、`view.dart` |
| `../mod/server/` | 配置同步的服务端（Mac 常驻的小 HTTP 服务，零依赖 Node） |

## 合并策略（重要）

对**官方文件**的改动一律满足两条：

1. **最小 hunk**：能一行调用就别写十行；逻辑都放进 `lib/mod/`。
2. **统一标记**：每处都带 `// [MOD-HOOK:<id>]` 注释，`grep -rn "MOD-HOOK" lib/` 就是完整的改动清单。

当前全部 hook（15 处）：

| hook id | 文件 | 行 | 做什么 |
| --- | --- | --- | --- |
| `speed-buttons` | `plugin/pl_player/view/view.dart` | ~946 | 全屏时把倍速按钮并进控制条同一行（一行调用） |
| `speed-buttons` | `pages/video/introduction/ugc/view.dart` | ~741 | 非全屏时把倍速按钮插在 UP 名与关注按钮之间（一行调用） |
| `card-date` | `common/widgets/video_card/video_card_v.dart` | ~242 | 尾部整块交给 `ModCardDate.statTrailing`（一行） |
| `card-date` | `models/home/rcmd/result.dart` | ~54 | 顺手解析 app 接口的 pubdate（现在接口没有，留作兼容） |
| `local-video` | `models/common/nav_bar_config.dart` | ~28 | 新增 `NavigationBarType.local`（**必须追加在枚举末尾**） |
| `local-video` | `pages/video/controller.dart` | 106 / 335 / 346 / 428 / 810 | 本地视频字段、进度、跳过分段、onInit 分支、FileSource.local |
| `local-video` | `plugin/pl_player/models/data_source.dart` | ~41 | `FileSource.local(path)` 命名构造 |
| `local-video` | `pages/video/introduction/local/controller.dart` | 53 / 138 | 本地视频跳过下载列表逻辑、空列表守卫 |
| `settings-sync` | `main.dart` | ~143 | 启动时初始化同步服务 |
| `settings-sync` | `pages/setting/view.dart` | ~188 | 设置页加「配置同步」入口 |
| `settings-sync` | `router/app_pages.dart` | ~130 | 注册 `/settingsSync` 路由 |
| （收藏/智能倍速） | `pages/setting/common_setting.dart`、`pages/setting/models/model.dart`、`router/app_pages.dart`、`pages/video/widgets/header_control.dart`、`main.dart`、`utils/storage_key.dart`、`utils/storage_pref.dart` | — | 第一轮 mod 的 hook，改动同样很小 |

## 升级官方版本时怎么做

```bash
# 1) 拉官方最新
git fetch upstream main

# 2) 把 mod 的提交 rebase 到官方最新
git rebase upstream/main          # 或者：git rebase --onto upstream/main <旧基> mod-2.1.6

# 3) 冲突时按 hook 清单逐个看
grep -rn "MOD-HOOK" lib/          # 列出全部改动点
# 冲突基本只会出现在上面这张表里的文件，按 hook 语义重放即可

# 4) 验证
flutter analyze                   # 必须 0 error
```

`_dsh/sync_upstream.sh` 把上面几步串成了一个脚本（会自动列出冲突文件与 hook 清单）。

## 与官方设置项的隔离

mod 自己的持久化键统一加前缀，避免和官方键冲突：

- `mod_sync_*`（配置同步）
- `mod_local_videos`（本地视频列表）

设置项收藏用的是官方 `setting` box 里的 `favoriteSettingIds` / `recentSettingIds`。

## 编译

见仓库根目录 `_dsh/mod-2.1.6-build-notes.md`（含 Flutter SDK 打补丁的完整流程）。
