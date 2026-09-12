# zremote Git 工作流

> 适用：单人/小团队 Flutter 项目。轻量级 Git Flow，不搞过度设计。

---

## 分支模型（两主分支 + 短命主题分支）

```
master  ──────●──────●──────●──────●──────  仅打 tag、合并 release/hotfix
              \      \      \      \
develop  ──────●──●───●──●───●──●───●────  日常集成，feature/fix/chore 合并目标
                \  \    \    \    \
feature/xxx      ●  ●    ●    ●
fix/yyy             ●    ●    ●
chore/zzz                  ●    ●
```

| 分支 | 来源 | 合并目标 | 保护 |
|---|---|---|---|
| `master` | `develop` / `release/*` / `hotfix/*` | — | 直推禁止，只走 PR/合并提交 |
| `develop` | `feature/*` / `fix/*` / `chore/*` | — | 直推允许（本项目单人） |
| `feature/*` | `develop` | `develop` | 完成删分支 |
| `fix/*` | `develop` | `develop` | 完成删分支 |
| `chore/*` | `develop` | `develop` | 完成删分支 |
| `release/vX.Y.Z` | `develop` | `master` + `develop` | 打 tag 后删 |
| `hotfix/vX.Y.Z` | `master` | `master` + `develop` | 打 tag 后删 |

---

## 命名规范

```
feature/<短动词>-<模块/功能>   # 新功能
fix/<短动词>-<模块/现象>       # Bug 修复
chore/<动作>-<对象>            # 重构、依赖升级、文档、配置
release/v<版本号>              # 发布准备
hotfix/v<版本号>               # 线上紧急修复
```

示例：
- `feature/add-scan-pair`
- `fix/chat-echo-duplicate`
- `chore/upgrade-flutter-3.24`
- `release/v1.2.0`

---

## 日常操作（单人模式，可直推 develop）

### 起新需求
```bash
git checkout develop
git pull
git checkout -b feature/add-scan-pair
# 开发...
git add -A && git commit -m "feat: 添加二维码扫码配对"
git checkout develop
git merge --no-ff feature/add-scan-pair  # 保留特性分支历史
git branch -d feature/add-scan-pair
```

### 改 Bug
```bash
git checkout -b fix/chat-echo-duplicate develop
# 修复...
git commit -m "fix: 回显去重逻辑修正，防止重复气泡"
git checkout develop && git merge --no-ff fix/chat-echo-duplicate
git branch -d fix/chat-echo-duplicate
```

### 重构/杂活
```bash
git checkout -b chore/upgrade-deps develop
# 搞...
git commit -m "chore: 升级 flutter_markdown 到 plus 版本"
git checkout develop && git merge --no-ff chore/upgrade-deps
git branch -d chore/upgrade-deps
```

### 发版
```bash
git checkout -b release/v1.2.0 develop
# 只改版本号、 changelog、必要的微调
git commit -m "chore: release v1.2.0"
git checkout master && git merge --no-ff release/v1.2.0
git tag -a v1.2.0 -m "Release v1.2.0"
git checkout develop && git merge --no-ff release/v1.2.0
git branch -d release/v1.2.0
git push --tags
```

### 热修
```bash
git checkout -b hotfix/v1.2.1 master
# 紧急修...
git commit -m "fix: 修复崩溃"
git checkout master && git merge --no-ff hotfix/v1.2.1
git tag -a v1.2.1 -m "Hotfix v1.2.1"
git checkout develop && git merge --no-ff hotfix/v1.2.1
git branch -d hotfix/v1.2.1
git push --tags
```

---

## 提交信息规范（Conventional Commits 简版）

```
<type>(<scope>): <一句话摘要>

[可选：正文说明动机/影响]
```

| type | 含义 | 举例 |
|---|---|---|
| `feat` | 新功能 | `feat(chat): 发送状态机补全` |
| `fix` | Bug 修复 | `fix(chat): 回显去重按 ref 匹配` |
| `refactor` | 重构（无行为变更） | `refactor(protocol): FragmentAssembler 共用` |
| `chore` | 杂活（依赖、配置、文档） | `chore: 升级 file_picker 8.3.7` |
| `perf` | 性能优化 | `perf(chat): 流式 delta 合帧 80ms` |
| `docs` | 文档 | `docs: 补充 API.md 协议清单` |
| `test` | 测试 | `test(protocol): 增加 CAS 重试回归测试` |
| `style` | 格式化/风格 | `style: dart format 全量对齐` |

**Scope 常用**：`chat` `task` `pair` `protocol` `relay` `conversation` `ui` `deps` `build` `ci`

---

## 版本号策略

- `MAJOR.MINOR.PATCH`（语义化版本）
- `pubspec.yaml` 的 `version: 1.2.0+123`（版本名+构建号）
- 每次 `release/*` 分支创建时同步改这两个地方

---

## 保护规则（本项目可选）

- `master`：GitHub/Bitbucket 设置 branch protection，要求 PR + CI 通过
- `develop`：单人可直推；多人时同理保护
- 提交前跑：`flutter analyze` + `flutter test`（见 `.github/workflows/ci.yml` 若后续加）

---

## 当前状态（2026-09-05 建立）

```
master (c9bb879) ── 最新稳定代码，已含所有近期重构
develop (c9bb879) ── 同步 master，下一个 feature 从此分出
```

下一步：按需求从 `develop` 拉 `feature/xxx` 开工。
<tool_call>
<function=Bash>
<parameter=command>
cd /d/tools/zremote && git log --oneline -1 && flutter analyze 2>&1 | tail -1 && flutter test 2>&1 | tail -2