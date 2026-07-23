#!/usr/bin/env python3
"""MobileNetV1-int8 classification on the RK3588 NPU via Mesa Teflon."""
import argparse, os, statistics, sys, time
import numpy as np
from PIL import Image

try:
    from tflite_runtime.interpreter import Interpreter, load_delegate
except ImportError:
    from ai_edge_litert.interpreter import Interpreter, load_delegate

A = "/opt/assets"
p = argparse.ArgumentParser()
p.add_argument("--image",  default=f"{A}/sample.jpg")
p.add_argument("--model",  default=f"{A}/mobilenet_v1_1.0_224_quant.tflite")
p.add_argument("--labels", default=f"{A}/labels.txt")
p.add_argument("--cpu", action="store_true", help="skip the NPU (baseline)")
p.add_argument("--runs", type=int, default=20)
p.add_argument("--threads", type=int, default=1)
a = p.parse_args()

delegates = []
if a.cpu:
    print("backend: CPU reference")
else:
    path = os.environ.get("TEFLON_DELEGATE", "/usr/local/lib/libteflon.so")
    try:
        delegates = [load_delegate(path)]
    except Exception as e:
        sys.exit(f"could not load delegate {path}: {e}\n"
                 f"is /dev/accel/accel0 passed into the container?")
    print(f"backend: NPU via {path}")

it = Interpreter(model_path=a.model, experimental_delegates=delegates,
                 num_threads=a.threads)
it.allocate_tensors()

inp, out = it.get_input_details()[0], it.get_output_details()[0]
_, h, w, _ = inp["shape"]

img = Image.open(a.image).convert("RGB").resize((w, h), Image.BILINEAR)
x = np.asarray(img, dtype=inp["dtype"])[None, ...]
if inp["dtype"] == np.float32:
    x = (x.astype(np.float32) - 127.5) / 127.5

it.set_tensor(inp["index"], x)
it.invoke()                                  # warm-up: weight upload/compile

t = []
for _ in range(a.runs):
    t0 = time.perf_counter(); it.invoke()
    t.append((time.perf_counter() - t0) * 1e3)

y = it.get_tensor(out["index"])[0].astype(np.float32)
if out["dtype"] == np.uint8:
    s, z = out["quantization"]
    y = (y - z) * (s or 1.0)

labels = [l.strip() for l in open(a.labels)]
print(f"\nmedian {statistics.median(t):.2f} ms  "
      f"min {min(t):.2f}  max {max(t):.2f}  (n={a.runs})\n")
for i in y.argsort()[-5:][::-1]:
    print(f"  {y[i]:7.3f}  {labels[i] if i < len(labels) else i}")