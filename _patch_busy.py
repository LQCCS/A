import sys

path = "/opt/comfyui-api-wrapper/main.py"
with open(path) as f:
    content = f.read()

if "PATCHED_WORKER_BUSY_BLOCKING_V1" in content:
    print("patch_api_wrapper: 阻塞版补丁已存在，跳过")
    sys.exit(0)

# ── Step 1: 删除所有已注入的 /generate/async 路由（可能有多个重复版本） ──────────
orig_marker = None
for q in ("'", '"'):
    candidate = f"@app.post({q}/generate{q},"
    if candidate in content:
        orig_marker = candidate
        break

if orig_marker is None:
    print("ERROR: /generate 原始路由未找到", file=sys.stderr)
    sys.exit(1)

orig_pos = content.find(orig_marker)
before_orig = content[:orig_pos]
after_and_including_orig = content[orig_pos:]

# 找到注入块最早的开始位置（注入代码在原始 @app.post('/generate', 之前）
injection_patterns = [
    "\n# ── /generate/async",
    "\nimport asyncio as _asyncio_p",
    "\nimport json as _json_p",
    "\n_async_task_store",
    "\n_worker_busy",
]

earliest_inject_pos = len(before_orig)
for pat in injection_patterns:
    pos = before_orig.find(pat)
    if pos != -1 and pos < earliest_inject_pos:
        earliest_inject_pos = pos

if earliest_inject_pos < len(before_orig):
    before_orig = before_orig[:earliest_inject_pos]
    print(f"✓ 已清除旧注入代码（{orig_pos - earliest_inject_pos} chars）")
else:
    print("ℹ️  未找到旧注入代码，直接注入新版本")

content = before_orig + after_and_including_orig

# ── Step 2: 注入新的阻塞版 /generate/async ──────────────────────────────────
injection = '''
# ── /generate/async 阻塞版：保持 pyworker num_requests_working > 0 直到生成完成 ──
# PATCHED_WORKER_BUSY_BLOCKING_V1
#
# 设计原理：
#   调用内部 /generate/sync（localhost，无代理超时），handler 阻塞到生成完成。
#   pyworker HandlerConfig 在 handler 返回前持续报告 num_requests_working > 0，
#   vast.ai 路由层不会把新任务分配到本 worker，彻底防止 VRAM OOM。
#   客户端（ttv.py）连接会在 60s 代理超时后断开，已有 S3 轮询兜底。
import json as _json_p
import time as _time_p
_async_task_store: dict = {}
_worker_busy: bool = False


@app.post("/generate/async")
async def _generate_async_patched(request: Request):
    global _worker_busy
    from fastapi.responses import JSONResponse as _JR
    if _worker_busy:
        return _JR({"status": "busy", "message": "worker is processing another task"}, status_code=503)
    body = await request.body()
    try:
        _d = _json_p.loads(body)
        _rid = (
            ((_d.get("payload") or {}).get("input") or {}).get("request_id")
            or f"async_{int(_time_p.time() * 1000)}"
        )
    except Exception:
        _rid = f"async_{int(_time_p.time() * 1000)}"
    _async_task_store[_rid] = {"status": "pending"}
    _worker_busy = True
    try:
        import aiohttp as _ah
        # /generate/sync 是 localhost 内部调用，无 60s 代理超时，阻塞到生成完成
        async with _ah.ClientSession(timeout=_ah.ClientTimeout(total=None)) as _s:
            async with _s.post(
                "http://127.0.0.1:18288/generate/sync",
                data=body,
                headers={"Content-Type": "application/json"},
            ) as _r:
                _async_task_store[_rid] = await _r.json()
    except Exception as _e:
        _async_task_store[_rid] = {"status": "failed", "message": str(_e)}
    finally:
        _worker_busy = False
    return {"id": _rid, "status": "pending"}


@app.get("/result/{_result_rid}")
async def _get_async_result(_result_rid: str):
    _r = _async_task_store.get(_result_rid)
    if _r is None:
        from fastapi.responses import JSONResponse as _JR
        return _JR({"status": "not_found"}, status_code=404)
    return _r


# ─────────────────────────────────────────────────────────────────────────────
'''

content = content.replace(orig_marker, injection + orig_marker, 1)

# ── Step 3: 确保 sentinel 存在（文件末尾）────────────────────────────────────
if "PATCHED_WORKER_BUSY_BLOCKING_V1" not in content:
    content += "\n# PATCHED_WORKER_BUSY_BLOCKING_V1\n"

with open(path, "w") as f:
    f.write(content)
print(f"✓ /generate/async 阻塞版已注入 {path}")
