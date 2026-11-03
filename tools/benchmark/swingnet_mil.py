"""Runs CoachMe's shipped SwingNet CoreML packages without CoreML.

The two .mlpackage files in CoachMe/Resources are ML Programs whose op set is
small (conv, clip, add, reduce_mean, transpose, lstm, linear). This module
reads their weights with coremltools (which can parse packages on any OS but
can only *execute* them on macOS) and evaluates the graph in NumPy.

Use it where CoreML is unavailable (Linux, CI). On a Mac, prefer
`--backend coreml` in golfdb_eval.py, which runs the real CoreML runtime, and
use `parity` below to check the two agree.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

RESOURCES = Path(__file__).resolve().parents[2] / "CoachMe" / "Resources"


def _load_program(package: Path):
    import coremltools as ct
    from coremltools.converters.mil.frontend.milproto.load import load

    model = ct.models.MLModel(str(package), skip_model_load=True)
    spec = model.get_spec()
    return load(spec, specification_version=spec.specificationVersion,
                file_weights_dir=model.weights_dir)


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def _conv(x, w, b, stride, pad, groups):
    """x [N,C,H,W], w [O,C/groups,kh,kw]; NCHW cross-correlation like CoreML."""
    n, c, h, wd = x.shape
    o, cg, kh, kw = w.shape
    top, bottom, left, right = pad
    x = np.pad(x, ((0, 0), (0, 0), (top, bottom), (left, right)))
    sh, sw = stride
    oh = (x.shape[2] - kh) // sh + 1
    ow = (x.shape[3] - kw) // sw + 1
    if kh == 1 and kw == 1 and groups == 1:
        xs = x[:, :, ::sh, ::sw][:, :, :oh, :ow]
        y = np.einsum("nchw,oc->nohw", xs, w[:, :, 0, 0], optimize=True)
    else:
        win = np.lib.stride_tricks.sliding_window_view(x, (kh, kw), axis=(2, 3))
        win = win[:, :, ::sh, ::sw][:, :, :oh, :ow]  # [N,C,oh,ow,kh,kw]
        if groups == 1:
            y = np.einsum("nchwij,ocij->nohw", win, w, optimize=True)
        elif groups == c and cg == 1 and o == c:
            y = np.einsum("nchwij,cij->nchw", win, w[:, 0], optimize=True)
        else:
            raise NotImplementedError(f"groups={groups} not used by SwingNet")
    return (y + b[None, :, None, None]).astype(np.float32)


def _lstm_direction(x, w_ih, w_hh, bias, reverse):
    """MIL gate order is input, forget, output, cell (i, f, o, z)."""
    t_len, batch, _ = x.shape
    hidden = w_hh.shape[1]
    h = np.zeros((batch, hidden), np.float32)
    c = np.zeros((batch, hidden), np.float32)
    proj = np.einsum("tbi,gi->tbg", x, w_ih) + bias
    out = np.zeros((t_len, batch, hidden), np.float32)
    steps = range(t_len - 1, -1, -1) if reverse else range(t_len)
    for t in steps:
        g = proj[t] + h @ w_hh.T
        i, f, o, z = np.split(g, 4, axis=1)
        c = _sigmoid(f) * c + _sigmoid(i) * np.tanh(z)
        h = _sigmoid(o) * np.tanh(c)
        out[t] = h
    return out


class _Graph:
    def __init__(self, package: Path):
        fn = _load_program(package).functions["main"]
        self.input = next(iter(fn.inputs))
        self.output = fn.outputs[0].name
        self.ops = [op for op in fn.operations if op.op_type != "const"]

    @staticmethod
    def _value(env, var):
        if var.val is not None:
            return var.val
        return env[var.name]

    def __call__(self, x: np.ndarray) -> np.ndarray:
        env = {self.input: x.astype(np.float32)}
        for op in self.ops:
            a = {k: self._value(env, v) for k, v in op.inputs.items()}
            t = op.op_type
            if t == "conv":
                y = _conv(a["x"], a["weight"], a["bias"], tuple(a["strides"]),
                          tuple(a["pad"]), int(a["groups"]))
            elif t == "clip":
                y = np.clip(a["x"], a["alpha"], a["beta"])
            elif t == "add":
                y = a["x"] + a["y"]
            elif t == "reduce_mean":
                y = a["x"].mean(axis=tuple(int(i) for i in a["axes"]), keepdims=bool(a["keep_dims"]))
            elif t == "transpose":
                y = np.transpose(a["x"], tuple(int(i) for i in a["perm"]))
            elif t == "linear":
                y = a["x"] @ a["weight"].T + a["bias"]
            elif t == "lstm":
                assert a["direction"] == "bidirectional"
                fwd = _lstm_direction(a["x"], a["weight_ih"], a["weight_hh"], a["bias"], False)
                bwd = _lstm_direction(a["x"], a["weight_ih_back"], a["weight_hh_back"], a["bias_back"], True)
                env[op.outputs[0].name] = np.concatenate([fwd, bwd], axis=2)
                continue
            else:
                raise NotImplementedError(t)
            env[op.outputs[0].name] = np.asarray(y, np.float32)
        return env[self.output]


class NumpySwingNet:
    """encode(images [N,3,160,160]) -> [N,1280]; sequence(features [T,1280]) -> logits [T,9]."""

    def __init__(self, resources: Path = RESOURCES):
        self._encoder = _Graph(resources / "SwingNetEncoder.mlpackage")
        self._sequence = _Graph(resources / "SwingNetSequence.mlpackage")

    def encode(self, images: np.ndarray, batch: int = 16) -> np.ndarray:
        return np.concatenate([self._encoder(images[i:i + batch]) for i in range(0, len(images), batch)])

    def sequence(self, features: np.ndarray) -> np.ndarray:
        return self._sequence(features[None])[0]


class CoreMLSwingNet:
    """Same interface, using the real CoreML runtime (macOS only)."""

    def __init__(self, resources: Path = RESOURCES):
        import coremltools as ct
        cpu = ct.ComputeUnit.CPU_ONLY  # the app's parity baseline
        self._encoder = ct.models.MLModel(str(resources / "SwingNetEncoder.mlpackage"), compute_units=cpu)
        self._sequence = ct.models.MLModel(str(resources / "SwingNetSequence.mlpackage"), compute_units=cpu)

    def encode(self, images: np.ndarray, batch: int = 16) -> np.ndarray:
        return np.stack([self._encoder.predict({"image": img[None].astype(np.float32)})["features"][0]
                         for img in images])

    def sequence(self, features: np.ndarray) -> np.ndarray:
        return self._sequence.predict({"features": features[None].astype(np.float32)})["logits"][0]
