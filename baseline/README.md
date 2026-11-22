# 回归基准

`golfdb400/` 是 GolfDB 沿目标线前 400 段经 **App 流水线**（解码 + MediaPipe）得到的关键点，加 GolfDB 的标注。不含视频。

| 文件 | 内容 | 谁写的 |
|---|---|---|
| `swings.json`、`landmarks.i16` | 关键点和标注，格式见 `tools/baseline/pack_golfdb.py` | CI 流程「回归基准数据」打包后推到 `baseline-data` 分支，再拷进来 |
| `expected.json` | 逐杆判定快照（判定、拒判原因、结论把握、offset）和由它算出的指标 | `python3 tools/baseline/regress.py --update` |

## 检查

```sh
python3 tools/baseline/regress.py                         # Python 判定与快照逐杆一致
python3 tools/baseline/regress.py --against origin/main   # 一致率不低于 main
swift test --package-path CoachMeCore --filter GolfDB400RegressionTests   # Swift 判定与快照逐杆一致
```

门槛指标是 `pairAgreement`：同一杆的实时和慢动作两个版本得到相同判定的比例。它下降的 PR 不能合并。

改了判定逻辑、结果有意变化时：运行 `--update`，把 `expected.json` 的差异一起提交，在 PR 里列出哪些杆变了、为什么。

## 重新生成关键点

App 的解码或姿态识别变了之后：跑一次「GolfDB App 基准」得到新的 App 关键点，把它的 run id 写进 `tools/e2e/golfdb_reuse_app_run.txt`，「回归基准数据」会重新打包。
