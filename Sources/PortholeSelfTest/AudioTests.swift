import Foundation
import PortholeCore

func audioTests() {
    var apps = SharedUse<Int32, UInt32>()
    check("audio: nothing shared means no apps to capture", apps.keys.isEmpty)
    check("audio: first window of Safari adds Safari", apps.add(10, to: 500))
    check("audio: second Safari window does not add it again", !apps.add(11, to: 500))
    expect("audio: Safari is captured once for two windows", apps.keys, [500])
    expect("audio: both windows count as users of Safari", apps.users(of: 500), [10, 11])
    check("audio: a Music window adds Music", apps.add(20, to: 600))
    expect("audio: Safari and Music are both captured", apps.keys, [500, 600])
    check("audio: closing one of two Safari windows keeps Safari", !apps.remove(10))
    expect("audio: Safari is still captured", apps.keys, [500, 600])
    check("audio: closing the last Safari window drops Safari", apps.remove(11))
    expect("audio: only Music is left", apps.keys, [600])
    check("audio: removing a window that was never added changes nothing", !apps.remove(99))
    check("audio: re-adding the same window to the same app changes nothing", !apps.add(20, to: 600))
    check("audio: a window id reused by another app moves to it", apps.add(20, to: 700))
    expect("audio: the old app is dropped when its only window moved", apps.keys, [700])
    check("audio: removeAll reports there was something", apps.removeAll())
    check("audio: removeAll leaves nothing", apps.keys.isEmpty && apps.owners.isEmpty)
    check("audio: removeAll on empty reports nothing changed", !apps.removeAll())

    var listening = SharedUse<String, UInt32>()
    check("viewer audio: first portal subscribes the mix", listening.add(1, to: Message.audioTrackName))
    check("viewer audio: second portal does not subscribe again", !listening.add(2, to: Message.audioTrackName))
    check("viewer audio: closing one of two portals keeps listening", !listening.remove(1))
    check("viewer audio: closing the last portal unsubscribes", listening.remove(2) && listening.keys.isEmpty)

    expect("audio mix: idle with nothing wanted stays idle", AudioMixStep.next(running: nil, want: []), .none)
    expect("audio mix: idle with apps wanted starts", AudioMixStep.next(running: nil, want: [500]), .start([500]))
    expect("audio mix: same apps leaves the stream alone", AudioMixStep.next(running: [500, 600], want: [600, 500]), .none)
    expect("audio mix: another app updates the filter", AudioMixStep.next(running: [500], want: [500, 600]), .update([500, 600]))
    expect("audio mix: fewer apps updates the filter", AudioMixStep.next(running: [500, 600], want: [600]), .update([600]))
    expect("audio mix: no apps left stops", AudioMixStep.next(running: [500], want: []), .stop)
    expect("audio mix: a running stream with no apps also stops", AudioMixStep.next(running: [], want: []), .stop)

    expect("audio track: canonical mix name", Message.audioTrackName, "aud-mix")
    check("audio track: the mix name is recognised", Message.isAudioTrackName("aud-mix"))
    for t in ["win-1", "aud-", "aud-mix ", "Aud-mix", "aud-1"] {
        check("audio track: \"\(t)\" is not the audio track", !Message.isAudioTrackName(t))
    }
    check("audio track: the audio track is never mistaken for a window track", Message.windowID(fromTrackName: Message.audioTrackName) == nil)

    var opened = Message(.opened)
    opened.win = 7; opened.track = Message.trackName(for: 7); opened.audio = Message.audioTrackName
    let wire = json(opened.encoded())
    check("opened: audio goes on the wire as \"audio\"", wire?["audio"] as? String == "aud-mix")
    expect("opened: audio survives a round trip", Message.decode(opened.encoded()), opened)
    let old = Message.decode(Data(#"{"t":"opened","win":7,"track":"win-7"}"#.utf8))
    check("opened: a reply from an older host without audio still decodes", old?.t == .opened && old?.track == "win-7" && old?.audio == nil)
    check("opened: no audio field is written when there is none", json(Message(.opened).encoded())?["audio"] == nil)

}
