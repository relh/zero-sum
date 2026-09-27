## Fixed numeric observation and action codec over the ordinary private seat view.

import std/json
import battle_royal/types

const Directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

proc makeActions*(): seq[JsonNode] =
  result.add(%*{"type": "action", "do": "none"})
  for name in Directions:
    result.add(%*{"type": "action", "do": "move", "dir": name})
  for name in Directions:
    result.add(%*{"type": "action", "do": "attack", "dir": name})
  result.add(%*{"type": "action", "do": "pickup"})
  for slot in [SlotHand, SlotBody, 0, 1, 2, 3]:
    result.add(%*{"type": "action", "do": "drop", "slot": slot})
  for slot in 0 .. 3:
    result.add(%*{"type": "action", "do": "use", "slot": slot})
  result.add(%*{"type": "action", "do": "interact"})

proc mapTile(config: JsonNode, x, y: int): TileKind =
  let size = config["arena"]["size"].getInt()
  if x < 0 or y < 0 or x >= size or y >= size: return tkWall
  let symbol = config["arena"]["static_map"][y].getStr()[x]
  for kind in TileKind:
    if $kind == $symbol: return kind
  raise newException(ValueError, "Unknown public arena tile")

proc legal*(config, observation, action: JsonNode): bool =
  if action["do"].getStr() == "none": return true
  if observation["phase"].getStr() != "live": return false
  let you = observation["you"]
  case action["do"].getStr()
  of "move":
    if you["move_ready_in"].getInt() > 0: return false
    for i, name in Directions:
      if name == action["dir"].getStr():
        let delta = [Pos(x: 0, y: -1), Pos(x: 1, y: -1),
                     Pos(x: 1, y: 0), Pos(x: 1, y: 1),
                     Pos(x: 0, y: 1), Pos(x: -1, y: 1),
                     Pos(x: -1, y: 0), Pos(x: -1, y: -1)][i]
        return config.mapTile(you["pos"][0].getInt() + delta.x,
          you["pos"][1].getInt() + delta.y) notin
          {tkWall, tkRock, tkFortressWall}
  of "attack": return you["attack_ready_in"].getInt() == 0
  of "pickup":
    for item in observation["visible"]["items"]:
      if item["pos"] == you["pos"]: return true
  of "drop":
    let slot = action["slot"].getInt()
    if slot == SlotHand: return you["hand"]["id"].getStr() != "none"
    if slot == SlotBody: return you["body"].kind != JNull
    return slot < you["pack"].len and you["pack"][slot].kind != JNull
  of "use":
    let slot = action["slot"].getInt()
    return slot < you["pack"].len and you["pack"][slot].kind != JNull
  of "interact":
    for bush in observation["visible"]["bushes"]:
      if bush["pos"] == you["pos"] and bush["charges"].getInt() > 0:
        return true
  else: raise newException(ValueError, "Unknown Battle Royal action")

proc itemCode(name: string): int =
  for item in ItemId:
    if $item == name: return ord(item)
  raise newException(ValueError, "Unknown Battle Royal item: " & name)

proc numericEncoding*(config, observation: JsonNode, decisionId: int): JsonNode =
  let controlledSeat = config["slot"].getInt()
  let maxTicks = config["max_ticks"].getInt()
  let tick = observation["tick"].getInt()
  let you = observation["you"]
  let zone = observation["zone"]
  var values = newJArray()
  for number in [float(tick) / float(maxTicks),
                 float(controlledSeat) / 15.0,
                 float(you["pos"][0].getInt()) / 48.0,
                 float(you["pos"][1].getInt()) / 48.0,
                 float(you["hp"].getInt()) / 100.0,
                 float(you["stats"]["speed"].getInt()) / 10.0,
                 float(you["stats"]["strength"].getInt()) / 10.0,
                 float(you["stats"]["intelligence"].getInt()) / 10.0,
                 float(you["stats"]["athleticism"].getInt()) / 10.0,
                 float(itemCode(you["hand"]["id"].getStr())) / float(ord(high(ItemId))),
                 float(if you["body"].kind == JNull: 0 else:
                   itemCode(you["body"].getStr())) / float(ord(high(ItemId))),
                 float(zone["radius"].getInt()) / 48.0,
                 float(zone["next_radius"].getInt()) / 48.0,
                 float(zone["center"][0].getInt()) / 48.0,
                 float(zone["center"][1].getInt()) / 48.0,
                 float(max(0, zone["shrink_tick"].getInt() - tick)) / float(maxTicks),
                 float(you["move_ready_in"].getInt()) / 100.0,
                 float(you["attack_ready_in"].getInt()) / 100.0,
                 float(you["kills"].getInt()) / 15.0,
                 float(observation["chat"].len) / 16.0,
                 float(observation["events"].len) / 16.0]:
    values.add(%number)
  for index in 0 .. 3:
    if index < you["pack"].len and you["pack"][index].kind != JNull:
      values.add(%(float(itemCode(you["pack"][index]["id"].getStr())) /
        float(ord(high(ItemId)))))
      values.add(%(float(you["pack"][index]["n"].getInt()) / 20.0))
    else:
      values.add(%0)
      values.add(%0)
  for slot in 0 .. 15:
    if slot == controlledSeat: continue
    var seen = newJNull()
    for other in observation["visible"]["agents"]:
      if other["slot"].getInt() == slot: seen = other
    if seen.kind == JNull:
      for unused in 0 .. 8: values.add(%0)
    else:
      values.add(%1)
      values.add(%(float(seen["pos"][0].getInt()) / 48.0))
      values.add(%(float(seen["pos"][1].getInt()) / 48.0))
      values.add(%(case seen["hp_band"].getStr()
        of "healthy": 1.0
        of "hurt": 0.5
        else: 0.0))
      values.add(%(if seen["netted"].getBool(): 1 else: 0))
      values.add(%(if seen["poisoned"].getBool(): 1 else: 0))
      values.add(%(float(itemCode(seen["hand"].getStr())) /
        float(ord(high(ItemId)))))
      values.add(%(float(if seen["body"].kind == JNull: 0 else:
        itemCode(seen["body"].getStr())) / float(ord(high(ItemId)))))
      values.add(%(if seen["channeling"].getBool(): 1 else: 0))
  for index in 0 .. 15:
    if index < observation["visible"]["items"].len:
      let item = observation["visible"]["items"][index]
      values.add(%1)
      values.add(%(float(item["pos"][0].getInt()) / 48.0))
      values.add(%(float(item["pos"][1].getInt()) / 48.0))
      values.add(%(float(itemCode(item["id"].getStr())) / float(ord(high(ItemId)))))
      values.add(%(float(item["n"].getInt()) / 20.0))
    else:
      for unused in 0 .. 4: values.add(%0)
  for index in 0 .. 7:
    if index < observation["visible"]["bushes"].len:
      let bush = observation["visible"]["bushes"][index]
      values.add(%1)
      values.add(%(float(bush["pos"][0].getInt()) / 48.0))
      values.add(%(float(bush["pos"][1].getInt()) / 48.0))
      values.add(%(float(bush["charges"].getInt()) / 10.0))
    else:
      for unused in 0 .. 3: values.add(%0)
  for y in -4 .. 4:
    for x in -4 .. 4:
      let tile = config.mapTile(you["pos"][0].getInt() + x,
        you["pos"][1].getInt() + y)
      values.add(%(float(ord(tile)) / float(ord(high(TileKind)))))
  var slots = newJArray()
  for action in makeActions():
    slots.add(if legal(config, observation, action): action else: newJNull())
  %*{"decision_id": decisionId, "values": values, "actions": slots}

