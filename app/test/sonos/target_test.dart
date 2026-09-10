import 'package:castqueue/playback/playback_target.dart';
import 'package:castqueue/sonos/sonos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const device = SonosDevice(uuid: 'RINCON_X', roomName: 'Bad', host: '192.168.1.20');

  PlayItem item(String id, {Duration? duration}) => PlayItem(
        id: id,
        url: Uri.parse('https://pods.example.com/stream/$id?t=tok'),
        title: id,
        artist: 'show',
        duration: duration,
      );

  test('id/name/supportsSpeed', () async {
    final t = SonosTarget(device);
    expect(t.id, 'sonos:RINCON_X');
    expect(t.name, 'Bad');
    expect(t.supportsSpeed, isFalse);
    expect(t.currentStatus.state, PlaybackState.idle);
    expect(await t.status.first, PlaybackStatus.idle);
    await t.dispose();
  });

  test('poll maps transport states and positions', () async {
    final t = SonosTarget(device);
    final current = item('a', duration: const Duration(minutes: 30));
    t.debugSetItems(current: current);

    t.debugApplyPoll(transportState: 'PLAYING', relTime: '0:01:30', trackDuration: '0:30:00');
    expect(t.currentStatus.state, PlaybackState.playing);
    expect(t.currentStatus.position, const Duration(minutes: 1, seconds: 30));
    expect(t.currentStatus.duration, const Duration(minutes: 30));
    expect(t.currentStatus.itemId, 'a');

    t.debugApplyPoll(transportState: 'PAUSED_PLAYBACK', relTime: '0:01:31', trackDuration: '0:30:00');
    expect(t.currentStatus.state, PlaybackState.paused);

    t.debugApplyPoll(transportState: 'TRANSITIONING', relTime: 'NOT_IMPLEMENTED', trackDuration: 'NOT_IMPLEMENTED');
    expect(t.currentStatus.state, PlaybackState.loading);
    // Unknown position keeps previous value.
    expect(t.currentStatus.position, const Duration(minutes: 1, seconds: 31));
    await t.dispose();
  });

  test('STOPPED near the end reports completed once', () async {
    final t = SonosTarget(device);
    t.debugSetItems(current: item('a', duration: const Duration(minutes: 30)));
    t.debugApplyPoll(transportState: 'PLAYING', relTime: '0:29:57', trackDuration: '0:30:00');
    t.debugApplyPoll(transportState: 'STOPPED', relTime: '0:00:00', trackDuration: '0:30:00');
    expect(t.currentStatus.state, PlaybackState.completed);
    expect(t.currentStatus.position, const Duration(minutes: 30));
    await t.dispose();
  });

  test('STOPPED mid-track reports paused', () async {
    final t = SonosTarget(device);
    t.debugSetItems(current: item('a', duration: const Duration(minutes: 30)));
    t.debugApplyPoll(transportState: 'PLAYING', relTime: '0:10:00', trackDuration: '0:30:00');
    t.debugApplyPoll(transportState: 'STOPPED', relTime: '0:10:00', trackDuration: '0:30:00');
    expect(t.currentStatus.state, PlaybackState.paused);
    await t.dispose();
  });

  test('detects auto-advance to the next item', () async {
    final t = SonosTarget(device);
    final a = item('a');
    final b = item('b');
    t.debugSetItems(current: a, next: b);
    t.debugApplyPoll(
      transportState: 'PLAYING',
      relTime: '0:00:03',
      trackDuration: '0:20:00',
      trackUri: 'https://pods.example.com/stream/b?t=tok',
    );
    expect(t.currentStatus.itemId, 'b');
    expect(t.currentStatus.state, PlaybackState.playing);
    await t.dispose();
  });
}
