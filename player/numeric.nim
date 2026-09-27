## Ordinary Battle Royal player backed by a frozen numeric policy service.

import std/[httpclient, json, os]
import whisky
import baseline, numeric_codec

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  let policyUrl = getEnv("PLAYER_NUMERIC_URL")
  doAssert url.len > 0 and policyUrl.len > 0
  let session = getEnv("PLAYER_POLICY_SESSION", "battle-royal-" & $getCurrentProcessId())
  let client = newHttpClient(timeout = 5000)
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let key = getEnv("PLAYER_NUMERIC_KEY")
  if key.len > 0: client.headers["Authorization"] = "Bearer " & key
  let ws = newWebSocket(url)
  ws.send($trainingAllocation(), TextMessage)
  var config: JsonNode
  var context: Ctx
  while true:
    let frame = ws.receiveMessage()
    if frame.isNone: break
    let message = parseJson(frame.get().data)
    case message["type"].getStr()
    of "player_config":
      config = message
      context = trainingContext(config)
    of "observation":
      let encoding = numericEncoding(config, message, message["tick"].getInt())
      var mask = newJArray()
      for action in encoding["actions"]: mask.add(%(action.kind != JNull))
      let request = %*{"session": session, "seat": config["slot"],
        "decision_id": encoding["decision_id"], "values": encoding["values"],
        "action_mask": mask}
      let response = parseJson(client.postContent(policyUrl, $request))
      doAssert response["actions"].len == 1
      let action = encoding["actions"][response["actions"][0].getInt()]
      doAssert action.kind != JNull
      for speech in context.talkMessages(message): ws.send($speech, TextMessage)
      ws.send($action, TextMessage)
    of "final": break
    else: discard
  client.close()
