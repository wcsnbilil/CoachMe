# GolfDB 阶段识别基准

用 GolfDB 公开数据集测量 CoachMe 自动识别挥杆阶段的准确率。同时给出两组数字：

- **official**：SwingNet 每个事件取全片概率最大的那一帧，和 GolfDB 论文的 `eval.py` 一致。
- **app**：经过 `SwingNetEventSelector` 之后、App 里用户真正看到的七个候选关键帧；
  App 因顺序矛盾而不给自动标记的挥杆，全部算错，并单独报告比例。

判定容差与论文相同：`max(round((击球帧 − 准备帧) / 30), 1)` 帧。

## 文件

| 文件 | 作用 |
|---|---|
| `swingnet_mil.py` | 直接读取 `CoachMe/Resources` 里 App 实际打包的两个 CoreML 模型。`numpy` 后端在任何系统上用 NumPy 执行模型图；`coreml` 后端在 Mac 上调用真正的 CoreML |
| `app_selector.py` | `CoachMeCore/.../SwingNetEventSelector.swift` 的 Python 移植，两边要同步修改 |
| `test_app_selector.py` | 与 `SwingNetEventSelectorTests.swift` 相同的用例（9/9 通过） |
| `golfdb_eval.py` | 评测脚本 |

## 在 Mac 上跑完整评测

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install coremltools opencv-python-headless numpy pandas

git clone https://github.com/wmcnally/golfdb ~/golfdb
# 按 golfdb README 从 Google Drive 下载 videos_160.zip，解压到 ~/golfdb/data/videos_160/

python tools/benchmark/golfdb_eval.py --golfdb ~/golfdb/data --backend coreml --split 1 --limit 20   # 先小跑
python tools/benchmark/golfdb_eval.py --golfdb ~/golfdb/data --backend coreml --split 1 --out golfdb_split1.json
```

**只能用 split 1 作测试集。** App 打包的 `swingnet_1800` 权重是在 split 2–4 上训练的，
在这些分组上测出的数字偏高，脚本会给出警告。

单个视频（不需要标注）可以这样看 App 会标出哪几帧：

```sh
python tools/benchmark/golfdb_eval.py --video my_swing.mp4 --backend numpy
```

## 已验证的内容（2026-11-03，Linux）

- `numpy` 后端能加载 App 打包的模型并完成推理。在 golfdb 仓库自带的 `test_video.mp4`
  （264 帧）上，App 选出的七帧是 74 / 86 / 98 / 114 / 132 / 143 / 236，顺序正确，
  逐帧目视检查分别对应准备、起杆、上杆中段、顶点、下杆中段、击球、收杆。
- `test_app_selector.py` 9/9 通过。

## 还没验证的

- **完整 GolfDB 评测还没跑。** 视频托管在 Google Drive，这次的云端环境访问不了，需要在 Mac 上下载后运行。
- `coreml` 后端没在 Mac 上跑过；`numpy` 与 `coreml` 两个后端的数值一致性也还没对比。
- 输入用的是 GolfDB 预处理过的 160×160 片段。App 是从原视频自己缩放，两者的插值实现略有不同。
