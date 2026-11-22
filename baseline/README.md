# 回归基准

两份数据，都不含视频：

- `golfdb400/`：GolfDB 沿目标线前 400 段经 **App 流水线**（解码 + MediaPipe）得到的关键点，加 GolfDB 的标注。用于外下/内下。
- `golfdb-split1-phases/`：App 打包的 SwingNet 模型在 GolfDB split 1（350 段，模型没在这个 split 上训练过）上的逐帧概率，加 GolfDB 的标注。用于 7 阶段切分。模型推理用 Python 的 numpy 后端，输入是 GolfDB 预处理好的 160×160 片段，不经过 App 自己的解码和缩放。

| 文件 | 内容 | 谁写的 |
|---|---|---|
| `golfdb400/swings.json`、`landmarks.i16` | 关键点和标注，格式见 `tools/baseline/pack_golfdb.py` | CI 流程「回归基准数据」打包后推到 `baseline-data` 分支，再拷进来 |
| `golfdb400/expected.json` | 逐杆判定快照（判定、拒判原因、结论把握、offset）和由它算出的指标 | `python3 tools/baseline/regress.py --update` |
| `golfdb-split1-phases/swings.json`、`probabilities.u16` | 逐帧概率和标注，格式见 `tools/baseline/pack_phases.py` | 同上 |
| `golfdb-split1-phases/expected.json` | 逐段 7 个关键帧的帧号快照和由它算出的指标 | `python3 tools/baseline/regress_phases.py --update` |

## 检查

```sh
python3 tools/baseline/regress.py                         # Python 判定与快照逐杆一致
python3 tools/baseline/regress.py --against origin/main   # 一致率不低于 main
swift test --package-path CoachMeCore --filter GolfDB400RegressionTests   # Swift 判定与快照逐杆一致

python3 tools/baseline/regress_phases.py                         # Python 选帧与快照逐段一致
python3 tools/baseline/regress_phases.py --against origin/main   # 7 阶段准确率不低于 main
swift test --package-path CoachMeCore --filter GolfDBPhaseRegressionTests # Swift 选帧与快照逐段一致
```

门槛指标有两个，任何一个下降的 PR 都不能合并：

- `pairAgreement`：同一杆的实时和慢动作两个版本得到相同外下/内下判定的比例。
- `phaseAccuracy`：7 个阶段的关键帧落在 GolfDB 论文容差（`max(round((击球帧 − 准备帧) / 30), 1)` 帧）内的比例；App 不给关键帧的片段 7 个阶段都算错。

改了判定或选帧逻辑、结果有意变化时：运行对应脚本的 `--update`，把 `expected.json` 的差异一起提交，在 PR 里列出哪些杆变了、为什么。

## 重新生成数据

- App 的解码或姿态识别变了之后：跑一次「GolfDB App 基准」得到新的 App 关键点，把它的 run id 写进 `tools/e2e/golfdb_reuse_app_run.txt`，「回归基准数据」会重新打包 `golfdb400`。
- 换了 SwingNet 模型文件之后：「回归基准数据」会重新跑 split 1 并打包 `golfdb-split1-phases`。
