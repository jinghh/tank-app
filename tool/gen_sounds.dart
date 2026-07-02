// 生成坦克大战音效（合成 WAV，无外部素材）。
// 运行：dart run tool/gen_sounds.dart
// 输出到 assets/sounds/*.wav

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const int sampleRate = 22050;
final Random rng = Random();

void main() {
  final out = Directory('assets/sounds');
  out.createSync(recursive: true);

  writeWav('shoot', toneSweep(0.14, 760, 180, wave: _square, decay: 6.0));
  writeWav('enemy_shoot', toneSweep(0.12, 520, 140, wave: _square, decay: 6.0, gain: 0.5));
  writeWav('hit', toneSweep(0.10, 240, 90, wave: _square, decay: 8.0, gain: 0.6));
  writeWav('steel', mix([
    toneSweep(0.12, 1400, 1100, wave: _square, decay: 10.0, gain: 0.4),
    noise(0.10, decay: 12.0, gain: 0.3),
  ]));
  writeWav('explosion', mix([
    noise(0.42, decay: 3.0, gain: 0.9),
    toneSweep(0.42, 160, 50, wave: _sine, decay: 3.5, gain: 0.6),
  ]));
  writeWav('big_explosion', mix([
    noise(0.6, decay: 2.2, gain: 1.0),
    toneSweep(0.6, 130, 40, wave: _sine, decay: 2.5, gain: 0.7),
  ]));
  writeWav('powerup', arpeggio([523, 659, 784, 1046], 0.09, gain: 0.6));
  writeWav('start', toneSweep(0.4, 330, 880, wave: _square, decay: 3.0, gain: 0.5));
  writeWav('gameover', arpeggio([523, 440, 349, 262], 0.18, gain: 0.6));
  writeWav('click', tone(0.04, 1000, wave: _square, gain: 0.4));

  print('Generated ${out.listSync().length} sound files in ${out.path}');
}

// ---- 合成基元 ----
double _sine(double p) => sin(p);
double _square(double p) => sin(p) >= 0 ? 1.0 : -1.0;

Float64List tone(double dur, double freq, {required double Function(double) wave, double gain = 1.0}) {
  final n = (dur * sampleRate).round();
  final out = Float64List(n);
  for (int i = 0; i < n; i++) {
    final t = i / sampleRate;
    out[i] = wave(2 * pi * freq * t) * gain;
  }
  return out;
}

Float64List toneSweep(double dur, double f0, double f1,
    {required double Function(double) wave, double decay = 4.0, double gain = 1.0}) {
  final n = (dur * sampleRate).round();
  final out = Float64List(n);
  for (int i = 0; i < n; i++) {
    final u = i / (n - 1);
    final t = i / sampleRate;
    final f = f0 + (f1 - f0) * u;
    final env = exp(-decay * t);
    out[i] = wave(2 * pi * f * t) * env * gain;
  }
  return out;
}

Float64List noise(double dur, {double decay = 4.0, double gain = 1.0}) {
  final n = (dur * sampleRate).round();
  final out = Float64List(n);
  double last = 0; // 简单低通，更像爆炸
  for (int i = 0; i < n; i++) {
    final t = i / sampleRate;
    final env = exp(-decay * t);
    final r = (rng.nextDouble() * 2 - 1);
    last = last * 0.6 + r * 0.4;
    out[i] = last * env * gain;
  }
  return out;
}

Float64List arpeggio(List<double> freqs, double step, {double gain = 1.0}) {
  final parts = <Float64List>[];
  for (final f in freqs) {
    parts.add(tone(step, f, wave: _square, gain: gain)..applyEnvelope(decay: 6.0, dur: step));
  }
  return concat(parts);
}

Float64List mix(List<Float64List> lists) {
  final n = lists.map((e) => e.length).reduce(max);
  final out = Float64List(n);
  for (final l in lists) {
    for (int i = 0; i < l.length; i++) {
      out[i] += l[i];
    }
  }
  for (int i = 0; i < n; i++) {
    out[i] = out[i].clamp(-1.0, 1.0);
  }
  return out;
}

Float64List concat(List<Float64List> lists) {
  final n = lists.fold<int>(0, (a, b) => a + b.length);
  final out = Float64List(n);
  int o = 0;
  for (final l in lists) {
    out.setAll(o, l);
    o += l.length;
  }
  return out;
}

extension _Env on Float64List {
  void applyEnvelope({required double decay, required double dur}) {
    for (int i = 0; i < length; i++) {
      final t = i / sampleRate;
      this[i] *= exp(-decay * t);
    }
  }
}

// ---- WAV 写入 ----
void writeWav(String name, Float64List samples) {
  final data = BytesBuilder();
  final numSamples = samples.length;
  final dataSize = numSamples * 2;

  void u32(int v) {
    data.addByte(v & 0xff);
    data.addByte((v >> 8) & 0xff);
    data.addByte((v >> 16) & 0xff);
    data.addByte((v >> 24) & 0xff);
  }

  void u16(int v) {
    data.addByte(v & 0xff);
    data.addByte((v >> 8) & 0xff);
  }

  data.add(ascii.encode('RIFF'));
  u32(36 + dataSize);
  data.add(ascii.encode('WAVE'));
  data.add(ascii.encode('fmt '));
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  data.add(ascii.encode('data'));
  u32(dataSize);
  for (final s in samples) {
    final v = (s.clamp(-1.0, 1.0) * 32767).round();
    u16(v & 0xffff);
  }

  final file = File('assets/sounds/$name.wav');
  file.writeAsBytesSync(data.toBytes());
}
