import 'package:app/services/vlm/prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const builder = PromptBuilder();

  test('builds unknown prompt without a location clause', () {
    expect(
      builder.build(),
      'You are a walking assistant for a visually impaired person. '
      'Describe the one or two most useful clearly visible objects ahead that matter for safe walking. '
      'If the path is open, still mention visible landmarks or side objects that help orientation. '
      'Include position whenever clearly visible. '
      'Include motion only if clearly visible. '
      'If two hazards are clearly visible, mention both briefly in the same '
      'sentence. '
      'If the scene is too dark to see, say exactly: '
      '"Too dark to see clearly." '
      'If the scene is visible but you cannot identify what is ahead, say '
      'exactly: "Scene unclear, cannot confirm what is ahead." '
      'Only if no meaningful object, obstacle, or landmark position can be '
      'identified, say exactly: '
      '"The path ahead is clear." '
      'Use plain natural language. Keep the answer to one short factual '
      'sentence.',
    );
  });

  test('builds indoor prompt with the indoor clause only', () {
    expect(
      builder.build(context: PromptLocationContext.indoor),
      'You are a walking assistant for a visually impaired person. '
      'Describe the one or two most useful clearly visible objects ahead that matter for safe walking. '
      'If the path is open, still mention visible landmarks or side objects that help orientation. '
      'Include position whenever clearly visible. '
      'Include motion only if clearly visible. '
      'If indoors, hazards that may be relevant include doors, stairs, '
      'railings, steps, or low obstacles. '
      'If two hazards are clearly visible, mention both briefly in the same '
      'sentence. '
      'If the scene is too dark to see, say exactly: '
      '"Too dark to see clearly." '
      'If the scene is visible but you cannot identify what is ahead, say '
      'exactly: "Scene unclear, cannot confirm what is ahead." '
      'Only if no meaningful object, obstacle, or landmark position can be '
      'identified, say exactly: '
      '"The path ahead is clear." '
      'Use plain natural language. Keep the answer to one short factual '
      'sentence.',
    );
  });

  test('builds outdoor prompt with the outdoor clause only', () {
    expect(
      builder.build(context: PromptLocationContext.outdoor),
      'You are a walking assistant for a visually impaired person. '
      'Describe the one or two most useful clearly visible objects ahead that matter for safe walking. '
      'If the path is open, still mention visible landmarks or side objects that help orientation. '
      'Include position whenever clearly visible. '
      'Include motion only if clearly visible. '
      'If outdoors, hazards that may be relevant include pedestrians, poles, '
      'curbs, steps, or uneven surfaces. '
      'Mention moving vehicles only if clearly visible. '
      'If two hazards are clearly visible, mention both briefly in the same '
      'sentence. '
      'If the scene is too dark to see, say exactly: '
      '"Too dark to see clearly." '
      'If the scene is visible but you cannot identify what is ahead, say '
      'exactly: "Scene unclear, cannot confirm what is ahead." '
      'Only if no meaningful object, obstacle, or landmark position can be '
      'identified, say exactly: '
      '"The path ahead is clear." '
      'Use plain natural language. Keep the answer to one short factual '
      'sentence.',
    );
  });
}
