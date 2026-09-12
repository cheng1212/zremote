/// 输入框 `/`（斜杠命令）`$`（技能）联想：纯 Dart，无 Flutter 依赖。
///
/// 整段输入就是一个 token（无空白）时才提示，避免句中打扰。
library;

/// 一条联想：token 含前缀（如 `/fix`、`$review`）。
class Suggestion {
  final String token;
  final String label;
  final String description;
  final bool isSkill;

  const Suggestion({
    required this.token,
    required this.label,
    required this.description,
    required this.isSkill,
  });
}

/// 根据当前输入从技能 / 斜杠命令里取前缀匹配，最多 [limit] 条。
List<Suggestion> buildSuggestions(
  String text,
  List<Map<String, dynamic>> skills,
  List<Map<String, dynamic>> commands, {
  int limit = 8,
}) {
  final t = text.trim();
  if (t.length < 2 || t.contains(RegExp(r'\s'))) return const [];
  if (!t.startsWith('/') && !t.startsWith(r'$')) return const [];
  final isSkill = t.startsWith(r'$');
  final q = t.substring(1).toLowerCase();
  if (q.isEmpty) return const [];
  final source = isSkill ? skills : commands;
  final out = <Suggestion>[];
  for (final m in source) {
    final name = tokenName(m);
    if (name.toLowerCase().startsWith(q)) {
      out.add(Suggestion(
        token: '${isSkill ? r'$' : '/'}$name',
        label: name,
        description: tokenDesc(m),
        isSkill: isSkill,
      ));
      if (out.length >= limit) break;
    }
  }
  return out;
}

/// 技能/斜杠命令的展示名：name → command → slug → id。
String tokenName(Map<String, dynamic> m) =>
    '${m['name'] ?? m['command'] ?? m['slug'] ?? m['id'] ?? ''}';

/// 技能/斜杠命令的描述：description → desc → summary。
String tokenDesc(Map<String, dynamic> m) =>
    '${m['description'] ?? m['desc'] ?? m['summary'] ?? ''}';
