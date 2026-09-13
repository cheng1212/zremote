# manual 探针（25 个）

逆向协议的**活文档**：每个探针直连真实桌面端验证一段协议行为，一个不删。

## 怎么跑

```bash
# 单个探针（需要对应前置条件，见各文件头部注释）
ZREMOTE_PROBE_LINK='<配对链接>' flutter test test/manual/manual_xxx_test.dart

# 跑全部探针
ZREMOTE_PROBE_LINK='<配对链接>' flutter test --tags manual test/manual/
```

- `ZREMOTE_PROBE_LINK`：配对链接（sid+hash 凭据，从桌面端生成），缺失时探针自动 skip。
- 默认 `flutter test` **不跑**本目录（`dart_test.yaml` 按标签 `manual` 排除）。
- 探针写死超时/轮询参数属有意为之，改之前先读文件头注释的契约来源。

## 清单速览

| 主题 | 探针 |
|---|---|
| 历史窗口/行拉取 | manual_history_window、manual_rowsrange_exhaust |
| 交互（AskUserQuestion） | manual_interaction、manual_interaction_history、manual_interaction_resolve |
| 模型/思考等级 | manual_model_watch、manual_setmodel、manual_glm_switch、manual_thought_levels |
| 自动化/定时 | manual_automation_roundtrip、manual_automation_runs、manual_automations |
| 引导/通知/用量 | manual_bootstrap_tasks、manual_global_notify、manual_usage、manual_usage_stats |
| 归档/清理/分叉 | manual_archive、manual_cleanup、manual_fork |
| 计划/服务清单/运行时切换 | manual_plan、manual_server_list_audit、manual_switch_runtime、manual_ws_default_model、manual_relay |
