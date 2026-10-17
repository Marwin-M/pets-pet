"""Only query the official read RPC; never print authentication or chat data."""
import json
import selectors
import subprocess
import time

process = subprocess.Popen(
    ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)

def send(message):
    process.stdin.write((json.dumps(message) + "\n").encode())
    process.stdin.flush()

try:
    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "pets_pet", "title": "Pet's Pet", "version": "0.1.0"}}})
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if not selector.select(timeout=1):
            continue
        line = process.stdout.readline()
        if not line:
            print("app-server exited", process.poll())
            break
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("id") == 1:
            if "error" in message:
                print("initialize error", message["error"].get("code"))
                break
            print("initialize: ok")
            send({"method": "initialized", "params": {}})
            send({"id": 2, "method": "account/rateLimits/read"})
        elif message.get("id") == 2:
            if "error" in message:
                print("quota error", message["error"].get("code"))
            else:
                result = message.get("result", {})
                for key, bucket in (result.get("rateLimitsByLimitId") or {"legacy": result.get("rateLimits", {})}).items():
                    print("bucket", key)
                    for name in ("primary", "secondary"):
                        window = bucket.get(name)
                        if window:
                            print(name, {key: window.get(key) for key in ("usedPercent", "windowDurationMins", "resetsAt")})
                cards = result.get("rateLimitResetCredits")
                print("reset cards provided:", isinstance(cards, dict))
                if isinstance(cards, dict):
                    print("availableCount:", cards.get("availableCount"))
                    details = cards.get("credits")
                    print("details provided:", isinstance(details, list))
                    if isinstance(details, list):
                        for credit in details:
                            print("card", {key: credit.get(key) for key in ("resetType", "status", "expiresAt")})
            break
    else:
        print("request timed out")
finally:
    process.stdin.close()
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
