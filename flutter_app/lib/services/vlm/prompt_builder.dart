enum PromptLocationContext {
  unknown,
  indoor,
  outdoor,
}

class PromptBuilder {
  const PromptBuilder();

  static const String _baseCore =
      'You are a walking assistant for a visually impaired person. '
      'Describe the one or two most useful clearly visible objects ahead that matter for safe walking. '
      'If the path is open, still mention visible landmarks or side objects that help orientation. '
      'Include position whenever clearly visible. '
      'Include motion only if clearly visible. ';

  static const String _dualHazardRule =
      'If two hazards are clearly visible, mention both briefly in the same '
      'sentence. ';

  static const String _indoorClause =
      'If indoors, hazards that may be relevant include doors, stairs, '
      'railings, steps, or low obstacles. ';

  static const String _outdoorClause =
      'If outdoors, hazards that may be relevant include pedestrians, poles, '
      'curbs, steps, or uneven surfaces. '
      'Mention moving vehicles only if clearly visible. ';

  static const String _fallbackBlock =
      'If the scene is too dark to see, say exactly: '
      '"Too dark to see clearly." '
      'If the scene is visible but you cannot identify what is ahead, say '
      'exactly: "Scene unclear, cannot confirm what is ahead." '
      'Only if no meaningful object, obstacle, or landmark position can be '
      'identified, say exactly: '
      '"The path ahead is clear." ';

  static const String _outputRule =
      'Use plain natural language. Keep the answer to one short factual '
      'sentence.';

  String build({PromptLocationContext context = PromptLocationContext.unknown}) {
    final parts = <String>[
      _baseCore,
      if (context == PromptLocationContext.indoor) _indoorClause,
      if (context == PromptLocationContext.outdoor) _outdoorClause,
      _dualHazardRule,
      _fallbackBlock,
      _outputRule,
    ];

    return parts.join('');
  }
}
