# 外下 / 内下 原型（Python 先行，之后移植 Swift）

只用 MediaPipe 2D 关键点 + 准备/顶点/击球三帧，比较同一高度上下杆和上杆双手的位置差（offset，单位=躯干长度）。
offset > 0 = 下杆双手在上杆轨迹靠球一侧（外下），< 0 = 身体一侧（内下）。测的是双手轨迹，不是杆头。

## v2 改了什么（针对第一次 GolfDB 200 杆的问题）

| 问题 | 处理 |
| --- | --- |
| 160px 下手腕抖动、左右手互换导致锯齿轨迹 | 双手距离 > 0.6 躯干的帧丢弃后插值；Hampel 去尖刺；平滑窗口按挥杆帧数缩放 |
| 实时和慢动作同一杆只有 80% 一致 | 平滑窗口按帧数缩放；每个高度取所有交点的中位数，不再只取第一个 |
| 左手球员（Mike Weir）是最大离群值 | 左右方向由双手、鼻子、肩膀、顶点四个线索投票，结果里有 `side_votes` |
| 机位偏离目标线、俯拍 | 准备姿势肩线/髋线太宽（> 0.3 躯干）判 无法判断；俯拍暂时没有检查 |
| 40% 职业球员被判外下 | `calibrate.py` 用职业球员的范围定阈值：职业球员覆盖的范围都算可以（有人故意略外下打 fade），只有超出范围才判 外下过度（易 slice/拉左）或 内下过度（易大左曲/推右）。每个球手只算一次 |

## 结果（GolfDB 沿目标线前 200 杆，Mac，v1 与 v2 用同一批关键点）

| | v1（±0.10） | v2（校准后） |
| --- | --- | --- |
| 外下 / 内下 / 正常 / 无法判断 | 80 / 25 / 92 / 3 | 29 / 20 / 148 / 3 |
| 职业球员判正常 | 46% | 74% |
| 实时 vs 慢动作同一杆一致 | 80%（17 个不一致里 14 个慢动作更外下） | 89%（9 个里 5 个） |
| Lydia Ko 11 杆 | 64% 外下 | 91% 正常 |

上表 v2 列是旧口径（80% 球手判正常）。

**v3（当前）**：下杆和准备姿势时"双手→肩膀"的固定参考线比（叠加图绿线），上杆很内不再算外下；上杆偏离单独报 `backswing_offset`，旧指标保留为 `loop`。
阈值取职业球员范围（单杆，每位球手合计权重 1，覆盖 98%）：外下过度 > 0.142，内下过度 < -0.516，中心 -0.154（职业球员下杆普遍在线的身体一侧）。前 200 杆和全部 400 杆定出来几乎一样。
400 杆结果：范围内 369、外下过度 4、内下过度 3、无法判断 24（机位 21、手腕 3）。留出的后 200 杆超出范围 3 杆（v2 为 13）；实时/慢动作一致 96%。
剩下的极端值里有追踪错误（478）和参考线被机位/俯拍带偏（Lexi 771/772、Kang 267），试过用 `ref_angle`（参考线偏离竖直的角度）过滤：中位数 11.5°，接近竖直的都是正常准备姿势，阈值 4° 会多拒 11% 好片子，所以默认不启用（只记录）。`caution` 只在判定超出范围时给出。

还没解决：追踪跳点（478）、俯拍（Kang 267 只靠 caution 提示）、半正对镜头但肩宽不超线（Lexi 771/772）。机位阈值 0.2（0.3 拦不住目测明显偏的 golfdb_33、361）。俯拍和轻微偏斜仍然拦不住。
阈值是在这 200 杆上定的，上面的数字偏乐观；后 200 杆的留出检查见 PR。
左手：Bubba Watson、Mike Weir、Scott Langley 四票全部判对。Mike Weir 仍是最大外下（0.45–0.54），不是左右手的问题，待目测。

## 重跑同样 200 杆并对比

```bash
# 1. 新版重跑（第一次要跑 MediaPipe；关键点存在 report_v2/landmarks/，以后重跑只要几秒）
python tools/faults/run_path.py --golfdb ~/coachme-bench/golfdb/data --limit 200 --out report_v2

# 2. 用职业球员的范围定阈值（--coverage 0.95 可去掉两端各 2.5% 的极端值），看肩/髋线宽度分布决定机位阈值
python tools/faults/calibrate.py report_v2/results.json --out calibration.json

# 3. 带新阈值再跑一次（秒级；不带 --calibration 就用代码里的默认值）
python tools/faults/run_path.py --golfdb ~/coachme-bench/golfdb/data --limit 200 --out report_v2 \
    --calibration calibration.json   # 需要时加 --max-line-width 0.25

# 4. 前后对比：判定分布、实时/慢动作一致率、同一球手一致性、改变的判定、左手球员
python tools/faults/compare.py report_v1/results.json report_v2/results.json --golfdb ~/coachme-bench/golfdb/data
```

注意：阈值是在这 200 杆上定的，再在同一批上看会偏乐观。想要干净的检查：`run_path.py --limit 400`，`calibrate.py --first 200`，然后看后 200 杆的结果。

合成数据测试：`python tools/faults/test_path_fault.py`
