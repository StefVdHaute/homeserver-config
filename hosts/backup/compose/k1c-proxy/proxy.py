"""Moonraker proxy for a Creality K1C on stock firmware.

The stock API (nexusp) lacks the webcam component and server.database.list,
which Fluidd needs. This proxy answers those methods and passes all other
HTTP and websocket traffic to the printer.

POST /camera relays go2rtc's WebRTC offer to the printer camera and corrects
the answer (see high_profile_answer).
"""
import asyncio
import base64
import json
import os
import re
import uuid
from pathlib import Path

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType, web

PRINTER = os.environ["PRINTER"]
CAMERA_URL = os.environ["CAMERA_URL"]
STORE = Path("/data/webcams.json")

SESSION = web.AppKey("session", ClientSession)
HOP_HEADERS = {"host", "connection", "keep-alive", "transfer-encoding", "upgrade",
               "content-length", "content-encoding"}
WEBCAM_DEFAULTS = {
    "location": "printer", "service": "iframe", "enabled": True, "icon": "mdiWebcam",
    "target_fps": 15, "target_fps_idle": 5, "stream_url": "", "snapshot_url": "",
    "flip_horizontal": False, "flip_vertical": False, "rotation": 0,
    "aspect_ratio": "4:3", "extra_data": {}, "source": "database",
}


def save_webcams(webcams):
    STORE.write_text(json.dumps(webcams, indent=2))


def load_webcams():
    if not STORE.exists():
        save_webcams([{**WEBCAM_DEFAULTS, "name": "K1C", "stream_url": "/webcam/",
                       "snapshot_url": "/webcam/snapshot.jpg", "aspect_ratio": "16:9",
                       "uid": str(uuid.uuid4())}])
    return json.loads(STORE.read_text())


def find_index(webcams, params):
    key = "uid" if params.get("uid") else "name"
    return next((i for i, cam in enumerate(webcams) if cam.get(key) == params.get(key)), None)


def require_index(webcams, params):
    i = find_index(webcams, params)
    if i is None:
        raise LookupError(f"webcam not found: {params}")
    return i


def webcams_list(params):
    return {"webcams": load_webcams()}


def webcams_get(params):
    webcams = load_webcams()
    return {"webcam": webcams[require_index(webcams, params)]}


def webcams_post(params):
    webcams = load_webcams()
    i = find_index(webcams, params)
    if i is None:
        cam = {**WEBCAM_DEFAULTS, **params, "uid": params.get("uid") or str(uuid.uuid4())}
        webcams.append(cam)
    else:
        cam = webcams[i] = {**webcams[i], **params}
    save_webcams(webcams)
    return {"webcam": cam}


def webcams_delete(params):
    webcams = load_webcams()
    cam = webcams.pop(require_index(webcams, params))
    save_webcams(webcams)
    return {"webcam": cam}


def database_list(params):
    return {"namespaces": ["fluidd"], "backups": []}


LOCAL_METHODS = {
    "server.webcams.list": webcams_list,
    "server.webcams.get_item": webcams_get,
    "server.webcams.post_item": webcams_post,
    "server.webcams.delete_item": webcams_delete,
    "server.database.list": database_list,
}
WEBCAM_WRITES = {"server.webcams.post_item", "server.webcams.delete_item"}


def add_webcam_component(text):
    if '"components"' not in text:
        return text
    msg = json.loads(text)
    result = msg.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("components"), list):
        return text
    if "webcam" not in result["components"]:
        result["components"].append("webcam")
    return json.dumps(msg)


def high_profile_answer(offer, answer):
    """Replace the second codec of the answer with the offer's High-profile H.264 type.

    The printer answers with payload types 96 and 0, but sends RTP with the
    offer's High-profile H.264 type, which go2rtc then cannot map to a track.
    go2rtc's creality client drops the first codec of the answer and uses the
    second one.
    """
    pt = re.search(r"^a=fmtp:(\d+) .*profile-level-id=64", offer, re.M).group(1)
    codec = [line for line in offer.splitlines()
             if line.startswith((f"a=rtpmap:{pt} ", f"a=fmtp:{pt} "))]
    lines = []
    for line in answer.splitlines():
        if line.startswith("m=video"):
            fields = line.split()
            first = fields[3]
            lines.append(" ".join(fields[:4] + [pt]))
        elif not line.startswith(("a=rtpmap:", "a=fmtp:")) or line.split()[0].endswith(f":{first}"):
            lines.append(line)
    return "\r\n".join(lines + codec) + "\r\n"


async def websocket(request):
    try:
        printer = await request.app[SESSION].ws_connect(
            f"ws://{PRINTER}{request.path_qs}", max_msg_size=0)
    except ClientError as e:
        raise web.HTTPBadGateway(text=str(e))
    client = web.WebSocketResponse(max_msg_size=0)
    await client.prepare(request)
    send_lock = asyncio.Lock()

    async def to_client(text):
        async with send_lock:
            await client.send_str(text)

    async def from_client():
        async for msg in client:
            if msg.type != WSMsgType.TEXT:
                continue
            req = json.loads(msg.data)
            method = req.get("method") if isinstance(req, dict) else None
            if method not in LOCAL_METHODS:
                await printer.send_str(msg.data)
                continue
            reply = {"jsonrpc": "2.0", "id": req.get("id")}
            try:
                reply["result"] = LOCAL_METHODS[method](req.get("params") or {})
            except LookupError as e:
                reply["error"] = {"code": 404, "message": str(e)}
            await to_client(json.dumps(reply))
            if method in WEBCAM_WRITES and "result" in reply:
                await to_client(json.dumps({"jsonrpc": "2.0", "method": "notify_webcams_changed",
                                            "params": [webcams_list({})]}))

    async def from_printer():
        async for msg in printer:
            if msg.type == WSMsgType.TEXT:
                await to_client(add_webcam_component(msg.data))

    tasks = [asyncio.create_task(from_client()), asyncio.create_task(from_printer())]
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for task in tasks:
        task.cancel()
    await printer.close()
    await client.close()
    return client


async def http(request):
    async with request.app[SESSION].request(
        request.method, f"http://{PRINTER}{request.path_qs}",
        headers={k: v for k, v in request.headers.items() if k.lower() not in HOP_HEADERS},
        data=await request.read() or None,
    ) as resp:
        body = await resp.read()
        headers = {k: v for k, v in resp.headers.items() if k.lower() not in HOP_HEADERS}
    if request.path == "/server/info":
        body = add_webcam_component(body.decode()).encode()
    return web.Response(status=resp.status, body=body, headers=headers)


async def camera(request):
    body = await request.read()
    offer = json.loads(base64.b64decode(body))["sdp"]
    async with request.app[SESSION].post(CAMERA_URL, data=body,
                                         headers={"Content-Type": request.content_type}) as resp:
        answer = json.loads(base64.b64decode(await resp.read()))
    answer["sdp"] = high_profile_answer(offer, answer["sdp"])
    return web.Response(text=base64.b64encode(json.dumps(answer).encode()).decode())


async def client_session(app):
    async with ClientSession(timeout=ClientTimeout(total=None, sock_connect=10)) as session:
        app[SESSION] = session
        yield


app = web.Application(client_max_size=1024**3)
app.cleanup_ctx.append(client_session)
app.router.add_get("/websocket", websocket)
app.router.add_post("/camera", camera)
app.router.add_route("*", "/{tail:.*}", http)
web.run_app(app, port=7125)
