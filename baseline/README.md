# 回归基准

三份数据，都不含视频：

- `golfdb400/`：GolfDB 沿目标线前 400 段经 **App 流水线**（解码 + MediaPipe）得到的关键点，加 GolfDB 的标注。用于外下/内下。
- `golfdb-split1-negatives/`：从 split 1 每段剪出的「不是一次完整挥杆」的视频（只站着、只到顶点、只有收杆、倒放、静止、两次挥杆连在一起，剪法见 `tools/baseline/pack_negatives.py`），同一个 SwingNet 模型的逐帧概率。用于量 App 会不会在这种视频上照样给关键帧。
- `golfdb-split1-phases/`：App 打包的 SwingNet 模型在 GolfDB split 1（350 段，模型没在这个 split 上训练过）上的逐帧概率，加 GolfDB 的标注。用于 7 阶段切分。模型推理用 Python 的 numpy 后端，输入是 GolfDB 预处理好的 160×160 片段，不经过 App 自己的解码和缩放。

| 文件 | 内容 | 谁写的 |
|---|---|---|
| `golfdb400/swings.json`、`landmarks.i16` | 关键点和标注，格式见 `tools/baseline/pack_golfdb.py` | CI 流程「回归基准数据」打包后推到 `baseline-data` 分支，再拷进来 |
| `golfdb400/expected.json` | 逐杆判定快照（判定、拒判原因、结论把握、offset）和由它算出的指标 | `python3 tools/baseline/regress.py --update` |
| `golfdb-split1-phases/swings.json`、`probabilities.u16` | 逐帧概率和标注，格式见 `tools/baseline/pack_phases.py` | 同上 |
| `golfdb-split1-phases/expected.json` | 逐段 7 个关键帧的帧号快照和由它算出的指标 | `python3 tools/baseline/regress_phases.py --update` |
| `golfdb-split1-negatives/swings.json`、`probabilities.u16` | 逐帧概率，格式见 `tools/baseline/pack_negatives.py` | 同上 |
| `golfdb-split1-negatives/expected.json` | 逐段关键帧快照（不给关键帧的为空）和由它算出的指标 | `python3 tools/baseline/regress_negatives.py --update` |
| `keyframes-to-path/expected.json` | 两份数据都有的片段（目前 89 段）：用识别出的关键帧和用标注的关键帧各判一次外下/内下的快照 | `python3 tools/baseline/regress_keyframes.py --update` |

## 检查

```sh
python3 tools/baseline/regress.py                         # Python 判定与快照逐杆一致
python3 tools/baseline/regress.py --against origin/main   # 一致率不低于 main
swift test --package-path CoachMeCore --filter GolfDB400RegressionTests   # Swift 判定与快照逐杆一致

python3 tools/baseline/regress_phases.py                         # Python 选帧与快照逐段一致
python3 tools/baseline/regress_phases.py --against origin/main   # 7 阶段准确率、挥杆中 5 阶段准确率都不低于 main
swift test --package-path CoachMeCore --filter GolfDBPhaseRegressionTests # Swift 选帧与快照逐段一致

python3 tools/baseline/regress_negatives.py                         # 非完整挥杆的选帧与快照一致
python3 tools/baseline/regress_negatives.py --against origin/main   # 不给关键帧的比例不低于 main

python3 tools/baseline/regress_keyframes.py                         # 识别关键帧 vs 标注关键帧的判定与快照一致
python3 tools/baseline/regress_keyframes.py --against origin/main   # 判定一致率不低于 main
```

门槛指标有四个，任何一个下降的 PR 都不能合并：

- `pairAgreement`：同一杆的实时和慢动作两个版本得到相同外下/内下判定的比例。
- `phaseAccuracy`：7 个阶段的关键帧落在 GolfDB 论文容差（`max(round((击球帧 − 准备帧) / 30), 1)` 帧）内的比例；App 不给关键帧的片段 7 个阶段都算错。
- `motionPhaseAccuracy`：同上，只算挥杆中的 5 个阶段（起杆、上杆中、顶点、下杆中、击球）。准备和收杆落在静止段里，GolfDB 的标注帧本身就不确定；单看总分，一个改动可以拿顶点、击球去换准备帧而不被发现。
- `negativeRejection`：剪出来的非完整挥杆里，App 不给关键帧的比例。两次挥杆连在一起的那种单独列出、不算进去：标出其中一杆暂时可以接受（2026-11-24 决定）。
- `verdictAgreement`：用 App 识别出的准备、顶点、击球帧判外下/内下，和用 GolfDB 标注的这三帧判，结论相同的片段比例。它量的是「关键帧的误差有没有改变用户看到的结论」；`phaseAccuracy` 量的是帧号本身。这一项只有 Python 版，Swift 的选帧和判定各自由上面两项的 Swift 测试对照。

改了判定或选帧逻辑、结果有意变化时：运行对应脚本的 `--update`，把 `expected.json` 的差异一起提交，在 PR 里列出哪些杆变了、为什么。

## 重新生成数据

- App 的解码或姿态识别变了之后：跑一次「GolfDB App 基准」得到新的 App 关键点，把它的 run id 写进 `tools/e2e/golfdb_reuse_app_run.txt`，「回归基准数据」会重新打包 `golfdb400`。
- 换了 SwingNet 模型文件之后：「回归基准数据」会重新跑 split 1 并打包 `golfdb-split1-phases` 和 `golfdb-split1-negatives`。
