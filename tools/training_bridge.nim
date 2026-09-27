## Train one Battle Royal seat against the shipped survival policy.
## The observation and actions use the same game-owned player protocol as /player.

import std/[json, os, strutils]
import battle_royal/[obs, sim, types]
import ../player/[baseline, numeric_codec]

var
  game: Sim
  contexts: array[16, Ctx]
  config: JsonNode
  decisionId: int
  maxTicks: int
  controlledSeat: int
  lastLearnerTalkTick: int
  actions: seq[JsonNode]

proc seedOf(value: string): uint64 =
  result = 14695981039346656037'u64
  for ch in value:
    result = (result xor uint64(ord(ch))) * 1099511628211'u64
  result = result and 0x7fffffffffffffff'u64

proc legal(action: JsonNode): bool =
  numeric_codec.legal(config,
    parseJson(observationJson(game, controlledSeat)), action)

proc current(): JsonNode =
  let observation = parseJson(observationJson(game, controlledSeat))
  var choices = newJArray()
  for action in actions:
    if numeric_codec.legal(config, observation, action): choices.add(action)
  let talkReadyIn = max(0, 24 - (game.tick - lastLearnerTalkTick))
  let view = %*{"config": config, "observation": observation,
    "talk_ready_in": talkReadyIn}
  var inbox = newJArray()
  for message in observation["chat"]:
    inbox.add(%*{"from": message["from"], "text": message["text"],
      "turn": message["tick"],
      "to": (if message["channel"].getStr() == "broadcast": %"public"
             else: %*[message["to"].getInt()])})
  %*{"kind": "decision", "game": "battle-royal", "decision_id": decisionId,
     "seat": 0, "engine_seat": controlledSeat, "turn": game.tick,
     "semantic_view": view, "inbox": inbox,
     "messages": [
       {"role": "system", "content": "Survive Battle Royal. Choose one legal action for this tick."},
       {"role": "user", "content": $view}],
     "speech_messages": (if talkReadyIn == 0: %*[
       {"role": "system", "content": "Speak to the living Battle Royal players. Return at most 120 printable ASCII characters."},
       {"role": "user", "content": $view}] else: newJArray()),
     "action_schema": {"enum": choices},
     "typed_question": newJNull()}

proc encoding(): JsonNode =
  numericEncoding(config, parseJson(observationJson(game, controlledSeat)),
    decisionId)

proc terminal(): JsonNode =
  doAssert game.phase == phEnded
  let score = game.episodeScore(game.computePlacements(), AgentId(controlledSeat))
  %*{"kind": "terminal", "scores": {"0": score},
     "utilities": {"0": float(score) / 12.5 - 1.0}}

proc reset(request: JsonNode): JsonNode =
  doAssert request["players"].getInt() == 1
  let seed = seedOf(request["seed"].getStr())
  controlledSeat = int(seed mod 16)
  game = initSim(parseSimConfig(%*{"seed": seed, "max_ticks": maxTicks,
    "freeze_ticks": min(240, maxTicks div 4)}, proc(): uint64 = seed))
  for seat in 0 .. 15:
    config = parseJson(playerConfigJson(game, seat))
    contexts[seat] = trainingContext(config)
    game.applyInputJson(AgentId(seat), trainingAllocation())
  config = parseJson(playerConfigJson(game, controlledSeat))
  while game.phase == phCountdown: game.step()
  decisionId = 0
  lastLearnerTalkTick = -24
  current()

proc advanceOpponents() =
  for seat in 0 .. 15:
    if seat == controlledSeat: continue
    if game.agents[seat].alive:
      let observation = parseJson(observationJson(game, seat))
      for message in contexts[seat].talkMessages(observation):
        game.applyInputJson(AgentId(seat), message)
      game.applyInputJson(AgentId(seat),
        trainingAction(contexts[seat], observation))
  game.step()

proc handle(request: JsonNode): JsonNode =
  case request["kind"].getStr()
  of "reset": return reset(request)
  of "encode": return encoding()
  of "say":
    doAssert request["decision_id"].getInt() == decisionId
    let public = request["to"].kind == JNull
    let recipient = if public: -1 else: request["to"].getInt()
    let channel = if public: tcBroadcast else: tcDm
    let text = request["text"].getStr()
    if game.submitTalk(AgentId(controlledSeat), channel, recipient, text) != tkAccepted:
      raise newException(ValueError, "Battle Royal rejected speech")
    lastLearnerTalkTick = game.tick
    return %*{"kind": "spoken", "text": sanitizeTalk(text),
      "to": (if public: %"public" else: %*[recipient]),
      "observation": current()}
  of "teacher":
    var action = trainingAction(contexts[controlledSeat],
      parseJson(observationJson(game, controlledSeat)))
    if not legal(action): action = actions[0]
    return %*{"response": $action}
  of "step":
    doAssert request["decision_id"].getInt() == decisionId
    let action = parseJson(request["response"].getStr())
    if action notin actions or not legal(action):
      return %*{"kind": "rejected", "reason": "Action is not legal"}
    game.applyInputJson(AgentId(controlledSeat), action)
    advanceOpponents()
    inc decisionId
    if not game.agents[controlledSeat].alive:
      while game.phase != phEnded:
        advanceOpponents()
    return %*{"kind": "accepted", "action": action,
      "observation": (if game.phase == phEnded or not game.agents[controlledSeat].alive:
        terminal() else: current())}
  else: raise newException(ValueError, "Unknown bridge command")

when isMainModule:
  let args = commandLineParams()
  if args.len > 1: quit("usage: training_bridge [max_ticks]", 1)
  maxTicks = if args.len == 1: parseInt(args[0]) else: 9120
  actions = makeActions()
  for line in stdin.lines:
    echo $handle(parseJson(line))
