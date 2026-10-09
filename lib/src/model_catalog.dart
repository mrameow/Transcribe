/// The speech-recognition models the app knows how to download and run.
///
/// All models come from the sherpa-onnx project
/// (https://github.com/k2-fsa/sherpa-onnx) and run fully offline once
/// downloaded.
library;

enum EngineKind {
  /// Low-latency streaming transducer: words appear while people speak.
  streaming,

  /// OpenAI Whisper, run sentence-by-sentence using voice activity detection.
  /// Slower but multilingual and usually more accurate, with punctuation.
  whisper,

  /// NVIDIA Parakeet TDT (English), also run sentence-by-sentence. Very
  /// accurate and fast, with punctuation and capitalisation.
  parakeet,
}

class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.title,
    required this.description,
    required this.kind,
    required this.downloadMb,
    this.sentenceCase = false,
    this.badge,
  });

  /// Archive / folder name on the sherpa-onnx release page.
  final String id;
  final String title;
  final String description;
  final EngineKind kind;
  final int downloadMb;

  /// The model outputs UPPER CASE text without punctuation; convert it to
  /// sentence case for readability.
  final bool sentenceCase;

  /// Short highlight shown on the model card, e.g. "Best for Malay".
  final String? badge;

  /// Whether the user can choose languages for this model.
  bool get multilingual => kind == EngineKind.whisper;

  /// Needs the voice activity detection model as well.
  bool get needsVad => kind != EngineKind.streaming;

  String get url => '$_releaseBase/$id.tar.bz2';
}

const _releaseBase =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

/// Silero voice-activity-detection model, needed by Whisper models.
const vadFileName = 'silero_vad.onnx';
const vadUrl = '$_releaseBase/$vadFileName';

const modelCatalog = <ModelInfo>[
  ModelInfo(
    id: 'sherpa-onnx-whisper-turbo',
    title: 'Whisper Turbo · Multilingual',
    description:
        'Most accurate for Malay, English and Malay–English mixing (99 '
        'languages). Text appears after each sentence. Needs a fast phone '
        '(e.g. Galaxy S23 or newer) or PC. Uses about 1 GB.',
    kind: EngineKind.whisper,
    downloadMb: 538,
    badge: 'Best for Malay + English',
  ),
  ModelInfo(
    id: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8',
    title: 'Parakeet · English',
    description:
        'NVIDIA Parakeet TDT 0.6B. Very accurate English with punctuation, '
        'and fast. Text appears after each sentence. English only.',
    kind: EngineKind.parakeet,
    downloadMb: 460,
    badge: 'Best for English',
  ),
  ModelInfo(
    id: 'sherpa-onnx-whisper-small',
    title: 'Whisper Small · Multilingual',
    description:
        'Good accuracy, smaller than Turbo (about 380 MB). For Malay, pick '
        'Malay + English rather than Auto-detect.',
    kind: EngineKind.whisper,
    downloadMb: 610,
  ),
  ModelInfo(
    id: 'sherpa-onnx-whisper-base',
    title: 'Whisper Base · Multilingual',
    description: 'Faster than Small, less accurate. For older phones and PCs.',
    kind: EngineKind.whisper,
    downloadMb: 198,
  ),
  ModelInfo(
    id: 'sherpa-onnx-whisper-tiny',
    title: 'Whisper Tiny · Multilingual',
    description: 'Fastest Whisper model, lowest accuracy.',
    kind: EngineKind.whisper,
    downloadMb: 111,
  ),
  ModelInfo(
    id: 'sherpa-onnx-streaming-zipformer-en-2023-06-26',
    title: 'English · Live (accurate)',
    description:
        'Words appear instantly while people talk. Less accurate than '
        'Parakeet, no punctuation.',
    kind: EngineKind.streaming,
    downloadMb: 296,
    sentenceCase: true,
  ),
  ModelInfo(
    id: 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17',
    title: 'English · Live (fast)',
    description:
        'Tiny streaming model for old devices. Words appear instantly, but '
        'it makes many mistakes.',
    kind: EngineKind.streaming,
    downloadMb: 122,
    sentenceCase: true,
  ),
];

ModelInfo? modelById(String? id) {
  for (final m in modelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

/// Languages offered for Whisper.
const whisperLanguages = <String, String>{
  'en': 'English',
  'ms': 'Malay',
  'id': 'Indonesian',
  'zh': 'Chinese',
  'ta': 'Tamil',
  'hi': 'Hindi',
  'ar': 'Arabic',
  'ja': 'Japanese',
  'ko': 'Korean',
  'th': 'Thai',
  'vi': 'Vietnamese',
  'tl': 'Filipino',
  'fr': 'French',
  'de': 'German',
  'es': 'Spanish',
  'pt': 'Portuguese',
  'ru': 'Russian',
};

/// The files inside a model folder that an engine needs.
class ModelFiles {
  const ModelFiles({
    required this.encoder,
    required this.decoder,
    required this.tokens,
    this.joiner,
  });

  final String encoder;
  final String decoder;
  final String tokens;

  /// Only used by transducer models (streaming and Parakeet).
  final String? joiner;
}

/// Picks the files an engine needs out of a list of file names (as found in
/// the model archive or folder). Prefers int8-quantised weights, which are
/// smaller and faster. Returns null if something required is missing.
///
/// The returned values are elements of [names].
ModelFiles? pickModelFiles(Iterable<String> names, EngineKind kind) {
  String base(String p) => p.split(RegExp(r'[\\/]')).last;
  final candidates = names
      .where((n) => !n.contains('test_wavs'))
      .toList(growable: false);

  String? pick(String role) {
    final onnx = candidates
        .where((n) => base(n).contains(role) && base(n).endsWith('.onnx'))
        .toList();
    if (onnx.isEmpty) return null;
    return onnx.firstWhere(
      (n) => base(n).contains('int8'),
      orElse: () => onnx.first,
    );
  }

  final tokens = candidates.where((n) => base(n).endsWith('tokens.txt'));
  final encoder = pick('encoder');
  final decoder = pick('decoder');
  final needsJoiner = kind != EngineKind.whisper;
  final joiner = needsJoiner ? pick('joiner') : null;
  if (tokens.isEmpty || encoder == null || decoder == null) return null;
  if (needsJoiner && joiner == null) return null;
  return ModelFiles(
    encoder: encoder,
    decoder: decoder,
    joiner: joiner,
    tokens: tokens.first,
  );
}
