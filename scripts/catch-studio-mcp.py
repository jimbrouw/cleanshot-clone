#!/usr/bin/env python3
"""Local MCP stdio adapter for the opt-in Catch Studio Unix socket."""
import json
import os
import socket
import sys

MAX_MESSAGE = 1_048_576
CAPTURE_KEY = os.environ.get("CATCH_CAPTURE_KEY", "")
READ_ONLY_TOOLS = {"selected_take"}
SOCKET_PATH = f"/tmp/catch-studio-{os.getuid()}/bridge.sock"
TOOLS = [
    ("load_script", "Load the teleprompter script and separate edit notes; does not start playback or recording.", {"script": {"type": "string"}, "edit_notes": {"type": "string"}}, ["script"]),
    ("screenshot", "Capture the current display and return the saved screenshot path.", {}, []),
    ("start", "Start Studio recording.", {}, []),
    ("pause", "Pause Studio recording.", {}, []),
    ("resume", "Resume Studio recording.", {}, []),
    ("stop", "Stop the current recording and return the finalized MP4 path.", {}, []),
    ("status", "Get the Studio state and any recording error.", {}, []),
    ("selected_take", "Get the explicitly selected finished take, script, and edit notes.", {}, []),
]


def call_bridge(name, arguments):
    request = {"action": name, **arguments}
    if name not in READ_ONLY_TOOLS:
        request["capture_key"] = CAPTURE_KEY
    body = json.dumps(request, ensure_ascii=False).encode() + b"\n"
    if len(body) > MAX_MESSAGE:
        raise ValueError("Request exceeds the bridge size limit.")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(65)
        connection.connect(SOCKET_PATH)
        connection.sendall(body)
        with connection.makefile("rb") as response:
            line = response.readline(MAX_MESSAGE + 1)
    if not line.endswith(b"\n") or len(line) > MAX_MESSAGE:
        raise ValueError("Invalid bridge response.")
    result = json.loads(line)
    if not isinstance(result, dict):
        raise ValueError("Invalid bridge response.")
    return result


def handle(message):
    method = message.get("method")
    available = [tool for tool in TOOLS if CAPTURE_KEY or tool[0] in READ_ONLY_TOOLS]
    if method == "initialize":
        params = message.get("params")
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        version = requested if requested in ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25") else "2025-11-25"
        return {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "catch-studio", "version": "0.1.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": name, "description": desc, "inputSchema": {"type": "object", "properties": props, "required": required, "additionalProperties": False}} for name, desc, props, required in available]}
    if method == "tools/call":
        params = message.get("params")
        if not isinstance(params, dict):
            raise ValueError("Tool params must be an object.")
        name = params.get("name")
        args = params.get("arguments", {})
        if not isinstance(name, str) or name not in {tool[0] for tool in available} or not isinstance(args, dict):
            raise ValueError("Unknown tool or invalid arguments.")
        allowed = {entry[0]: set(entry[2]) for entry in TOOLS}[name]
        if set(args) - allowed:
            raise ValueError("Unexpected arguments.")
        if name == "load_script" and (not isinstance(args.get("script"), str) or not isinstance(args.get("edit_notes", ""), str)):
            raise ValueError("script and edit_notes must be strings.")
        try:
            result = call_bridge(name, args)
        except (OSError, ValueError) as error:
            result = {"error": f"Catch bridge unavailable or disabled: {error}"}
        return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}], "isError": "error" in result}
    raise ValueError("Method not found")


def main():
    while True:
        line = sys.stdin.buffer.readline(MAX_MESSAGE + 1)
        if not line:
            break
        if len(line) > MAX_MESSAGE:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(MAX_MESSAGE + 1)
            print(json.dumps({"jsonrpc": "2.0", "id": None, "error": {
                "code": -32600, "message": "Request exceeds the size limit."
            }}), flush=True)
            continue
        request = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                raise ValueError("Invalid JSON-RPC request")
            if "id" not in request:
                continue
            result = handle(request)
            reply = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            reply = {"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None, "error": {"code": -32600, "message": str(error)}}
        print(json.dumps(reply, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
