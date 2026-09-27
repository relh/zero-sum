"""Run the published Battle Royal rules and baseline through the training bridge."""

import json
import subprocess
import sys

process = subprocess.Popen(
    [sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
)
assert process.stdin is not None and process.stdout is not None


def request(command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


try:
    observation = request({"kind": "reset", "seed": "training-full-game", "players": 1})
    assert observation["kind"] == "decision"
    assert observation["engine_seat"] in range(16)
    rejected = request({
        "kind": "step", "decision_id": observation["decision_id"],
        "response": json.dumps({"type": "action", "do": "drop", "slot": -1}),
    })
    assert rejected["kind"] == "rejected"
    assert observation["speech_messages"]
    spoken = request({
        "kind": "say", "decision_id": observation["decision_id"],
        "text": "native speech contract proof", "to": None,
    })
    assert spoken["kind"] == "spoken"
    assert spoken["text"] == "native speech contract proof"
    assert spoken["observation"]["decision_id"] == observation["decision_id"]
    assert spoken["observation"]["semantic_view"]["talk_ready_in"] == 24
    assert spoken["observation"]["speech_messages"] == []
    observation = spoken["observation"]
    decisions = 0
    visible_messages = 0
    own_speech_delivered = False
    private_speech_delivered = False
    while observation["kind"] == "decision":
        if decisions == 24:
            recipient = (observation["engine_seat"] + 1) % 16
            spoken = request({
                "kind": "say", "decision_id": observation["decision_id"],
                "text": "native dm contract proof", "to": recipient,
            })
            assert spoken["to"] == [recipient]
            assert spoken["observation"]["decision_id"] == observation["decision_id"]
            observation = spoken["observation"]
        native_chat = observation["semantic_view"]["observation"]["chat"]
        for message, native in zip(observation["inbox"], native_chat, strict=True):
            assert message == {
                "from": native["from"], "text": native["text"], "turn": native["tick"],
                "to": "public" if native["channel"] == "broadcast" else [native["to"]],
            }
        own_speech_delivered |= any(message["text"] == "native speech contract proof" for message in native_chat)
        private_speech_delivered |= any(message["text"] == "native dm contract proof" for message in native_chat)
        visible_messages += len(native_chat)
        if decisions % 100 == 0:
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            assert len(encoding["values"]) == 357
            assert len(encoding["actions"]) == 29
            assert encoding["actions"][0] == {"type": "action", "do": "none"}
        response = request({"kind": "teacher"})["response"]
        result = request({
            "kind": "step", "decision_id": observation["decision_id"],
            "response": response,
        })
        assert result["kind"] == "accepted", result
        observation = result["observation"]
        decisions += 1
        assert decisions <= 9120
    assert observation["kind"] == "terminal"
    assert visible_messages > 0
    assert own_speech_delivered
    assert private_speech_delivered
    assert 0 <= observation["scores"]["0"] <= 25
    assert -1 <= observation["utilities"]["0"] <= 1
    print(f"complete game: {decisions} decisions, score {observation['scores']['0']}, {visible_messages} visible messages")
finally:
    process.stdin.close()
    assert process.wait() == 0
