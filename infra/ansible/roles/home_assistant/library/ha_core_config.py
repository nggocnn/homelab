#!/usr/bin/python3
# Set Home Assistant's core config (time zone, units, country...) over the websocket API.
# Runs on the controller; needs python3-websocket. Only differing keys are sent.
import json

from ansible.module_utils.basic import AnsibleModule

try:
    import websocket
except ImportError:
    websocket = None


def call(ws, msg_id, payload):
    ws.send(json.dumps(dict(payload, id=msg_id)))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == msg_id:
            return msg


def main():
    module = AnsibleModule(
        argument_spec=dict(
            url=dict(type="str", required=True),
            token=dict(type="str", required=True, no_log=True),
            config=dict(type="dict", required=True),
        ),
        supports_check_mode=True,
    )
    if websocket is None:
        module.fail_json(msg="python3-websocket is missing on the controller: sudo apt install python3-websocket")

    want = {k: v for k, v in module.params["config"].items() if v is not None}
    ws = websocket.create_connection(module.params["url"].replace("http", "ws", 1) + "/api/websocket", timeout=30)
    try:
        ws.recv()  # auth_required
        ws.send(json.dumps({"type": "auth", "access_token": module.params["token"]}))
        if json.loads(ws.recv()).get("type") != "auth_ok":
            module.fail_json(msg="websocket authentication failed")

        have = call(ws, 1, {"type": "get_config"})["result"]
        # get_config reports the unit system as its units, not by name.
        have = dict(have, unit_system="metric" if have["unit_system"].get("length") == "km" else "us_customary")
        diff = {k: v for k, v in want.items() if have.get(k) != v}

        if diff and not module.check_mode:
            res = call(ws, 2, dict(diff, type="config/core/update"))
            if not res.get("success"):
                module.fail_json(msg="config/core/update failed", error=res.get("error"))
    finally:
        ws.close()

    module.exit_json(changed=bool(diff), diff={"before": {k: have.get(k) for k in diff}, "after": diff})


if __name__ == "__main__":
    main()
